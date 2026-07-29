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

-- Regression guard. Every case above feeds TUNING, whose values are the
-- production ones, so a module that inlined those same literals and ignored
-- the table entirely would still pass all of them. The cases below feed
-- deliberately contrasting values, so each one goes red if its constant is
-- hardcoded rather than read.
local function tuned(over)
  local c = {}
  for k, v in pairs(TUNING) do c[k] = v end
  for k, v in pairs(over) do c[k] = v end
  return c
end

t.test("cacheMaxAgeSeconds is read from tuning, not inlined", function()
  local generous = tuned({cacheMaxAgeSeconds = 1})
  runner.isTrue(axpolicy.isCacheUsable(cache(), 1000.3, 100, 200, 42, generous))
  local strict = tuned({cacheMaxAgeSeconds = 0.01})
  runner.eq(axpolicy.isCacheUsable(cache(), 1000.1, 100, 200, 42, strict), false)
end)

t.test("cacheTolerancePx is read from tuning, not inlined", function()
  local loose = tuned({cacheTolerancePx = 25})
  runner.isTrue(axpolicy.isCacheUsable(cache(), 1000.1, 120, 200, 42, loose))
  local exact = tuned({cacheTolerancePx = 0})
  runner.eq(axpolicy.isCacheUsable(cache(), 1000.1, 101, 200, 42, exact), false)
end)

t.test("breakerThreshold is read from tuning, not inlined", function()
  local twitchy = axpolicy.newBreaker(tuned({breakerThreshold = 2}))
  twitchy:recordFailure(7, 100); twitchy:recordFailure(7, 101)
  runner.isTrue(twitchy:isOpen(7, 101))
  local patient = axpolicy.newBreaker(tuned({breakerThreshold = 5}))
  patient:recordFailure(7, 100); patient:recordFailure(7, 101)
  patient:recordFailure(7, 102)
  runner.eq(patient:isOpen(7, 102), false)
end)

t.test("breakerWindowSeconds is read from tuning, not inlined", function()
  local long = axpolicy.newBreaker(tuned({breakerWindowSeconds = 100}))
  long:recordFailure(7, 100); long:recordFailure(7, 105)
  long:recordFailure(7, 120)
  runner.isTrue(long:isOpen(7, 120))
  local short = axpolicy.newBreaker(tuned({breakerWindowSeconds = 1}))
  short:recordFailure(7, 100); short:recordFailure(7, 101)
  short:recordFailure(7, 102)
  runner.eq(short:isOpen(7, 102), false)
end)

t.test("breakerCooldownSeconds is read from tuning, not inlined", function()
  local b = axpolicy.newBreaker(tuned({breakerCooldownSeconds = 5}))
  b:recordFailure(7, 100); b:recordFailure(7, 100); b:recordFailure(7, 100)
  runner.isTrue(b:isOpen(7, 104))
  runner.eq(b:isOpen(7, 105), false)
end)

-- Frame containment. This is the hover loop's IPC elision test: while the
-- cursor sits inside the frame the last probe reported, the answer cannot
-- have changed, so no round trip into the app is needed.
--
-- The rectangle is half-open: the top and left edges belong to it, the
-- bottom and right edges belong to the next widget along. That matches how
-- adjacent AX frames tile a window without overlapping, and it makes a
-- zero-size frame contain nothing at all rather than pinning the cache to a
-- single degenerate point.
local FRAME = {x = 10, y = 20, w = 100, h = 50}

t.test("a point well inside the frame is inside", function()
  runner.isTrue(axpolicy.isInsideFrame(FRAME, 50, 40))
end)

t.test("a point left of the frame is outside", function()
  runner.eq(axpolicy.isInsideFrame(FRAME, 9, 40), false)
end)

t.test("a point right of the frame is outside", function()
  runner.eq(axpolicy.isInsideFrame(FRAME, 111, 40), false)
end)

t.test("a point above the frame is outside", function()
  runner.eq(axpolicy.isInsideFrame(FRAME, 50, 19), false)
end)

t.test("a point below the frame is outside", function()
  runner.eq(axpolicy.isInsideFrame(FRAME, 50, 71), false)
end)

t.test("the top left edge is inside, the bottom right edge is not", function()
  runner.isTrue(axpolicy.isInsideFrame(FRAME, 10, 20))
  runner.eq(axpolicy.isInsideFrame(FRAME, 110, 40), false)
  runner.eq(axpolicy.isInsideFrame(FRAME, 50, 70), false)
end)

t.test("a nil frame is never a containment", function()
  runner.eq(axpolicy.isInsideFrame(nil, 50, 40), false)
end)

t.test("a zero size frame contains nothing, not even its origin", function()
  runner.eq(axpolicy.isInsideFrame({x = 10, y = 20, w = 0, h = 0}, 10, 20),
            false)
end)

t.test("a frame missing width and height is never a containment", function()
  runner.eq(axpolicy.isInsideFrame({x = 10, y = 20}, 10, 20), false)
end)

t.test("the probe budget and window are read from tuning, not inlined", function()
  local wide = axpolicy.newBreaker(tuned({probeWindowSeconds = 10}))
  wide:noteProbeTime(0.04, 100.0); wide:noteProbeTime(0.04, 100.2)
  wide:noteProbeTime(0.04, 100.4)
  runner.isTrue(wide:isOverBudget(101.6))
  local rich = axpolicy.newBreaker(tuned({probeBudgetSeconds = 0.5}))
  rich:noteProbeTime(0.04, 100.0); rich:noteProbeTime(0.04, 100.2)
  rich:noteProbeTime(0.04, 100.4)
  runner.eq(rich:isOverBudget(100.4), false)
end)

return t
