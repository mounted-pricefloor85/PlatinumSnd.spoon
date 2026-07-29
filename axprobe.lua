local axpolicy = dofile(hs.spoons.resourcePath("axpolicy.lua"))

local Probe = {}
Probe.__index = Probe

local axprobe = {}

-- Sharpen a role with the ONE extra attribute that tells two widgets apart
-- from the roles they share, and return a SYNTHETIC role saying which.
--
-- macOS does not report a close box or a tab as a role of its own. The red
-- traffic light is an AXButton whose AXSubrole is AXCloseButton; a tab is an
-- AXRadioButton whose parent is an AXTabGroup. Between them those two facts
-- unlock eight of the pack's sounds -- the whole `wcl*` close-box cycle and
-- the whole `tab*` one -- and there is no cheaper signal for either.
--
-- WHAT THIS COSTS, AND WHY IT IS AFFORDABLE. Only a real probe reaches here,
-- and the hover loop's frame elision means a real probe happens on a
-- TRANSITION rather than on every tick. So this is one extra read per newly
-- hovered widget, not sixteen a second: a button probe goes from three round
-- trips to four, a radio button probe from three to five -- the parent is an
-- element, so its role is a second hop. Both synthetic roles are leaves, so
-- the elision covers them once they are known and a cursor resting on a close
-- box pays nothing at all.
--
-- WHICH IS WHY THE GATING IS NARROW. The subrole is read only for a button
-- and the parent only for a radio button; every other role returns before
-- either. Nothing here may be lifted onto the elision path -- the whole
-- budget argument above is that this runs on transitions only.
--
-- A read that fails is NOT a probe failure. The role in hand is still
-- correct, merely less specific, so the answer is the plain role and the
-- caller's failure counters and circuit breaker are left alone.
local function refined(element, role)
  if role == "AXButton" then
    local ok, subrole = pcall(function()
      return element:attributeValue("AXSubrole")
    end)
    if not ok then return role end
    return axpolicy.refinedRole(role, subrole)
  end

  if role == "AXRadioButton" then
    local ok, parentRole = pcall(function()
      local parent = element:attributeValue("AXParent")
      return parent and parent:attributeValue("AXRole")
    end)
    if not ok then return role end
    return axpolicy.refinedRole(role, parentRole)
  end

  return role
end

-- THE PROCESS-WIDE AX MESSAGING BOUND.
--
-- A timeout set on the system-wide element becomes the default for every AX
-- message this process sends, which is why it is set once here rather than on
-- each element a hit-test returns -- that hit-test is itself a blocking round
-- trip into the app under the cursor, running on the same runloop that
-- services the event taps, and setting a timeout on its result would already
-- be too late. A multi-second block there is enough for macOS to disable the
-- tap, which nothing in this Spoon would notice.
--
-- NOT OWNED BY THE PROBE, though the functions live in the module that knows
-- what an AX timeout is. The bound is process-wide, so three sources depend on
-- it without ever touching this file: src_windows reads `focusedWindow`,
-- `frame` and `subrole`, and src_keys reads `subrole`. When the install lived
-- in `new`, it worked only because src_pointer happens to be registered first
-- -- and since each source start is individually pcall'ed, a src_pointer that
-- failed to start left the others making UNBOUNDED AX calls on the main
-- runloop. That is precisely the tap death this guardrail exists to prevent.
-- init.lua installs it before any source starts and resets it after all of
-- them stop, so there is exactly one owner and it is not a source.
--
-- A failure to install is logged rather than swallowed. There is no getter for
-- the value, so an unlogged failure is invisible: every AX call in the process
-- silently loses its bound, and the first symptom is a dead event tap with
-- nothing in the Console to explain it.
function axprobe.installTimeout(tuning, log)
  local ok, err = pcall(function()
    hs.axuielement.systemWideElement():setTimeout(tuning.axTimeoutSeconds)
  end)
  if not ok then
    log.e("AX messaging timeout NOT installed, every AX call in this process "
          .. "is unbounded and a slow app can now kill the event taps: "
          .. tostring(err))
  end
  return ok
end

-- Hand the bound back. Hammerspoon documents 0.0 on the system-wide element as
-- "reset the global default", so this undoes exactly what installTimeout did
-- rather than guessing at a prior value. Without it the 50 ms bound outlives
-- the Spoon and keeps applying to hs.window, hs.uielement and every other AX
-- consumer in the process -- so a failure here is a mutation left behind on a
-- Spoon the user has just switched off, and it gets said out loud.
function axprobe.resetTimeout(log)
  local ok, err = pcall(function()
    hs.axuielement.systemWideElement():setTimeout(0.0)
  end)
  if not ok then
    log.e("AX messaging timeout NOT handed back, this Spoon's bound outlives "
          .. "it and still applies to every other AX consumer: "
          .. tostring(err))
  end
  return ok
end

-- No `log`: every failure a probe has is counted in `counts` and acted on by
-- the breaker, which is its reporting channel. The one thing in this module
-- worth logging is the timeout install above, and that is not a probe's to do.
function axprobe.new(tuning)
  local self = setmetatable({
    tuning = tuning,
    breaker = axpolicy.newBreaker(tuning),
    counts = {probes = 0, failures = 0},
  }, Probe)
  -- Held for elementAtPosition. The messaging bound that used to be installed
  -- here now belongs to init.lua; see installTimeout above for why.
  self.sys = hs.axuielement.systemWideElement()
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

  -- Fetch the bounds in the same visit. This one extra attribute is what
  -- lets the hover loop skip whole probes while the cursor stays inside the
  -- widget, so it buys back far more round-trips than it costs. Only worth
  -- asking when the role came back: on an element that just timed out, the
  -- second read would only buy a second timeout.
  --
  -- Not every element publishes AXFrame. A miss is not a probe failure --
  -- the role is still good, the hover loop just cannot elide the next tick.
  local frame
  if gotRole and role ~= nil then
    local gotFrame, value = pcall(function()
      return element:attributeValue("AXFrame")
    end)
    if gotFrame then frame = value end

    -- Two roles are worth one more attribute to sharpen. Gated on the same
    -- "the role came back" condition as the frame, and on the role itself
    -- inside, so nothing else pays for it. See `refined` above for the cost
    -- argument; the short version is that only a transition gets this far.
    role = refined(element, role)
  end

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
  return role, pid, frame
end

-- Which process owns the element at a point.
--
-- Deliberately not the pid roleAt reports. That one is the frontmost
-- application, which is the right identity for the circuit breaker -- it is
-- the app being asked -- but it is not who owns the window under the
-- pointer. Dragging something does not bring the window beneath it to the
-- front, so at the end of a drag the two answers routinely differ, and a
-- drop cares about the window it landed on.
--
-- Bounded by the same 50 ms messaging timeout as everything else here, and
-- asked once at the end of a gesture rather than on a loop, so it stays out
-- of the probe budget. A nil answer means "could not tell", which every
-- caller should read as "do not sound anything".
function Probe:pidAt(x, y)
  local ok, element = pcall(function()
    return self.sys:elementAtPosition(x, y)
  end)
  if not ok or not element then return nil end
  local gotPid, pid = pcall(function() return element:pid() end)
  if not gotPid then return nil end
  return pid
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
