package.path = "../?.lua;" .. package.path
local runner = require("runner")
local axpolicy = require("axpolicy")
local t = runner.suite("axpolicy")

local TUNING = {
  cacheMaxAgeSeconds         = 0.25,
  cacheTolerancePx           = 4,
  cacheRevalidateSeconds     = 2,
  containerRevalidateSeconds = 0.2,
  breakerThreshold           = 3,
  breakerWindowSeconds       = 10,
  breakerCooldownSeconds     = 30,
  probeBudgetSeconds         = 0.1,
  probeWindowSeconds         = 1,
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

-- Revalidation ceiling. A successful frame elision refreshes the cache's
-- `at`, so the click path keeps seeing a fresh cache for as long as the
-- cursor rests on one control. That is only safe because the ceiling below
-- caps how long a role can survive without the app being asked again: the
-- UI can change under a stationary cursor, and `probedAt` -- set only by a
-- real probe, never by an elision -- is what notices.
local function probed(over)
  local c = {role = "AXButton", pid = 42, x = 100, y = 200,
             at = 1000.0, probedAt = 1000.0}
  for k, v in pairs(over or {}) do c[k] = v end
  return c
end

-- The ceiling arrives as an argument rather than being looked up, because
-- the hover loop applies two of them: the generous one below for a cached
-- leaf role, and a much shorter one for a container, whose frame can enclose
-- children the cache knows nothing about.
local CEILING = TUNING.cacheRevalidateSeconds

t.test("a recently probed cache needs no revalidation", function()
  runner.eq(axpolicy.needsRevalidation(probed(), 1001.0, CEILING), false)
end)

t.test("a cache probed beyond the ceiling needs revalidation", function()
  runner.isTrue(axpolicy.needsRevalidation(probed(), 1002.1, CEILING))
end)

t.test("exactly at the ceiling does not yet need revalidation", function()
  runner.eq(axpolicy.needsRevalidation(probed(), 1002.0, CEILING), false)
end)

t.test("a shorter ceiling expires a cache the long one would keep", function()
  local short = TUNING.containerRevalidateSeconds
  runner.eq(axpolicy.needsRevalidation(probed(), 1000.1, CEILING), false)
  runner.isTrue(axpolicy.needsRevalidation(probed(), 1000.3, short))
end)

-- The ceiling must read probedAt, not at. A cache kept alive by a long run
-- of elisions has a fresh `at` and a stale `probedAt`; reading `at` here
-- would let a wrong role survive forever, which is the whole bug the
-- ceiling exists to bound.
t.test("a long run of elisions still trips the ceiling", function()
  runner.isTrue(axpolicy.needsRevalidation(probed({at = 1009.9}), 1010.0,
                                           CEILING))
end)

t.test("a nil cache needs revalidation", function()
  runner.isTrue(axpolicy.needsRevalidation(nil, 1000.0, CEILING))
end)

-- Spelled out rather than built with probed({probedAt = nil}): a nil value
-- in a Lua table constructor creates no key, so that override would have
-- been a silent no-op and this case would have tested nothing.
t.test("a cache with no probedAt needs revalidation", function()
  local unprobed = {role = "AXButton", pid = 42, x = 100, y = 200, at = 1000.0}
  runner.isTrue(axpolicy.needsRevalidation(unprobed, 1000.0, CEILING))
end)

-- Whether a move has earned its exit/enter pair. The frame is the element's
-- identity: two menu items differ by frame though both are AXMenuItem, and
-- the same widget re-probed comes back with the frame it had. Comparing
-- roles alone would blip once on the first menu item and never again, when
-- blipping on every item is the whole character of the sound.
local A = {x = 0, y = 0, w = 10, h = 10}
local B = {x = 0, y = 10, w = 10, h = 10}

t.test("a changed role sounds", function()
  runner.isTrue(axpolicy.transitionSounds("AXButton", A, "AXCheckBox", B))
end)

t.test("the same role in a different frame sounds", function()
  runner.isTrue(axpolicy.transitionSounds("AXMenuItem", A, "AXMenuItem", B))
end)

t.test("the same role in an identical frame is silent", function()
  runner.eq(axpolicy.transitionSounds("AXMenuItem", A, "AXMenuItem",
                                      {x = 0, y = 0, w = 10, h = 10}), false)
end)

t.test("arriving from no previous role sounds", function()
  runner.isTrue(axpolicy.transitionSounds(nil, nil, "AXButton", A))
end)

-- The probe came back empty, so the role looks like it changed to nothing,
-- but nothing is known to have moved. "Could not ask" is not "left".
t.test("a probe that answered nothing never sounds", function()
  runner.eq(axpolicy.transitionSounds("AXButton", A, nil, nil), false)
  runner.eq(axpolicy.transitionSounds(nil, nil, nil, nil), false)
end)

-- Frames are optional: not every element publishes AXFrame. With one
-- missing there is no identity to compare, so the roles decide alone.
t.test("a missing frame on either side falls back to the roles", function()
  runner.eq(axpolicy.transitionSounds("AXMenuItem", nil, "AXMenuItem", B),
            false)
  runner.eq(axpolicy.transitionSounds("AXMenuItem", A, "AXMenuItem", nil),
            false)
  runner.isTrue(axpolicy.transitionSounds("AXButton", nil, "AXCheckBox", nil))
end)

t.test("a malformed frame is treated as no identity, not as a move",
  function()
    runner.eq(axpolicy.transitionSounds("AXMenuItem", {}, "AXMenuItem", {}),
              false)
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

-- needsRevalidation takes its ceiling as an argument rather than a tuning
-- table, so the guard is that it honours the number it was handed. Which of
-- the two tuning ceilings applies is the hover loop's decision, and that
-- lives outside this suite.
t.test("the revalidation ceiling is the argument, not an inlined constant",
  function()
    runner.eq(axpolicy.needsRevalidation(probed(), 1005.0, 60), false)
    runner.isTrue(axpolicy.needsRevalidation(probed(), 1001.0, 0.5))
  end)

return t
