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
  AXSlider = {press = "slider.press", release = "slider.release"},
  AXScrollBar = {
    press = "scrollarrow.press", release = "scrollarrow.release",
  },
  -- laup/ladr are almost certainly up and down rather than press and
  -- release, but AXIncrementor does not report which half was hit. Both
  -- map to press until auditioning settles it; Task 10 revisits this.
  AXIncrementor = {press = "littlearrow.up"},
  -- Menu items are owned by src_menus for press/release. The pointer layer
  -- contributes only the highlight, so clicking one does not sound twice.
  AXMenuItem = {enter = "menu.item"},
}

local GENERIC = {press = "button.press", release = "button.release"}

function rolemap.semantic(role, action)
  local entry = role and TABLE[role]
  if entry then return entry[action] end
  return GENERIC[action]
end

return rolemap
