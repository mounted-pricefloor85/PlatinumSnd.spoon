local fgate = dofile(hs.spoons.resourcePath("fgate.lua"))

local src = {}

-- Identity, not tuning: this names the one app the source exists to watch.
local FINDER_BUNDLE = "com.apple.finder"

-- `fdon`/`fdof` are kThemeSoundFinderDragOnIcon/OffIcon -- the cursor crossing
-- a droppable icon mid-drag -- so they belong to the pointer layer, not here.
-- Row expand and collapse have no sound in this pack, which is why no
-- `AXRow*` notification appears below. `fral` (kThemeSoundResolveAlias) has no
-- signal worth guessing at and stays unmapped.
local WATCHED = {
  AXSelectedChildrenChanged = "finder.select",
}

local function isFinder(app)
  return app ~= nil and app:bundleID() == FINDER_BUNDLE
end

local function finderIsFrontmost()
  return isFinder(hs.application.frontmostApplication())
end

-- Whether this event changes what exists, and if so what the disk says now:
-- true for an arrival, false for a departure, nil for neither.
--
-- FSEvents coalesces per path, so one entry can carry several flags at once.
-- A modification is not a change of existence and never counts -- a file
-- being written to is not a new item. Created, renamed and removed all are,
-- and each is handed over with what is on disk now, because `itemRenamed`
-- fires on both ends of a move and a file created a moment ago may already be
-- gone. The gate decides what a pair of them means: an arrival and a
-- departure under one parent is a rename, not an appearance.
local function existenceChange(path, flag)
  if not (flag.itemCreated or flag.itemRenamed or flag.itemRemoved) then
    return nil
  end
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
    -- Compared against nil deliberately: false is a departure, which the gate
    -- very much wants to hear about.
    local exists = flag and existenceChange(path, flag)
    if exists ~= nil and self.gate:noteChange(path, exists, now) then
      self:scheduleSettle()
    end
  end
end

function src:attachFinder(app)
  if not isFinder(app) then return end
  -- Read the pid before tearing anything down: an app object that cannot
  -- answer must not cost us a working observer.
  local pid = app:pid()
  if not pid then return end
  -- A relaunched Finder has a new pid, and an observer is bound to the pid it
  -- was made for, so the old one is dead weight however it got here.
  self:detachFinder()

  local ok, observer = pcall(hs.axuielement.observer.new, pid)
  if not ok or not observer then return end

  local element = hs.axuielement.applicationElement(app)
  if not element then
    pcall(function() observer:stop() end)
    return
  end

  observer:callback(function(_, _, notification)
    local semantic = WATCHED[notification]
    if semantic then self.engine:play(semantic) end
  end)

  -- Individually guarded, and counted. An observer that registered nothing
  -- would sit there watching for a notification it never asked for, and
  -- recording it would tell the retry in start() that all was well -- leaving
  -- selection silent for the session, with no error and no second chance,
  -- because Finder does not relaunch again in normal use.
  local registered = 0
  for notification in pairs(WATCHED) do
    if pcall(function() observer:addWatcher(element, notification) end) then
      registered = registered + 1
    end
  end
  if registered == 0 then
    pcall(function() observer:stop() end)
    return
  end

  -- Recorded only once it is actually running, so stop() never has an
  -- observer to shut down that was never started, and a failure here leaves
  -- the source unattached and retryable rather than holding a dead handle.
  if pcall(function() observer:start() end) then
    self.observer = observer
    self.observerPid = pid
  else
    pcall(function() observer:stop() end)
  end
end

function src:detachFinder()
  if self.observer then
    pcall(function() self.observer:stop() end)
    self.observer = nil
  end
  self.observerPid = nil
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
      -- A retry that costs nothing. Attachment can fail transiently, and it
      -- can also go stale: Finder can be relaunched without a terminated
      -- event ever reaching us, leaving an observer bound to a pid that no
      -- longer exists. Keying on the pid covers both, and Finder activates
      -- constantly in normal use, so selection heals within seconds instead
      -- of staying silent for the session. No timer, no sweeper.
      if self.observerPid ~= app:pid() then self:attachFinder(app) end
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
