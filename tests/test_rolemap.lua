package.path = "../?.lua;" .. package.path
local runner = require("runner")
local rolemap = require("rolemap")
local t = runner.suite("rolemap")

t.test("buttons have the full tracking cycle", function()
  runner.eq(rolemap.semantic("AXButton", "press"), "button.press")
  runner.eq(rolemap.semantic("AXButton", "release"), "button.release")
  runner.eq(rolemap.semantic("AXButton", "enter"), "button.enter")
  runner.eq(rolemap.semantic("AXButton", "exit"), "button.exit")
end)

t.test("checkboxes have no enter or exit sound", function()
  runner.eq(rolemap.semantic("AXCheckBox", "press"), "checkbox.press")
  runner.isNil(rolemap.semantic("AXCheckBox", "enter"))
end)

t.test("menu items are silent on press, owned by the menu source", function()
  runner.isNil(rolemap.semantic("AXMenuItem", "press"))
  runner.isNil(rolemap.semantic("AXMenuItem", "release"))
  runner.eq(rolemap.semantic("AXMenuItem", "enter"), "menu.item")
end)

-- docs/sound-decode.md settles what the scroll bar sounds are. `sbtp` is
-- kThemeSoundScrollTrackPress -- the trough being clicked, not the thumb --
-- and the thumb's own sound is the `sbth` attack-sustain-decay set, an
-- envelope only the pointer layer can drive. So the trough sounds here and
-- the thumb deliberately does not, because falling through to the generic
-- click would put a button noise under a grabbed thumb.
t.test("the trough sounds, the thumb is left to the pointer layer", function()
  runner.eq(rolemap.semantic("AXScrollBar", "press"), "scrolltrack.press")
  runner.isNil(rolemap.semantic("AXScrollBar", "release"))
  runner.isNil(rolemap.semantic("AXValueIndicator", "press"))
  runner.isNil(rolemap.semantic("AXValueIndicator", "release"))
end)

-- `sltp` is kThemeSoundSliderTrackPress. Its counterpart `slte` is
-- kThemeSoundSliderEndOfTrack, which is not a release at all -- it needs the
-- slider's value against its bounds -- so a slider has no release sound.
t.test("a slider presses on its track and releases silently", function()
  runner.eq(rolemap.semantic("AXSlider", "press"), "slider.press")
  runner.isNil(rolemap.semantic("AXSlider", "release"))
end)

-- `laup` is the UP press and `ladr` the DOWN release, so which of the two a
-- click earns depends on which half of the frame it landed in. This table
-- sees a role and an action and nothing else, and the generic fallthrough
-- would put a plain button click on a stepper, so it stays silent and the
-- pointer layer decides against the cached frame.
t.test("an incrementor is silent until geometry decides", function()
  runner.isNil(rolemap.semantic("AXIncrementor", "press"))
  runner.isNil(rolemap.semantic("AXIncrementor", "release"))
end)

-- Five of the pack's sounds are owned by nothing on purpose: `sbap`/`sbar`
-- are the arrows of a scroll bar modern macOS no longer draws, `slte` needs
-- the slider's value compared against its bounds on every drag tick, and
-- `bevp`/`bevr` would need an AXParent round trip per probe to tell a
-- toolbar button from any other. This guards the decision against a role
-- quietly acquiring one of them again.
t.test("no role produces a deliberately unmapped sound", function()
  local banned = {
    ["scrollarrow.press"] = true, ["scrollarrow.release"] = true,
    ["slider.endoftrack"] = true,
    ["bevel.press"] = true, ["bevel.release"] = true,
  }
  local roles = {"AXButton", "AXCheckBox", "AXRadioButton",
                 "AXDisclosureTriangle", "AXPopUpButton", "AXSlider",
                 "AXScrollBar", "AXValueIndicator", "AXIncrementor",
                 "AXMenuItem", "AXToolbar", "AXGroup", "AXStaticText"}
  for _, role in ipairs(roles) do
    for _, action in ipairs({"press", "release", "enter", "exit"}) do
      runner.isNil(banned[rolemap.semantic(role, action)],
        string.format("%s %s produces an unmapped sound", role, action))
    end
  end
end)

t.test("unknown roles fall back to a generic click", function()
  runner.eq(rolemap.semantic("AXGroup", "press"), "button.press")
  runner.eq(rolemap.semantic("AXStaticText", "release"), "button.release")
end)

t.test("unknown roles produce no enter or exit sound", function()
  runner.isNil(rolemap.semantic("AXGroup", "enter"))
  runner.isNil(rolemap.semantic("AXGroup", "exit"))
end)

t.test("nil role produces the generic click on press", function()
  runner.eq(rolemap.semantic(nil, "press"), "button.press")
end)

-- Leafness. Accessibility elements nest, and a hit-test descends to the
-- deepest one at the point, so a probe that lands on container-only space
-- caches a frame that ENCLOSES children with different roles. The hover
-- loop may only trust frame containment when the cached role cannot have a
-- differently-roled child inside it.
--
-- This is a containment question, not a sound question: AXStaticText and
-- AXValueIndicator are leaves with no entry in the sound table at all, and
-- AXScrollBar has an entry but is a container -- it holds the indicator and
-- the two arrow buttons.
t.test("the interactive leaf roles are leaves", function()
  for _, role in ipairs({"AXButton", "AXCheckBox", "AXRadioButton",
                         "AXDisclosureTriangle", "AXPopUpButton", "AXSlider",
                         "AXMenuItem", "AXValueIndicator", "AXIncrementor",
                         "AXStaticText"}) do
    runner.isTrue(rolemap.isLeafRole(role), role .. " should be a leaf")
  end
end)

t.test("container roles are not leaves", function()
  for _, role in ipairs({"AXWindow", "AXGroup", "AXScrollArea", "AXToolbar",
                         "AXMenu", "AXMenuBar", "AXList", "AXTable",
                         "AXSplitGroup", "AXTabGroup"}) do
    runner.eq(rolemap.isLeafRole(role), false, role .. " should not be a leaf")
  end
end)

-- A scroll bar sounds, but it still contains its indicator and arrows, so
-- an element having a sound says nothing about whether it can be trusted to
-- hold the cursor alone.
t.test("a role with a sound can still be a container", function()
  runner.eq(rolemap.isLeafRole("AXScrollBar"), false)
end)

t.test("an unknown role is not a leaf", function()
  runner.eq(rolemap.isLeafRole("AXSomethingNobodyMapped"), false)
end)

t.test("a nil role is not a leaf", function()
  runner.eq(rolemap.isLeafRole(nil), false)
end)

return t
