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
-- and this caps the drift at cacheRevalidateSeconds.
--
-- A cache with no probedAt at all reads as due, so any path that builds one
-- without going through a probe degrades to asking rather than to trusting.
function axpolicy.needsRevalidation(cache, now, tuning)
  if not cache then return true end
  if type(cache.probedAt) ~= "number" then return true end
  return now - cache.probedAt > tuning.cacheRevalidateSeconds
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
