local src = {}

-- `mnus` is kThemeSoundMenuItemRelease and this source owns it exclusively:
-- an observer also catches keyboard-driven selection, which the pointer layer
-- never sees. `mnui` (kThemeSoundMenuItemHilite) is deliberately absent --
-- highlighting falls out of the hover layer's AXMenuItem transitions, and a
-- second owner here would sound every menu item twice.
local WATCHED = {
  AXMenuOpened = "menu.open",
  AXMenuItemSelected = "menu.select",
  AXMenuClosed = "menu.close",
}

function src:start(ctx)
  self.engine = ctx.engine
  self.tuning = ctx.tuning
  self.log = ctx.log
  self.observers = {}  -- pid -> hs.axuielement.observer

  for _, app in ipairs(hs.application.runningApplications()) do
    self:attach(app)
  end

  self.appWatcher = hs.application.watcher.new(function(_, event, app)
    if event == hs.application.watcher.launched then
      self:attach(app)
    elseif event == hs.application.watcher.terminated then
      self:detach(app and app:pid())
    end
  end)
  self.appWatcher:start()

  -- An app can die without a clean terminated notification -- a crash, a
  -- force quit, a watcher started after the app was already gone -- and the
  -- observer for its pid would then sit in the table forever. Reconcile
  -- against the list of processes that actually exist.
  self.sweeper = hs.timer.doEvery(ctx.tuning.observerSweepSeconds, function()
    self:sweep()
  end)
end

function src:attach(app)
  if not app then return end
  -- Only apps with a UI and a Dock tile. Background agents have no menus,
  -- and observing every daemon on the machine would be pure cost.
  if app:kind() ~= 1 then return end
  local pid = app:pid()
  if not pid or self.observers[pid] then return end

  local ok, observer = pcall(hs.axuielement.observer.new, pid)
  if not ok or not observer then return end

  local element = hs.axuielement.applicationElement(app)
  if not element then return end

  observer:callback(function(_, _, notification)
    local semantic = WATCHED[notification]
    if semantic then self.engine:play(semantic) end
  end)

  -- Individually guarded: an app that refuses one notification should still
  -- be observed for the others it does publish.
  for notification in pairs(WATCHED) do
    pcall(function() observer:addWatcher(element, notification) end)
  end

  -- Only recorded once it is actually running, so the table never holds an
  -- observer that stop() would then try to shut down.
  local started = pcall(function() observer:start() end)
  if started then
    self.observers[pid] = observer
  end
end

function src:detach(pid)
  if not pid then return end
  local observer = self.observers and self.observers[pid]
  if observer then
    pcall(function() observer:stop() end)
    self.observers[pid] = nil
  end
end

function src:sweep()
  local alive = {}
  for _, app in ipairs(hs.application.runningApplications()) do
    local pid = app:pid()
    if pid then alive[pid] = true end
  end
  -- Clearing an existing key during a pairs() traversal is defined behaviour
  -- in Lua; adding one would not be, and this loop adds nothing.
  for pid in pairs(self.observers) do
    if not alive[pid] then self:detach(pid) end
  end
end

function src:observerCount()
  local n = 0
  for _ in pairs(self.observers or {}) do n = n + 1 end
  return n
end

function src:stop()
  -- Watcher and sweeper first: neither may add an observer to a table that
  -- is being emptied.
  if self.appWatcher then self.appWatcher:stop(); self.appWatcher = nil end
  if self.sweeper then self.sweeper:stop(); self.sweeper = nil end
  for pid in pairs(self.observers or {}) do self:detach(pid) end
  self.observers = {}
end

return src
