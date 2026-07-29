local src = {}

-- Floating windows get the palette pair rather than the document pair.
-- `pwop`/`pwcl` are kThemeSoundPopupWindowOpen/Close, OS 9's pop-up windows
-- docked at the screen edge. Nothing modern behaves like that, so a floating
-- utility panel is the closest honest analogue.
local function isPalette(win)
  local ok, subrole = pcall(function()
    return hs.axuielement.windowElement(win):attributeValue("AXSubrole")
  end)
  return ok and subrole == "AXFloatingWindow"
end

-- Arm the frame sampler for the gesture that just began. Deliberately reads
-- no frame: the first tick records the baseline the second one compares
-- against, so nothing is asked of another process from inside the event tap.
local function beginDrag(self)
  self.lastFrame = nil
  self.dragging = false
  if self.dragTimer and not self.dragTimer:running() then
    self.dragTimer:start()
  end
end

-- Disarm, and silence whatever the gesture was sustaining. Safe to call when
-- no drag is in progress and after a partial start(), which is what makes it
-- usable from both the tap and stop().
local function endDrag(self)
  if self.dragTimer then self.dragTimer:stop() end
  if self.engine then
    self.engine:release("window.move")
    self.engine:release("window.moving")
  end
  self.dragging = false
  self.lastFrame = nil
end

function src:start(ctx)
  self.engine = ctx.engine
  self.tuning = ctx.tuning
  self.log = ctx.log

  local filter = hs.window.filter
  self.filter = filter.new(nil)
  self.filter:subscribe({
    -- The subrole read is an AX round-trip, but a window opening is a rare
    -- user-initiated event, not anything on a hot path.
    [filter.windowCreated] = function(win)
      self.engine:play(isPalette(win) and "palette.open" or "window.open")
    end,
    -- No palette.close counterpart. By the time this fires the window's AX
    -- element is gone, so its subrole can no longer be asked for, and every
    -- window -- palette or document -- closes with `wcls`.
    [filter.windowDestroyed] = function()
      self.engine:play("window.close")
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
  self.appWatcher = hs.application.watcher.new(function(_, event)
    if event == hs.application.watcher.launched then
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
  self.dragTimer = hs.timer.new(ctx.tuning.dragSampleSeconds, function()
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
      elseif self.dragging then
        -- Only once movement has actually been seen. A plain click on a
        -- button holds the mouse down too, and must stay silent here.
        self.engine:release("window.moving")
        self.engine:sustain("window.move")
      end
    end
    self.lastFrame = frame
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
  if self.filter then self.filter:unsubscribeAll(); self.filter = nil end
  if self.volumeWatcher then
    self.volumeWatcher:stop(); self.volumeWatcher = nil
  end
  if self.appWatcher then self.appWatcher:stop(); self.appWatcher = nil end
end

return src
