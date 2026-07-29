local menugate = dofile(hs.spoons.resourcePath("menugate.lua"))

local src = {}

-- `mnus` is kThemeSoundMenuItemRelease and this source owns it exclusively:
-- an observer also catches keyboard-driven selection, which the pointer layer
-- never sees. `mnui` (kThemeSoundMenuItemHilite) is deliberately absent --
-- highlighting falls out of the hover layer's AXMenuItem transitions, and a
-- second owner here would sound every menu item twice.
--
-- All three are registered on the application element. AXMenuItemSelected is
-- registered a second time on each menu as it opens, because that is the only
-- one of the three that does not reliably reach the application element; see
-- watchMenu below.
local WATCHED = {
  AXMenuOpened = "menu.open",
  AXMenuItemSelected = "menu.select",
  AXMenuClosed = "menu.close",
}

-- Protocol names, not tuning: these are the three notifications above spelled
-- out where the dispatch has to branch on which one arrived.
local MENU_OPENED = "AXMenuOpened"
local MENU_CLOSED = "AXMenuClosed"
local MENU_ITEM_SELECTED = "AXMenuItemSelected"

function src:start(ctx)
  self.engine = ctx.engine
  self.tuning = ctx.tuning
  self.log = ctx.log
  -- pid -> {observer = hs.axuielement.observer, menus = menugate gate}
  self.observers = {}

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
  --
  -- Wrapped, because an hs.timer stops itself for good on an unhandled error.
  -- A sweeper that disarms itself is exactly the leak it was put here to
  -- prevent, and nothing would be left to notice observerCount() climbing.
  self.sweeper = hs.timer.doEvery(ctx.tuning.observerSweepSeconds, function()
    local ok, err = pcall(function() self:sweep() end)
    if not ok then self.log.e("observer sweep: " .. tostring(err)) end
  end)
end

function src:attach(app)
  if not app then return end
  -- Only apps with a UI and a Dock tile. Background agents have no menus,
  -- and observing every daemon on the machine would be pure cost.
  if app:kind() ~= 1 then return end
  local pid = app:pid()
  if not pid or self.observers[pid] then return end

  -- Every precondition that needs nothing built comes first. An observer
  -- created and then abandoned on an early return could never be reached
  -- again -- detach() and stop() only walk the table -- so on the two paths
  -- below that do abandon one, it is stopped explicitly on the way out.
  local element = hs.axuielement.applicationElement(app)
  if not element then return end

  local ok, observer = pcall(hs.axuielement.observer.new, pid)
  if not ok or not observer then return end

  -- One register per observer, so a pid going away takes its open menus with
  -- it and no entry can outlive the observer whose watchers it describes.
  local record = {observer = observer, menus = menugate.newGate(self.tuning)}

  observer:callback(function(_, source, notification)
    self:onNotification(record, source, notification)
  end)

  -- Individually guarded: an app that refuses one notification should still
  -- be observed for the others it does publish.
  local registered = 0
  for notification in pairs(WATCHED) do
    if pcall(function() observer:addWatcher(element, notification) end) then
      registered = registered + 1
    end
  end

  -- An app is announced as launched before its accessibility tree is
  -- necessarily ready -- hs.window.filter retries its own registrations for
  -- the same reason. A pid that registered nothing would otherwise be
  -- recorded deaf and, because the table itself is the guard against
  -- re-attaching, stay deaf for as long as the app lived. Leaving it
  -- unrecorded is what lets the sweep try it again.
  if registered == 0 then
    pcall(function() observer:stop() end)
    return
  end

  -- Only recorded once it is actually running, so the table never holds an
  -- observer that stop() would then try to shut down.
  if not pcall(function() observer:start() end) then
    pcall(function() observer:stop() end)
    return
  end
  self.observers[pid] = record
end

-- Every registration this observer holds arrives here -- the three on the
-- application element and one per open menu -- so the dispatch is on the
-- notification rather than on which watcher brought it in.
--
-- `source` is the element that GENERATED the notification, not the one the
-- watcher was registered against: for AXMenuOpened and AXMenuClosed that is
-- the menu, and for AXMenuItemSelected the menu item.
function src:onNotification(record, source, notification)
  local semantic = WATCHED[notification]
  if not semantic then return end
  local now = hs.timer.secondsSinceEpoch()
  if notification == MENU_OPENED then
    self:watchMenu(record, source, now)
  elseif notification == MENU_CLOSED then
    -- The watcher comes off the moment the menu says it has closed. If a
    -- given app turns out to post AXMenuItemSelected AFTER AXMenuClosed
    -- rather than before, that app is back to relying on the
    -- application-level watcher; 3.22 in the verification checklist is where
    -- that gets recorded, and holding the watcher for a grace period is the
    -- remedy if it does. Nothing here can settle it off a Mac.
    local held = record.menus:noteClose(source)
    if held then self:releaseMenus(record, {held}) end
  elseif notification == MENU_ITEM_SELECTED then
    -- One selection can arrive twice over -- once through the application
    -- element in an app that forwards it, once through the menu's own watcher
    -- -- in no guaranteed order. Exactly one sound comes out.
    if not record.menus:shouldSoundSelect(source, now) then return end
  end
  self.engine:play(semantic)
end

-- Put a selection watcher on the menu itself.
--
-- Apple's header says AXMenuItemSelected carries "the selected menu item
-- UIElement" -- the item posts it -- and separately that an observer on the
-- application element hears from any element in the app. The second half is
-- what does not hold up: guided step F2 recorded the open, four item
-- highlights and the close with no selection between them, while a later
-- capture in the same run did get one. So the application-level watcher stays,
-- for the apps that do forward it, and this adds one closer to the poster.
--
-- The menu is the item's parent and the one ancestor known to exist at this
-- moment, which is why the watcher goes there rather than on each item. It has
-- not been established on which apps that last hop is enough; where it is not,
-- the behaviour is exactly what it is today.
function src:watchMenu(record, menu, now)
  -- Anything held too long comes off first, so the fleet cannot grow by a
  -- watcher per menu in an app that never posts AXMenuClosed. The sweeper does
  -- the same on its own schedule, for the session that opens no further menus.
  self:releaseMenus(record, record.menus:expire(now))
  if not record.menus:noteOpen(menu, now) then return end
  local attached = pcall(function()
    record.observer:addWatcher(menu, MENU_ITEM_SELECTED)
  end)
  -- Nothing attached, so nothing may be remembered as attached: a register
  -- that claimed this menu would refuse to try it again and would hand a
  -- phantom back to be detached.
  if not attached then record.menus:noteClose(menu) end
end

-- Take selection watchers off. Individually guarded: a menu element can be
-- gone by the time its app gets round to announcing the close, and one dead
-- handle must not strand the rest.
function src:releaseMenus(record, menus)
  for _, menu in ipairs(menus) do
    pcall(function()
      record.observer:removeWatcher(menu, MENU_ITEM_SELECTED)
    end)
  end
end

function src:detach(pid)
  if not pid then return end
  local record = self.observers and self.observers[pid]
  if record then
    -- Stopping the observer drops every watcher it holds, menu-level ones
    -- included, so there is nothing left to remove -- but the register is
    -- emptied all the same, because an entry that outlived its observer would
    -- be a claim about watchers that no longer exist.
    record.menus:drain()
    pcall(function() record.observer:stop() end)
    self.observers[pid] = nil
  end
end

-- Reconciliation in both directions, not reaping alone: attach() leaves a pid
-- unrecorded when its accessibility tree was not ready yet, and this is what
-- comes back for it. Safe to insert from, because the loop that attaches
-- walks the application list while only the second loop walks self.observers.
function src:sweep()
  local alive = {}
  for _, app in ipairs(hs.application.runningApplications()) do
    local pid = app:pid()
    if pid then alive[pid] = true end
    self:attach(app)
  end
  -- Clearing an existing key during a pairs() traversal is defined behaviour
  -- in Lua; adding one would not be, and this loop adds nothing.
  local now = hs.timer.secondsSinceEpoch()
  for pid, record in pairs(self.observers) do
    if not alive[pid] then
      self:detach(pid)
    else
      -- A menu that opened and never reported closing, in an app that is
      -- still very much alive. Its watcher would otherwise sit on the
      -- observer for as long as the app did, one per menu ever opened.
      self:releaseMenus(record, record.menus:expire(now))
    end
  end
end

function src:observerCount()
  local n = 0
  for _ in pairs(self.observers or {}) do n = n + 1 end
  return n
end

-- Menu-level selection watchers currently attached, across the whole fleet.
-- Nothing in the Spoon reads this; the diagnostics do, to show that opening
-- menus is not growing a watcher per menu the user ever opened.
function src:menuWatchCount()
  local n = 0
  for _, record in pairs(self.observers or {}) do
    n = n + record.menus:count()
  end
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
