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
-- cursor is still inside the same element's frame with the same app
-- frontmost is stronger evidence than "the sample is under a quarter of a
-- second old". That would otherwise let a role live forever, and a UI can
-- change under a resting cursor -- a button replaced in place by a progress
-- bar keeps the same bounds and reports a different role. So `probedAt`
-- records when an app was last actually asked, an elision never touches it,
-- and this caps the drift.
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
-- Frames are optional: not every element publishes AXFrame. With one
-- missing, or malformed, there is no identity to compare and the roles
-- decide alone -- which errs towards silence rather than towards a blip on
-- every tick.
function axpolicy.transitionSounds(previousRole, previousFrame,
                                   newRole, newFrame)
  if newRole == nil then return false end
  if previousRole ~= newRole then return true end
  if type(previousFrame) ~= "table" or type(newFrame) ~= "table" then
    return false
  end
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
