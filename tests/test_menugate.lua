package.path = "../?.lua;" .. package.path
local runner = require("runner")
local menugate = require("menugate")
local t = runner.suite("menugate")

local TUNING = {menuWatchMaxSeconds = 60, menuSelectDedupeSeconds = 0.1}

-- Stand-ins for accessibility elements. The real ones are userdata that
-- Hammerspoon mints afresh for every notification, so two handles for one menu
-- are two distinct objects that compare equal through their own `__eq`. These
-- behave the same way, which is what lets the tests below tell a register that
-- compares with `==` from one that keys a table by the handle -- Lua looks
-- table keys up by RAW equality, so the table would treat the two as different
-- menus and never match the second one against the first.
local Element = {}
Element.__index = Element
Element.__eq = function(a, b) return a.id == b.id end
local function element(id) return setmetatable({id = id}, Element) end

-- The open-menu register. AXMenuItemSelected is posted by the menu item, so a
-- watcher has to go on the menu itself; this remembers which menus have one so
-- that none is attached twice, none is left behind, and none can accumulate.

t.test("a menu opening is worth a watcher", function()
  local g = menugate.newGate(TUNING)
  runner.isTrue(g:noteOpen(element("file"), 100))
  runner.eq(g:count(), 1)
end)

t.test("the same menu opening twice is worth one watcher", function()
  local g = menugate.newGate(TUNING)
  runner.isTrue(g:noteOpen(element("file"), 100))
  -- A second handle for the same menu, which is what a second notification
  -- would carry.
  runner.eq(g:noteOpen(element("file"), 100.5), false)
  runner.eq(g:count(), 1)
end)

t.test("closing hands back the handle the watcher was attached with",
  function()
    local g = menugate.newGate(TUNING)
    local attached = element("file")
    g:noteOpen(attached, 100)
    local held = g:noteClose(element("file"))
    -- Equal, and the very same object: the watcher must come off with what it
    -- went on with, not with the handle the close notification happened to
    -- carry.
    runner.isTrue(rawequal(held, attached))
    runner.eq(g:count(), 0)
  end)

t.test("closing a menu that was never open hands back nothing", function()
  local g = menugate.newGate(TUNING)
  runner.isNil(g:noteClose(element("edit")))
end)

t.test("closing twice hands back nothing the second time", function()
  local g = menugate.newGate(TUNING)
  g:noteOpen(element("file"), 100)
  runner.isTrue(g:noteClose(element("file")) ~= nil)
  runner.isNil(g:noteClose(element("file")))
end)

-- A missing element is not a menu. Registering nil would make every later nil
-- look like the same open menu, and hand it back to be detached.
t.test("a nil element is never registered", function()
  local g = menugate.newGate(TUNING)
  runner.eq(g:noteOpen(nil, 100), false)
  runner.eq(g:count(), 0)
  runner.isNil(g:noteClose(nil))
end)

-- Opening a submenu leaves the parent menu open, and both post
-- AXMenuItemSelected from their own items.
t.test("a submenu is held alongside its parent", function()
  local g = menugate.newGate(TUNING)
  runner.isTrue(g:noteOpen(element("file"), 100))
  runner.isTrue(g:noteOpen(element("file>recent"), 100.4))
  runner.eq(g:count(), 2)
  runner.isTrue(g:noteClose(element("file>recent")) ~= nil)
  runner.eq(g:count(), 1)
end)

-- Not every app posts AXMenuClosed -- the verification checklist records that
-- as expected rather than as a fault -- so without an age ceiling the register
-- would gain an entry, and the observer a watcher, for every menu the user
-- ever opened.

t.test("a menu that never reports closing ages out", function()
  local g = menugate.newGate(TUNING)
  local stuck = element("file")
  g:noteOpen(stuck, 100)
  local stale = g:expire(200)
  runner.eq(#stale, 1)
  runner.isTrue(rawequal(stale[1], stuck))
  runner.eq(g:count(), 0)
end)

t.test("expiry hands back only what is stale", function()
  local g = menugate.newGate(TUNING)
  g:noteOpen(element("old"), 100)
  g:noteOpen(element("new"), 150)
  local stale = g:expire(170)
  runner.eq(#stale, 1)
  runner.eq(stale[1].id, "old")
  runner.eq(g:count(), 1)
  -- And the survivor is still the one the watcher went on with.
  runner.eq(g:noteClose(element("new")).id, "new")
end)

t.test("a menu exactly at the ceiling is not yet stale", function()
  local g = menugate.newGate(TUNING)
  g:noteOpen(element("file"), 0)
  runner.eq(#g:expire(60), 0)
  runner.eq(g:count(), 1)
end)

t.test("expiry with nothing open hands back nothing", function()
  local g = menugate.newGate(TUNING)
  runner.eq(#g:expire(200), 0)
end)

t.test("draining empties the register and hands everything back", function()
  local g = menugate.newGate(TUNING)
  g:noteOpen(element("file"), 100)
  g:noteOpen(element("edit"), 100)
  runner.eq(#g:drain(), 2)
  runner.eq(g:count(), 0)
  runner.eq(#g:drain(), 0)
end)

-- The selection dedupe. The application-level watcher and the menu-level one
-- can both deliver a single selection in an app that propagates, in no
-- guaranteed order, and exactly one sound must come out.

t.test("a lone selection sounds", function()
  local g = menugate.newGate(TUNING)
  runner.isTrue(g:shouldSoundSelect(element("save"), 100))
end)

t.test("the same item twice inside the window sounds once", function()
  local g = menugate.newGate(TUNING)
  runner.isTrue(g:shouldSoundSelect(element("save"), 100))
  runner.eq(g:shouldSoundSelect(element("save"), 100.01), false)
end)

t.test("the dedupe boundary belongs to the silence", function()
  local g = menugate.newGate(TUNING)
  runner.isTrue(g:shouldSoundSelect(element("save"), 0))
  runner.eq(g:shouldSoundSelect(element("save"), 0.1), false)
end)

t.test("the same item again past the window sounds again", function()
  local g = menugate.newGate(TUNING)
  runner.isTrue(g:shouldSoundSelect(element("save"), 100))
  runner.isTrue(g:shouldSoundSelect(element("save"), 100.5))
end)

-- Two watchers for one selection is a duplicate; two selections is two
-- selections, however fast they arrive.
t.test("a different item inside the window still sounds", function()
  local g = menugate.newGate(TUNING)
  runner.isTrue(g:shouldSoundSelect(element("save"), 100))
  runner.isTrue(g:shouldSoundSelect(element("close"), 100.01))
end)

-- An unknown handle cannot be shown to be a different item, and two menu
-- items chosen inside a tenth of a second is not something a human does. So
-- the conservative reading costs nothing real, and the alternative is the
-- double sound this whole mechanism exists to avoid.
t.test("an unknown handle is treated as a possible repeat", function()
  local g = menugate.newGate(TUNING)
  runner.isTrue(g:shouldSoundSelect(nil, 100))
  runner.eq(g:shouldSoundSelect(nil, 100.01), false)
  runner.eq(g:shouldSoundSelect(element("save"), 100.02), false)
end)

t.test("an unknown handle beside a known one still sounds later", function()
  local g = menugate.newGate(TUNING)
  runner.isTrue(g:shouldSoundSelect(element("save"), 100))
  runner.eq(g:shouldSoundSelect(nil, 100.01), false)
  runner.isTrue(g:shouldSoundSelect(nil, 100.5))
end)

-- Extending the window on every suppression would let a stuck stream of
-- notifications silence selection for as long as it lasted.
t.test("a suppressed selection does not extend the window", function()
  local g = menugate.newGate(TUNING)
  runner.isTrue(g:shouldSoundSelect(element("save"), 100))
  runner.eq(g:shouldSoundSelect(element("save"), 100.05), false)
  -- 0.15 after the one that sounded, 0.1 after the one that did not.
  runner.isTrue(g:shouldSoundSelect(element("save"), 100.15))
end)

-- The open-menu register and the dedupe are independent: a watcher going on
-- or coming off must not decide whether the next selection sounds.
t.test("registering a menu does not disturb the dedupe", function()
  local g = menugate.newGate(TUNING)
  runner.isTrue(g:shouldSoundSelect(element("save"), 100))
  g:noteOpen(element("file"), 100.01)
  g:noteClose(element("file"))
  runner.eq(g:shouldSoundSelect(element("save"), 100.02), false)
end)

-- Regression guard. Every case above feeds TUNING, whose values are the
-- production ones, so a module that inlined those same literals and ignored
-- the table entirely would still pass all of them.
local function tuned(over)
  local c = {}
  for k, v in pairs(TUNING) do c[k] = v end
  for k, v in pairs(over) do c[k] = v end
  return c
end

t.test("menuWatchMaxSeconds is read from tuning, not inlined", function()
  local patient = menugate.newGate(tuned({menuWatchMaxSeconds = 600}))
  patient:noteOpen(element("file"), 100)
  runner.eq(#patient:expire(300), 0)
  local strict = menugate.newGate(tuned({menuWatchMaxSeconds = 1}))
  strict:noteOpen(element("file"), 100)
  runner.eq(#strict:expire(102), 1)
end)

t.test("menuSelectDedupeSeconds is read from tuning, not inlined", function()
  local wide = menugate.newGate(tuned({menuSelectDedupeSeconds = 5}))
  wide:shouldSoundSelect(element("save"), 100)
  runner.eq(wide:shouldSoundSelect(element("save"), 102), false)
  local narrow = menugate.newGate(tuned({menuSelectDedupeSeconds = 0.001}))
  narrow:shouldSoundSelect(element("save"), 100)
  runner.isTrue(narrow:shouldSoundSelect(element("save"), 100.01))
end)

return t
