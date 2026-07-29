-- PURE. AX role -> semantic sound name, per action.
local rolemap = {}

local TABLE = {
  AXButton = {
    press = "button.press", release = "button.release",
    enter = "button.enter", exit = "button.exit",
  },
  AXCheckBox = {press = "checkbox.press", release = "checkbox.release"},
  AXRadioButton = {
    press = "radio.press", release = "radio.release",
    enter = "radio.enter", exit = "radio.exit",
  },
  AXDisclosureTriangle = {
    press = "disclosure.press", release = "disclosure.release",
    enter = "disclosure.enter", exit = "disclosure.exit",
  },
  AXPopUpButton = {press = "popup.press", release = "popup.release"},
  -- `sltp` is kThemeSoundSliderTrackPress. There is no release counterpart:
  -- `slte` is kThemeSoundSliderEndOfTrack, the thumb hitting a stop, which
  -- is a value question rather than a click one. Dragging the slider is the
  -- `slgh` loop, and the pointer layer owns that.
  AXSlider = {press = "slider.press"},
  -- `sbtp` is kThemeSoundScrollTrackPress: the TROUGH being clicked, which
  -- is the only part of a modern scroll bar you can press and let go of.
  -- `sbap`/`sbar` are the arrow presses of a scroll bar macOS no longer
  -- draws, so nothing here produces them.
  AXScrollBar = {press = "scrolltrack.press"},
  -- Both silent on purpose, and both need an entry to say so -- without one
  -- they would fall through to the generic click below.
  --
  -- The thumb's sound is the `sbth` attack-sustain-decay envelope, which
  -- spans a whole gesture rather than an instant, so only the pointer layer
  -- can drive it. And `laup`/`ladr` are the UP press and the DOWN release of
  -- a stepper, so which one a click earns depends on which half of the frame
  -- it landed in -- geometry this table cannot see.
  AXValueIndicator = {},
  AXIncrementor = {},
  -- Menu items are owned by src_menus for press/release. The pointer layer
  -- contributes only the highlight, so clicking one does not sound twice.
  AXMenuItem = {enter = "menu.item"},
}

local GENERIC = {press = "button.press", release = "button.release"}

-- Roles that cannot hold a differently-roled child. Accessibility elements
-- nest and a hit-test descends to the deepest one at the point, so a probe
-- landing on container-only space -- toolbar background, a scroll area, the
-- panel of a menu between its items -- caches a frame that ENCLOSES children
-- with other roles. Frame containment is only a sound proxy for "the answer
-- cannot have changed" when the cached role is one of these.
--
-- This is a containment question, not a sound question. AXStaticText and
-- AXValueIndicator are leaves with no entry in TABLE at all, while
-- AXScrollBar has one and is still a container: it holds the indicator and
-- the two arrow buttons. Anything absent -- every container, every role
-- nobody has mapped, and nil -- is not a leaf, which is the safe answer
-- because it only costs a probe.
local LEAF = {
  AXButton = true, AXCheckBox = true, AXRadioButton = true,
  AXDisclosureTriangle = true, AXPopUpButton = true, AXSlider = true,
  AXMenuItem = true, AXValueIndicator = true, AXIncrementor = true,
  AXStaticText = true,
}

function rolemap.isLeafRole(role)
  return role ~= nil and LEAF[role] == true
end

function rolemap.semantic(role, action)
  local entry = role and TABLE[role]
  if entry then return entry[action] end
  return GENERIC[action]
end

return rolemap
