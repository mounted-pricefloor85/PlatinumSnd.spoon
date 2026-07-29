--- === PlatinumSnd ===
---
--- Mac OS 9 Platinum interface sounds for modern macOS.
---
--- The sound pack is NOT included and this Spoon is silent until you add it.
--- The sounds are Apple's, from the Platinum Sounds set that shipped with
--- Mac OS 8.5 through 9.2.2, and are not mine to redistribute, so `snd/` is
--- empty here. The README says where to find a copy and lists every filename
--- the loader expects.
---
--- Needs Accessibility permission, and Full Disk Access for the Finder
--- sounds. Run `spoon.PlatinumSnd:audition()` once the pack is in place to
--- confirm it loaded.

local obj = {}
obj.__index = obj

obj.name = "PlatinumSnd"
obj.version = "0.1"
obj.author = "Andrey Subbotin"
obj.license = "MIT - https://opensource.org/licenses/MIT"
obj.homepage = "https://github.com/eploko/PlatinumSnd.spoon"

--- PlatinumSnd.tuning
--- Variable
--- Every constant the Spoon uses, in one table. Timings are in seconds and
--- distances in points. Change a value before calling `start()`; the sources
--- read the table when they start, not when they are registered.
obj.tuning = {
  hoverIntervalSeconds        = 0.06,
  cacheMaxAgeSeconds          = 0.25,
  cacheTolerancePx            = 4,
  -- How long a cached role may ride on frame containment alone. A leaf role
  -- gets the generous ceiling: its frame cannot enclose a child with some
  -- other role, so containment really does mean the answer has not changed.
  -- A container gets the short one, because a hit-test would have descended
  -- past it into children the cache has never seen.
  cacheRevalidateSeconds      = 2,
  containerRevalidateSeconds  = 0.2,
  axTimeoutSeconds            = 0.05,
  breakerThreshold            = 3,
  breakerWindowSeconds        = 10,
  breakerCooldownSeconds      = 30,
  probeBudgetSeconds          = 0.1,
  probeWindowSeconds          = 1,
  finderCoalesceSeconds       = 0.2,
  finderGraceSeconds          = 2,
  -- Relative to $HOME. The places a user actually creates and copies things;
  -- watching the whole home directory would pick up every application's
  -- support files and caches.
  finderWatchedDirs           = {"Desktop", "Documents", "Downloads"},
  finderTrashDir              = ".Trash",
  dragSampleSeconds           = 0.1,
  -- How far the pointer must travel between a press and its release for the
  -- gesture to have been a drag rather than a click. A drag's release is not
  -- a click and does not sound like one; well under this, a sloppy click is
  -- still a click.
  dragThresholdPx             = 10,
  -- How long a Return that found no dialog suppresses the next check. The
  -- check is one accessibility call, and this is what keeps a held Return in
  -- a text editor from making one per keystroke.
  defaultButtonRecheckSeconds = 0.2,
  observerSweepSeconds        = 60,
  -- How long a menu-level AXMenuItemSelected watcher may live without its
  -- menu ever reporting closed. Not every app posts AXMenuClosed, so this is
  -- what stops the observer fleet growing a watcher per menu ever opened. Far
  -- longer than anyone holds a menu down mid-decision, and a menu still open
  -- past it simply falls back to the application-level watcher.
  menuWatchMaxSeconds         = 60,
  -- How long one menu selection stays deduped. The application-level and
  -- menu-level watchers can both deliver it, microseconds apart and in no
  -- guaranteed order; a human cannot choose two menu items this fast.
  menuSelectDedupeSeconds     = 0.1,
  poolSize                    = 3,
  volume                      = 0.5,
}

obj.log = hs.logger.new("PlatinumSnd", "info")
obj.sources = {}
obj.running = false

function obj:init()
  -- Loaded here rather than at each start(), for the two module functions that
  -- own the process-wide AX messaging bound. src_pointer loads its own copy
  -- for the Probe constructor; both are stateless with respect to the bound,
  -- which lives on the system-wide element rather than in either table.
  self.axprobe = dofile(hs.spoons.resourcePath("axprobe.lua"))
  local Sound = dofile(hs.spoons.resourcePath("sound.lua"))
  self.engine = Sound.new({
    root = hs.spoons.resourcePath("snd"),
    volume = self.tuning.volume,
    poolSize = self.tuning.poolSize,
    log = self.log,
  })
  self:register(dofile(hs.spoons.resourcePath("src_pointer.lua")))
  self:register(dofile(hs.spoons.resourcePath("src_windows.lua")))
  self:register(dofile(hs.spoons.resourcePath("src_menus.lua")))
  self:register(dofile(hs.spoons.resourcePath("src_finder.lua")))
  self:register(dofile(hs.spoons.resourcePath("src_keys.lua")))
  return self
end

function obj:register(source)
  table.insert(self.sources, source)
  return self
end

--- PlatinumSnd:start()
--- Method
--- Starts making sounds. Loads the sound pack, installs the accessibility
--- timeout and starts every source. Does nothing if already running, and
--- refuses to start without Accessibility permission, alerting once and
--- raising the system prompt instead.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The PlatinumSnd object
function obj:start()
  if self.running then return self end
  if not hs.accessibilityState() then
    hs.alert.show("PlatinumSnd needs Accessibility permission")
    hs.accessibilityState(true)
    return self
  end
  self.engine:load()
  -- BEFORE any source starts. The 50 ms AX messaging bound is process-global
  -- and three sources rely on it -- src_pointer for its hit-test and attribute
  -- reads, src_windows for focusedWindow/frame/subrole, src_keys for subrole.
  -- It used to be installed by the pointer probe's constructor, which worked
  -- only because that source is registered first, and since each start below
  -- is individually pcall'ed a pointer that failed to start left the other two
  -- making unbounded AX calls on the main runloop. Owned here instead, where
  -- it cannot depend on any one source surviving.
  self.axprobe.installTimeout(self.tuning, self.log)
  local ctx = {engine = self.engine, tuning = self.tuning, log = self.log}
  for _, source in ipairs(self.sources) do
    local ok, err = pcall(function() source:start(ctx) end)
    if not ok then self.log.e("source failed to start: " .. tostring(err)) end
  end
  self.running = true
  return self
end

--- PlatinumSnd:stop()
--- Method
--- Stops making sounds, and stops costing anything. Every event tap, timer,
--- watcher and accessibility observer is torn down and the process-wide
--- accessibility timeout is handed back, so a stopped Spoon is inert rather
--- than muted. Does nothing if not running.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The PlatinumSnd object
function obj:stop()
  if not self.running then return self end
  for _, source in ipairs(self.sources) do
    local ok, err = pcall(function() source:stop() end)
    if not ok then self.log.e("source failed to stop: " .. tostring(err)) end
  end
  -- AFTER every source has stopped, so nothing is still making AX calls when
  -- the bound goes. It is a process-global mutation, so leaving it set would
  -- keep this Spoon's 50 ms limit on hs.window, hs.uielement and every other
  -- AX consumer long after the toggle hotkey was supposed to make us inert.
  -- Unconditional: a source that threw on the way down does not get to keep
  -- the bound alive. See 5.10 in docs/mac-verification.md.
  self.axprobe.resetTimeout(self.log)
  self.running = false
  return self
end

--- PlatinumSnd:toggle()
--- Method
--- Starts the Spoon if it is stopped, stops it if it is running, and shows an
--- alert saying which of those actually happened.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The PlatinumSnd object
function obj:toggle()
  if self.running then
    self:stop()
  else
    self:start()
  end
  -- Report the state we ended up in, not the one we intended. start() bails
  -- out without starting when Accessibility is denied, and announcing "on"
  -- there would be the only user-facing surface telling a flat lie.
  hs.alert.show(self.running and "PlatinumSnd on" or "PlatinumSnd off")
  return self
end

--- PlatinumSnd:bindHotkeys(mapping)
--- Method
--- Binds the Spoon's hotkeys. One action is available, `toggle`.
---
--- Parameters:
---  * mapping - A table mapping action names to a {mods, key} pair, for
---    example `{toggle = {{"cmd", "alt", "ctrl"}, "9"}}`
---
--- Returns:
---  * The PlatinumSnd object
function obj:bindHotkeys(mapping)
  -- bindHotkeysToSpec takes (spec, mapping): spec maps names to functions,
  -- mapping maps the same names to {mods, key}.
  local spec = {toggle = hs.fnutils.partial(self.toggle, self)}
  hs.spoons.bindHotkeysToSpec(spec, mapping)
  return self
end

--- PlatinumSnd:dryRun(enabled)
--- Method
--- Logs the sound each event would play instead of playing it. Lines look
--- like `AXCheckBox -> checkbox.press (chkp)`, which is how you find out why
--- something sounded wrong.
---
--- Parameters:
---  * enabled - true to log instead of play, false to go back to sounding
---
--- Returns:
---  * The PlatinumSnd object
function obj:dryRun(enabled) self.engine:dryRun(enabled); return self end

--- PlatinumSnd:audition()
--- Method
--- Plays every sound in the pack in sequence, printing each name to the
--- Console as it goes. Takes a bit over a minute. Use it to confirm the pack
--- loaded and to learn what each of the four letter names sounds like.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The PlatinumSnd object
function obj:audition() self.engine:audition(); return self end

-- The diagnostic harness. Loaded on demand rather than at init, so a Spoon
-- nobody is diagnosing never pays for it: no file read, no table built, and
-- no chance of a tool that exists to observe the Spoon changing it.
--
-- `:diagnose()` runs phases A to E and G by itself and takes about a minute;
-- `:diagnose({guided = true})` adds the handful of steps that need a human,
-- and `{delay = 10}` waits before starting so another app can be brought to
-- the front for the accessibility walk. Writes ~/Desktop and the Console.
--- PlatinumSnd:diagnose([opts])
--- Method
--- Runs a diagnostic harness against the live Hammerspoon: permissions, the
--- sound pack, the accessibility assumptions the design rests on, the
--- decision chain over whatever is on screen, the cache hit rate, and
--- teardown. Writes a report to the Desktop and prints it to the Console. It
--- moves the cursor briefly and puts it back, and touches nothing else of
--- yours.
---
--- Parameters:
---  * opts - An optional table. `guided = true` adds the steps that need you
---    to open a menu or drag a file. `delay = 10` waits that many seconds
---    before starting, so another application can be brought to the front
---    for the accessibility walk.
---
--- Returns:
---  * None
function obj:diagnose(opts)
  return dofile(hs.spoons.resourcePath("diagnose.lua"))(self, opts)
end

return obj
