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
