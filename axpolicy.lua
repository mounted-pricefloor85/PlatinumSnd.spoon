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
