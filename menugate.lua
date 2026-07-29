-- PURE. No hs dependency and no clock: `now` is always supplied by the
-- caller, and the menu elements are opaque handles it never looks inside.
--
-- Two jobs, both consequences of where `AXMenuItemSelected` comes from.
-- Apple's AXNotificationConstants.h says of it, verbatim, "Value is the
-- selected menu item UIElement" -- the menu ITEM posts it -- and of
-- AXMenuOpened, "Value is the opened menu UIElement". The same header also
-- says that an observer registered on the application element receives a
-- notification "regardless of which element in the application sends the
-- notification", so on paper all three should arrive there. In practice
-- AXMenuOpened and AXMenuClosed do and AXMenuItemSelected mostly does not, so
-- a second watcher goes on the menu handed over when it opened. Hence:
--
--   * the open-menu register, which remembers the handle each watcher went on
--     with so the same watcher is never attached twice, always comes off
--     again, and cannot accumulate one per menu the user ever opened;
--   * the selection dedupe, which lets exactly one sound out when the
--     application-level and menu-level watchers both fire for one selection.
local menugate = {}

local Gate = {}
Gate.__index = Gate

function menugate.newGate(tuning)
  return setmetatable({
    tuning = tuning,
    open = {},
    lastItem = nil,
    lastAt = nil,
  }, Gate)
end

-- A list scanned with `==`, not a table keyed by the element, and the
-- difference matters: Lua looks table keys up by RAW equality, which for
-- userdata is object identity, while the accessibility layer mints a fresh
-- handle for every notification. Two handles for one menu would be two keys,
-- and the close would never find what the open put there. `==` runs the
-- handle's own equality instead.
--
-- Linear because the list is a menu and its open submenus. There is no depth
-- of menu on a Mac at which the scan is worth a hash.
local function indexOf(open, menu)
  for i, entry in ipairs(open) do
    if entry.menu == menu then return i end
  end
  return nil
end

-- A menu opened at `now`. Returns true when this is the first the register has
-- heard of it, which is the caller's cue to attach a watcher.
--
-- A nil element is not a menu and is never recorded: registering it would make
-- every later nil look like the same open menu and be handed back to be
-- detached.
function Gate:noteOpen(menu, now)
  if menu == nil then return false end
  if indexOf(self.open, menu) then return false end
  table.insert(self.open, {menu = menu, at = now})
  return true
end

-- A menu closed. Returns the handle the register is holding -- the one the
-- watcher went on with, not the one the close notification happened to carry
-- -- or nil when this menu had no watcher.
function Gate:noteClose(menu)
  if menu == nil then return nil end
  local i = indexOf(self.open, menu)
  if not i then return nil end
  return table.remove(self.open, i).menu
end

-- Every menu open longer than `menuWatchMaxSeconds`, removed from the register
-- and handed back for the caller to detach.
--
-- Not every app posts AXMenuClosed -- the verification checklist records that
-- as expected rather than as a fault -- and without a ceiling the register
-- would gain an entry, and the observer a watcher, for every menu the user
-- ever opened. A menu genuinely still open past the ceiling loses its
-- menu-level watcher and falls back to the application-level one, which is the
-- cheaper mistake: nobody holds a menu down for a minute mid-decision.
--
-- The ceiling is exclusive, so a menu exactly at it survives one more round.
function Gate:expire(now)
  local stale = {}
  -- Backwards, so removing an entry cannot skip the one behind it.
  for i = #self.open, 1, -1 do
    if now - self.open[i].at > self.tuning.menuWatchMaxSeconds then
      table.insert(stale, table.remove(self.open, i).menu)
    end
  end
  return stale
end

-- Everything the register holds, emptied and handed back. The caller's
-- teardown: an entry that outlived its observer would be a claim about
-- watchers that no longer exist.
function Gate:drain()
  local all = {}
  for _, entry in ipairs(self.open) do table.insert(all, entry.menu) end
  self.open = {}
  return all
end

function Gate:count() return #self.open end

-- Whether a selection of `item` at `now` should sound.
--
-- The application-level and menu-level watchers can both deliver one selection
-- in an app that propagates, and nothing says which arrives first, so this is
-- a window rather than a rule about ordering.
--
-- An unknown handle on either side is read as a possible repeat rather than a
-- proven difference. Two menu items chosen inside the window is not something
-- a human does, so the conservative reading costs nothing real, and the
-- alternative is the double sound the whole mechanism exists to prevent.
--
-- A suppressed selection does not move the window. Extending it on every
-- suppression would let a stuck stream of notifications silence selection for
-- as long as it lasted.
function Gate:shouldSoundSelect(item, now)
  local same = item == nil or self.lastItem == nil or item == self.lastItem
  if self.lastAt and same
    and now - self.lastAt <= self.tuning.menuSelectDedupeSeconds then
    return false
  end
  self.lastItem = item
  self.lastAt = now
  return true
end

return menugate
