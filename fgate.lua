-- PURE. No hs dependency, no clock and no filesystem: `now` and the paths are
-- always supplied by the caller.
--
-- Two jobs, both about the same problem -- a filesystem event says what
-- changed but never who changed it, or how many changes are really one act:
--
--   * the frontmost gate, which keeps Dropbox syncing and background
--     downloads silent by requiring Finder to have been frontmost recently;
--   * the burst accumulator, which gathers the paths appearing inside one
--     coalesce window so a five-file copy sounds once, and says how many
--     appeared so the caller can tell a new item from a copy finishing.
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

-- Record that `path` appeared. Returns true when this opened a new burst,
-- which is the caller's cue to schedule the settle; every other call folds
-- into the burst already open and schedules nothing.
--
-- The window is anchored at the first event and never extended, so a long
-- copy trickling files in cannot hold the sound off indefinitely. It sounds
-- once, 200 ms in, and the stragglers open the next burst.
--
-- An event arriving when the open burst is already overdue starts a fresh one
-- rather than joining it. That is what keeps a settle lost to a reload or a
-- clock step from stranding one burst that then swallows every appearance for
-- the rest of the session.
function Gate:noteAppeared(path, now)
  if fgate.isIgnorablePath(path) then return false end
  local burst = self.burst
  if burst and not isDue(burst, now, self.tuning) then
    if not burst.paths[path] then
      burst.paths[path] = true
      burst.count = burst.count + 1
    end
    return false
  end
  self.burst = {openedAt = now, paths = {[path] = true}, count = 1}
  return true
end

-- The number of distinct paths that appeared in the settled burst, or nil
-- when there is nothing to sound yet. One is a new item; two or more is a
-- copy or a multi-file drop finishing.
--
-- Called before the window is up it reports nothing and leaves the burst
-- open, so a timer that fires a hair early costs a retry rather than a wrong
-- count. There is no separate "a sound just fired" suppression: bursts are a
-- full coalesce window apart by construction, so a second mechanism could
-- only ever suppress something legitimate.
function Gate:settle(now)
  local burst = self.burst
  if not burst then return nil end
  if not isDue(burst, now, self.tuning) then return nil end
  self.burst = nil
  return burst.count
end

return fgate
