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

local FINDER_BUNDLE = "com.apple.finder"

-- Whether the app in front is the Finder. Read once per gesture, at the
-- press, rather than per tick: the frontmost app does not change under a
-- held mouse button, and a bundle identifier comes from NSRunningApplication
-- rather than from an accessibility round trip, so the drag pays for this
-- once and every tick of it pays nothing.
local function frontmostIsFinder()
  local front = hs.application.frontmostApplication()
  return front ~= nil and front:bundleID() == FINDER_BUNDLE
end

-- Which of the pack's two little-arrow sounds a click on a stepper earns.
-- `laup` is kThemeSoundLittleArrowUpPress and `ladr` is
-- kThemeSoundLittleArrowDnRelease; the other four of the six are not in the
-- pack at all, so an up release and a down press stay silent rather than
-- borrowing a sound that means something else.
--
-- The half is decided against the frame the probe has already returned, so
-- deciding costs no accessibility traffic. With no frame in hand there is
-- nothing to compare against and the stepper stays silent, which is the same
-- answer the role map gives on its own.
local function littleArrowSemantic(frame, y, action)
  if type(frame) ~= "table" or type(frame.y) ~= "number"
    or type(frame.h) ~= "number" then
    return nil
  end
  if y < frame.y + frame.h / 2 then
    if action == "press" then return "littlearrow.uppress" end
  elseif action == "release" then
    return "littlearrow.downrelease"
  end
  return nil
end

-- The sound a click earns. That is the role map's answer everywhere except
-- on a stepper, where which arrow was hit is a question of geometry and the
-- role map is deliberately silent.
local function clickSemantic(role, action, point, frame)
  if role == "AXIncrementor" then
    return littleArrowSemantic(frame, point.y, action)
  end
  return rolemap.semantic(role, action)
end

-- Whether the gesture in progress is moving a window, as reported by
-- src_windows.
--
-- That source samples the focused window's frame under a held button and
-- publishes the moment the frame is actually seen to move, so this is "a
-- window move or resize is under way" rather than "a button is down". It is
-- the only thing that separates dragging a Finder window from dragging a file
-- in one: both hold the button, both travel, and both end over Finder.
--
-- Read through the shared context table rather than passed in, because the two
-- sources are started independently and neither may reach into the other. A
-- src_windows that failed to start never writes it, and nil reads as false --
-- which is the behaviour this layer had before the flag existed.
--
-- GATED ON A GESTURE BEING OPEN. src_windows clears the flag on the press
-- rather than the release, deliberately: both sources tap leftMouseUp and
-- nothing orders two taps against each other, so clearing on the release would
-- race this read and drop the fix intermittently. The price is that the flag
-- stays true after a window drag until the next press, and `dragStart` is what
-- confines the answer to the gesture it describes -- without it, every hover
-- after a window drag would be silent.
local function windowDragging(self)
  return self.dragStart ~= nil and self.ctx ~= nil
    and self.ctx.windowDragging == true
end

-- Silence whatever a gesture is sustaining and forget the gesture. Safe to
-- call with none in progress and after a partial start(), which is what
-- makes it usable from the tap, from the watchdog and from stop().
local function clearGesture(self)
  if self.engine then
    if self.thumbDragging then self.engine:release("scrollthumb.drag") end
    if self.sliderDragging then self.engine:release("slider.ghost") end
  end
  self.thumbDragging = false
  self.sliderDragging = false
  self.dragStart = nil
end

-- Record where a press began, and open whatever envelope it starts.
--
-- The role comes from the cache only when the cache is fit to answer for
-- this point. A press with no usable cache opens no sustained gesture: the
-- deferred probe that rescues the click sound arrives a runloop turn later,
-- and an attack that late is just another click. In practice the cache is
-- almost always good here -- reaching a thumb means moving onto it, which is
-- exactly what makes the hover loop probe, and then resting on it refreshes
-- the stamp without probing, because AXValueIndicator is a leaf role.
local function beginGesture(self, point, cached)
  self.dragStart = {
    x = point.x, y = point.y,
    role = cached and cached.role,
    finder = frontmostIsFinder(),
  }
  -- The thumb's three files are an attack-sustain-decay set, so grabbing one
  -- starts the envelope rather than sounding a click. `sbtp` is not this: it
  -- is kThemeSoundScrollTrackPress, the trough, and the role map owns it.
  if self.dragStart.role == "AXValueIndicator" then
    self.engine:play("scrollthumb.attack")
    self.engine:sustain("scrollthumb.drag")
    self.thumbDragging = true
  end
end

-- Close the gesture a release ends, and answer whether it owned that
-- release.
--
-- A release that ends a drag is not a click. The button went down in one
-- place and came up in another, so sounding the element under the cursor as
-- well would put a button noise on the end of every thumb drag, every slider
-- sweep and every file drop. A press and release in nearly the same place is
-- a click, and only that falls through to the role map.
local function endGesture(self, point)
  local start = self.dragStart
  local wasThumb = self.thumbDragging
  -- Read BEFORE clearGesture, which nils `dragStart` -- and windowDragging is
  -- gated on that being set, so asking afterwards would always answer false.
  local movingWindow = windowDragging(self)
  -- A gesture that sustained anything owns its own release however far it
  -- travelled: the decay is the sound of letting a thumb go, and a ghost
  -- drag nudged three pixels is still a ghost drag rather than a click.
  local owned = wasThumb or self.sliderDragging
  clearGesture(self)
  if wasThumb then self.engine:play("scrollthumb.decay") end
  if not start then return owned end

  local dx, dy = point.x - start.x, point.y - start.y
  local threshold = self.tuning.dragThresholdPx
  if dx * dx + dy * dy <= threshold * threshold then return owned end

  -- A window move is not a drop. Dragging a Finder window by its title bar
  -- releases over that same Finder window, which is precisely what the hit
  -- test below asks, so without this every Finder window move -- and every
  -- resize, which travels the same way -- would end in `fdrp`. src_windows
  -- publishes `windowDragging` the moment it sees the focused window's frame
  -- actually change, which is the one fact available here that tells the two
  -- gestures apart.
  --
  -- WHAT THIS DOES NOT COVER. Rubber-band selection on the Desktop moves no
  -- window, so it still reads as a drop and still sounds `fdrp`. That is a
  -- known risk recorded at 4.10 in docs/mac-verification.md, and nothing
  -- available at a release distinguishes "let go of a file" from "finished
  -- sweeping a selection". This fix is window move and resize, and no more.
  if movingWindow then return true end

  -- `fdrp` is kThemeSoundReceiveDrop: something let go over a Finder window.
  -- The hit test is an accessibility call, so it happens on a later tick --
  -- nothing on this path may delay the user's own mouse-up. The probe and
  -- the engine are captured rather than read through self, so a stop()
  -- landing in between cannot fault on a torn-down probe, and the tap check
  -- inside keeps a drop from sounding after the Spoon was switched off.
  local probe, engine = self.probe, self.engine
  local x, y = point.x, point.y
  hs.timer.doAfter(0, function()
    if not self.tap or not probe then return end
    -- By bundle identifier, not by display name. `hs.application.get` would
    -- match "Finder" against a localised or user-renamed app, and the same
    -- constant is what frontmostIsFinder and src_finder already test.
    local finder = hs.application.get(FINDER_BUNDLE)
    if not finder then return end
    if probe:pidAt(x, y) == finder:pid() then engine:play("finder.drop") end
  end)
  return true
end

function src:start(ctx)
  self.engine = ctx.engine
  self.tuning = ctx.tuning
  self.log = ctx.log
  -- Held whole, for windowDragging above. init.lua builds one context per
  -- start() and hands the same table to every source, so what src_windows
  -- writes there is what this reads -- no ordering dependency between the two,
  -- and no source reaching into another's fields.
  self.ctx = ctx
  -- No log argument: the probe reports through its counters and its breaker.
  -- The process-wide AX messaging bound this probe relies on is installed by
  -- init.lua before any source starts, because src_windows and src_keys rely
  -- on it too and must not depend on this source having started.
  self.probe = axprobe.new(ctx.tuning)
  self.cache = nil
  -- Where the held button went down, and which loops that press opened.
  -- Cleared together, always through clearGesture.
  self.dragStart = nil
  self.thumbDragging = false
  self.sliderDragging = false

  -- Hover driver: a timer, deliberately not an event tap on mouse-moved.
  -- It never touches the event stream, so it cannot be disabled by the OS
  -- for slowness and cannot delay input.
  self.timer = hs.timer.doEvery(ctx.tuning.hoverIntervalSeconds, function()
    local pos = hs.mouse.absolutePosition()
    local cached = self.cache

    -- Belt and braces against a lost mouse-up. An event tap can be disabled
    -- by the OS mid-gesture (kCGEventTapDisabledByTimeout); Hammerspoon
    -- re-enables it, but any release delivered while it was off is simply
    -- gone, and that one lost event would leave a loop playing with nothing
    -- alive to stop it. checkMouseButtons reads this process's own event
    -- source, so it costs nothing like a probe does, and it is consulted
    -- only while a gesture is believed to be open.
    if self.dragStart and not hs.eventtap.checkMouseButtons()[1] then
      clearGesture(self)
    end

    -- Leafness decides how far the cached frame can be trusted, so both
    -- paths below need it. A leaf role -- a button, a menu item -- cannot
    -- contain a child with a different role, so its frame really does mean
    -- "the answer here has not changed". A container's frame encloses
    -- children the cache has never seen, and a hit-test would have
    -- descended into them, so containment there is only an approximation.
    local overLeaf = cached and rolemap.isLeafRole(cached.role)

    -- A motionless cursor over a leaf, with the frontmost app unchanged, is
    -- the strongest evidence there is that the cached role still applies --
    -- stronger than a moving one -- so refresh the validation stamp and
    -- stop. Hovering a control, pausing, then clicking is the commonest
    -- interaction there is, and without this the pause alone would age the
    -- cache out and drop the click onto the deferred probe.
    --
    -- Over a CONTAINER the cursor may be resting on a child the cache never
    -- saw, so the stamp is deliberately not refreshed: let the cache age
    -- out and let the click take the deferred probe. Late and right beats
    -- instant and wrong, and this is the one place where the difference
    -- between the two is a click on a menu item sounding like a button.
    --
    -- No probe on this path either way -- no IPC, not even an AXFrame read.
    -- A resting cursor costing nothing is a property worth keeping.
    if self.lastX == pos.x and self.lastY == pos.y then
      if overLeaf and cached.pid == frontmostPid() then
        cached.at = hs.timer.secondsSinceEpoch()
      end
      return
    end
    self.lastX, self.lastY = pos.x, pos.y

    -- The slider ghost. `slgh` is a 0.94 s loop, not a click: it runs for as
    -- long as the ghost is being dragged. Started here, on the first
    -- movement after the press, rather than in the tap -- a plain click on a
    -- slider holds the button down too, and smearing a loop across one would
    -- turn every jump-to-here into a scrape. In-process only: this is the
    -- cursor position the tick has already read, not an AX call.
    if self.dragStart and self.dragStart.role == "AXSlider"
      and not self.sliderDragging then
      self.engine:sustain("slider.ghost")
      self.sliderDragging = true
    end

    local pid = frontmostPid()
    local now = hs.timer.secondsSinceEpoch()

    -- Frame elision. While the cursor is still inside the bounds the last
    -- probe reported, and the same app is still frontmost, we skip the
    -- round-trip. Without this the loop probes into another process up to
    -- 16 times a second for as long as the cursor keeps moving, nearly all
    -- of it re-asking a question whose answer it already holds.
    --
    -- The elision is EXACT over a leaf and APPROXIMATE over a container. A
    -- leaf has no differently-roled children, so nothing inside its frame
    -- can change the answer. A container's frame spans children the cache
    -- has never seen, so moving onto one of them is a transition this loop
    -- will swallow -- bounded by the much shorter container ceiling, which
    -- still removes most of the IPC over empty chrome while capping a
    -- missed transition at a fifth of a second rather than two seconds.
    local ceiling = overLeaf and self.tuning.cacheRevalidateSeconds
      or self.tuning.containerRevalidateSeconds
    if cached and cached.pid == pid
      and axpolicy.isInsideFrame(cached.frame, pos.x, pos.y)
      and not axpolicy.needsRevalidation(cached, now, ceiling) then
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
    local previousFrame = cached and cached.frame

    -- roleAt answers with no role when it could not ask: hung app, tripped
    -- breaker, budget overrun. Leave the whole cache alone in that case --
    -- role, frame and both stamps. Overwriting the role would throw away
    -- the best evidence available for the next click, and refusing to
    -- advance the stamps is what keeps the ceiling due, so the next tick
    -- tries again rather than settling for the failure.
    if role ~= nil then
      -- Read the clock again: roleAt may have blocked for up to the AX
      -- timeout, and both stamps should say when the app actually answered.
      local sampled = hs.timer.secondsSinceEpoch()
      self.cache = {role = role, pid = probedPid, x = pos.x, y = pos.y,
                    frame = frame, at = sampled, probedAt = sampled}
    end

    -- Moving a window is src_windows' gesture to describe, and it is already
    -- describing it with the `wmov` loop. Every crossing the cursor makes
    -- while carrying a window is part of that one gesture, so nothing here
    -- sounds for it -- not `fdon`/`fdof`, not the button enter/exit pair.
    -- Sounding either would layer a second and third description of a single
    -- drag on top of the loop, which is the rattle this suppression exists to
    -- remove.
    --
    -- Covers window MOVE and RESIZE, both of which change the frame
    -- src_windows samples. It does NOT cover rubber-band selection on the
    -- Desktop, which moves no window and so still crosses elements audibly --
    -- a known risk recorded at 4.10 in docs/mac-verification.md.
    local movingWindow = windowDragging(self)

    -- Transitions are by element, using the frame as identity, so sliding
    -- down a menu blips on every item rather than only the first -- every
    -- one of them is AXMenuItem, and a role comparison could not tell them
    -- apart. Sweeping a toolbar therefore blips per button too; the 60 ms
    -- poll is what keeps that from becoming machine-gun fire.
    if not movingWindow
      and axpolicy.transitionSounds(previous, previousFrame, role, frame) then
      -- Mid-drag in the Finder a crossing means something else. `fdon` and
      -- `fdof` are kThemeSoundFinderDragOnIcon/OffIcon: the cursor passing
      -- over a droppable icon with something in hand. They REPLACE the
      -- button enter/exit pair rather than joining it -- a drag is not a
      -- hover, and two sounds for one crossing is a rattle.
      --
      -- Whether the Finder is in front was settled at the press, so this
      -- costs one table lookup per transition rather than an app lookup.
      -- Nothing here can tell a droppable icon from any other element, so
      -- every crossing sounds; the 60 ms poll is what keeps that from
      -- becoming machine-gun fire.
      if self.dragStart and self.dragStart.finder then
        -- transitionSounds is false on a nil new role, so there is always
        -- something to have arrived at; there may be nothing left behind.
        if previous ~= nil then self.engine:play("finder.dragofficon") end
        self.engine:play("finder.dragonicon")
      else
        local left = rolemap.semantic(previous, "exit")
        if left then self.engine:play(left) end
        local entered = rolemap.semantic(role, "enter")
        if entered then self.engine:play(entered) end
      end
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

      -- The hover loop has usually just answered this. The test is still the
      -- age-and-tolerance rule -- `cacheMaxAgeSeconds` and
      -- `cacheTolerancePx` -- but note what the elision above feeds it: a
      -- successful elision writes `cached.at` AND `cached.x`/`cached.y`, which
      -- is two of the three things isCacheUsable tests. So for a cursor moving
      -- inside one widget this rule is satisfied continuously, and 250 ms is
      -- NOT the bound on how long ago the app confirmed the role.
      --
      -- That bound is the revalidation ceiling instead: `cacheRevalidateSeconds`
      -- (2 s) over a leaf, `containerRevalidateSeconds` (0.2 s) over a
      -- container, both measured from `probedAt`, which no elision touches.
      -- Intended -- it is what keeps a click after a quarter-second of
      -- movement off the deferred probe -- and worth stating plainly, because
      -- the two numbers are an order of magnitude apart.
      local usable = axpolicy.isCacheUsable(self.cache, now, point.x, point.y,
                                            pid, self.tuning)
      local cached = usable and self.cache or nil

      -- Gestures first, and all in-process: opening one records a point and
      -- may start a loop, closing one may stop a loop and schedule a hit
      -- test for later. No accessibility call happens on this thread either
      -- way, so a hung app can never delay the user's click.
      if action == "press" then
        beginGesture(self, point, cached)
      elseif endGesture(self, point) then
        return false
      end

      if cached then
        local semantic = clickSemantic(cached.role, action, point,
                                       cached.frame)
        if semantic then self.engine:play(semantic) end
      else
        -- Return immediately; all AX work happens on a later tick so a hung
        -- app can delay a sound but never the user's click. The probe and
        -- the engine are captured rather than read through self, so a stop()
        -- landing between the click and this tick cannot fault on a
        -- torn-down probe, and the tap check keeps a click from sounding
        -- after the Spoon was switched off.
        local probe, engine = self.probe, self.engine
        hs.timer.doAfter(0, function()
          if not self.tap or not probe then return end
          local role, _, frame = probe:roleAt(point.x, point.y)
          local semantic = clickSemantic(role, action, point, frame)
          if semantic then engine:play(semantic) end
        end)
      end
      return false
    end)
  self.tap:start()
end

function src:stop()
  if self.tap then self.tap:stop(); self.tap = nil end
  if self.timer then self.timer:stop(); self.timer = nil end
  -- Before anything else is dropped: a stop() landing mid-drag must not
  -- leave a loop playing with nothing left alive to release it. No decay
  -- here -- the toggle means silence now, not a flourish on the way out.
  clearGesture(self)
  -- Just dropped, not released. The AX messaging timeout is process-global and
  -- three sources depend on it, so handing it back is init.lua's job once
  -- every source has stopped -- doing it here would have unbounded the others
  -- while they were still running.
  self.probe = nil
  self.cache = nil
  self.lastX, self.lastY = nil, nil
  self.ctx = nil
end

return src
