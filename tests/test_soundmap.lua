package.path = "../?.lua;" .. package.path
local runner = require("runner")
local soundmap = require("soundmap")
local t = runner.suite("soundmap")

t.test("maps the button tracking cycle", function()
  runner.eq(soundmap.bases["button.press"], "btnp")
  runner.eq(soundmap.bases["button.release"], "btnr")
  runner.eq(soundmap.bases["button.enter"], "btne")
  runner.eq(soundmap.bases["button.exit"], "btnx")
end)

t.test("marks window drag and scrollbar thumb as sustained", function()
  runner.isTrue(soundmap.sustained["window.move"])
  runner.isTrue(soundmap.sustained["scrollthumb.drag"])
end)

t.test("every sustained name also has a base mapping", function()
  for semantic in pairs(soundmap.sustained) do
    runner.isTrue(soundmap.bases[semantic] ~= nil,
      "sustained name missing a base: " .. semantic)
  end
end)

t.test("no two semantic names share a base", function()
  local seen = {}
  for semantic, base in pairs(soundmap.bases) do
    runner.isNil(seen[base],
      string.format("base %s used by both %s and %s",
        base, tostring(seen[base]), semantic))
    seen[base] = semantic
  end
end)

return t
