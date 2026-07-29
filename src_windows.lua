local src = {}

-- Identity, not tuning: the window kinds this Spoon has a sound for, the way
-- src_finder names the one app it watches.
--
-- The first three are what hs.window.filter allows by default. The fourth is
-- ours: `pwop`/`pwcl` are kThemeSoundPopupWindowOpen/Close, OS 9's pop-up
-- windows docked at the screen edge, and a floating utility panel is the
-- closest honest analogue. Deliberately not `*`, which admits the role-less
-- tooltips, popovers and completion panels that would sound wopn/wcls all
-- day long.
local FLOATING = "AXFloatingWindow"

local WINDOW_ROLES = {
  "AXStandardWindow", "AXDialog", "AXSystemDialog", FLOATING,
}

-- hs.window publishes the subrole itself; going through
-- hs.axuielement.windowElement would be the same round trip with a wrapper
-- around it. Guarded because a window can die between the notification and
-- this call, and an unreadable subrole should read as "not a palette".
local function isPalette(win)
  local ok, subrole = pcall(function() return win:subrole() end)
  return ok and subrole == FLOATING
end

-- Publish "the focused window has been seen to move under the held button" on
-- the shared context table.
--
-- This source owns the fact; src_pointer is the one that needs it. Dragging a
-- Finder window by its title bar releases over that very Finder window, which
-- is exactly the test the drop probe applies, so without this every Finder
-- window move would end in `fdrp` and every frame crossing during it would
-- blip `fdon`/`fdof` on top of the `wmov` loop. One gesture, three
-- descriptions, from two sources that could not see each other.
--
-- `ctx` is the table init.lua builds once per start() and hands to every
-- source, so the write is visible to a src_pointer that was started before
-- this source was. Guarded on self.ctx, because the callers must stay callable
-- after a partial start() -- the same reason endDrag already tolerates no
-- engine. A src_windows that failed to start therefore leaves the flag unset,
-- and src_pointer degrades to exactly the behaviour it had before this
-- existed.
--
-- CLEARED ON MOUSE-DOWN, NEVER ON MOUSE-UP, and that is load-bearing. Both
-- this source and src_pointer tap leftMouseUp, and nothing orders two taps in
-- one process against each other. Clearing here on the release would race the
-- reader: whenever this tap won, src_pointer's endGesture would see a cleared
-- flag and sound the drop after all, intermittently. Clearing on the press
-- instead puts the write a whole gesture ahead of every read, so the order the
-- two taps happen to run in stops mattering.
--
-- The cost is that the flag stays true between the end of a window drag and
-- the next press. src_pointer gates both its readers on having a gesture open,
-- so nothing consults it in that gap.
local function publishDragging(self, value)
  if self.ctx then self.ctx.windowDragging = value end
end

-- Arm the frame sampler for the gesture that just began. Deliberately reads
-- no frame: the first tick records the baseline the second one compares
-- against, so nothing is asked of another process from inside the event tap.
local function beginDrag(self)
  self.lastFrame = nil
  self.dragging = false
  publishDragging(self, false)
  if self.dragTimer and not self.dragTimer:running() then
    self.dragTimer:start()
  end
end

-- Disarm, and silence whatever the gesture was sustaining. Safe to call when
-- no drag is in progress and after a partial start(), which is what makes it
-- usable from both the tap and stop().
--
-- `self.dragging` resets here because sampleDrag's idle branch keys off it and
-- would otherwise sound `wmov idle` on the next plain button hold. The
-- published flag deliberately does NOT reset here; see publishDragging above
-- for why the clear belongs on the press.
local function endDrag(self)
  if self.dragTimer then self.dragTimer:stop() end
  if self.engine then
    self.engine:release("window.move")
    self.engine:release("window.moving")
  end
  self.dragging = false
  self.lastFrame = nil
end

-- One sample of the dragged window's position. Runs only while a left button
-- is held; see the timer that owns it below.
local function sampleDrag(self)
  -- Belt and braces. An event tap can be disabled by the OS mid-gesture
  -- (kCGEventTapDisabledByTimeout); Hammerspoon re-enables it, but any
  -- mouse-up delivered while it was off is simply lost. Without this check
  -- that one lost event would leave a looping sound running with nothing
  -- alive to stop it. checkMouseButtons reads this process's own event
  -- source, so it costs nothing like a frame read does.
  if not hs.eventtap.checkMouseButtons()[1] then
    endDrag(self)
    return
  end
  local win = hs.window.focusedWindow()
  if not win then return end
  local frame = win:frame()
  if self.lastFrame then
    local moved = frame.x ~= self.lastFrame.x or frame.y ~= self.lastFrame.y
    if moved then
      self.engine:release("window.move")
      self.engine:sustain("window.moving")
      self.dragging = true
      publishDragging(self, true)
    elseif self.dragging then
      -- Only once movement has actually been seen. A plain click on a button
      -- holds the mouse down too, and must stay silent here.
      self.engine:release("window.moving")
      self.engine:sustain("window.move")
    end
  end
  self.lastFrame = frame
end

function src:start(ctx)
  self.engine = ctx.engine
  self.tuning = ctx.tuning
  self.log = ctx.log
  -- Held for publishDragging above, which publishes the window-drag fact that
  -- src_pointer reads. The whole table, not a copy of a field: the point is
  -- that both sources see the same one.
  self.ctx = ctx

  -- Which windows were palettes when they opened. Consulted at destruction,
  -- when the subrole can no longer be read.
  self.paletteIds = {}

  local filter = hs.window.filter
  -- The default windowfilter's app rejections are worth keeping: launchers,
  -- menulets and preference panes have no windows worth sounding. Its default
  -- *rule* is not, because it is built for window management rather than for
  -- noticing things happen, and it silences two of the events below outright:
  --
  --   * it allows only standard, dialog and system-dialog roles, so a
  --     floating panel never reaches a subscription at all -- neither `pwop`
  --     nor even `wcls`, since a window that was never allowed emits nothing
  --     when it goes;
  --   * it allows only visible windows, and an unminimising window is still
  --     invisible when that event is raised, so `wexp` never arrives even
  --     though `wcol` does.
  --
  -- setDefaultFilter replaces the rule rather than merging into it, so
  -- leaving `visible` unset is what admits minimised windows. Other Spaces
  -- and fullscreen windows are governed by a different setting and are not
  -- excluded here.
  --
  -- Not chained off setDefaultFilter, so that holding the filter never
  -- depends on what that method chooses to return.
  self.filter = filter.new(nil)
  self.filter:setDefaultFilter{allowRoles = WINDOW_ROLES}
  self.filter:subscribe({
    -- The subrole read is an AX round-trip, but a window opening is a rare
    -- user-initiated event, not anything on a hot path.
    [filter.windowCreated] = function(win)
      local palette = isPalette(win)
      local id = win and win:id()
      if palette and id then self.paletteIds[id] = true end
      self.engine:play(palette and "palette.open" or "window.open")
    end,
    -- The window's AX element is dead by now, so its subrole cannot be asked
    -- for -- but its id still reads, and the handler above recorded which ids
    -- were palettes. Consumed on the way out so the set cannot grow across a
    -- long session. A window whose id cannot be read closes as a document
    -- window, which is what every window did before this pair existed.
    [filter.windowDestroyed] = function(win)
      local id = win and win:id()
      local palette = id and self.paletteIds[id] or false
      if id then self.paletteIds[id] = nil end
      self.engine:play(palette and "palette.close" or "window.close")
    end,
    -- wcol/wexp are kThemeSoundWindowCollapseUp/Down: the OS 9 windowshade
    -- rolling a window up into its title bar. Minimise and unminimise are the
    -- nearest gesture modern macOS still has.
    [filter.windowMinimized] = function()
      self.engine:play("window.collapse")
    end,
    [filter.windowUnminimized] = function()
      self.engine:play("window.expand")
    end,
    [filter.windowFullscreened] = function()
      self.engine:play("window.zoomin")
    end,
    [filter.windowUnfullscreened] = function()
      self.engine:play("window.zoomout")
    end,
    -- Sole owner of window.activate. Application activation must not also
    -- emit it: switching apps raises both, and two owners would sound twice.
    [filter.windowFocused] = function()
      self.engine:play("window.activate")
    end,
  })

  self.volumeWatcher = hs.fs.volume.new(function(event)
    if event == hs.fs.volume.didMount then
      self.engine:play("disk.insert")
    elseif event == hs.fs.volume.didUnmount then
      self.engine:play("disk.eject")
    end
  end)
  self.volumeWatcher:start()

  -- `flap` is kThemeSoundLaunchApp. The window filter cannot stand in for it:
  -- an app can launch without opening a window at all, and the first window
  -- of one that does is a separate event with its own sound.
  --
  -- Gated on kind(), because the notification behind this watcher announces
  -- LSUIElement helpers, updaters and background agents too, and an
  -- unexplained `flap` when a helper starts is noise. That is the same test
  -- src_menus applies, so both sources agree by intent on what counts as an
  -- application rather than agreeing by accident.
  self.appWatcher = hs.application.watcher.new(function(_, event, app)
    if event == hs.application.watcher.launched
      and app and app:kind() == 1 then
      self.engine:play("app.launch")
    end
  end)
  self.appWatcher:start()

  -- Sustained window drag: `wmov idle` while the button is held still,
  -- `wmov moving` while the position is actually changing. That distinction
  -- is the only reason both files exist in the pack.
  --
  -- The sampler is demand-driven. Reading a window's frame is an
  -- accessibility round-trip into another process, so a free-running timer
  -- would pay that ten times a second for the entire life of the Spoon, to
  -- serve the few seconds a window is ever actually being dragged. The tap
  -- below runs it only between a left button going down and coming back up.
  -- With no button held there is no timer scheduled and no AX traffic at all.
  self.dragging = false
  publishDragging(self, false)
  -- Wrapped, because an hs.timer stops itself for good on an unhandled error
  -- and this body can realistically throw: focusedWindow() can hand back a
  -- window whose app dies before frame() is called, and indexing the nil that
  -- comes back would take the drag sound out for the rest of the session. The
  -- timer stays armed and the next tick tries again.
  self.dragTimer = hs.timer.new(ctx.tuning.dragSampleSeconds, function()
    local ok, err = pcall(sampleDrag, self)
    if not ok then self.log.e("drag sampler: " .. tostring(err)) end
  end)

  local types = hs.eventtap.event.types
  self.tap = hs.eventtap.new(
    {types.leftMouseDown, types.leftMouseUp},
    function(event)
      -- Arming or disarming a timer and stopping a sound are all in-process;
      -- no accessibility call happens on this thread, so a hung app can never
      -- delay the user's click.
      if event:getType() == types.leftMouseDown then
        beginDrag(self)
      else
        endDrag(self)
      end
      return false
    end)
  self.tap:start()
end

function src:stop()
  if self.tap then self.tap:stop(); self.tap = nil end
  -- Before the timer is dropped: a stop() landing mid-drag must not leave a
  -- looping sound playing with nothing left alive to release it.
  endDrag(self)
  if self.dragTimer then self.dragTimer:stop(); self.dragTimer = nil end
  -- `delete()` rather than `unsubscribeAll()`. start() builds a fresh
  -- hs.window.filter every time, and a filter instance registers itself with
  -- the module -- dropping the last Lua reference to one is not enough to
  -- retire it. Unsubscribing silences this instance's callbacks but leaves it
  -- registered and still watching, so N presses of the toggle hotkey would
  -- leave N of them behind. `delete()` is the documented full teardown, and
  -- niling the reference afterwards is what makes stop() idempotent.
  if self.filter then self.filter:delete(); self.filter = nil end
  if self.volumeWatcher then
    self.volumeWatcher:stop(); self.volumeWatcher = nil
  end
  if self.appWatcher then self.appWatcher:stop(); self.appWatcher = nil end
  self.paletteIds = nil
  -- endDrag above resets this source's own state but deliberately leaves the
  -- published flag alone, so clear it here: a stop() landing mid-drag must not
  -- leave it stuck true on a context src_pointer may still be holding. Then
  -- drop the reference, which is what makes a second stop() a no-op.
  publishDragging(self, false)
  self.ctx = nil
end

return src
