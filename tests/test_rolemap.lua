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

return t
