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
  -- Tried in order; the first one installed and NOT already running is used,
  -- and quit again afterwards. Nothing already running is ever touched.
  launchCandidates      = {
    "com.apple.calculator", "com.apple.stickies", "com.apple.TextEdit",
  },
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
  {index = 1, name = "src_pointer",
   nils = {"tap", "timer", "probe", "cache"},
   falses = {"thumbDragging", "sliderDragging"}},
  {index = 2, name = "src_windows",
   nils = {"tap", "dragTimer", "filter", "volumeWatcher", "appWatcher",
           "paletteIds"},
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
  local step = self.steps[index]
  if not step then return self:finish() end
  self.stepIndex = index

  local finished = false
  local watchdog
  local function advance()
    if finished then return end
    finished = true
    if watchdog then pcall(function() watchdog:stop() end) end
    hs.timer.doAfter(0, function() self:runStep(index + 1) end)
  end

  local limit = step.timeout or C.stepTimeoutSeconds
  watchdog = hs.timer.doAfter(limit, function()
    if finished then return end
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

  local timeout = (self.obj.tuning or {}).axTimeoutSeconds
  local setOk, setResult = pcall(self.sys.setTimeout, self.sys, timeout)
  self:verdict(setOk, "B2", string.format(
    ":setTimeout(%s) on the system-wide element %s", tostring(timeout),
    setOk and ("returned " .. tostring(setResult))
      or ("errored: " .. tostring(setResult))))

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
    if role == nil then
      self:fail(id, text .. " -- the probe answered nothing at its centre")
    elseif role ~= item.expect then
      self:warn(id, text .. string.format(
        " -- the walk matched %s but the probe at its centre answered %s",
        item.key, tostring(role)))
    else
      self:pass(id, text)
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

-- A genuine windowCreated/windowDestroyed pair, raised by Hammerspoon's own
-- console so nothing of the user's is opened or closed.
function H:consoleWindows(done)
  local wasOpen = fcall(hs.console.hswindow) ~= nil
  self.consoleWasOpen = wasOpen
  local function step(fn, wait, next_)
    local ok = pcall(fn)
    if not ok then return next_(false) end
    after(wait, function() next_(true) end)
  end
  -- Opening an already-open console only focuses it, so it has to be shut
  -- first for the creation to be a real one.
  step(function() if wasOpen then hs.closeConsole() end end,
    wasOpen and C.consoleWaitSeconds or 0, function()
      local mark = self:mark()
      step(hs.openConsole, C.consoleWaitSeconds, function(opened)
        local created = self:since(mark)
        local mark2 = self:mark()
        step(hs.closeConsole, C.consoleWaitSeconds, function(closed)
          local destroyed = self:since(mark2)
          if not opened then
            self:fail("E1", "hs.openConsole() errored")
          else
            self:verdict(
              tapeHas(created, "window.open")
                or tapeHas(created, "palette.open"),
              "E1", "console windowCreated asked for: " .. tapeText(created))
          end
          if not closed then
            self:fail("E2", "hs.closeConsole() errored")
          else
            self:verdict(
              tapeHas(destroyed, "window.close")
                or tapeHas(destroyed, "palette.close"),
              "E2", "console windowDestroyed asked for: "
                .. tapeText(destroyed))
          end
          self:appLaunch(done)
        end)
      end)
    end)
end

-- `flap` needs an application that is not already running, and the only
-- honest trigger is to launch one. Nothing already running is touched, and
-- anything this launches is quit again.
function H:appLaunch(done)
  local chosen
  for _, bundle in ipairs(C.launchCandidates) do
    local installed = fcall(hs.application.pathForBundleID, bundle)
    local running = fcall(hs.application.get, bundle)
    if installed and not running and not chosen then chosen = bundle end
  end
  if not chosen then
    self:na("E3", "not tested: every candidate app is already running or "
      .. "not installed -- see the guided phase")
    return self:finderFiles(done)
  end
  local mark = self:mark()
  local ok = pcall(hs.application.launchOrFocusByBundleID, chosen)
  if not ok then
    self:fail("E3", "could not launch " .. chosen)
    return self:finderFiles(done)
  end
  after(C.launchWaitSeconds, function()
    local tape = self:since(mark)
    self:verdict(tapeHas(tape, "app.launch"), "E3", string.format(
      "launching %s asked for: %s", chosen, tapeText(tape)))
    local app = fcall(hs.application.get, chosen)
    if app then pcall(function() app:kill() end) end
    self:finderFiles(done)
  end)
end

-- A file appearing and disappearing under a watched directory. With anything
-- but Finder frontmost the gate is meant to swallow it, which is check 4.2 --
-- the positive case needs Finder in front and lives in the guided phase.
function H:finderFiles(done)
  local home = os.getenv("HOME") or ""
  local path = string.format("%s/Desktop/platinumsnd-diagnostic-%d.tmp",
    home, math.floor(clock()))
  local front = fcall(hs.application.frontmostApplication)
  local frontBundle = front and call(front, "bundleID")
  local finderFront = frontBundle == "com.apple.finder"

  local gate = ((self.obj.sources or {})[4] or {}).gate
  local graceOpen = false
  if gate then
    local ok, answer = pcall(gate.shouldSound, gate, clock())
    graceOpen = ok and answer or false
  end

  local mark = self:mark()
  local file, err = io.open(path, "w")
  if not file then
    self:fail("E4", "could not create " .. path .. ": " .. tostring(err))
    return done()
  end
  file:write("PlatinumSnd diagnostics\n")
  file:close()

  after(C.finderWaitSeconds, function()
    local created = self:since(mark)
    local mark2 = self:mark()
    os.remove(path)
    after(C.finderWaitSeconds, function()
      local removed = self:since(mark2)
      local expectSound = finderFront or graceOpen
      local text = string.format(
        "creating then removing %s with frontmost=%s (gate open: %s): "
        .. "create asked for %s, remove asked for %s",
        path:match("[^/]+$"), tostring(frontBundle), tostring(graceOpen),
        tapeText(created), tapeText(removed))
      if expectSound then
        self:verdict(tapeHas(created, "finder.new")
          or tapeHas(created, "finder.copydone"), "E4", text)
      else
        self:verdict(#created == 0 and #removed == 0, "E4", text
          .. " -- expected silence, since the gate requires Finder to have "
          .. "been frontmost within finderGraceSeconds")
      end
      done()
    end)
  end)
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
  {id = "F6", instruction = "Mount a disk image, then eject it.",
   expect = {"disk.insert", "disk.eject"}},
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
  local text = string.format("%s (%ds): %s", step.id, C.guidedWindowSeconds,
    step.instruction)
  print("PlatinumSnd diagnose: " .. text)
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
    self:guidedStep(index + 1, done)
  end)
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

  -- Hold on to the probe: stop() drops the reference, and whether it handed
  -- the process-wide AX messaging timeout back is only readable from the
  -- object itself.
  local probe = (sources[1] or {}).probe
  local observersBefore = call(sources[3], "observerCount")

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

  -- macOS publishes no getter for the AX messaging timeout, so the strongest
  -- evidence available is that Probe:release() ran -- it is the only thing
  -- that hands the process-wide 50 ms bound back.
  local released = probe and probe.released == true
  self:verdict(released == true, "G9", string.format(
    "the probe handed the process-wide AX timeout back (released=%s); there "
    .. "is no getter for it, so this is the strongest available evidence",
    tostring(probe and probe.released)))

  -- And a functional proxy: accessibility still answers after the bound was
  -- supposed to be lifted.
  local title = call(fcall(hs.window.focusedWindow), "title")
  self:verdict(title ~= nil, "G10", string.format(
    "accessibility still answers after stop() (focused window title: %s)",
    tostring(title)))

  after(C.settleSeconds, function()
    if self.wasRunning then
      local ok = pcall(function() self.obj:start() end)
      self:verdict(ok and self.obj.running == true, "G11", string.format(
        "restarted the Spoon as it was found (running=%s)",
        tostring(self.obj.running)))
    else
      self:na("G11", "left stopped, which is how the Spoon was found")
    end
    done()
  end)
end

-- ================================================================= report

function H:summary()
  self:heading("Summary")
  self:raw(string.format("PASS %d   FAIL %d   WARN %d   ---- %d   SKIP %d",
    self.counts.PASS, self.counts.FAIL, self.counts.WARN,
    self.counts["----"], self.counts.SKIP))
  self:raw("")
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

function H:finish()
  -- Restoration first, and each part on its own, so one failure cannot leave
  -- the rest of the user's Spoon disturbed.
  pcall(function() self:removeShim() end)
  pcall(function()
    if self.cursorHome then mouseSet(self.cursorHome.x, self.cursorHome.y) end
  end)
  pcall(function()
    if self.obj.engine then self.obj:dryRun(self.wasDryRun) end
  end)
  pcall(function()
    if self.consoleWasOpen then hs.openConsole() end
  end)

  pcall(function()
    for _, timer in ipairs(self.timers or {}) do
      pcall(function() timer:stop() end)
    end
    self.timers = nil
    self.obj.diagnosing = nil
  end)

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

  local delay = tonumber(self.opts.delay) or 0
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

return function(obj, opts)
  opts = opts or {}
  -- One at a time. Two harnesses would shim each other's shims, move the
  -- cursor against each other and interleave their reports, and the second
  -- one's restoration would put the first one's wrapper back.
  if obj.diagnosing then
    print("PlatinumSnd diagnose: already running; wait for it to finish")
    return obj
  end
  print("PlatinumSnd diagnose: running; this takes about a minute "
    .. (opts.guided and "plus the guided steps " or "")
    .. "and moves the cursor. Keep your hands off the mouse until it says "
    .. "it has finished.")
  pcall(hs.alert.show, "PlatinumSnd diagnostics running -- hands off the "
    .. "mouse", 6)
  local harness = H.new(obj, opts)
  -- Rooted on the Spoon for the duration. Every step after the first is
  -- reached through a timer callback, and a harness reachable only from a
  -- timer closure would be at the mercy of when those are collected.
  obj.diagnosing = harness
  local ok, err = pcall(function() harness:begin() end)
  if not ok then
    pcall(function() harness:removeShim() end)
    obj.diagnosing = nil
    print("PlatinumSnd diagnose: could not start: " .. tostring(err))
  end
  return obj
end
