local fgate = dofile(hs.spoons.resourcePath("fgate.lua"))

local src = {}

-- Identity, not tuning: these name the one app and the one notification this
-- source exists to watch, the way src_menus names its notifications.
local FINDER_BUNDLE = "com.apple.finder"
local SELECTION_CHANGED = "AXSelectedChildrenChanged"

-- `fdon`/`fdof` are kThemeSoundFinderDragOnIcon/OffIcon -- the cursor crossing
-- a droppable icon mid-drag -- so they belong to the pointer layer, not here.
-- Row expand and collapse have no sound in this pack; nothing is wired to
-- them. `fral` (kThemeSoundResolveAlias) has no signal worth guessing at and
-- stays unmapped.

local function isFinder(app)
  return app ~= nil and app:bundleID() == FINDER_BUNDLE
end

local function finderIsFrontmost()
  return isFinder(hs.application.frontmostApplication())
end

-- Whether this event is something arriving rather than something leaving.
--
-- FSEvents coalesces per path, so one entry can carry several flags at once.
-- `itemRenamed` fires on both ends of a move -- which is how a drag from
-- another folder arrives -- and a file created a moment ago may already be
-- gone, so existence on disk is what separates an arrival from a departure.
local function appeared(path, flag)
  if not (flag.itemCreated or flag.itemRenamed) then return false end
  return hs.fs.attributes(path) ~= nil
end

-- Entries in the Trash, or nil when it cannot be read -- which the caller
-- treats as "no transition to judge" rather than as empty, so an unreadable
-- Trash stays silent instead of announcing a phantom emptying.
--
-- `.` and `..` need no special case: they fall out of the same dot rule that
-- discards `.DS_Store`, which an emptied Trash keeps and which would
-- otherwise stop it ever looking empty.
local function trashCount(path)
  local ok, iter, data = pcall(hs.fs.dir, path)
  if not ok or type(iter) ~= "function" then return nil end
  local n = 0
  for name in iter, data do
    if not fgate.isIgnorablePath(name) then n = n + 1 end
  end
  return n
end

-- `ftrs` is kThemeSoundEmptyTrash: the Trash being emptied, not a file being
-- thrown into it. So it sounds on a genuine non-empty -> empty transition and
-- on nothing else, which also makes the repeated events of one long emptying
-- collapse to a single sound without needing the burst gate.
--
-- Deliberately not gated on Finder being frontmost, unlike the sounds below.
-- Emptying the Trash is unambiguous whoever is in front, and the confirmation
-- sheet can move focus.
function src:judgeTrash()
  local count = trashCount(self.trashPath)
  if count == nil then return end
  if self.trashWasEmpty == false and count == 0 then
    self.engine:play("finder.trash")
  end
  self.trashWasEmpty = (count == 0)
end

-- At most one settle timer, ever.
--
-- The gate reports a burst opening once, but a run loop stalled past the
-- coalesce window delivers the next filesystem event before the timer it
-- already armed -- both are queued on the same loop -- so the gate opens a
-- fresh burst with the old timer still live. Left alone, the old one fires
-- into a burst that is not due, finds nothing to sound, and clears the handle
-- to the new timer on its way out: stop() could then no longer reach it.
function src:scheduleSettle()
  if self.settleTimer then self.settleTimer:stop() end
  self.settleTimer = hs.timer.doAfter(self.tuning.finderCoalesceSeconds,
    function()
      self.settleTimer = nil
      local count = self.gate:settle(hs.timer.secondsSinceEpoch())
      if not count then return end
      -- `fnew` is kThemeSoundNewItem and `fcpd` is kThemeSoundCopyDone. One
      -- path appearing is a new item; several appearing together is a copy or
      -- a multi-file drop finishing.
      self.engine:play(count > 1 and "finder.copydone" or "finder.new")
    end)
end

function src:onDirChange(paths, flags)
  local now = hs.timer.secondsSinceEpoch()
  -- Refresh the front stamp here as well as on activation. Finder can sit
  -- frontmost for minutes before the user makes a folder, and a stamp that
  -- only moved on activation would have aged out of the grace period long
  -- before the event it is meant to admit.
  if finderIsFrontmost() then self.gate:noteFinderFront(now) end
  if not self.gate:shouldSound(now) then return end
  -- Gate first, loop second: background noise costs one in-process read of
  -- the front app and not a single stat call.
  for i, path in ipairs(paths) do
    -- No flag table means no way to tell an arrival from a departure, so the
    -- path is skipped rather than guessed at.
    local flag = flags and flags[i]
    if flag and appeared(path, flag) and self.gate:noteAppeared(path, now) then
      self:scheduleSettle()
    end
  end
end

function src:attachFinder(app)
  if not isFinder(app) then return end
  -- A relaunched Finder has a new pid, and an observer is bound to the pid it
  -- was made for, so the old one is dead weight however it got here.
  self:detachFinder()
  local pid = app:pid()
  if not pid then return end

  local ok, observer = pcall(hs.axuielement.observer.new, pid)
  if not ok or not observer then return end

  local element = hs.axuielement.applicationElement(app)
  if not element then return end

  observer:callback(function(_, _, notification)
    if notification == SELECTION_CHANGED then
      self.engine:play("finder.select")
    end
  end)

  local added = pcall(function()
    observer:addWatcher(element, SELECTION_CHANGED)
  end)
  if not added then return end

  -- Recorded only once it is actually running, so stop() never has an
  -- observer to shut down that was never started.
  if pcall(function() observer:start() end) then
    self.observer = observer
  end
end

function src:detachFinder()
  if self.observer then
    pcall(function() self.observer:stop() end)
    self.observer = nil
  end
end

function src:start(ctx)
  self.engine = ctx.engine
  self.tuning = ctx.tuning
  self.log = ctx.log
  self.gate = fgate.newGate(ctx.tuning)
  self.watchers = {}

  local home = os.getenv("HOME")
  self.trashPath = home .. "/" .. ctx.tuning.finderTrashDir

  -- Seed the emptiness state from what is actually there. Without this the
  -- first event on an already-empty Trash would look like an emptying. Left
  -- unknown if the Trash could not be read, which judgeTrash treats as
  -- nothing to compare against rather than as non-empty.
  local seeded = trashCount(self.trashPath)
  if seeded ~= nil then self.trashWasEmpty = (seeded == 0) end

  for _, dir in ipairs(ctx.tuning.finderWatchedDirs) do
    local path = home .. "/" .. dir
    if hs.fs.attributes(path, "mode") == "directory" then
      local watcher = hs.pathwatcher.new(path, function(paths, flags)
        self:onDirChange(paths, flags)
      end)
      watcher:start()
      table.insert(self.watchers, watcher)
    else
      self.log.d("no such directory to watch: " .. path)
    end
  end

  self.trashWatcher = hs.pathwatcher.new(self.trashPath, function()
    self:judgeTrash()
  end)
  self.trashWatcher:start()

  self.appWatcher = hs.application.watcher.new(function(_, event, app)
    if event == hs.application.watcher.activated and isFinder(app) then
      self.gate:noteFinderFront(hs.timer.secondsSinceEpoch())
    elseif event == hs.application.watcher.launched then
      self:attachFinder(app)
    elseif event == hs.application.watcher.terminated and isFinder(app) then
      self:detachFinder()
    end
  end)
  self.appWatcher:start()

  -- Finder is normally already running, but it need not be: it can be
  -- relaunched, and start() can land while it is down. Either way the watcher
  -- above picks it up when it comes back.
  self:attachFinder(hs.application.get(FINDER_BUNDLE))
end

function src:stop()
  -- Watchers first, so nothing can fire into a half-dismantled source.
  for _, watcher in ipairs(self.watchers or {}) do watcher:stop() end
  self.watchers = {}
  if self.trashWatcher then
    self.trashWatcher:stop(); self.trashWatcher = nil
  end
  if self.appWatcher then self.appWatcher:stop(); self.appWatcher = nil end
  -- Before the gate goes: a settle armed a moment ago must not fire into a
  -- source that has stopped.
  if self.settleTimer then self.settleTimer:stop(); self.settleTimer = nil end
  self:detachFinder()
  self.gate = nil
  self.trashWasEmpty = nil
end

return src
