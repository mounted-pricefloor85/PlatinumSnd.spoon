package.path = "../?.lua;" .. package.path
local runner = require("runner")
local axpolicy = require("axpolicy")
local t = runner.suite("axpolicy")

local TUNING = {
  cacheMaxAgeSeconds     = 0.25,
  cacheTolerancePx       = 4,
  breakerThreshold       = 3,
  breakerWindowSeconds   = 10,
  breakerCooldownSeconds = 30,
  probeBudgetSeconds     = 0.1,
  probeWindowSeconds     = 1,
}

local function cache(over)
  local c = {role = "AXButton", pid = 42, x = 100, y = 200, at = 1000.0}
  for k, v in pairs(over or {}) do c[k] = v end
  return c
end

t.test("fresh cache at the same point is usable", function()
  runner.isTrue(axpolicy.isCacheUsable(cache(), 1000.1, 100, 200, 42, TUNING))
end)

t.test("nil cache is never usable", function()
  runner.eq(axpolicy.isCacheUsable(nil, 1000.1, 100, 200, 42, TUNING), false)
end)

t.test("cache older than the max age is rejected", function()
  runner.eq(axpolicy.isCacheUsable(cache(), 1000.3, 100, 200, 42, TUNING), false)
end)

t.test("cursor beyond the pixel tolerance is rejected", function()
  runner.eq(axpolicy.isCacheUsable(cache(), 1000.1, 120, 200, 42, TUNING), false)
end)

t.test("cursor within the pixel tolerance is accepted", function()
  runner.isTrue(axpolicy.isCacheUsable(cache(), 1000.1, 103, 202, 42, TUNING))
end)

t.test("a different frontmost pid is rejected", function()
  runner.eq(axpolicy.isCacheUsable(cache(), 1000.1, 100, 200, 99, TUNING), false)
end)

t.test("breaker opens on the third failure inside the window", function()
  local b = axpolicy.newBreaker(TUNING)
  b:recordFailure(7, 100)
  b:recordFailure(7, 101)
  runner.eq(b:isOpen(7, 101), false)
  b:recordFailure(7, 102)
  runner.isTrue(b:isOpen(7, 102))
end)

t.test("failures ageing out of the window do not accumulate", function()
  local b = axpolicy.newBreaker(TUNING)
  b:recordFailure(7, 100)
  b:recordFailure(7, 105)
  b:recordFailure(7, 120)
  runner.eq(b:isOpen(7, 120), false)
end)

t.test("breaker closes again after the cooldown", function()
  local b = axpolicy.newBreaker(TUNING)
  b:recordFailure(7, 100); b:recordFailure(7, 100); b:recordFailure(7, 100)
  runner.isTrue(b:isOpen(7, 120))
  runner.eq(b:isOpen(7, 131), false)
end)

t.test("breaker is per pid", function()
  local b = axpolicy.newBreaker(TUNING)
  b:recordFailure(7, 100); b:recordFailure(7, 100); b:recordFailure(7, 100)
  runner.isTrue(b:isOpen(7, 100))
  runner.eq(b:isOpen(8, 100), false)
end)

t.test("success clears the failure history", function()
  local b = axpolicy.newBreaker(TUNING)
  b:recordFailure(7, 100); b:recordFailure(7, 100)
  b:recordSuccess(7)
  b:recordFailure(7, 100)
  runner.eq(b:isOpen(7, 100), false)
end)

t.test("global budget trips when probe time exceeds it in one second", function()
  local b = axpolicy.newBreaker(TUNING)
  b:noteProbeTime(0.04, 100.0)
  b:noteProbeTime(0.04, 100.2)
  runner.eq(b:isOverBudget(100.2), false)
  b:noteProbeTime(0.04, 100.4)
  runner.isTrue(b:isOverBudget(100.4))
end)

t.test("budget recovers once old samples age out", function()
  local b = axpolicy.newBreaker(TUNING)
  b:noteProbeTime(0.04, 100.0)
  b:noteProbeTime(0.04, 100.2)
  b:noteProbeTime(0.04, 100.4)
  runner.isTrue(b:isOverBudget(100.4))
  runner.eq(b:isOverBudget(101.6), false)
end)

return t
