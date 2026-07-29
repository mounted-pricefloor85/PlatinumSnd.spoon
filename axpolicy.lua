-- PURE. No hs dependency: `now` is always supplied by the caller.
local axpolicy = {}

function axpolicy.isCacheUsable(cache, now, x, y, pid, tuning)
  if not cache then return false end
  if now - cache.at > tuning.cacheMaxAgeSeconds then return false end
  if cache.pid ~= pid then return false end
  local tol = tuning.cacheTolerancePx
  if math.abs(cache.x - x) > tol or math.abs(cache.y - y) > tol then
    return false
  end
  return true
end

-- Returns true when (x, y) lies within the frame rectangle. A nil frame is
-- never a containment, so a missing AXFrame degrades to probing every tick
-- rather than silently pinning the cache.
--
-- The rectangle is half-open: the top and left edges are inside, the bottom
-- and right edges are not. Adjacent AX frames tile a window edge to edge, so
-- a fully closed test would claim the seam belongs to both neighbours; this
-- way it belongs to exactly one. It also makes a zero-size frame contain
-- nothing, which keeps a degenerate frame from pinning the cache to a point.
--
-- Deliberately separate from isCacheUsable. This is an extra elision for the
-- hover loop only; the click path still answers to the staleness and
-- tolerance rules above, which are about how old the ground truth is rather
-- than where the cursor sits.
function axpolicy.isInsideFrame(frame, x, y)
  if type(frame) ~= "table" then return false end
  local fx, fy, fw, fh = frame.x, frame.y, frame.w, frame.h
  if type(fx) ~= "number" or type(fy) ~= "number"
    or type(fw) ~= "number" or type(fh) ~= "number" then
    return false
  end
  return x >= fx and x < fx + fw and y >= fy and y < fy + fh
end

-- The ceiling on how long a role may survive on frame containment alone.
--
-- A successful elision refreshes the cache's `at`, because confirming the
-- cursor is still inside the same element's frame with the same app frontmost
-- is stronger evidence than "the sample is under a quarter of a second old".
-- That would otherwise let a role live forever, so `probedAt` records when an
-- app was last actually asked, an elision never touches it, and this caps the
-- drift for a cursor that is MOVING.
--
-- It does not cap a motionless one. The hover loop's resting-cursor branch
-- returns before this function is ever reached, so a UI that changes under a
-- genuinely still cursor -- a button replaced in place by a progress bar keeps
-- the same bounds and reports a different role -- keeps its old role until the
-- cursor twitches, with no ceiling at all. That is a deliberate trade, made to
-- keep the zero-idle-cost property, and it is recorded under "Known judgement
-- calls" in docs/mac-verification.md alongside the 2.4 check that pins the
-- property it buys.
--
-- The ceiling arrives as an argument because the caller applies two of
-- them. A cached leaf role gets a generous one: its frame cannot enclose a
-- child with a different role, so containment really does mean the answer
-- has not changed. A cached container gets a short one, because its frame
-- encloses children the cache has never seen and containment there is only
-- an approximation.
--
-- A cache with no probedAt at all reads as due, so any path that builds one
-- without going through a probe degrades to asking rather than to trusting.
function axpolicy.needsRevalidation(cache, now, ceilingSeconds)
  if not cache then return true end
  if type(cache.probedAt) ~= "number" then return true end
  return now - cache.probedAt > ceilingSeconds
end

-- Roles that mean more than AXRole alone can say, and the second attribute
-- that settles them.
--
-- Both answers are SYNTHETIC ROLES. macOS reports neither `AXCloseButton` nor
-- `AXTab` as an AXRole, ever -- the first is a SUBROLE promoted into the role
-- slot, the second is invented here outright. They exist because refining the
-- role STRING keeps everything downstream unchanged: the probe cache keeps its
-- shape, `transitionSounds`, `isInsideFrame` and `isCacheUsable` never learn
-- about them, and the role map needs one ordinary entry each.
--
--   AXButton      + AXSubrole == "AXCloseButton"  -> AXCloseButton
--   AXRadioButton + parent AXRole == "AXTabGroup" -> AXTab
--
-- A macOS window's red traffic light is an AXButton whose AXSubrole is
-- AXCloseButton, which is what unlocks `wclp`/`wclr`/`wcle`/`wclx` -- the
-- whole OS 9 close-box tracking cycle. A macOS tab is an AXRadioButton child
-- of an AXTabGroup, which is what unlocks `tabp`/`tabr`/`tabe`/`tabx` and
-- stops tabs borrowing the radio button's sounds.
--
-- Keyed by the role rather than open-coded so that adding a third refinement
-- is a table entry, and so that the "which roles pay for a second read" answer
-- is in one readable place: exactly two, and neither is the generic case.
local REFINE = {
  AXButton = {AXCloseButton = "AXCloseButton"},
  AXRadioButton = {AXTabGroup = "AXTab"},
}

-- What a role becomes once its refining attribute has been read.
--
-- `value` is whatever the probe got back -- a subrole for a button, the
-- parent's role for a radio button -- and nil means the read failed or the
-- attribute was absent. Nil is not an error here: an unrefined role is still
-- a correct role, so the answer is simply the role that came in. Same for a
-- role nobody refines, and for a value that belongs to the other pair.
function axpolicy.refinedRole(role, value)
  local entry = role and REFINE[role]
  if not entry then return role end
  return entry[value] or role
end

-- Whether a table is a frame this module will compare. `type(t) == "table"`
-- is not enough on its own: a table with missing or non-numeric fields passes
-- that test and then compares unpredictably. Two of them compare EQUAL, since
-- nil == nil four times over, which silences a real move; one nil field
-- against a number compares unequal and blips on a widget the cursor never
-- left. Neither answer is earned by anything that was measured.
--
-- Not a theoretical shape. `axprobe` stores whatever AXFrame handed back, and
-- 2.1 in docs/mac-verification.md records that the flat {x, y, w, h} layout is
-- read off Hammerspoon's source rather than confirmed on a Mac. An
-- origin/size nesting arrives here as precisely this table.
local function isFrame(t)
  return type(t) == "table"
    and type(t.x) == "number" and type(t.y) == "number"
    and type(t.w) == "number" and type(t.h) == "number"
end

local function sameRect(a, b)
  return a.x == b.x and a.y == b.y and a.w == b.w and a.h == b.h
end

-- Whether a move has earned its exit/enter pair.
--
-- The frame is the element's identity. Roles alone are too coarse: every
-- element in a menu is AXMenuItem, so a role comparison blips once on the
-- first item and stays silent all the way down, when blipping on every item
-- is the whole character of the sound. Two different items have different
-- frames; one widget re-probed comes back with the frame it had, so a
-- revalidation of something the cursor never left stays silent.
--
-- A newRole of nil means the probe could not answer -- hung app, tripped
-- breaker, budget overrun -- which is not the same as the cursor having
-- moved onto nothing. "Could not ask" is not "left", and sounding an exit
-- there gives a phantom blip on a control the pointer is still resting on.
--
-- Frames are optional: not every element publishes AXFrame. With one missing,
-- or malformed, there is no identity to compare -- and since the roles are
-- already known to be equal by the time that matters, the answer is silence.
-- So a missing frame costs a blip that was earned, never adds one that was
-- not, which is the right way round for a sound that fires on every crossing.
--
-- "Malformed" is checked field by field rather than by type alone, because a
-- table with nil fields would otherwise reach sameRect and compare by
-- accident. See `isFrame` above for what that gets wrong in both directions.
function axpolicy.transitionSounds(previousRole, previousFrame,
                                   newRole, newFrame)
  if newRole == nil then return false end
  if previousRole ~= newRole then return true end
  if not isFrame(previousFrame) or not isFrame(newFrame) then return false end
  return not sameRect(previousFrame, newFrame)
end

local Breaker = {}
Breaker.__index = Breaker

function axpolicy.newBreaker(tuning)
  return setmetatable({
    tuning = tuning,
    failures = {},  -- pid -> array of timestamps
    openUntil = {}, -- pid -> timestamp
    probes = {},    -- array of {at, seconds}
  }, Breaker)
end

function Breaker:recordFailure(pid, now)
  local list = self.failures[pid] or {}
  table.insert(list, now)

  local window = self.tuning.breakerWindowSeconds
  local kept = {}
  for _, at in ipairs(list) do
    if now - at <= window then table.insert(kept, at) end
  end
  self.failures[pid] = kept

  if #kept >= self.tuning.breakerThreshold then
    self.openUntil[pid] = now + self.tuning.breakerCooldownSeconds
    self.failures[pid] = {}
  end
end

function Breaker:recordSuccess(pid)
  self.failures[pid] = nil
end

function Breaker:isOpen(pid, now)
  local until_ = self.openUntil[pid]
  if not until_ then return false end
  if now >= until_ then
    self.openUntil[pid] = nil
    return false
  end
  return true
end

function Breaker:noteProbeTime(seconds, now)
  table.insert(self.probes, {at = now, seconds = seconds})
end

function Breaker:isOverBudget(now)
  local kept, total = {}, 0
  for _, p in ipairs(self.probes) do
    if now - p.at <= self.tuning.probeWindowSeconds then
      table.insert(kept, p)
      total = total + p.seconds
    end
  end
  self.probes = kept
  return total > self.tuning.probeBudgetSeconds
end

return axpolicy
