local axpolicy = dofile(hs.spoons.resourcePath("axpolicy.lua"))

local Probe = {}
Probe.__index = Probe

local axprobe = {}

function axprobe.new(tuning, log)
  local self = setmetatable({
    tuning = tuning,
    log = log,
    breaker = axpolicy.newBreaker(tuning),
    counts = {probes = 0, failures = 0},
  }, Probe)
  -- Bound the messaging timeout ONCE, on the system-wide element. A timeout
  -- set there applies to every AX message this process sends, so it covers
  -- the hit-test as well as the attribute read. Setting it on the element the
  -- hit-test returns would be too late: that hit-test is itself a blocking
  -- round-trip into the app under the cursor, and it runs on the same runloop
  -- that services the event tap. A multi-second block there is enough for
  -- macOS to disable the tap, which nothing here would notice.
  self.sys = hs.axuielement.systemWideElement()
  pcall(function() self.sys:setTimeout(tuning.axTimeoutSeconds) end)
  return self
end

function Probe:roleAt(x, y)
  local front = hs.application.frontmostApplication()
  local pid = front and front:pid() or -1
  local now = hs.timer.secondsSinceEpoch()

  if self.breaker:isOpen(pid, now) then return nil, pid end
  if self.breaker:isOverBudget(now) then return nil, pid end

  local started = hs.timer.secondsSinceEpoch()
  local ok, element = pcall(function()
    return self.sys:elementAtPosition(x, y)
  end)
  self.counts.probes = self.counts.probes + 1

  if not ok or not element then
    self.counts.failures = self.counts.failures + 1
    self.breaker:noteProbeTime(hs.timer.secondsSinceEpoch() - started, now)
    self.breaker:recordFailure(pid, now)
    return nil, pid
  end

  local gotRole, role = pcall(function()
    return element:attributeValue("AXRole")
  end)
  -- Measure the whole probe, not just the hit-test. attributeValue is the
  -- other AX round-trip, and a budget that cannot see it will read "under
  -- budget" while real AX spend runs over.
  self.breaker:noteProbeTime(hs.timer.secondsSinceEpoch() - started, now)

  if not gotRole or role == nil then
    self.counts.failures = self.counts.failures + 1
    self.breaker:recordFailure(pid, now)
    return nil, pid
  end

  self.breaker:recordSuccess(pid)
  return role, pid
end

function Probe:stats()
  local open = {}
  local now = hs.timer.secondsSinceEpoch()
  for pid in pairs(self.breaker.openUntil) do
    if self.breaker:isOpen(pid, now) then table.insert(open, pid) end
  end
  return {probes = self.counts.probes, failures = self.counts.failures,
          openPids = open}
end

return axprobe
