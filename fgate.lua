-- PURE. No hs dependency, no clock and no filesystem: `now` and the paths are
-- always supplied by the caller.
--
-- Two jobs, both about the same problem -- a filesystem event says what
-- changed but never who changed it, or how many changes are really one act:
--
--   * the frontmost gate, which keeps Dropbox syncing and background
--     downloads silent by requiring Finder to have been frontmost recently;
--   * the burst accumulator, which gathers the paths changing inside one
--     coalesce window so a five-file copy sounds once, nets arrivals against
--     departures so a rename is not mistaken for a new item, and says how
--     many really appeared so the caller can tell one from the other.
local fgate = {}

-- The final path component, so the rule reads the same whether it is handed a
-- full FSEvents path or a bare directory entry.
local function lastComponent(path)
  return path:match("([^/]+)/?$") or path
end

-- Finder rewrites `.DS_Store` whenever a window's contents change, so a new
-- folder on the Desktop arrives as two paths, not one -- which without this
-- would sound like a copy finishing rather than a new item. An "empty" Trash
-- keeps its `.DS_Store` too, and would never look empty.
--
-- The rule is the last component only, deliberately. Testing every component
-- would be stricter, but everything in `~/.Trash` sits under a dotted parent
-- and the trash counter has to be able to count it.
function fgate.isIgnorablePath(path)
  if type(path) ~= "string" then return true end
  return lastComponent(path):sub(1, 1) == "."
end

local Gate = {}
Gate.__index = Gate

function fgate.newGate(tuning)
  return setmetatable({
    tuning = tuning,
    frontAt = nil,
    burst = nil,
  }, Gate)
end

-- Finder was seen frontmost at `now`. Called on activation and again on each
-- filesystem event that arrives while Finder is still the front app, so the
-- grace below measures "Finder was frontmost this recently" rather than "the
-- user switched to Finder this recently" -- otherwise a window left frontmost
-- for a minute would gate itself out.
function Gate:noteFinderFront(now)
  self.frontAt = now
end

-- The boundary belongs to the sound: a copy started in Finder can finish just
-- after the user has switched away, which is the case the grace exists for.
function Gate:shouldSound(now)
  if not self.frontAt then return false end
  return now - self.frontAt <= self.tuning.finderGraceSeconds
end

local function isDue(burst, now, tuning)
  return now - burst.openedAt >= tuning.finderCoalesceSeconds
end

-- Record a change to `path`: `exists` says whether the item is on disk now,
-- so true is an arrival and false a departure. Returns true when this opened
-- a new burst, which is the caller's cue to schedule the settle; every other
-- call folds into the burst already open and schedules nothing.
--
-- Departures open bursts too, because FSEvents does not promise to deliver
-- the two halves of a rename in any particular order. A departure that could
-- not open one would be dropped whenever it arrived first, and the arrival
-- behind it would then look like a brand new item.
--
-- The window is anchored at the first event and never extended, so a long
-- copy trickling files in cannot hold the sound off indefinitely. It sounds
-- once, 200 ms in, and the stragglers open the next burst.
--
-- An event arriving when the open burst is already overdue starts a fresh one
-- rather than joining it. That is what keeps a settle lost to a reload or a
-- clock step from stranding one burst that then swallows every appearance for
-- the rest of the session.
function Gate:noteChange(path, exists, now)
  if fgate.isIgnorablePath(path) then return false end
  local burst = self.burst
  local opened = false
  if not burst or isDue(burst, now, self.tuning) then
    burst = {openedAt = now, arrivals = {}, departures = {}}
    self.burst = burst
    opened = true
  end
  -- Sets, so a path reported twice counts once -- and separate sets, so a
  -- file created and deleted inside one window cancels itself rather than
  -- being swallowed by a single seen-list.
  if exists then
    burst.arrivals[path] = true
  else
    burst.departures[path] = true
  end
  return opened
end

-- The directory an entry sits in. Tolerates a trailing slash, which FSEvents
-- may or may not put on a directory path, so a renamed folder still matches
-- the parent its old name was under.
local function parentOf(path)
  return path:match("^(.*)/[^/]+/?$") or ""
end

-- How many items really appeared in the settled burst, or nil when there is
-- nothing to sound. One is a new item; two or more is a copy or a multi-file
-- drop finishing.
--
-- Departures cancel arrivals under the same parent, one for one. A rename in
-- place reports the old name leaving and the new name arriving under one
-- parent, and `fnew` is kThemeSoundNewItem -- a renamed item did not appear,
-- it was already there. An item moved in from elsewhere has its departure
-- under a different parent, so nothing cancels it and it sounds, which is
-- right: it did appear where it now is.
--
-- One for one rather than by set membership, so a rename that happens to
-- share a window with a genuine arrival silences only its own half. A burst
-- that cancels down to nothing is still cleared, so the next change opens a
-- fresh one.
--
-- Called before the window is up it reports nothing and leaves the burst
-- open. Nothing re-arms the timer, so a settle arriving early -- which needs
-- the wall clock to step backwards, since run loop timers do not fire before
-- their due time -- costs that burst its sound: the next change past the
-- window opens a fresh burst and discards the stale one. Losing one sound to
-- a clock step beats a re-arming loop for a case the run loop does not
-- produce.
--
-- There is no separate "a sound just fired" suppression: bursts are a full
-- coalesce window apart by construction, so a second mechanism could only
-- ever suppress something legitimate.
function Gate:settle(now)
  local burst = self.burst
  if not burst then return nil end
  if not isDue(burst, now, self.tuning) then return nil end
  self.burst = nil

  local net = {}
  for path in pairs(burst.arrivals) do
    local parent = parentOf(path)
    net[parent] = (net[parent] or 0) + 1
  end
  for path in pairs(burst.departures) do
    local parent = parentOf(path)
    net[parent] = (net[parent] or 0) - 1
  end

  local count = 0
  for _, n in pairs(net) do
    -- Per parent, and never below zero: a surplus of departures in one
    -- directory must not eat arrivals in another.
    if n > 0 then count = count + n end
  end
  if count == 0 then return nil end
  return count
end

return fgate
