package.path = "../?.lua;" .. package.path
local runner = require("runner")
local fgate = require("fgate")
local t = runner.suite("fgate")

local TUNING = {finderCoalesceSeconds = 0.2, finderGraceSeconds = 2}

-- Times are chosen to sit clear of the window boundary rather than on it,
-- because 100.2 - 100 is not 0.2 in doubles. The boundary itself is tested
-- separately from zero, where the arithmetic is exact.
--
-- noteChange takes the path, whether the item is on disk NOW, and the time.
-- True is an arrival, false a departure.

-- The frontmost gate. Filesystem events say nothing about who caused them,
-- so this is the whole defence against Dropbox and background downloads.

t.test("silent when Finder was never frontmost", function()
  local g = fgate.newGate(TUNING)
  runner.eq(g:shouldSound(100), false)
end)

t.test("sounds when Finder is currently frontmost", function()
  local g = fgate.newGate(TUNING)
  g:noteFinderFront(100)
  runner.isTrue(g:shouldSound(100.5))
end)

t.test("silent once the grace period lapses", function()
  local g = fgate.newGate(TUNING)
  g:noteFinderFront(100)
  runner.eq(g:shouldSound(103), false)
end)

-- A copy started in Finder can finish just after the user has switched away,
-- which is exactly what the grace period exists to cover, so the boundary
-- belongs to the sound rather than to the silence.
t.test("still sounds at the far edge of the grace period", function()
  local g = fgate.newGate(TUNING)
  g:noteFinderFront(100)
  runner.isTrue(g:shouldSound(102))
end)

-- The burst accumulator. One item appearing is a new item; several appearing
-- together is a copy finishing, and either way it sounds exactly once.

t.test("a lone appearance settles as one item", function()
  local g = fgate.newGate(TUNING)
  runner.isTrue(g:noteChange("/Desktop/notes.txt", true, 100))
  runner.eq(g:settle(100.3), 1)
end)

t.test("a burst of several settles once, carrying the count", function()
  local g = fgate.newGate(TUNING)
  runner.isTrue(g:noteChange("/Desktop/a", true, 100))
  runner.eq(g:noteChange("/Desktop/b", true, 100.02), false)
  runner.eq(g:noteChange("/Desktop/c", true, 100.05), false)
  runner.eq(g:noteChange("/Desktop/d", true, 100.06), false)
  runner.eq(g:noteChange("/Desktop/e", true, 100.08), false)
  runner.eq(g:settle(100.3), 5)
  runner.isNil(g:settle(100.6), "the burst must not settle twice")
end)

-- FSEvents reports a path once per change, not once per file, so a create
-- followed by a metadata write arrives as the same path twice.
t.test("the same path twice inside a window counts once", function()
  local g = fgate.newGate(TUNING)
  g:noteChange("/Desktop/a", true, 100)
  g:noteChange("/Desktop/a", true, 100.05)
  runner.eq(g:settle(100.3), 1)
end)

t.test("an event arriving mid-window does not extend it", function()
  local g = fgate.newGate(TUNING)
  g:noteChange("/Desktop/a", true, 100)
  g:noteChange("/Desktop/b", true, 100.15)
  -- Due 0.2 after the FIRST event. Were the window extended by the second,
  -- it would not be due until 100.35 and this would report nothing.
  runner.eq(g:settle(100.25), 2)
end)

t.test("the window is due at exactly the coalesce interval", function()
  local g = fgate.newGate(TUNING)
  g:noteChange("/Desktop/a", true, 0)
  runner.eq(g:settle(0.2), 1)
end)

t.test("settling before the window elapses keeps the burst open", function()
  local g = fgate.newGate(TUNING)
  g:noteChange("/Desktop/a", true, 100)
  runner.isNil(g:settle(100.1))
  runner.eq(g:settle(100.3), 1)
end)

t.test("two bursts a window apart settle separately", function()
  local g = fgate.newGate(TUNING)
  runner.isTrue(g:noteChange("/Desktop/a", true, 100))
  runner.eq(g:settle(100.3), 1)
  -- Same path again: a settled burst remembers nothing.
  runner.isTrue(g:noteChange("/Desktop/a", true, 100.5))
  runner.eq(g:settle(100.8), 1)
end)

t.test("settling with no burst open reports nothing", function()
  local g = fgate.newGate(TUNING)
  runner.isNil(g:settle(100))
end)

-- Self-healing. If the caller's settle never arrives -- a timer lost to a
-- reload, a clock stepping backwards -- the stale burst must not swallow
-- every appearance that follows it for the rest of the session.
t.test("an appearance past an overdue window opens a fresh burst", function()
  local g = fgate.newGate(TUNING)
  g:noteChange("/Desktop/a", true, 100)
  runner.isTrue(g:noteChange("/Desktop/b", true, 100.5))
  runner.eq(g:settle(100.8), 1)
end)

-- Renames. `fnew` is kThemeSoundNewItem, and a renamed item did not appear --
-- it was already there under another name. FSEvents reports a rename in place
-- as the old name leaving and the new name arriving under the same parent,
-- inside one batch; an item moved in from elsewhere arrives with no matching
-- departure to cancel it.

t.test("a rename in place is silent", function()
  local g = fgate.newGate(TUNING)
  g:noteChange("/Desktop/untitled folder", false, 100)
  g:noteChange("/Desktop/Reports", true, 100.01)
  runner.isNil(g:settle(100.3))
end)

t.test("a rename reported arrival-first is equally silent", function()
  local g = fgate.newGate(TUNING)
  g:noteChange("/Desktop/Reports", true, 100)
  g:noteChange("/Desktop/untitled folder", false, 100.01)
  runner.isNil(g:settle(100.3))
end)

t.test("a cancelled burst is cleared, not left open", function()
  local g = fgate.newGate(TUNING)
  g:noteChange("/Desktop/old", false, 100)
  g:noteChange("/Desktop/new", true, 100.01)
  runner.isNil(g:settle(100.3))
  runner.isTrue(g:noteChange("/Desktop/later", true, 100.31))
  runner.eq(g:settle(100.61), 1)
end)

t.test("a file moved in from another folder still sounds", function()
  local g = fgate.newGate(TUNING)
  -- Both watchers feed one gate, and the departure lands under a different
  -- parent, so it cancels nothing. The item did appear where it now is.
  g:noteChange("/Downloads/report.pdf", false, 100)
  g:noteChange("/Desktop/report.pdf", true, 100.01)
  runner.eq(g:settle(100.3), 1)
end)

t.test("three files moved in sound one copy", function()
  local g = fgate.newGate(TUNING)
  for _, name in ipairs({"a", "b", "c"}) do
    g:noteChange("/Downloads/" .. name, false, 100)
    g:noteChange("/Desktop/" .. name, true, 100.01)
  end
  runner.eq(g:settle(100.3), 3)
end)

t.test("a rename beside a real arrival still sounds for the arrival",
  function()
    local g = fgate.newGate(TUNING)
    g:noteChange("/Desktop/old", false, 100)
    g:noteChange("/Desktop/new", true, 100.01)
    g:noteChange("/Desktop/dropped", true, 100.02)
    -- One departure cancels one arrival, not every arrival that happens to
    -- share the parent.
    runner.eq(g:settle(100.3), 1)
  end)

t.test("one departure cancels only one arrival", function()
  local g = fgate.newGate(TUNING)
  g:noteChange("/Desktop/a", true, 100)
  g:noteChange("/Desktop/b", true, 100.01)
  g:noteChange("/Desktop/gone", false, 100.02)
  g:noteChange("/Desktop/gone", false, 100.03)  -- the same departure twice
  runner.eq(g:settle(100.3), 1)
end)

t.test("a departure alone opens a burst and sounds nothing", function()
  local g = fgate.newGate(TUNING)
  runner.isTrue(g:noteChange("/Desktop/deleted", false, 100))
  runner.isNil(g:settle(100.3))
end)

t.test("more departures than arrivals never goes negative", function()
  local g = fgate.newGate(TUNING)
  g:noteChange("/Desktop/x", false, 100)
  g:noteChange("/Desktop/y", false, 100.01)
  g:noteChange("/Downloads/z", true, 100.02)
  -- The surplus departure under one parent must not eat the arrival under
  -- another.
  runner.eq(g:settle(100.3), 1)
end)

t.test("a trailing slash does not hide the shared parent", function()
  local g = fgate.newGate(TUNING)
  g:noteChange("/Desktop/old folder/", false, 100)
  g:noteChange("/Desktop/new folder/", true, 100.01)
  runner.isNil(g:settle(100.3))
end)

-- Bookkeeping files. Finder rewrites .DS_Store whenever a window's contents
-- change, so without this a new folder on the Desktop would arrive as two
-- items and sound like a copy.

t.test("bookkeeping files never open a burst", function()
  local g = fgate.newGate(TUNING)
  runner.eq(g:noteChange("/Desktop/.DS_Store", true, 100), false)
  runner.isNil(g:settle(100.3))
end)

t.test("a bookkeeping file does not inflate a new item into a copy", function()
  local g = fgate.newGate(TUNING)
  g:noteChange("/Desktop/untitled folder", true, 100)
  g:noteChange("/Desktop/.DS_Store", true, 100.05)
  runner.eq(g:settle(100.3), 1)
end)

t.test("a bookkeeping departure cannot cancel a real arrival", function()
  local g = fgate.newGate(TUNING)
  g:noteChange("/Desktop/report.pdf", true, 100)
  g:noteChange("/Desktop/.DS_Store", false, 100.05)
  runner.eq(g:settle(100.3), 1)
end)

t.test("the ignorable rule reads the last component only", function()
  runner.isTrue(fgate.isIgnorablePath(".DS_Store"))
  runner.isTrue(fgate.isIgnorablePath("/Users/x/Desktop/.DS_Store"))
  runner.isTrue(fgate.isIgnorablePath("/Users/x/Desktop/.hidden/"))
  -- Everything in ~/.Trash sits under a dotted parent, and the trash counter
  -- has to be able to count it.
  runner.eq(fgate.isIgnorablePath("/Users/x/.Trash/report.pdf"), false)
  runner.eq(fgate.isIgnorablePath("report.pdf"), false)
end)

t.test("a non-string path is ignorable rather than fatal", function()
  runner.isTrue(fgate.isIgnorablePath(nil))
end)

-- Regression guard. Every case above feeds TUNING, whose values are the
-- production ones, so a module that inlined those same literals and ignored
-- the table entirely would still pass all of them. The cases below feed
-- deliberately contrasting values.
local function tuned(over)
  local c = {}
  for k, v in pairs(TUNING) do c[k] = v end
  for k, v in pairs(over) do c[k] = v end
  return c
end

t.test("finderGraceSeconds is read from tuning, not inlined", function()
  local patient = fgate.newGate(tuned({finderGraceSeconds = 30}))
  patient:noteFinderFront(100)
  runner.isTrue(patient:shouldSound(120))
  local strict = fgate.newGate(tuned({finderGraceSeconds = 0.5}))
  strict:noteFinderFront(100)
  runner.eq(strict:shouldSound(101), false)
end)

t.test("finderCoalesceSeconds is read from tuning, not inlined", function()
  local slow = fgate.newGate(tuned({finderCoalesceSeconds = 1}))
  slow:noteChange("/Desktop/a", true, 100)
  runner.isNil(slow:settle(100.3))
  local quick = fgate.newGate(tuned({finderCoalesceSeconds = 0.01}))
  quick:noteChange("/Desktop/a", true, 100)
  runner.eq(quick:settle(100.05), 1)
end)

return t
