-- PlatinumSnd diagnostic harness.
--
-- NOT part of the Spoon's runtime. Nothing in this file is loaded until
-- `spoon.PlatinumSnd:diagnose()` is called, nothing it does survives the run,
-- and no other file changes behaviour because it exists.
--
-- WHAT IT IS FOR. Every line of this Spoon that touches Hammerspoon was
-- written on a machine with no macOS. `docs/mac-verification.md` lists 78
-- manual checks; most of them conflate a DECISION with a PERCEPTION --
-- "clicking a checkbox sounds like a checkbox" is really "the probe returned
-- AXCheckBox and the map chose chkp" (machine-checkable) plus "chkp is the
-- right noise" (ears only). This harness automates every first half it can
-- reach and leaves only the genuinely perceptual questions to a human.
--
-- WHY IT IS ASYNCHRONOUS. The interesting properties -- the hover loop's
-- frame elision, a sustained sound still looping, a window filter firing --
-- only exist while the run loop turns. Anything that blocked with
-- hs.timer.usleep would measure a Spoon that was never allowed to run, and a
-- long block is also exactly what makes macOS disable an event tap. So every
-- step is a queued continuation, each one given a watchdog: a step that hangs
-- is reported and the harness moves on rather than taking the run down.
--
-- SAFETY. Every probe is wrapped, because a broken assumption must produce a
-- [FAIL] line rather than a traceback -- a crashed harness tells us nothing.
-- Everything it touches is put back: cursor position, dry-run mode, the
-- engine's play/sustain/release methods, and the Spoon's running state.

local soundmap = dofile(hs.spoons.resourcePath("soundmap.lua"))
local resolver = dofile(hs.spoons.resourcePath("resolver.lua"))
local rolemap = dofile(hs.spoons.resourcePath("rolemap.lua"))
local axpolicy = dofile(hs.spoons.resourcePath("axpolicy.lua"))

-- Every dial the harness turns, in one place. None of these is a Spoon
-- setting: the Spoon's own constants live in obj.tuning and are read from
-- there wherever a check depends on one.
local C = {
  reportBaseName        = "platinumsnd-diagnostics.txt",
  reportDir             = "/Desktop",     -- relative to $HOME
  reportFallbackDir     = "",             -- $HOME itself, if Desktop is denied

  -- A step that has not finished by this is reported and abandoned. Well
  -- clear of the longest automatic step (the tree walk, ~6 s) so that only a
  -- genuinely stuck call trips it.
  stepTimeoutSeconds    = 45,
  guidedTimeoutSeconds  = 90,
  -- How long a guided step listens after printing its instruction.
  guidedWindowSeconds   = 12,

  -- Let the run loop turn between two things the harness did itself.
  settleSeconds         = 0.3,
  -- Hover ticks to wait after moving the cursor, in units of
  -- tuning.hoverIntervalSeconds. Three ticks is enough for the loop to see
  -- the move, probe, and cache the answer.
  hoverTicks            = 4,
  hoverFloorSeconds     = 0.2,

  -- Accessibility tree walk. Bounded three ways -- nodes, depth and wall
  -- clock -- because an app can publish a tree with tens of thousands of
  -- elements and this must never become the reason Hammerspoon stalls.
  walkMaxNodes          = 2500,
  walkMaxDepth          = 14,
  -- A slice is deliberately small. Each node costs at least one accessibility
  -- round trip into another process, and a slice that overruns its own
  -- interval turns the walk into a run-loop hog -- which is exactly the
  -- condition that gets an event tap disabled by the OS.
  walkNodesPerSlice     = 25,
  walkSliceSeconds      = 0.02,
  walkBudgetSeconds     = 6,
  -- Ignore elements too small to aim the cursor at with any confidence.
  minFrameSide          = 6,

  overlapPlays          = 5,
  overlapSpacingSeconds = 0.06,
  overlapSampleSeconds  = 0.02,
  overlapTailSeconds    = 0.4,
  -- A sustained file is judged still playing well past twice its length.
  sustainWaitMultiple   = 2,
  sustainWaitFloor      = 2,
  sustainWaitCeiling    = 8,
  sustainStopSeconds    = 0.4,

  idleSeconds           = 3,
  jiggleSeconds         = 3,
  sweepSeconds          = 3,
  moveIntervalSeconds   = 0.05,
  jiggleRadiusPx        = 2,
  -- A jiggle target must be comfortably bigger than the jiggle itself.
  jiggleMinSidePx       = 24,
  sweepMarginPx         = 60,
  -- The sweep runs along the menu bar: it is the one horizontal span on any
  -- Mac guaranteed to be tiled with many small, distinctly-framed elements,
  -- which is what a sweep needs in order to defeat the elision on purpose.
  sweepMenuBarOffsetPx  = 10,
  -- Below this the sweep found nothing to cross and the ratio means nothing.
  sweepMinProbes        = 5,
  -- The sweep should out-probe the jiggle by at least this much.
  elisionRatioFloor     = 2,

  consoleWaitSeconds    = 1,
  launchWaitSeconds     = 4,
  finderWaitSeconds     = 1.8,
  -- How often F8 looks at the tape while its scratch file is on disk. The
  -- file comes off as soon as the sound it was created to provoke arrives,
  -- so this is what decides how long it exists in the ordinary case: the
  -- coalesce window plus one poll, rather than the full wait above.
  finderPollSeconds     = 0.1,
  -- The scratch file guided step F8 creates. ONE FIXED NAME, deliberately:
  -- see the scratch section below for why a clock-stamped name could not be
  -- swept up again without globbing a directory of the user's.
  scratchName           = "platinumsnd-diagnostic-scratch.tmp",
  scratchMarker         = "PlatinumSnd diagnostics scratch file; safe to "
                          .. "delete",
  -- Used only if it is installed and NOT already running, launched WITHOUT
  -- activation, and quit again by the exact pid that appeared. Calculator
  -- alone, deliberately: it owns no documents, so quitting it can neither
  -- prompt nor lose anything. An editor here could sit on unsaved work.
  launchBundle          = "com.apple.calculator",
  -- Hard ceiling on the whole run. If the step chain is ever broken badly
  -- enough that it stops advancing, this is what still gives the cursor,
  -- the dry-run flag, the engine's methods and the running state back.
  deadmanSeconds        = 300,
  deadmanGuidedExtra    = 200,
}

-- The roles Phase C hunts for, in report order. `expect` is the role the
-- probe should hand back once axprobe's refinement has run, which is not
-- always the role the walk matched on: a tab is an AXRadioButton until its
-- parent is read, and a close box is an AXButton until its subrole is.
local WANTED = {
  {key = "AXButton",             expect = "AXButton"},
  {key = "AXCheckBox",           expect = "AXCheckBox"},
  {key = "AXRadioButton",        expect = "AXRadioButton"},
  {key = "AXPopUpButton",        expect = "AXPopUpButton"},
  {key = "AXSlider",             expect = "AXSlider"},
  {key = "AXScrollBar",          expect = "AXScrollBar"},
  {key = "AXValueIndicator",     expect = "AXValueIndicator"},
  {key = "AXIncrementor",        expect = "AXIncrementor"},
  {key = "AXDisclosureTriangle", expect = "AXDisclosureTriangle"},
  {key = "AXStaticText",         expect = "AXStaticText"},
  {key = "AXTabGroup",           expect = "AXTabGroup"},
  {key = "AXTab",                expect = "AXTab"},
  {key = "AXCloseButton",        expect = "AXCloseButton"},
}

-- Subroles that make a button something other than a plain button. A window's
-- traffic lights are the first AXButtons in most trees, and the red one
-- refines to AXCloseButton -- so taking the first match would test the close
-- box twice and never test a plain button at all.
local TRAFFIC_LIGHTS = {
  AXCloseButton = true, AXMinimizeButton = true, AXZoomButton = true,
  AXFullScreenButton = true,
}

-- What each source must have let go of by the time stop() returns. Keyed by
-- the registration order init.lua fixes, which Phase G verifies separately
-- rather than assuming.
local TEARDOWN = {
  -- `ctx` on both: the shared context table src_windows publishes
  -- windowDragging into and src_pointer reads. A source still holding one
  -- after stop() is holding a live channel to a source that has stopped.
  {index = 1, name = "src_pointer",
   nils = {"tap", "timer", "probe", "cache", "ctx"},
   falses = {"thumbDragging", "sliderDragging"}},
  {index = 2, name = "src_windows",
   nils = {"tap", "dragTimer", "filter", "volumeWatcher", "appWatcher",
           "paletteIds", "ctx"},
   falses = {"dragging"}},
  {index = 3, name = "src_menus", nils = {"appWatcher", "sweeper"}},
  {index = 4, name = "src_finder",
   nils = {"trashWatcher", "appWatcher", "settleTimer", "observer",
           "gate"}},
  {index = 5, name = "src_keys", nils = {"tap"}},
}

-- Which live field identifies each source while it is running. Phase G uses
-- this to confirm the documented registration order before tearing down.
local SOURCE_MARKERS = {
  {index = 1, name = "src_pointer", field = "probe"},
  {index = 2, name = "src_windows", field = "dragTimer"},
  {index = 3, name = "src_menus",   field = "observers"},
  {index = 4, name = "src_finder",  field = "gate"},
  {index = 5, name = "src_keys",    field = "quietUntil"},
}

-- ---------------------------------------------------------------- helpers

local function clock()
  local ok, t = pcall(hs.timer.secondsSinceEpoch)
  if ok and type(t) == "number" then return t end
  return os.time()
end

-- Every accessibility read in this file goes through one of these two, so a
-- dead element or an unimplemented attribute is a nil rather than a
-- traceback. pcall on the method directly rather than through a closure:
-- one fewer allocation per read, and there are thousands of reads in a walk.
local function att(element, name)
  if not element then return nil end
  local ok, value = pcall(element.attributeValue, element, name)
  if ok then return value end
  return nil
end

-- A METHOD call: object:method(...), guarded.
local function call(object, method, ...)
  if not object or type(object[method]) ~= "function" then return nil end
  local ok, value = pcall(object[method], object, ...)
  if ok then return value end
  return nil
end

-- A plain FUNCTION call, guarded. Deliberately separate from `call` above:
-- Hammerspoon's module-level functions are not methods and reject an extra
-- leading argument outright, so hs.window.focusedWindow() called as if it
-- were hs.window:focusedWindow() fails on argument checking -- silently,
-- through the pcall, which would turn a working API into an empty result.
local function fcall(fn, ...)
  if type(fn) ~= "function" then return nil end
  local ok, value = pcall(fn, ...)
  if ok then return value end
  return nil
end

-- A frame is usable when axpolicy could do anything with it: a table whose
-- x/y/w/h read as numbers. Deliberately the same test axpolicy.isInsideFrame
-- applies, by direct indexing rather than by enumeration -- see B5, where a
-- shape that enumerates differently but indexes correctly is still a pass.
local function usableFrame(frame)
  if type(frame) ~= "table" then return false end
  for _, key in ipairs({"x", "y", "w", "h"}) do
    local ok, value = pcall(function() return frame[key] end)
    if not ok or type(value) ~= "number" then return false end
  end
  return true
end

-- Whether this element is a REPRESENTATIVE example of its role rather than
-- one of the two cases the probe refines into something else. A non-plain
-- match is still kept, provisionally, so that a window whose only buttons are
-- traffic lights reports something rather than nothing.
local function isPlainExample(element, role)
  if role == "AXButton" then
    return TRAFFIC_LIGHTS[att(element, "AXSubrole")] ~= true
  end
  if role == "AXRadioButton" then
    return att(att(element, "AXParent"), "AXRole") ~= "AXTabGroup"
  end
  return true
end

-- The enumerable shape of a value, as key=type pairs. B5 needs to report
-- what AXFrame actually came back as, and hs.inspect on a deep accessibility
-- table is unreadable.
local function shapeText(value, depth)
  depth = depth or 0
  if type(value) ~= "table" then return type(value) end
  local keys = {}
  for k in pairs(value) do table.insert(keys, tostring(k)) end
  table.sort(keys)
  if #keys == 0 then return "{} (no enumerable keys)" end
  local parts = {}
  for _, k in ipairs(keys) do
    local v = value[k]
    if type(v) == "table" and depth < 1 then
      table.insert(parts, k .. "=" .. shapeText(v, depth + 1))
    else
      table.insert(parts, k .. "=" .. type(v))
    end
  end
  return "{" .. table.concat(parts, ", ") .. "}"
end

-- Below shapeText deliberately: an unusable frame is reported by its shape,
-- which is the one thing worth knowing about it.
local function frameText(frame)
  if not usableFrame(frame) then return shapeText(frame) end
  return string.format("{x=%.0f, y=%.0f, w=%.0f, h=%.0f}",
    frame.x, frame.y, frame.w, frame.h)
end

local function mouseGet()
  local ok, point = pcall(hs.mouse.absolutePosition)
  if ok and type(point) == "table" and type(point.x) == "number" then
    return {x = point.x, y = point.y}
  end
  return nil
end

local function mouseSet(x, y)
  return (pcall(hs.mouse.absolutePosition, {x = x, y = y}))
end

local function centreOf(frame)
  return frame.x + frame.w / 2, frame.y + frame.h / 2
end

local function round(n)
  if type(n) ~= "number" then return n end
  return math.floor(n + 0.5)
end

-- ------------------------------------------------------- the scratch file

-- Guided step F8 is the only thing in this harness that writes anywhere but
-- the report, and it writes under the user's Desktop because that is where
-- the Finder source is watching. The run it writes during is one a person is
-- being asked to act in, so BEING INTERRUPTED IS NORMAL -- a reload, a quit,
-- a hand on the wrong key -- and "the run was cut short" is not an excuse for
-- leaving a file of ours behind. It happened once already.
--
-- Four mechanisms, because each closes a hole the others leave open:
--
--   1. the step itself removes the file in the same callback that first sees
--      the sound it was created to provoke (H:guidedFinderFile);
--   2. restore() -- the finally block -- removes it on any error, watchdog
--      or dead man's timer that ends the run early;
--   3. hs.shutdownCallback removes it if the Lua environment is torn down
--      mid-run, chained so that whatever the config had there still runs;
--   4. the NEXT run sweeps it before anything else, and reports having done
--      so.
--
-- (4) exists because (3) cannot be relied on. Hammerspoon documents
-- hs.shutdownCallback as firing when the Lua environment is destroyed,
-- including on a reload -- but a crash, a force quit, or a config that
-- installs its own handler after this one all skip it, and the run that
-- prompted all this was ended by a reload with a file still on the Desktop.
-- A cleanup that only works when the process is shut down politely is not a
-- cleanup.
--
-- (4) is also why the name is FIXED. Whatever destroys the Lua state takes
-- every in-memory record with it -- this file is dofile'd fresh on every
-- :diagnose(), so even the table below is new each run -- which leaves the
-- file on disk as its own record. A clock-stamped name could only be found
-- again by globbing a directory of the user's, and this harness does not
-- glob: it removes ONE known path, and only after reading the first line back
-- and matching the marker it wrote, so a file of theirs that happens to share
-- the name is recognised as not ours and left exactly where it is.
local scratch = {
  path = nil,             -- outstanding: on disk right now, ours to remove
  shutdown = nil,         -- the callback we installed, while one is installed
  previousShutdown = nil, -- whatever was there before, called after ours
}

local function scratchPath()
  return (os.getenv("HOME") or "") .. C.reportDir .. "/" .. C.scratchName
end

-- Ours, by content rather than by name.
--
-- An EMPTY file at this exact path counts as ours too. io.open creates the
-- file before anything is written to it, and a write that fails -- a full
-- disk is the realistic one -- leaves nothing in it: recognising only the
-- marker would strand a zero-byte file of our own making that no sweep could
-- ever pick up. Nothing of the user's is at risk in that rule, because a
-- zero-byte file is not data.
local function isOurScratch(path)
  local file = io.open(path, "r")
  if not file then return false end
  local ok, first = pcall(function() return file:read("l") end)
  pcall(function() file:close() end)
  return ok and (first == C.scratchMarker or first == nil)
end

-- Whether anything is at that path at all, ours or not.
local function scratchExists(path)
  local file = io.open(path, "r")
  if not file then return false end
  pcall(function() file:close() end)
  return true
end

local function disarmShutdownSweep()
  if not scratch.shutdown then return end
  -- Only put ours back if it is still ours to put back: a config that
  -- installed its own during the run keeps it.
  if hs.shutdownCallback == scratch.shutdown then
    hs.shutdownCallback = scratch.previousShutdown
  end
  scratch.shutdown, scratch.previousShutdown = nil, nil
end

local function armShutdownSweep()
  if scratch.shutdown then return end
  scratch.previousShutdown = hs.shutdownCallback
  scratch.shutdown = function()
    if scratch.path and isOurScratch(scratch.path) then
      pcall(os.remove, scratch.path)
    end
    if type(scratch.previousShutdown) == "function" then
      pcall(scratch.previousShutdown)
    end
  end
  hs.shutdownCallback = scratch.shutdown
end

-- Remove the outstanding scratch file NOW, by exact name. Returns nil when
-- there was nothing of ours to remove, true when it went, or false and the
-- reason when it would not go. Called from the step, from restore(), and
-- from the next run's sweep, so it must be safe to call at any time.
local function takeScratch(path)
  path = path or scratch.path
  local outstanding = (path ~= nil) and (path == scratch.path)
  if not path or not isOurScratch(path) then
    if outstanding then scratch.path = nil end
    disarmShutdownSweep()
    return nil
  end
  local ok, err = os.remove(path)
  if ok then
    if outstanding then scratch.path = nil end
    disarmShutdownSweep()
    return true
  end
  return false, tostring(err)
end

-- ------------------------------------------------------------- the harness

local H = {}
H.__index = H

function H.new(obj, opts)
  return setmetatable({
    obj = obj,
    opts = opts or {},
    lines = {},
    problems = {},
    counts = {PASS = 0, FAIL = 0, WARN = 0, SKIP = 0, ["----"] = 0},
    steps = {},
    log = {},        -- the recording shim's tape
    found = {},      -- Phase C: role key -> {element, frame, role}
    swept = {},      -- scratch files a previous run left behind
    scratchLeft = {},-- still on disk at the end, shouted about in the summary
    stepIndex = 0,
  }, H)
end

-- ---- report primitives

function H:raw(text) table.insert(self.lines, text or "") end

function H:heading(text)
  self:raw("")
  self:raw(text)
  self:raw(string.rep("-", #text))
end

function H:note(text) self:raw("       " .. text) end

function H:record(status, id, text)
  local line = string.format("[%s] %-4s %s", status, id, text)
  table.insert(self.lines, line)
  self.counts[status] = (self.counts[status] or 0) + 1
  if status == "FAIL" or status == "WARN" then
    table.insert(self.problems, line)
  end
  return line
end

-- A path this run could not get off disk. Recorded rather than only printed,
-- because the summary shouts about these and the phase body scrolls past.
--
-- False when the path is already on the list, which is how the retry in
-- restore() reports nothing the step has already said: one file, one line,
-- however many times the harness tried to remove it.
function H:scratchStillThere(path, why)
  for _, known in ipairs(self.scratchLeft) do
    if known == path then return false end
  end
  table.insert(self.scratchLeft, path)
  print("PlatinumSnd diagnose: could not remove " .. path
    .. (why and (" (" .. tostring(why) .. ")") or ""))
  return true
end

function H:pass(id, text) return self:record("PASS", id, text) end
function H:fail(id, text) return self:record("FAIL", id, text) end
function H:warn(id, text) return self:record("WARN", id, text) end
function H:skip(id, text) return self:record("SKIP", id, text) end
function H:na(id, text) return self:record("----", id, text) end

-- PASS on a true condition, FAIL otherwise, with one text for both. Keeps a
-- check to one line where the only difference is the verdict.
function H:verdict(ok, id, text)
  if ok then return self:pass(id, text) end
  return self:fail(id, text)
end

-- ---- the recording shim

-- Record what the engine is ASKED to play without changing what it does.
-- Wrapping the instance rather than the Sound metatable keeps the blast
-- radius to this one engine, and rawget remembers whether the instance had a
-- field of its own to put back (it does not, but restoring by assignment
-- would silently leave one behind).
function H:installShim()
  local engine = self.obj and self.obj.engine
  if not engine then return false end
  self.shimmed = engine
  self.shimShadow = {
    play = rawget(engine, "play"),
    sustain = rawget(engine, "sustain"),
    release = rawget(engine, "release"),
  }
  local original = {
    play = engine.play, sustain = engine.sustain, release = engine.release,
  }
  self.shimOriginal = original
  local harness = self
  for _, kind in ipairs({"play", "sustain", "release"}) do
    engine[kind] = function(target, semantic)
      table.insert(harness.log, {
        at = clock(), kind = kind, semantic = semantic,
        base = soundmap.bases[semantic],
      })
      return original[kind](target, semantic)
    end
  end
  return true
end

function H:removeShim()
  if not self.shimmed then return end
  for _, kind in ipairs({"play", "sustain", "release"}) do
    self.shimmed[kind] = self.shimShadow[kind]
  end
  self.shimmed = nil
end

function H:mark() return #self.log end

function H:since(mark)
  local out = {}
  for i = (mark or 0) + 1, #self.log do table.insert(out, self.log[i]) end
  return out
end

local function tapeText(entries)
  if #entries == 0 then return "nothing" end
  local parts = {}
  for _, entry in ipairs(entries) do
    table.insert(parts, string.format("%s %s(%s)", entry.kind,
      tostring(entry.semantic), tostring(entry.base)))
  end
  return table.concat(parts, ", ")
end

local function tapeHas(entries, semantic)
  for _, entry in ipairs(entries) do
    if entry.semantic == semantic then return true end
  end
  return false
end

-- ---- the step queue

function H:add(name, fn, timeout)
  table.insert(self.steps, {name = name, fn = fn, timeout = timeout})
end

-- One step, then the next on a fresh run loop turn. The turn matters twice
-- over: it keeps a long chain from becoming one deep recursion, and it gives
-- the Spoon's own timers -- the hover loop above all -- room to run between
-- the things this harness does to them.
function H:runStep(index)
  -- Wrapped whole. A failure INSIDE the machinery -- not inside a step, which
  -- is guarded below, but in the guarding itself -- would otherwise stop the
  -- chain advancing with the cursor moved and the engine still shimmed. Any
  -- such failure ends the run properly instead.
  local ok, err = pcall(function() self:runStepGuarded(index) end)
  if not ok then
    pcall(function()
      self:fail("!!", "the harness itself failed: " .. tostring(err))
    end)
    self:finish()
  end
end

function H:runStepGuarded(index)
  local step = self.steps[index]
  if not step then return self:finish() end

  local advanced = false
  local watchdog
  local function advance()
    if advanced then return end
    advanced = true
    if watchdog then pcall(function() watchdog:stop() end) end
    hs.timer.doAfter(0, function() self:runStep(index + 1) end)
  end

  local limit = step.timeout or C.stepTimeoutSeconds
  watchdog = hs.timer.doAfter(limit, function()
    if advanced then return end
    self:fail(step.name, string.format(
      "step did not finish within %ds and was abandoned", limit))
    advance()
  end)

  local ok, err = pcall(step.fn, self, advance)
  if not ok then
    self:fail(step.name, "step errored: " .. tostring(err))
    advance()
  end
end

local function delayOf(opts)
  local delay = tonumber((opts or {}).delay) or 0
  if delay < 0 then return 0 end
  return delay
end

-- Wait, then continue. Every pause in the harness goes through this so that
-- none of them is ever a blocking sleep.
local function after(seconds, fn)
  return hs.timer.doAfter(seconds, function()
    local ok, err = pcall(fn)
    if not ok then print("PlatinumSnd diagnose: " .. tostring(err)) end
  end)
end

-- ===================================================================== A

function H:phaseA(done)
  self:heading("Phase A -- environment and assets")

  -- What the entry sweep found, if anything. No line at all when there was
  -- nothing to sweep: this is a report of something that happened, not a
  -- check that can pass.
  for _, item in ipairs(self.swept) do
    if item.foreign then
      self:warn("A0", "a file with this harness's scratch name is on your "
        .. "Desktop but was NOT written by it, so it has been left alone: "
        .. item.path .. " -- guided step F8 will not run while it is there")
    elseif item.removed then
      self:warn("A0", "an earlier run was interrupted before it could remove "
        .. "its scratch file. This run removed it: " .. item.path)
    elseif self:scratchStillThere(item.path, item.err) then
      self:fail("A0", "an earlier run left its scratch file behind and this "
        .. "run could not remove it either: " .. item.path .. " ("
        .. tostring(item.err) .. ") -- delete it yourself")
    end
  end

  local osVersion = self.env.osVersion
  self:verdict(osVersion ~= nil, "A1", "macOS version: " .. tostring(osVersion))
  self:verdict(self.env.hsVersion ~= nil, "A2",
    "Hammerspoon version: " .. tostring(self.env.hsVersion))
  self:verdict(self.env.luaVersion ~= nil, "A3",
    "Lua version: " .. tostring(self.env.luaVersion))
  self:verdict(self.obj.version ~= nil, "A4",
    "PlatinumSnd version: " .. tostring(self.obj.version))

  local axOk = self.env.accessibility
  if axOk then
    self:pass("A5", "Accessibility permission granted")
  else
    self:fail("A5", "Accessibility permission NOT granted -- every "
      .. "accessibility check below is meaningless without it")
  end

  -- Full Disk Access has no API to interrogate, so the proxy is the thing
  -- that actually breaks without it: whether the TCC-protected directories
  -- the Finder source watches can be enumerated at all.
  local home = os.getenv("HOME") or ""
  local dirs = {"/Desktop", "/Documents", "/Downloads", "/.Trash"}
  for i, suffix in ipairs(dirs) do
    local path = home .. suffix
    local id = "A" .. tostring(5 + i)
    local ok, iter, data = pcall(hs.fs.dir, path)
    if not ok or type(iter) ~= "function" then
      self:fail(id, string.format("cannot enumerate %s (%s) -- Full Disk "
        .. "Access is probably missing", path, tostring(iter)))
    else
      local n = 0
      local counted = pcall(function()
        for _ in iter, data do n = n + 1 end
      end)
      if counted then
        self:pass(id, string.format("%s enumerates (%d entries)", path, n))
      else
        self:fail(id, path .. " opened but could not be walked")
      end
    end
  end

  -- The constants that were actually in play, printed in full. A tuning
  -- value read back wrong is invisible in every other check here.
  self:pass("A10", "obj.tuning dump follows")
  local keys = {}
  for k in pairs(self.obj.tuning or {}) do table.insert(keys, k) end
  table.sort(keys)
  for _, k in ipairs(keys) do
    local v = self.obj.tuning[k]
    if type(v) == "table" then
      local parts = {}
      for _, item in ipairs(v) do table.insert(parts, tostring(item)) end
      v = "{" .. table.concat(parts, ", ") .. "}"
    end
    self:note(string.format("%-28s %s", k, tostring(v)))
  end

  -- Every base name against the real filesystem, and which container each
  -- one landed in. The claim under test is 67 WAV plus `bevp` to MP3.
  local root = hs.spoons.resourcePath("snd")
  local total, wav, mp3, unresolved, wrongKind = 0, 0, 0, {}, {}
  local names = {}
  for semantic in pairs(soundmap.bases) do table.insert(names, semantic) end
  table.sort(names)
  for _, semantic in ipairs(names) do
    local base = soundmap.bases[semantic]
    total = total + 1
    local path = resolver.resolve(root, base, function(candidate)
      return hs.fs.attributes(candidate, "mode") == "file"
    end)
    if not path then
      table.insert(unresolved, semantic .. " (" .. tostring(base) .. ")")
    elseif path:sub(-4) == ".wav" then
      wav = wav + 1
      if base == "bevp" then
        table.insert(wrongKind, "bevp resolved to WAV, expected MP3")
      end
    else
      mp3 = mp3 + 1
      if base ~= "bevp" then
        table.insert(wrongKind, base .. " resolved to MP3, expected WAV")
      end
    end
  end
  self:verdict(#unresolved == 0, "A11", string.format(
    "%d/%d pack base names resolve against %s", total - #unresolved, total,
    root))
  for _, name in ipairs(unresolved) do self:note("unresolved: " .. name) end
  self:verdict(#wrongKind == 0, "A12", string.format(
    "container split: %d WAV, %d MP3 (expected %d WAV and bevp alone as MP3)",
    wav, mp3, total - 1))
  for _, text in ipairs(wrongKind) do self:note(text) end

  -- What the engine actually built out of that, which is a different
  -- question: hs.sound.getByFile can return nil for a path that exists, and
  -- the engine swallows that with no log and no entry in `missing`.
  local engine = self.obj.engine
  local pools, sustainers, emptyPools = 0, 0, {}
  for semantic, pool in pairs(engine and engine.pools or {}) do
    pools = pools + 1
    if #(pool.objects or {}) == 0 then table.insert(emptyPools, semantic) end
  end
  for _ in pairs(engine and engine.sustainers or {}) do
    sustainers = sustainers + 1
  end
  local expectedSustainers = 0
  for _ in pairs(soundmap.sustained) do
    expectedSustainers = expectedSustainers + 1
  end
  local built = pools + sustainers
  self:verdict(built == total - #unresolved, "A13", string.format(
    "engine built %d one-shot pools and %d sustainers (%d of %d resolvable "
    .. "names)%s", pools, sustainers, built, total - #unresolved,
    self.obj.running and ""
      or " -- the Spoon is not running, so load() has never been called"))
  self:verdict(sustainers == expectedSustainers, "A14", string.format(
    "%d of %d sustained names became looping sounds", sustainers,
    expectedSustainers))
  for _, semantic in ipairs(emptyPools) do
    self:note("pool with no sound objects: " .. semantic)
  end
  done()
end

-- ===================================================================== B

function H:phaseB1(done)
  self:heading("Phase B -- API assumptions that would invalidate the design")

  -- B1 to B8 need accessibility; B9 to B11 are sound checks and do not, so
  -- every bail-out below falls through to them rather than returning.
  local function skipRest(from, why)
    for i = from, 8 do self:na("B" .. i, "not tested: " .. why) end
  end

  if not self.env.accessibility then
    skipRest(1, "Accessibility permission is not granted")
    return self:phaseB2(done)
  end

  local ok, sys = pcall(hs.axuielement.systemWideElement)
  self.sys = ok and sys or nil
  self:verdict(self.sys ~= nil, "B1", string.format(
    "hs.axuielement.systemWideElement() returned %s",
    ok and tostring(sys) or ("an error: " .. tostring(sys))))
  if not self.sys then
    skipRest(2, "no system-wide element to ask")
    return self:phaseB2(done)
  end

  -- The AX messaging timeout is a PROCESS-GLOBAL mutation, which makes both
  -- halves of this check awkward.
  --
  -- Setting it is what the check is for, but the harness must not leave one
  -- behind. When the Spoon is running the bound is already installed and
  -- owned by the Spoon, so setting the same value again changes nothing and
  -- there is nothing to give back. When the Spoon is stopped, this call is
  -- the only thing that installed it, and restore() hands it back with 0.0.
  local timeout = (self.obj.tuning or {}).axTimeoutSeconds
  local ownedBySpoon = self.obj.running == true
  local setOk, setResult = pcall(self.sys.setTimeout, self.sys, timeout)
  if setOk and not ownedBySpoon then self.axTimeoutOurs = true end
  self:verdict(setOk, "B2", string.format(
    ":setTimeout(%s) on the system-wide element %s", tostring(timeout),
    setOk and ("returned " .. tostring(setResult))
      or ("errored: " .. tostring(setResult))))

  -- WHERE the bound is installed, which the whole-branch review flagged: it
  -- used to be `axprobe.new`, which worked only because the pointer source
  -- happens to be registered first, while three other sources depended on it
  -- without knowing. The fix moves it to obj:start(). Both arrangements are
  -- recognised here, so this line says which one is actually in the code
  -- being diagnosed rather than which one was expected.
  local probe = ((self.obj.sources or {})[1] or {}).probe
  local ax = self.obj.axprobe
  local holders = {}
  if type(ax) == "table" and type(ax.installTimeout) == "function"
    and type(ax.resetTimeout) == "function" then
    table.insert(holders,
      "obj:start() via axprobe.installTimeout (the owner it should have)")
  end
  -- Discriminated on Probe:release, not on probe.sys: the probe still holds a
  -- system-wide element for its hit-test under either arrangement, so holding
  -- one says nothing. Owning the bound is what release() undoes, and its
  -- existence is what says the probe still owns it.
  if probe ~= nil and type(probe.release) == "function" then
    table.insert(holders,
      "sources[1].probe (axprobe.new + Probe:release -- the arrangement the "
      .. "review flagged; a pointer source that fails to start unbounds the "
      .. "other three)")
  end
  if #holders == 0 then
    table.insert(holders, "nowhere this harness could find")
  end
  self:verdict(#holders == 1 and (ownedBySpoon or self.axTimeoutOurs == true),
    "B2+", string.format("the %ss AX messaging bound is installed by: %s -- "
      .. "in force: %s", tostring(timeout), table.concat(holders, " AND "),
      tostring(ownedBySpoon or self.axTimeoutOurs == true)))
  self:note("process-global: it applies to hs.window, hs.uielement and every "
    .. "other AX consumer in Hammerspoon, not just this Spoon. macOS "
    .. "publishes no getter, so 'in force' is read from who installed it, "
    .. "never from the value")

  local point = mouseGet()
  if not point then
    skipRest(3, "the cursor position could not be read")
    return self:phaseB2(done)
  end

  local hit, element = pcall(self.sys.elementAtPosition, self.sys,
                             point.x, point.y)
  element = hit and element or nil
  self:verdict(element ~= nil, "B3", string.format(
    "elementAtPosition(%d, %d) returned %s", round(point.x), round(point.y),
    element and tostring(element) or "nothing"))
  if not element then
    skipRest(4, "no element under the cursor")
    return self:phaseB2(done)
  end

  local role = att(element, "AXRole")
  self:verdict(type(role) == "string", "B4", string.format(
    "AXRole on that element is %s (%s)", tostring(role), type(role)))

  -- The whole frame elision assumes a flat table indexable as x/y/w/h. A
  -- shape that enumerates as origin/size but indexes correctly would still
  -- work; one that does not index is a redesign, so both are reported.
  local frame = att(element, "AXFrame")
  local indexable = usableFrame(frame)
  self:verdict(indexable, "B5", string.format(
    "AXFrame indexes as flat numeric x/y/w/h: %s", tostring(indexable)))
  self:note("enumerable shape: " .. shapeText(frame))
  self:note("direct index: " .. (indexable and frameText(frame)
    or string.format("x=%s y=%s w=%s h=%s",
      type(type(frame) == "table" and frame.x or nil),
      type(type(frame) == "table" and frame.y or nil),
      type(type(frame) == "table" and frame.w or nil),
      type(type(frame) == "table" and frame.h or nil))))
  self:note("metatable present: "
    .. tostring(type(frame) == "table" and getmetatable(frame) ~= nil))

  -- Coordinate agreement on the screen the cursor is already on.
  local inside = axpolicy.isInsideFrame(frame, point.x, point.y)
  self:verdict(inside, "B6", string.format(
    "cursor (%d, %d) falls inside the AXFrame %s of the element under it",
    round(point.x), round(point.y), frameText(frame)))

  local pid = call(element, "pid")
  self:verdict(type(pid) == "number", "B7", string.format(
    "element:pid() returned %s (%s)", tostring(pid), type(pid)))

  -- The close box refinement's whole basis: the red traffic light is an
  -- AXButton whose AXSubrole is AXCloseButton.
  local win = fcall(hs.window.focusedWindow)
  local winElement = win and fcall(hs.axuielement.windowElement, win)
  local closeBox = winElement and att(winElement, "AXCloseButton")
  if not closeBox then
    self:na("B8", "the focused window published no AXCloseButton "
      .. "(focused window: " .. tostring(win and call(win, "title")) .. ")")
  else
    local closeRole = att(closeBox, "AXRole")
    local closeSubrole = att(closeBox, "AXSubrole")
    local refined = axpolicy.refinedRole(closeRole, closeSubrole)
    self:verdict(refined == "AXCloseButton", "B8", string.format(
      "close box reports AXRole=%s AXSubrole=%s, refines to %s",
      tostring(closeRole), tostring(closeSubrole), tostring(refined)))
    local frameCB = att(closeBox, "AXFrame")
    if usableFrame(frameCB) and closeRole then
      self.found["AXCloseButton"] = {
        element = closeBox, frame = frameCB, role = closeRole,
      }
    end
  end
  return self:phaseB2(done)
end

-- Sound behaviour: the only two checks in the harness that make a noise,
-- because there is no other way to ask NSSound whether it overlapped or
-- whether it looped.
function H:phaseB2(done)
  local engine = self.obj.engine
  if not engine or not engine.pools then
    self:na("B9", "not tested: no engine")
    self:na("B10", "not tested: no engine")
    self:na("B11", "not tested: no engine")
    return done()
  end

  -- The longest pooled one-shot, because five plays 60 ms apart can only
  -- overlap if the file outlasts the spacing. Grading a 78 ms click as a
  -- pooling failure would be the harness's own fault.
  local best, bestDuration = nil, -1
  for semantic, pool in pairs(engine.pools) do
    local snd = (pool.objects or {})[1]
    local duration = snd and call(snd, "duration")
    if type(duration) == "number" and duration > bestDuration then
      best, bestDuration = semantic, duration
    end
  end
  if not best then
    self:na("B9", "not tested: no pooled sound reported a duration")
    return self:phaseB3(done)
  end

  local pool = engine.pools[best]
  local wasDryRun = engine.isDryRun
  engine:dryRun(false)
  local maxAlive = 0
  -- Held on self, like every repeating timer here: the harness itself is
  -- rooted on the Spoon for the duration of the run, so nothing the run
  -- depends on can be collected out from under it mid-step.
  local sampler = hs.timer.doEvery(C.overlapSampleSeconds, function()
    local alive = 0
    for _, snd in ipairs(pool.objects or {}) do
      if call(snd, "isPlaying") then alive = alive + 1 end
    end
    if alive > maxAlive then maxAlive = alive end
  end)
  self.timers = {sampler}
  for i = 1, C.overlapPlays do
    after((i - 1) * C.overlapSpacingSeconds, function()
      engine:play(best)
    end)
  end
  local window = C.overlapPlays * C.overlapSpacingSeconds + bestDuration
    + C.overlapTailSeconds
  after(window, function()
    pcall(function() sampler:stop() end)
    engine:dryRun(wasDryRun)
    local text = string.format(
      "%s (%s, %.2f s) played %d times %d ms apart: at most %d of %d pool "
      .. "objects playing at once", best, tostring(soundmap.bases[best]),
      bestDuration, C.overlapPlays, round(C.overlapSpacingSeconds * 1000),
      maxAlive, #(pool.objects or {}))
    if maxAlive >= 2 then
      self:pass("B9", text)
    elseif maxAlive == 1 and bestDuration <= C.overlapSpacingSeconds then
      self:na("B9", text .. " -- inconclusive: the file is shorter than the "
        .. "spacing, so no overlap was possible")
    elseif maxAlive == 0 then
      self:fail("B9", text .. " -- nothing played at all")
    else
      self:fail("B9", text .. " -- pooling is not overlapping")
    end
    self:phaseB3(done)
  end)
end

function H:phaseB3(done)
  local engine = self.obj.engine
  local semantic = "window.move"
  local snd = (engine.sustainers or {})[semantic]
  if not snd then
    self:na("B10", "not tested: no sustainer built for " .. semantic)
    self:na("B11", "not tested: no sustainer built for " .. semantic)
    return done()
  end
  local duration = call(snd, "duration") or 0
  local wait = math.max(C.sustainWaitFloor, duration * C.sustainWaitMultiple)
  wait = math.min(wait, C.sustainWaitCeiling)

  local wasDryRun = engine.isDryRun
  engine:dryRun(false)
  engine:sustain(semantic)
  after(wait, function()
    local playing = call(snd, "isPlaying")
    self:verdict(playing == true, "B10", string.format(
      "%s (%s, %.2f s) still playing %.1f s after sustain: %s -- loopSound "
      .. "%s taking effect", semantic, tostring(soundmap.bases[semantic]),
      duration, wait, tostring(playing), playing and "is" or "is NOT"))
    engine:release(semantic)
    after(C.sustainStopSeconds, function()
      local stillPlaying = call(snd, "isPlaying")
      self:verdict(stillPlaying == false, "B11", string.format(
        "release stopped it: isPlaying is %s", tostring(stillPlaying)))
      engine:dryRun(wasDryRun)
      done()
    end)
  end)
end

-- Screens, and the coordinate agreement question nobody has been able to
-- test: a display placed above or to the left of the primary puts the origin
-- negative, and the hover cache rests entirely on AX and hs.mouse agreeing
-- about what those numbers mean.
function H:phaseBScreens(done)
  local ok, screens = pcall(hs.screen.allScreens)
  if not ok or type(screens) ~= "table" then
    self:na("B12", "hs.screen.allScreens() gave nothing to enumerate")
    return done()
  end
  local primary = fcall(hs.screen.primaryScreen)
  local primaryId = primary and call(primary, "id")
  local negative = nil
  self:pass("B12", string.format("%d screen(s) enumerated", #screens))
  for i, screen in ipairs(screens) do
    local full = call(screen, "fullFrame")
    local frame = call(screen, "frame")
    local id = call(screen, "id")
    self:note(string.format("screen %d %-28s full=%s visible=%s%s", i,
      '"' .. tostring(call(screen, "name")) .. '"', frameText(full),
      frameText(frame), (id and id == primaryId) and " [primary]" or ""))
    if usableFrame(full) and (full.x < 0 or full.y < 0) and not negative then
      negative = {screen = screen, full = full, index = i}
    end
  end

  if not negative then
    self:na("B13", "no screen has a negative origin, so the multi-display "
      .. "coordinate assumption stays untested -- place a second display "
      .. "above or to the left of the primary and re-run")
    return done()
  end
  if not self.sys then
    self:na("B13", "not tested: no system-wide element to ask")
    return done()
  end

  local x, y = centreOf(negative.full)
  if not mouseSet(x, y) then
    self:fail("B13", "the cursor could not be moved onto screen "
      .. tostring(negative.index))
    return done()
  end
  after(C.settleSeconds, function()
    local point = mouseGet() or {x = x, y = y}
    local hit, element = pcall(self.sys.elementAtPosition, self.sys,
                               point.x, point.y)
    element = hit and element or nil
    if not element then
      self:warn("B13", string.format(
        "no element at (%d, %d) on the negative-origin screen, so "
        .. "containment could not be judged there", round(point.x),
        round(point.y)))
      return done()
    end
    local frame = att(element, "AXFrame")
    local inside = axpolicy.isInsideFrame(frame, point.x, point.y)
    self:verdict(inside, "B13", string.format(
      "negative-origin screen %d: cursor (%d, %d) inside %s of %s -- %s",
      negative.index, round(point.x), round(point.y), frameText(frame),
      tostring(att(element, "AXRole")),
      inside and "AX and hs.mouse agree" or
        "AX and hs.mouse DISAGREE about the origin"))
    done()
  end)
end

-- ===================================================================== C

-- Walk the focused application's tree in slices, so the run loop keeps
-- turning and a huge tree cannot stall Hammerspoon. Bounded by nodes, by
-- depth and by wall clock, whichever comes first.
function H:walk(root, callback)
  local queue, head, visited = {{element = root, depth = 0}}, 1, 0
  local deadline = clock() + C.walkBudgetSeconds
  local timer
  local function slice()
    local processed = 0
    while processed < C.walkNodesPerSlice do
      if head > #queue or visited >= C.walkMaxNodes or clock() > deadline then
        pcall(function() timer:stop() end)
        return callback(visited, head > #queue)
      end
      local item = queue[head]
      head = head + 1
      processed = processed + 1
      visited = visited + 1

      -- One attribute read per node in the common case. The frame is the
      -- expensive half and it is only ever wanted for a role this phase is
      -- hunting, and only for the first example of it, so everything else
      -- costs exactly one round trip.
      local role = att(item.element, "AXRole")
      local existing = type(role) == "string" and self.found[role] or nil
      -- Wanted while there is no example yet, and still wanted while the one
      -- held is only provisional -- a close box standing in for a plain
      -- button gets replaced the moment a real one turns up.
      local wanted = type(role) == "string" and self.wantedKeys[role]
        and (existing == nil or existing.provisional == true)
      local interesting = wanted
        or (role == "AXTabGroup" and self.found["AXTab"] == nil)
      if interesting then
        local frame = att(item.element, "AXFrame")
        if usableFrame(frame) and frame.w >= C.minFrameSide
          and frame.h >= C.minFrameSide then
          local plain = wanted and isPlainExample(item.element, role)
          if wanted and (existing == nil or plain) then
            self.found[role] = {element = item.element, frame = frame,
                                role = role, provisional = not plain}
          end
          -- A tab is an AXRadioButton whose parent is an AXTabGroup, so the
          -- only place to recognise one is from the group down.
          if role == "AXTabGroup" and self.found["AXTab"] == nil then
            for _, child in ipairs(att(item.element, "AXChildren") or {}) do
              if att(child, "AXRole") == "AXRadioButton" then
                local childFrame = att(child, "AXFrame")
                if usableFrame(childFrame)
                  and childFrame.w >= C.minFrameSide then
                  self.found["AXTab"] = {element = child, frame = childFrame,
                                         role = "AXRadioButton"}
                  break
                end
              end
            end
          end
        end
      end

      if item.depth < C.walkMaxDepth then
        for _, child in ipairs(att(item.element, "AXChildren") or {}) do
          table.insert(queue, {element = child, depth = item.depth + 1})
        end
      end
    end
  end
  timer = hs.timer.doEvery(C.walkSliceSeconds, function()
    local ok, err = pcall(slice)
    if not ok then
      pcall(function() timer:stop() end)
      callback(visited, false, tostring(err))
    end
  end)
  self.timers = {timer}
end

function H:phaseC(done)
  self:heading("Phase C -- the decision chain over real UI, without clicking")

  if not self.env.accessibility or not self.obj.running then
    self:na("C0", "not tested: the Spoon is not running with Accessibility")
    return done()
  end

  self.wantedKeys = {}
  for _, item in ipairs(WANTED) do self.wantedKeys[item.key] = true end

  local app = fcall(hs.application.frontmostApplication)
  local appName = app and call(app, "name") or "unknown"
  local root = app and fcall(hs.axuielement.applicationElement, app)
  if not root then
    self:na("C0", "not tested: no accessibility element for the frontmost "
      .. "application (" .. tostring(appName) .. ")")
    return done()
  end

  print("PlatinumSnd diagnose: walking " .. tostring(appName) .. " ...")
  self:walk(root, function(visited, exhausted, err)
    self:pass("C0", string.format(
      "walked %d elements of the frontmost application %q%s", visited,
      tostring(appName), exhausted and " (whole tree)" or " (bounded early)"))
    if err then self:note("walk stopped on: " .. err) end
    self:note("roles not present in this app are a coverage gap in the test, "
      .. "not a failure -- re-run with a richer app frontmost using "
      .. "spoon.PlatinumSnd:diagnose({delay = 10})")
    self:hoverEach(1, done)
  end)
end

-- Divergences between the role the walk matched and the role the probe
-- answered that are the design working rather than a defect.
--
-- Keyed walked-role -> observed-role. `when`, where present, must also agree
-- that the refinement had a reason to fire on THIS element, so that an
-- unexplained AXTab still warns: a plain radio button that probes as a tab
-- would be a real bug and this table must not swallow it.
local EXPLAINED = {
  AXRadioButton = {
    AXTab = {
      when = function(entry)
        return att(att(entry.element, "AXParent"), "AXRole") == "AXTabGroup"
      end,
      why = "a macOS tab IS an AXRadioButton inside an AXTabGroup, and this "
        .. "one is. axpolicy.refinedRole promoted it to the synthetic AXTab "
        .. "so tabs get the pack's tab sounds instead of borrowing the radio "
        .. "button's -- the refinement fired exactly as designed",
    },
  },
  AXTabGroup = {
    AXTab = {
      why = "the centre of an AXTabGroup is a tab. The tabs tile the group, "
        .. "so a hit test aimed at the middle of it lands on one, and that "
        .. "tab refines to AXTab -- the refinement fired as designed. The "
        .. "group answers for itself only where no tab covers it",
    },
  },
}

-- Why a scroll bar and its thumb so often probe as whatever is behind them.
-- Genuinely unexplained until this was understood, and still a WARN, because
-- the check cannot measure what it is for until the setting changes.
local OVERLAY_SCROLLBARS =
  "macOS overlay scroll bars are published in the accessibility tree even "
  .. "while they are hidden, but they are not HIT-TESTABLE while hidden, so "
  .. "the probe falls through to the container behind them. That is an "
  .. "appearance setting rather than a defect in this Spoon: System Settings "
  .. "> Appearance > \"Show scroll bars: Always\" makes them persistent and "
  .. "hittable, and this check then measures what it is for"

local HINTS = {
  AXScrollBar = OVERLAY_SCROLLBARS,
  AXValueIndicator = OVERLAY_SCROLLBARS,
}

-- Move to each found element in turn, let the hover loop take a tick, and
-- record what the probe answered and what the maps would do with it. No
-- clicking: press and release semantics are read out of rolemap rather than
-- produced by a real button-down, which is the whole point -- the decision is
-- machine-checkable even though the noise is not.
function H:hoverEach(index, done)
  local item = WANTED[index]
  if not item then
    if self.cursorHome then
      mouseSet(self.cursorHome.x, self.cursorHome.y)
    end
    return done()
  end
  local id = "C" .. tostring(index)
  local entry = self.found[item.key]
  if not entry then
    self:na(id, item.key .. ": not present in the walked app, not tested")
    return self:hoverEach(index + 1, done)
  end

  local x, y = centreOf(entry.frame)
  if not mouseSet(x, y) then
    self:fail(id, item.key .. ": the cursor could not be moved to its centre")
    return self:hoverEach(index + 1, done)
  end

  local tuning = self.obj.tuning or {}
  local wait = math.max(C.hoverFloorSeconds,
    (tuning.hoverIntervalSeconds or 0.06) * C.hoverTicks)
  after(wait, function()
    local source = (self.obj.sources or {})[1]
    local cache = source and source.cache
    local role, via = nil, "direct probe"
    local tolerance = tuning.cacheTolerancePx or 4
    if cache and math.abs((cache.x or -1e9) - x) <= tolerance
      and math.abs((cache.y or -1e9) - y) <= tolerance then
      role, via = cache.role, "hover cache"
    elseif source and source.probe then
      role = (call(source.probe, "roleAt", x, y))
    end

    local text = string.format("%-20s -> %-18s (%s, %s)", item.key,
      tostring(role), rolemap.isLeafRole(role) and "leaf" or "container", via)
    local explained = ((EXPLAINED[item.key] or {})[role])
    if explained and explained.when then
      local ok, agreed = pcall(explained.when, entry)
      if not (ok and agreed) then explained = nil end
    end
    if role == nil then
      self:fail(id, text .. " -- the probe answered nothing at its centre")
    elseif role == item.expect then
      self:pass(id, text)
    elseif explained then
      self:pass(id, text .. string.format(
        " -- %s as designed: %s", item.key .. " -> " .. tostring(role),
        explained.why))
    else
      self:warn(id, text .. string.format(
        " -- the walk matched %s but the probe at its centre answered %s",
        item.key, tostring(role))
        .. (HINTS[item.key] and (". " .. HINTS[item.key]) or ""))
    end
    self:note("  frame " .. frameText(entry.frame)
      .. "  raw AXRole " .. tostring(entry.role)
      .. (entry.provisional and "  [no plain example of this role was on "
          .. "screen; this one refines into something else]" or ""))
    self:note("  " .. self:semanticsText(role, entry.frame))
    self:hoverEach(index + 1, done)
  end)
end

-- press/release/enter/exit for a role, with the base name and whether the
-- file behind it resolved. The stepper is the one role whose click sound is
-- geometry rather than a table lookup, so it reports both halves.
function H:semanticsText(role, frame)
  local engine = self.obj.engine
  local parts = {}
  for _, action in ipairs({"press", "release", "enter", "exit"}) do
    local semantic = rolemap.semantic(role, action)
    local base = semantic and soundmap.bases[semantic]
    local path = semantic and engine and (engine.paths or {})[semantic]
    table.insert(parts, string.format("%s=%s/%s%s", action,
      tostring(semantic), tostring(base),
      (semantic and not path) and "[NO FILE]" or ""))
  end
  local text = table.concat(parts, "  ")
  if role == "AXIncrementor" and usableFrame(frame) then
    text = text .. string.format(
      "  [stepper geometry: upper half press=%s, lower half release=%s]",
      "littlearrow.uppress/laup", "littlearrow.downrelease/ladr")
  end
  return text
end

-- ===================================================================== D

function H:probeCount()
  local source = (self.obj.sources or {})[1]
  if not source or not source.probe then return nil end
  local stats = call(source.probe, "stats")
  return stats and stats.probes or nil
end

function H:phaseD(done)
  self:heading("Phase D -- elision and cost")
  if not self.obj.running or not self:probeCount() then
    for i = 1, 4 do
      self:na("D" .. i, "not tested: no live probe to read statistics from")
    end
    return done()
  end
  self:note("keep your hands off the mouse for the next ~10 seconds")
  self:idleCost(done)
end

-- A motionless cursor must cost nothing. The hover timer fires 16 times a
-- second; the position short-circuit is supposed to return before any IPC.
function H:idleCost(done)
  local start = mouseGet()
  after(C.settleSeconds, function()
    local before = self:probeCount()
    after(C.idleSeconds, function()
      local later = self:probeCount()
      local finish = mouseGet()
      local moved = not start or not finish
        or start.x ~= finish.x or start.y ~= finish.y
      local delta = (later or 0) - (before or 0)
      if moved then
        self:na("D1", string.format(
          "idle probe delta over %ds was %d, but the cursor moved during the "
          .. "window -- rerun without touching the mouse", C.idleSeconds,
          delta))
      else
        self:verdict(delta == 0, "D1", string.format(
          "idle probe delta over %ds: %d (expected 0)", C.idleSeconds, delta))
      end
      self:jiggleCost(done)
    end)
  end)
end

-- Choose the biggest leaf-roled element the walk found, because leafness is
-- what earns the generous revalidation ceiling and therefore what the low
-- number is supposed to prove.
function H:jiggleTarget()
  local best, bestArea, bestRole = nil, -1, nil
  for key, entry in pairs(self.found or {}) do
    if rolemap.isLeafRole(key) and usableFrame(entry.frame)
      and entry.frame.w >= C.jiggleMinSidePx
      and entry.frame.h >= C.jiggleMinSidePx then
      local area = entry.frame.w * entry.frame.h
      if area > bestArea then best, bestArea, bestRole = entry, area, key end
    end
  end
  return best, bestRole
end

-- A moving cursor that never leaves one element should still barely probe:
-- the frame elision is supposed to swallow every tick until the 2 s
-- revalidation ceiling rearms.
function H:jiggleCost(done)
  local target, role = self:jiggleTarget()
  if not target then
    self:na("D2", "not tested: the walk found no leaf element big enough to "
      .. "jiggle inside")
    return self:sweepCost(done, nil)
  end
  local cx, cy = centreOf(target.frame)
  local before, steps = nil, 0
  local total = math.floor(C.jiggleSeconds / C.moveIntervalSeconds)
  mouseSet(cx, cy)
  after(C.settleSeconds, function()
    before = self:probeCount()
    local timer
    timer = hs.timer.doEvery(C.moveIntervalSeconds, function()
      steps = steps + 1
      if steps > total then
        pcall(function() timer:stop() end)
        local delta = (self:probeCount() or 0) - (before or 0)
        local ceiling = (self.obj.tuning or {}).cacheRevalidateSeconds or 2
        local expected = math.ceil(C.jiggleSeconds / ceiling) + 1
        local text = string.format(
          "%d probes while jiggling inside one %s for %ds (ceiling %.1fs "
          .. "predicts about %d)", delta, tostring(role), C.jiggleSeconds,
          ceiling, expected)
        if delta <= expected + 2 then
          self:pass("D2", text)
        else
          self:warn("D2", text .. " -- higher than the ceiling predicts, so "
            .. "the frame elision may not be firing")
        end
        return self:sweepCost(done, delta)
      end
      local dx = (steps % 2 == 0) and C.jiggleRadiusPx or -C.jiggleRadiusPx
      local dy = (steps % 4 < 2) and C.jiggleRadiusPx or -C.jiggleRadiusPx
      mouseSet(cx + dx, cy + dy)
    end)
    self.timers = {timer}
  end)
end

-- The control: a cursor crossing many differently-framed elements must probe
-- far more often. Without this the low jiggle number could equally mean the
-- elision is never engaging and the probe is simply broken.
function H:sweepCost(done, jiggleDelta)
  local screen = fcall(hs.screen.primaryScreen)
  local full = screen and call(screen, "fullFrame")
  if not usableFrame(full) then
    self:na("D3", "not tested: the primary screen's frame could not be read")
    self:na("D4", "not tested: no sweep to compare against")
    return done()
  end
  local y = full.y + C.sweepMenuBarOffsetPx
  local x0 = full.x + C.sweepMarginPx
  local x1 = full.x + full.w - C.sweepMarginPx
  local total = math.floor(C.sweepSeconds / C.moveIntervalSeconds)
  local steps, before = 0, nil
  mouseSet(x0, y)
  after(C.settleSeconds, function()
    before = self:probeCount()
    local timer
    timer = hs.timer.doEvery(C.moveIntervalSeconds, function()
      steps = steps + 1
      if steps > total then
        pcall(function() timer:stop() end)
        if self.cursorHome then
          mouseSet(self.cursorHome.x, self.cursorHome.y)
        end
        local delta = (self:probeCount() or 0) - (before or 0)
        self:verdict(delta >= C.sweepMinProbes, "D3", string.format(
          "%d probes while sweeping %d px of the menu bar for %ds",
          delta, round(x1 - x0), C.sweepSeconds))
        if not jiggleDelta then
          self:na("D4", "no jiggle figure to compare the sweep against")
        elseif delta < C.sweepMinProbes then
          self:warn("D4", "the sweep crossed too little to compare")
        elseif jiggleDelta == 0 then
          self:warn("D4", string.format(
            "sweep %d, jiggle 0 -- a zero jiggle means probedAt may be being "
            .. "refreshed by elisions, which would let a wrong role persist",
            delta))
        else
          local ratio = delta / jiggleDelta
          self:verdict(ratio >= C.elisionRatioFloor, "D4", string.format(
            "elision ratio sweep:jiggle = %d:%d = %.1fx (want >= %.0fx)",
            delta, jiggleDelta, ratio, C.elisionRatioFloor))
        end
        return done()
      end
      local t = steps / total
      mouseSet(x0 + (x1 - x0) * t, y)
    end)
    self.timers = {timer}
  end)
end

-- ===================================================================== E

function H:phaseE(done)
  self:heading("Phase E -- sources, self-triggered")
  -- Nothing here means anything with the sources torn down: an absent sound
  -- would say only that the Spoon is off, which A5 has already said.
  if not self.obj.running then
    for i = 1, 4 do
      self:na("E" .. i, "not tested: the Spoon is not running, so no source "
        .. "is subscribed to anything")
    end
    return done()
  end
  self:consoleWindows(done)
end

-- Whether the Hammerspoon console window EXISTS, or nil when that cannot be
-- determined. Existence, not visibility: a console that exists is one the
-- user opened, whether it is in front or buried, and this harness does not
-- close windows it did not open.
local function consoleExists()
  if type(hs.console) ~= "table" or type(hs.console.hswindow) ~= "function"
    or type(hs.openConsole) ~= "function"
    or type(hs.closeConsole) ~= "function" then
    return nil
  end
  local ok, win = pcall(hs.console.hswindow)
  if not ok then return nil end
  return win ~= nil
end

-- A genuine windowCreated/windowDestroyed pair -- but only ever with the
-- harness's OWN window.
--
-- This is the one place the harness could damage a session, and the damage
-- would be invisible: :diagnose() is almost always typed INTO the console, so
-- closing it to get a clean creation event would be shutting a window the
-- user opened, in order to test that shutting windows makes a noise. So the
-- test runs only when the console was closed to begin with -- then the window
-- is ours, opening it and closing it again leaves the session exactly as it
-- was, and there is nothing to restore. Console already open: skipped.
-- Console state unreadable: not run at all, because "probably closed" is not
-- good enough to act on.
function H:consoleWindows(done)
  local exists = consoleExists()
  if exists == nil then
    self:na("E1", "not tested: the console's state could not be read, and "
      .. "this test will not open or close a window it is unsure about")
    self:na("E2", "not tested: as E1")
    return self:appLaunch(done)
  end
  if exists then
    self:skip("E1", "skipped: the console is already open, and it is yours -- "
      .. "the harness will not close a window it did not open. Close the "
      .. "console and re-run (bind :diagnose() to a hotkey) to test "
      .. "windowCreated")
    self:skip("E2", "skipped: as E1")
    return self:appLaunch(done)
  end

  local function step(fn, wait, next_)
    local ok = pcall(fn)
    if not ok then return next_(false) end
    after(wait, function() next_(true) end)
  end
  local mark = self:mark()
  step(hs.openConsole, C.consoleWaitSeconds, function(opened)
    local created = self:since(mark)
    local mark2 = self:mark()
    -- Closing our own window again, which is what leaves the console exactly
    -- as this run found it.
    step(hs.closeConsole, C.consoleWaitSeconds, function(closed)
      local destroyed = self:since(mark2)
      if not opened then
        self:fail("E1", "hs.openConsole() errored")
      else
        self:verdict(
          tapeHas(created, "window.open") or tapeHas(created, "palette.open"),
          "E1", "the harness's own console window, created: "
            .. tapeText(created))
      end
      if not closed then
        self:fail("E2", "hs.closeConsole() errored -- the console was opened "
          .. "by this harness and is still open; close it yourself")
      else
        self:verdict(
          tapeHas(destroyed, "window.close")
            or tapeHas(destroyed, "palette.close"),
          "E2", "the harness's own console window, destroyed: "
            .. tapeText(destroyed))
      end
      -- Available to Phase G as the one window event the harness may raise
      -- without touching anything of the user's.
      self.consoleIsOurs = (opened == true) and (closed == true)
      self:appLaunch(done)
    end)
  end)
end

-- `flap` needs an application that is not already running, and the only
-- honest trigger is to launch one.
--
-- Launched WITHOUT activation -- `open -g` rather than
-- launchOrFocusByBundleID -- so the frontmost application never changes and
-- nothing of the user's is pushed behind anything. Only an app that was not
-- already running is a candidate, so no running app is ever quit, and the
-- quit afterwards names the exact pid that appeared.
function H:appLaunch(done)
  local bundle = C.launchBundle
  local installed = fcall(hs.application.pathForBundleID, bundle)
  local already = fcall(hs.application.get, bundle)
  if not installed or already or type(hs.execute) ~= "function" then
    self:na("E3", string.format(
      "not tested: %s is %s -- an app that is already running cannot be "
      .. "launched, and this harness will not quit one it did not start; "
      .. "guided step F7 covers it", bundle,
      already and "already running" or "not installed"))
    return self:finderFiles(done)
  end

  local mark = self:mark()
  -- -g: open in the background. The user's frontmost app stays frontmost.
  local ok = pcall(hs.execute, "open -g -b " .. bundle)
  if not ok then
    self:fail("E3", "could not launch " .. bundle .. " in the background")
    return self:finderFiles(done)
  end
  after(C.launchWaitSeconds, function()
    local tape = self:since(mark)
    self:verdict(tapeHas(tape, "app.launch"), "E3", string.format(
      "launching %s in the background asked for: %s", bundle, tapeText(tape)))
    local app = fcall(hs.application.get, bundle)
    local pid = app and call(app, "pid")
    if app and pid then
      local quit = pcall(function() app:kill() end)
      if not quit then
        self:warn("E3+", string.format(
          "%s (pid %s) was launched by this harness and could not be quit -- "
          .. "quit it yourself", bundle, tostring(pid)))
      end
    elseif app then
      self:warn("E3+", bundle .. " was launched by this harness but its pid "
        .. "could not be read, so it was left running rather than risk "
        .. "quitting something else")
    end
    self:finderFiles(done)
  end)
end

-- The Finder path-watcher check needs a file to appear under a watched
-- directory, and the only watched directories are the user's own Desktop,
-- Documents and Downloads. Writing there is touching their data, however
-- uniquely the file is named and however promptly it is removed, so the
-- automatic run does not do it: nothing outside the report file is written
-- without being asked for and told where. Guided step F7 does it, announcing
-- the exact path first.
function H:finderFiles(done)
  self:na("E4", "not run automatically: it would create a file under your "
    .. "Desktop. The only file the automatic phases write is the report "
    .. "itself. Run :diagnose({guided = true}) for step F8, which announces "
    .. "the exact path before creating it and removes it as soon as it has "
    .. "read what it needs")
  return done()
end

-- Create one file under the Desktop, watch what the Finder source makes of
-- it, and remove that exact path again the instant the check has what it
-- came for.
--
-- Every part of this is deliberately narrow: ONE path, fixed and announced,
-- created with io.open and removed with os.remove BY NAME. No glob, no
-- directory removal, no recursion, and nothing touched that this harness did
-- not itself write and cannot recognise as its own on the way out.
--
-- The file exists for as short a time as the question allows, which is not
-- zero and not a fixed wait either. There is a FLOOR: removing it before the
-- creation has been delivered and coalesced would merge the two events into
-- one burst, and an arrival and a departure under one parent is a RENAME to
-- the gate -- the step would then be testing something it was not asked
-- about. So it polls the tape and takes the file off disk in the same
-- callback that first sees the sound, falling back to the full window only
-- when there is no sound to wait for. Everything else about the file's
-- lifetime is covered by the scratch section at the top of this file.
function H:guidedFinderFile(step, done)
  local path = scratchPath()
  print("PlatinumSnd diagnose: " .. step.id
    .. " will create and then remove exactly this one file:")
  print("    " .. path)
  print("    (removed the moment the check has read what it needs; if this "
    .. "run is interrupted, the next one removes it and says so)")
  pcall(hs.alert.show, step.id .. ": creating and removing\n" .. path, 4)

  -- Nothing is created over the top of a file that is already there. Either
  -- it is a file of the user's that happens to share the name -- not ours to
  -- overwrite OR to remove -- or it is one of ours that the sweep at entry
  -- could not shift, and creating a second one would help nobody.
  if scratchExists(path) then
    if isOurScratch(path) then
      self:na(step.id, "not run: an earlier run's scratch file is still at "
        .. path .. " and this run could not remove it either (A0 says why), "
        .. "so nothing new was created")
    else
      self:na(step.id, "not run: something is already at " .. path
        .. " and it was not written by this harness, so it has been left "
        .. "exactly as it is")
    end
    return done()
  end

  local front = fcall(hs.application.frontmostApplication)
  local frontBundle = front and call(front, "bundleID")
  local gate = ((self.obj.sources or {})[4] or {}).gate
  local graceOpen = false
  if gate then
    local ok, answer = pcall(gate.shouldSound, gate, clock())
    graceOpen = ok and answer or false
  end

  local mark = self:mark()
  local file, err = io.open(path, "w")
  if not file then
    self:fail(step.id, "could not create " .. path .. ": " .. tostring(err))
    return done()
  end
  -- Recorded as outstanding BEFORE the write, so that every path out of here
  -- -- including one that never reaches the next line -- knows about it.
  scratch.path = path
  self.scratchCreated = path
  armShutdownSweep()
  file:write(C.scratchMarker .. "\n")
  file:close()

  local expectSound = frontBundle == "com.apple.finder" or graceOpen

  local function report(created, removed, removeErr)
    local mark2 = self:mark()
    after(C.finderWaitSeconds, function()
      local departed = self:since(mark2)
      local text = string.format(
        "%s: created then removed (frontmost %s, gate open %s) -- create "
        .. "asked for %s, remove asked for %s", path:match("[^/]+$"),
        tostring(frontBundle), tostring(graceOpen), tapeText(created),
        tapeText(departed))
      if expectSound then
        self:verdict(tapeHas(created, "finder.new")
          or tapeHas(created, "finder.copydone"), step.id, text)
      else
        self:verdict(#created == 0 and #departed == 0, step.id, text
          .. " -- expected silence: the gate requires Finder to have been "
          .. "frontmost within finderGraceSeconds")
      end
      if removed == false and self:scratchStillThere(path, removeErr) then
        self:fail(step.id .. "!", "THE SCRATCH FILE COULD NOT BE REMOVED: "
          .. path .. " (" .. tostring(removeErr) .. ") -- delete it yourself")
      end
      done()
    end)
  end

  local waited = 0
  local function poll()
    waited = waited + C.finderPollSeconds
    local created = self:since(mark)
    if #created == 0 and waited < C.finderWaitSeconds then
      return after(C.finderPollSeconds, poll)
    end
    -- Same callback, first thing, no later phase and no teardown handler.
    local removed, removeErr = takeScratch(path)
    report(created, removed, removeErr)
  end
  after(C.finderPollSeconds, poll)
end

-- ===================================================================== F

local GUIDED = {
  {id = "F1", instruction = "Pull down any menu, then press Escape.",
   expect = {"menu.open"}},
  {id = "F2", instruction = "Open a menu and choose any harmless item.",
   expect = {"menu.select"}},
  {id = "F3", instruction = "Drag a window by its title bar, pause "
     .. "mid-drag while still holding, then let go.",
   expect = {"window.moving"}},
  {id = "F4", instruction = "Bring Finder to the front and make a new "
     .. "folder on the Desktop.", expect = {"finder.new"}},
  {id = "F5", instruction = "Drag a file into a Finder window and drop it.",
   expect = {"finder.drop"}},
  -- Left for the human on purpose. The harness could make a scratch .dmg
  -- under /tmp and mount it, and the file itself would be no worse than F8's
  -- -- but mounting one puts a volume in /Volumes, in the Finder's sidebar
  -- and in every open-file dialog on the machine, and an interrupted run
  -- would leave THAT behind rather than an empty file. F8 has already shown
  -- that a run gets interrupted, and a mounted volume is a great deal more
  -- work to undo than a stat and an os.remove. So the step tells you how to
  -- make a throwaway image, and you stay in charge of it.
  {id = "F6", instruction = "Mount a disk image, then eject it.",
   hint = "No image to hand? In Terminal: hdiutil create -size 10m -fs "
     .. "APFS -volname PSndTest /tmp/psnd-test.dmg && open "
     .. "/tmp/psnd-test.dmg -- eject it in the Finder, then rm "
     .. "/tmp/psnd-test.dmg. The harness will not mount anything itself: an "
     .. "interrupted run would leave a volume mounted.",
   expect = {"disk.insert", "disk.eject"}},
  {id = "F7", instruction = "Launch an application that is not already "
     .. "running.", expect = {"app.launch"}},
  -- Machine-driven rather than instructed, and the one step in this file that
  -- writes anything: `runner` marks it so, and it announces the exact path it
  -- will create and remove before it does either.
  {id = "F8", instruction = "The harness creates and removes one scratch file "
     .. "on your Desktop (path announced below).",
   runner = "guidedFinderFile"},
}

function H:phaseF(done)
  self:heading("Phase F -- guided steps")
  if not self.opts.guided then
    for _, step in ipairs(GUIDED) do
      self:na(step.id, "not run: pass {guided = true} to include it")
    end
    return done()
  end
  -- The human is driving here, so let them hear it as well as have it
  -- recorded. Dry run goes back on afterwards.
  local engine = self.obj.engine
  if engine then engine:dryRun(false) end
  self:guidedStep(1, function()
    if engine then engine:dryRun(true) end
    done()
  end)
end

function H:guidedStep(index, done)
  local step = GUIDED[index]
  if not step then return done() end
  local function continue_() self:guidedStep(index + 1, done) end
  -- A step the harness performs itself rather than asks for. It reports its
  -- own verdict, so there is no capture window to open around it.
  if step.runner then
    local ok = pcall(function() self[step.runner](self, step, continue_) end)
    if not ok then
      self:fail(step.id, "the step errored and was abandoned")
      continue_()
    end
    return
  end
  local text = string.format("%s (%ds): %s", step.id, C.guidedWindowSeconds,
    step.instruction)
  print("PlatinumSnd diagnose: " .. text)
  -- The hint goes to the console only: it is a paragraph, and an alert is a
  -- sentence.
  if step.hint then print("    " .. step.hint) end
  pcall(hs.alert.show, text, C.guidedWindowSeconds)
  local mark = self:mark()
  after(C.guidedWindowSeconds, function()
    local tape = self:since(mark)
    if #tape == 0 then
      self:skip(step.id, step.instruction .. " -- nothing was captured, "
        .. "recorded as skipped rather than failed")
    else
      local missing = {}
      for _, semantic in ipairs(step.expect) do
        if not tapeHas(tape, semantic) then
          table.insert(missing, semantic)
        end
      end
      if #missing == 0 then
        self:pass(step.id, step.instruction .. " -> " .. tapeText(tape))
      else
        self:warn(step.id, string.format("%s -> %s (no %s)", step.instruction,
          tapeText(tape), table.concat(missing, ", ")))
      end
    end
    continue_()
  end)
end

-- Count the calls that install and hand back the process-wide AX bound.
--
-- There is no getter for the value, so the call is the only observable. Same
-- shape as the engine shim: record, delegate, and put the module function
-- back through restore() whatever happens in between. Absent on a Spoon that
-- still installs the bound from axprobe.new, where there is nothing to count.
function H:installAxShim()
  local ax = self.obj.axprobe
  if type(ax) ~= "table" then return end
  if type(ax.installTimeout) ~= "function"
    or type(ax.resetTimeout) ~= "function" then
    return
  end
  self.axCalls = {install = 0, reset = 0}
  self.axShimmed = ax
  self.axShadow = {
    installTimeout = ax.installTimeout, resetTimeout = ax.resetTimeout,
  }
  local calls, shadow = self.axCalls, self.axShadow
  ax.installTimeout = function(...)
    calls.install = calls.install + 1
    return shadow.installTimeout(...)
  end
  ax.resetTimeout = function(...)
    calls.reset = calls.reset + 1
    return shadow.resetTimeout(...)
  end
end

function H:removeAxShim()
  if not self.axShimmed then return end
  self.axShimmed.installTimeout = self.axShadow.installTimeout
  self.axShimmed.resetTimeout = self.axShadow.resetTimeout
  self.axShimmed = nil
end

-- Whether the window filter really went away, which the whole-branch review
-- doubted: src_windows calls :unsubscribeAll(), and Hammerspoon documents
-- :delete() as the full teardown. The difference matters because the toggle
-- hotkey builds a new filter on every start, so a filter that survives its
-- stop is one more live subscriber on the next one -- and the symptom is
-- window sounds doubling, then trebling, not an error.
--
-- Three things are readable from Lua and one is not: whether the source let
-- go of its reference, whether :delete exists to be called, and whether the
-- instance still holds subscriptions. Hammerspoon publishes no registry of
-- filter instances, so the COUNT of live filters cannot be read at all --
-- G13 measures the consequence instead of the cause.
-- Record which teardown method the source calls on its filter. Wrapped before
-- stop() and read after it, because "delete exists" and "delete was called"
-- are different claims and only the second one is worth reporting.
function H:installFilterShim(filter)
  if not filter then return end
  self.filterCalls = {delete = 0, unsubscribeAll = 0}
  local calls = self.filterCalls
  local shadow = {delete = filter.delete,
                  unsubscribeAll = filter.unsubscribeAll}
  for _, name in ipairs({"delete", "unsubscribeAll"}) do
    if type(shadow[name]) == "function" then
      filter[name] = function(...)
        calls[name] = calls[name] + 1
        return shadow[name](...)
      end
    end
  end
  self.filterHasDelete = type(shadow.delete) == "function"
end

function H:filterTeardown(filter)
  if not filter then
    self:na("G11", "no window filter to inspect: src_windows never built one")
    return
  end
  local calls = self.filterCalls or {delete = 0, unsubscribeAll = 0}
  local subscriptions, counted = 0, false
  for _, field in ipairs({"subscriptions", "events", "notifyfns"}) do
    local value = rawget(filter, field)
    if type(value) == "table" then
      counted = true
      for _ in pairs(value) do subscriptions = subscriptions + 1 end
    end
  end
  local how
  if calls.delete > 0 then
    how = ":delete() was called, which is the documented full teardown"
  elseif calls.unsubscribeAll > 0 then
    how = ":unsubscribeAll() was called and :delete() was not -- that "
      .. "silences this instance's callbacks but leaves it registered, so "
      .. "each toggle leaves another live filter behind"
  else
    how = "neither :delete() nor :unsubscribeAll() was called on it"
  end
  local text = string.format("window filter after stop(): %s; %s; reference "
    .. "%s", how,
    counted and string.format("%d subscription entries left on the instance",
      subscriptions)
      or "no readable subscription table on the instance",
    (self.obj.sources[2] or {}).filter == nil and "dropped"
      or "STILL HELD by the source")
  self:verdict(calls.delete > 0
    or (not self.filterHasDelete and calls.unsubscribeAll > 0), "G11", text)
  self:note("Hammerspoon exposes no registry of filter instances, so live "
    .. "filters cannot be counted from Lua; G14 tests the consequence")
end

-- ===================================================================== G

function H:phaseG(done)
  self:heading("Phase G -- teardown")
  local sources = self.obj.sources or {}

  -- Identify the sources while they are still running, so the checks below
  -- are known to be reading the source they name.
  local ordered = true
  for _, marker in ipairs(SOURCE_MARKERS) do
    local source = sources[marker.index]
    if not source or source[marker.field] == nil then ordered = false end
  end
  self:verdict(ordered, "G1", string.format(
    "%d sources registered in the documented order (pointer, windows, "
    .. "menus, finder, keys)", #sources))

  -- Hold on to the probe and the window filter: stop() drops both references,
  -- and what each did on the way out is only readable from the object itself.
  local probe = (sources[1] or {}).probe
  local filter = (sources[2] or {}).filter
  local observersBefore = call(sources[3], "observerCount")

  self:installAxShim()
  self:installFilterShim(filter)
  local stopped = pcall(function() self.obj:stop() end)
  self:verdict(stopped and self.obj.running == false, "G2", string.format(
    "obj:stop() completed and running is %s", tostring(self.obj.running)))

  for i, spec in ipairs(TEARDOWN) do
    local source = sources[spec.index]
    local leaks = {}
    if not source then
      table.insert(leaks, "the source itself is missing")
    else
      for _, field in ipairs(spec.nils or {}) do
        if source[field] ~= nil then
          table.insert(leaks, field .. " is still " .. tostring(source[field]))
        end
      end
      for _, field in ipairs(spec.falses or {}) do
        if source[field] ~= false then
          table.insert(leaks, field .. " is " .. tostring(source[field]))
        end
      end
      if spec.name == "src_menus" then
        local count = call(source, "observerCount") or -1
        if count ~= 0 then
          table.insert(leaks, count .. " menu observers still attached")
        end
      end
      if spec.name == "src_finder" then
        local n = #(source.watchers or {})
        if n ~= 0 then
          table.insert(leaks, n .. " path watchers still held")
        end
      end
    end
    self:verdict(#leaks == 0, "G" .. tostring(2 + i), string.format(
      "%s released everything%s", spec.name,
      #leaks == 0 and "" or ": " .. table.concat(leaks, "; ")))
  end
  if observersBefore then
    self:note(string.format("src_menus held %d observers before stop()",
      observersBefore))
  end

  local playing = {}
  for semantic, snd in pairs((self.obj.engine or {}).sustainers or {}) do
    if call(snd, "isPlaying") then table.insert(playing, semantic) end
  end
  self:verdict(#playing == 0, "G8", string.format(
    "no sustained sound left playing after stop()%s",
    #playing == 0 and "" or ": " .. table.concat(playing, ", ")))

  -- macOS publishes no getter for the AX messaging timeout, so the only way
  -- to know it was handed back is to watch the call that hands it back. The
  -- shim installed above counts it; the older arrangement, where the probe
  -- released it from its own stop(), is read from the probe instead.
  if self.axCalls then
    self:verdict(self.axCalls.reset == 1, "G9", string.format(
      "obj:stop() called axprobe.resetTimeout %d time(s) (expected exactly "
      .. "1) -- there is no getter for the bound, so watching the call is "
      .. "the strongest evidence available", self.axCalls.reset))
  elseif probe ~= nil and rawget(probe, "released") ~= nil then
    self:verdict(probe.released == true, "G9", string.format(
      "the probe handed the process-wide AX timeout back (released=%s)",
      tostring(probe.released)))
  else
    self:na("G9", "no mechanism found that hands the AX messaging bound "
      .. "back: neither axprobe.resetTimeout nor Probe:release exists, so "
      .. "this Spoon's 50 ms bound may outlive it")
  end

  -- And a functional proxy: accessibility still answers after the bound was
  -- supposed to be lifted.
  --
  -- Asked of the accessibility API itself, because that is the claim. The
  -- first version of this check read the focused window's TITLE, which is
  -- neither necessary nor sufficient for it: there may be no focused window
  -- at this point in the run at all -- the harness has just closed the
  -- console and quit Calculator -- and plenty of perfectly healthy windows
  -- have no title. It duly reported a failure with nothing wrong, which is
  -- worse than no check, because it teaches whoever reads this report that a
  -- FAIL line can be ignored.
  --
  -- systemWideElement is the entry point every other accessibility call in
  -- this Spoon goes through, and a hit test at the cursor is the smallest
  -- round trip into another process that returns something with a role. No
  -- part of it depends on which window has focus.
  local sysNow = fcall(hs.axuielement.systemWideElement)
  local point = mouseGet()
  local where = point and string.format("(%d, %d)", round(point.x),
    round(point.y)) or "the cursor, whose position could not be read"
  local probed, roleNow = nil, nil
  if sysNow and point then
    local hit, element = pcall(sysNow.elementAtPosition, sysNow, point.x,
                               point.y)
    probed = hit and element or nil
    roleNow = att(probed, "AXRole")
  end
  if not sysNow then
    self:fail("G10", "accessibility does NOT answer after stop(): "
      .. "hs.axuielement.systemWideElement() returned nothing")
  elseif type(roleNow) == "string" then
    self:pass("G10", string.format(
      "accessibility still answers after stop(): systemWideElement returned "
      .. "an element and a hit test at %s answered AXRole=%s", where, roleNow))
  else
    -- Nothing under the cursor is an empty screen region, not a defect, so
    -- this warns instead of failing.
    self:warn("G10", string.format(
      "accessibility answered in part after stop(): systemWideElement "
      .. "returned an element, but the hit test at %s came back with %s. An "
      .. "empty region of screen is not a defect -- put the cursor over a "
      .. "window and re-run if you want this settled", where,
      probed and "an element with no readable AXRole" or "nothing"))
  end

  self:filterTeardown(filter)

  after(C.settleSeconds, function()
    if self.wasRunning then
      local ok = pcall(function() self.obj:start() end)
      self:verdict(ok and self.obj.running == true, "G12", string.format(
        "restarted the Spoon as it was found (running=%s)",
        tostring(self.obj.running)))
      self:axReinstalled()
      return after(C.settleSeconds, function() self:doubledEvents(done) end)
    end
    self:na("G12", "left stopped, which is how the Spoon was found")
    self:axReinstalled()
    self:na("G14", "not tested: the Spoon is stopped, so nothing is "
      .. "subscribed to duplicate")
    done()
  end)
end

-- The other half of G9: a start must put back what its stop gave away, or the
-- Spoon comes back up with every AX call in the process unbounded -- which is
-- the tap-death condition the bound exists to prevent, and it is silent.
function H:axReinstalled()
  if not self.axCalls then
    self:na("G12+", "not tested: this Spoon does not install the AX bound "
      .. "through axprobe.installTimeout")
  elseif not self.wasRunning then
    self:verdict(self.axCalls.install == 0, "G12+", string.format(
      "nothing reinstalled the AX bound on a Spoon left stopped (%d calls)",
      self.axCalls.install))
  else
    self:verdict(self.axCalls.install == 1, "G12+", string.format(
      "obj:start() called axprobe.installTimeout %d time(s) on the restart "
      .. "(expected exactly 1)", self.axCalls.install))
  end
  self:removeAxShim()
end

-- Whether a stop and a start leave TWO subscribers where there was one.
--
-- This is the consequence of the filter teardown question, and the only way
-- to see it is to raise one window event and count the sounds it asks for.
-- One window event is available without touching anything of the user's: the
-- console, and only when this run found it closed and therefore owns it. With
-- the console already open -- the usual case, since :diagnose() is typed into
-- it -- there is no window the harness may raise an event with, and the check
-- reports that rather than borrowing one of the user's.
function H:doubledEvents(done)
  if not self.consoleIsOurs then
    self:na("G14", "not tested: raising a window event needs a window, and "
      .. "the only one the harness owns is a console it opened itself -- "
      .. "which this run did not (E1 says why). Close the console and re-run "
      .. "from a hotkey to test whether stop/start doubles subscribers")
    return done()
  end
  local mark = self:mark()
  local opened = pcall(hs.openConsole)
  after(C.consoleWaitSeconds, function()
    local tape = self:since(mark)
    pcall(hs.closeConsole)
    after(C.consoleWaitSeconds, function()
      local opens = 0
      for _, entry in ipairs(tape) do
        if entry.semantic == "window.open"
          or entry.semantic == "palette.open" then
          opens = opens + 1
        end
      end
      if not opened then
        self:na("G14", "not tested: the console would not reopen")
      else
        self:verdict(opens == 1, "G14", string.format(
          "one window opening after a stop/start asked for %d open sound(s) "
          .. "(expected exactly 1; more means a window filter survived its "
          .. "stop and the new one joined it)", opens))
      end
      done()
    end)
  end)
end

-- ================================================================= report

function H:summary()
  self:heading("Summary")
  self:raw(string.format("PASS %d   FAIL %d   WARN %d   ---- %d   SKIP %d",
    self.counts.PASS, self.counts.FAIL, self.counts.WARN,
    self.counts["----"], self.counts.SKIP))
  self:raw("")
  -- Above everything else, including the failures: a file of this harness's
  -- that is still on the user's disk is the one thing here they have to act
  -- on, and the phase body it was first reported in has scrolled past.
  if #self.scratchLeft > 0 then
    self:raw("!! A FILE THIS HARNESS CREATED IS STILL ON YOUR DISK AND COULD "
      .. "NOT BE REMOVED.")
    self:raw("!! Delete it yourself:")
    for _, path in ipairs(self.scratchLeft) do self:raw("!!     " .. path) end
    self:raw("")
  end
  if #self.problems == 0 then
    self:raw("Nothing failed and nothing warned.")
  else
    self:raw("Needs attention:")
    for _, line in ipairs(self.problems) do self:raw("  " .. line) end
  end
  self:raw("")
  self:raw("[----] means not tested here, usually a coverage gap rather "
    .. "than a defect.")
end

function H:write(text)
  local home = os.getenv("HOME") or ""
  local paths = {
    home .. C.reportDir .. "/" .. C.reportBaseName,
    home .. C.reportFallbackDir .. "/" .. C.reportBaseName,
  }
  for _, path in ipairs(paths) do
    local file = io.open(path, "w")
    if file then
      local ok = pcall(function()
        file:write(text)
        file:close()
      end)
      if ok then return path end
    end
  end
  return nil
end

-- Put back everything the harness touched. Idempotent, and each part guarded
-- on its own so that one failure cannot cost the others.
--
-- This is the finally block. It is reached from three directions: the normal
-- end of the run, a step that died so badly the chain stopped advancing, and
-- the dead man's timer -- because a harness that leaves the cursor parked on
-- a menu bar and every sound suppressed is worse than one that never ran.
--
-- Note what is NOT here: nothing to reopen, reposition or refocus a window.
-- The harness never closes or moves one, so there is nothing of the user's to
-- undo. The console is the only window it ever opens, only when it was
-- closed to begin with, and it closes that one itself.
function H:restore()
  if self.restored then return end
  self.restored = true
  pcall(function() self:removeShim() end)
  pcall(function() self:removeAxShim() end)
  pcall(function()
    if self.cursorHome then mouseSet(self.cursorHome.x, self.cursorHome.y) end
  end)
  pcall(function()
    if self.obj.engine then self.obj:dryRun(self.wasDryRun) end
  end)
  -- Only ever set while the Spoon was stopped, in which case nothing else in
  -- the process is relying on the bound and 0.0 is the documented default.
  pcall(function()
    if self.axTimeoutOurs and self.sys then self.sys:setTimeout(0.0) end
  end)
  pcall(function()
    for _, timer in ipairs(self.timers or {}) do
      pcall(function() timer:stop() end)
    end
    self.timers = nil
  end)
  pcall(function()
    if self.deadman then self.deadman:stop(); self.deadman = nil end
  end)
  -- The scratch file, if F8 was cut short between creating it and removing
  -- it. This runs before the summary is assembled, so a removal that fails
  -- here still gets shouted about in the report.
  pcall(function()
    local path = scratch.path
    if not path then return end
    local removed, err = takeScratch(path)
    if removed == true then
      pcall(function()
        self:warn("F8!", "the run ended before guided step F8 could remove "
          .. "its scratch file; it was removed here instead: " .. path)
      end)
    elseif removed == false and self:scratchStillThere(path, err) then
      pcall(function()
        self:fail("F8!", "THE SCRATCH FILE COULD NOT BE REMOVED: " .. path
          .. " (" .. tostring(err) .. ") -- delete it yourself")
      end)
    end
  end)
  pcall(function() self.obj.diagnosing = nil end)
end

function H:finish()
  if self.finished then return self.obj end
  self.finished = true
  self:restore()

  pcall(function() self:summary() end)

  -- Even the report is guarded. A run that got this far has already learned
  -- everything it is going to; losing it to a formatting slip in the last
  -- three lines would be the worst possible failure this file could have.
  local formatted = pcall(function()
    local header = {
      "PlatinumSnd diagnostics",
      "generated " .. os.date("%Y-%m-%d %H:%M:%S %z"),
      string.format("macOS %s | Hammerspoon %s | %s | PlatinumSnd %s",
        tostring(self.env.osVersion), tostring(self.env.hsVersion),
        tostring(self.env.luaVersion), tostring(self.obj.version)),
      string.format("phases A-E and G automatic, F %s | took %.1f s",
        self.opts.guided and "guided" or "not run", clock() - self.startedAt),
      "touched: the cursor (put back), this Spoon's state (put back), and "
        .. "this report file.",
      "no window was opened, closed, moved or focused; "
        -- Asked of the disk rather than of the bookkeeping: this line is the
        -- harness's account of what it did to the machine, and a stat is the
        -- only version of it that cannot be wrong.
        .. (self.scratchCreated
            and ("guided step F8 created one scratch file, "
                 .. self.scratchCreated .. ", and "
                 .. (isOurScratch(self.scratchCreated)
                     and "COULD NOT REMOVE IT -- see the summary"
                     or "removed it again") .. ".")
            or "no other file was written."),
      string.rep("=", 72),
    }
    local body = table.concat(header, "\n") .. "\n"
      .. table.concat(self.lines, "\n") .. "\n"

    local path = self:write(body)
    print(body)
    if path then
      print("PlatinumSnd diagnose: written to " .. path)
    else
      print("PlatinumSnd diagnose: the report could not be written to disk; "
        .. "copy it from the console above")
    end
  end)
  if not formatted then
    print("PlatinumSnd diagnose: the report could not be assembled; the "
      .. "raw lines follow")
    for _, line in ipairs(self.lines) do print(line) end
  end
  pcall(hs.alert.show, "PlatinumSnd diagnostics finished", 3)
  return self.obj
end

-- ================================================================== entry

function H:begin()
  self.startedAt = clock()
  -- Before anything else, and before a single check runs: a scratch file an
  -- earlier run was interrupted before it could remove. Removed here, and
  -- reported by Phase A as a WARN naming the path -- silently tidying it away
  -- would mean the user never learns it happened.
  local path = scratchPath()
  if isOurScratch(path) then
    local removed, err = takeScratch(path)
    table.insert(self.swept, {path = path, removed = removed == true,
                              err = err})
  elseif scratchExists(path) then
    table.insert(self.swept, {path = path, removed = false, foreign = true})
  end
  self.cursorHome = mouseGet()
  self.wasRunning = self.obj.running == true
  self.wasDryRun = (self.obj.engine or {}).isDryRun == true

  self.env = {
    osVersion = fcall(hs.host.operatingSystemVersionString),
    hsVersion = hs.processInfo and hs.processInfo.version,
    luaVersion = _VERSION,
    accessibility = fcall(hs.accessibilityState) == true,
  }

  self:installShim()

  -- Everything from here on runs against a live Spoon: Phase C needs the
  -- hover loop turning and Phase D needs the probe's counters.
  if not self.wasRunning and self.env.accessibility then
    pcall(function() self.obj:start() end)
  end
  -- Silent by default. The two sound checks in Phase B and the guided phase
  -- lift this for exactly as long as they need it.
  if self.obj.engine then self.obj:dryRun(true) end

  self:add("A", function(h, done) h:phaseA(done) end)
  self:add("B", function(h, done) h:phaseB1(done) end)
  self:add("B*", function(h, done) h:phaseBScreens(done) end)
  self:add("C", function(h, done) h:phaseC(done) end)
  self:add("D", function(h, done) h:phaseD(done) end)
  self:add("E", function(h, done) h:phaseE(done) end)
  self:add("F", function(h, done) h:phaseF(done) end,
    C.guidedTimeoutSeconds + #GUIDED * C.guidedWindowSeconds)
  self:add("G", function(h, done) h:phaseG(done) end)

  -- The dead man's timer. Nothing is expected to need it -- every step has a
  -- watchdog and runStep is wrapped -- which is exactly why it is here: the
  -- failure it covers is the one nobody predicted, and the cost of that one
  -- is a cursor left parked somewhere and every sound suppressed until the
  -- next reload.
  local budget = C.deadmanSeconds + delayOf(self.opts)
    + (self.opts.guided and C.deadmanGuidedExtra or 0)
  self.deadman = hs.timer.doAfter(budget, function()
    if self.finished then return end
    pcall(function()
      self:fail("!!", string.format(
        "the harness passed its %ds deadline; everything it touched has been "
        .. "put back and the report is whatever had been reached", budget))
    end)
    self:finish()
  end)

  local delay = delayOf(self.opts)
  if delay > 0 then
    print(string.format("PlatinumSnd diagnose: starting in %.0f s -- bring "
      .. "the app you want walked to the front now", delay))
    pcall(hs.alert.show, string.format(
      "PlatinumSnd diagnostics start in %.0f s -- front the app to inspect",
      delay), delay)
  end
  after(delay, function() self:runStep(1) end)
  return self.obj
end

-- What it will touch, what it will not, before it touches anything. Anyone
-- should be able to read this and know the run is safe without reading the
-- 1,800 lines above it.
local function preamble(opts)
  local home = os.getenv("HOME") or "~"
  local lines = {
    "PlatinumSnd diagnose: starting. About a minute"
      .. (opts.guided and " plus the guided steps." or "."),
    "  TOUCHES: the mouse CURSOR (Phase C moves it over controls it finds, "
      .. "and puts it back);",
    "           this Spoon's own state (dry run on, briefly stopped and "
      .. "restarted at the end);",
    "           one file, " .. home .. C.reportDir .. "/" .. C.reportBaseName
      .. ", which is the report.",
    "  LEAVES ALONE: your windows -- none are opened, closed, moved, resized "
      .. "or focused;",
    "                your files -- nothing is created, changed or deleted "
      .. "anywhere else;",
    "                your frontmost app -- it stays frontmost throughout.",
    "  If Calculator is not running it is launched IN THE BACKGROUND and "
      .. "quit again, to test",
    "  the app-launch sound. Nothing already running is ever quit.",
    "  It never clicks, types, or acts on an accessibility element. It only "
      .. "reads and hovers,",
    "  so apps may show a tooltip or a highlight as the cursor passes. That "
      .. "is all they will do.",
    "  Keep your hands off the mouse until it says it has finished.",
  }
  if opts.guided then
    table.insert(lines, "  Guided steps ask YOU to act, and one of them "
      .. "creates and removes a single")
    table.insert(lines, "  scratch file, " .. home .. C.reportDir .. "/"
      .. C.scratchName .. " -- it prints the path")
    table.insert(lines, "  before creating it, removes it as soon as it has "
      .. "read what it needs, and if this")
    table.insert(lines, "  run is interrupted in between, the next run "
      .. "removes it and says so.")
  end
  print(table.concat(lines, "\n"))
end

return function(obj, opts)
  opts = opts or {}
  -- One at a time. Two harnesses would shim each other's shims, move the
  -- cursor against each other and interleave their reports, and the second
  -- one's restoration would put the first one's wrapper back.
  if obj.diagnosing then
    print("PlatinumSnd diagnose: already running; wait for it to finish")
    return obj
  end
  pcall(preamble, opts)
  pcall(hs.alert.show, "PlatinumSnd diagnostics running -- hands off the "
    .. "mouse", 6)
  local harness = H.new(obj, opts)
  -- Rooted on the Spoon for the duration. Every step after the first is
  -- reached through a timer callback, and a harness reachable only from a
  -- timer closure would be at the mercy of when those are collected.
  obj.diagnosing = harness
  local ok, err = pcall(function() harness:begin() end)
  if not ok then
    pcall(function() harness:restore() end)
    print("PlatinumSnd diagnose: could not start: " .. tostring(err))
  end
  return obj
end
