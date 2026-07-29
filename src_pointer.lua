local axpolicy = dofile(hs.spoons.resourcePath("axpolicy.lua"))
local axprobe = dofile(hs.spoons.resourcePath("axprobe.lua"))
local rolemap = dofile(hs.spoons.resourcePath("rolemap.lua"))

local src = {}

-- NSWorkspace's idea of the front app, not an accessibility round-trip, so
-- both callers below can afford it on every tick. Always a number: an
-- unknown front app reads as -1 rather than nil, which keeps it comparable
-- against a cached pid without a nil check at each site.
local function frontmostPid()
  local front = hs.application.frontmostApplication()
  return front and front:pid() or -1
end

function src:start(ctx)
  self.engine = ctx.engine
  self.tuning = ctx.tuning
  self.log = ctx.log
  self.probe = axprobe.new(ctx.tuning, ctx.log)
  self.cache = nil

  -- Hover driver: a timer, deliberately not an event tap on mouse-moved.
  -- It never touches the event stream, so it cannot be disabled by the OS
  -- for slowness and cannot delay input.
  self.timer = hs.timer.doEvery(ctx.tuning.hoverIntervalSeconds, function()
    local pos = hs.mouse.absolutePosition()
    if self.lastX == pos.x and self.lastY == pos.y then return end
    self.lastX, self.lastY = pos.x, pos.y

    local pid = frontmostPid()
    local now = hs.timer.secondsSinceEpoch()
    local cached = self.cache

    -- Frame elision. While the cursor is still inside the bounds the last
    -- probe reported, and the same app is still frontmost, the role under
    -- the cursor cannot have changed -- so there is nothing to ask, and no
    -- IPC to pay for. Only leaving the frame, a change of frontmost app, an
    -- element that never published a frame, or the revalidation ceiling
    -- costs a round-trip. Without this the loop probes into another process
    -- up to 16 times a second for as long as the cursor keeps moving,
    -- nearly all of it re-asking a question whose answer it already holds.
    if cached and cached.pid == pid
      and axpolicy.isInsideFrame(cached.frame, pos.x, pos.y)
      and not axpolicy.needsRevalidation(cached, now, self.tuning) then
      -- A successful elision is a revalidation, not a stale sample: it has
      -- just confirmed the cursor is inside the same element's frame with
      -- the same app frontmost, which is stronger evidence than the sample
      -- being under cacheMaxAgeSeconds old. So move the sample point and
      -- the validation stamp forward, and leave `probedAt` alone -- that is
      -- what the ceiling above measures, and what stops a role living
      -- indefinitely on containment alone. Without this refresh a click
      -- after a quarter-second of movement inside one widget would fall to
      -- the deferred probe, which is the path that mis-sounds menu items.
      cached.x, cached.y, cached.at = pos.x, pos.y, now
      return
    end

    local role, probedPid, frame = self.probe:roleAt(pos.x, pos.y)
    local previous = cached and cached.role
    -- Read the clock again: roleAt may have blocked for up to the AX
    -- timeout, and both stamps should say when the app actually answered.
    local sampled = hs.timer.secondsSinceEpoch()
    self.cache = {role = role, pid = probedPid, x = pos.x, y = pos.y,
                  frame = frame, at = sampled, probedAt = sampled}

    -- Transitions are by role, not by element: crossing between two buttons
    -- in a toolbar is silent, which is what stops a sweep along one from
    -- machine-gunning btne.
    if role ~= previous then
      local left = rolemap.semantic(previous, "exit")
      if left then self.engine:play(left) end
      local entered = rolemap.semantic(role, "enter")
      if entered then self.engine:play(entered) end
    end
  end)

  local types = hs.eventtap.event.types
  self.tap = hs.eventtap.new(
    {types.leftMouseDown, types.leftMouseUp},
    function(event)
      local action = (event:getType() == types.leftMouseDown)
        and "press" or "release"
      local point = event:location()
      local now = hs.timer.secondsSinceEpoch()
      local pid = frontmostPid()

      -- The hover loop has usually just answered this. Staleness here stays
      -- the age-and-tolerance rule, untouched by the frame elision above:
      -- the frame says where the widget is, not how long ago the app
      -- confirmed it was still there.
      if axpolicy.isCacheUsable(self.cache, now, point.x, point.y, pid,
                                self.tuning) then
        local semantic = rolemap.semantic(self.cache.role, action)
        if semantic then self.engine:play(semantic) end
      else
        -- Return immediately; all AX work happens on a later tick so a hung
        -- app can delay a sound but never the user's click. The probe is
        -- captured rather than read through self, so a stop() landing
        -- between the click and this tick cannot fault on a torn-down one.
        local probe = self.probe
        hs.timer.doAfter(0, function()
          local role = probe:roleAt(point.x, point.y)
          local semantic = rolemap.semantic(role, action)
          if semantic then self.engine:play(semantic) end
        end)
      end
      return false
    end)
  self.tap:start()
end

function src:stop()
  if self.tap then self.tap:stop(); self.tap = nil end
  if self.timer then self.timer:stop(); self.timer = nil end
  -- Hand the AX messaging timeout back before dropping the probe. It is a
  -- process-global default, so leaving it set would keep this Spoon's 50 ms
  -- bound on hs.window and every other AX consumer long after the toggle
  -- hotkey was supposed to make us inert.
  if self.probe then self.probe:release(); self.probe = nil end
  self.cache = nil
  self.lastX, self.lastY = nil, nil
end

return src
