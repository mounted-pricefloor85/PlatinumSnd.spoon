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

-- flap is kThemeSoundLaunchApp, so it belongs to an event the Spoon can
-- actually observe rather than sitting in the unmapped misc group.
t.test("app launch owns flap, and nothing else claims it", function()
  runner.eq(soundmap.bases["app.launch"], "flap")
  runner.isNil(soundmap.bases["misc.flap"])
end)

-- Regression guard on the decode. Three of these were guesses the plan had
-- pointed at the wrong events, and the Finder source depends on the
-- corrected reading: ftrs is the Trash being emptied, fnew one item
-- appearing, fcpd several appearing at once.
t.test("the Finder source's four sounds keep their decoded bases", function()
  runner.eq(soundmap.bases["finder.select"], "fsel")
  runner.eq(soundmap.bases["finder.new"], "fnew")
  runner.eq(soundmap.bases["finder.copydone"], "fcpd")
  runner.eq(soundmap.bases["finder.trash"], "ftrs")
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
