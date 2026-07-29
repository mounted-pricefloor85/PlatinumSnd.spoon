--- === PlatinumSnd ===
---
--- Mac OS 9 Platinum interface sounds for modern macOS.

local obj = {}
obj.__index = obj

obj.name = "PlatinumSnd"
obj.version = "0.1"
obj.author = "Andrey Subbotin"
obj.license = "MIT - https://opensource.org/licenses/MIT"

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
  poolSize                    = 3,
  volume                      = 0.5,
}

obj.log = hs.logger.new("PlatinumSnd", "info")
obj.sources = {}
obj.running = false

function obj:init()
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

function obj:start()
  if self.running then return self end
  if not hs.accessibilityState() then
    hs.alert.show("PlatinumSnd needs Accessibility permission")
    hs.accessibilityState(true)
    return self
  end
  self.engine:load()
  local ctx = {engine = self.engine, tuning = self.tuning, log = self.log}
  for _, source in ipairs(self.sources) do
    local ok, err = pcall(function() source:start(ctx) end)
    if not ok then self.log.e("source failed to start: " .. tostring(err)) end
  end
  self.running = true
  return self
end

function obj:stop()
  if not self.running then return self end
  for _, source in ipairs(self.sources) do
    local ok, err = pcall(function() source:stop() end)
    if not ok then self.log.e("source failed to stop: " .. tostring(err)) end
  end
  self.running = false
  return self
end

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

function obj:bindHotkeys(mapping)
  -- bindHotkeysToSpec takes (spec, mapping): spec maps names to functions,
  -- mapping maps the same names to {mods, key}.
  local spec = {toggle = hs.fnutils.partial(self.toggle, self)}
  hs.spoons.bindHotkeysToSpec(spec, mapping)
  return self
end

function obj:dryRun(enabled) self.engine:dryRun(enabled); return self end
function obj:audition() self.engine:audition(); return self end

-- The diagnostic harness. Loaded on demand rather than at init, so a Spoon
-- nobody is diagnosing never pays for it: no file read, no table built, and
-- no chance of a tool that exists to observe the Spoon changing it.
--
-- `:diagnose()` runs phases A to E and G by itself and takes about a minute;
-- `:diagnose({guided = true})` adds the handful of steps that need a human,
-- and `{delay = 10}` waits before starting so another app can be brought to
-- the front for the accessibility walk. Writes ~/Desktop and the Console.
function obj:diagnose(opts)
  return dofile(hs.spoons.resourcePath("diagnose.lua"))(self, opts)
end

return obj
