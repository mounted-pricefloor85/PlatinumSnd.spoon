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

-- The semantic names are supposed to say what the constant says. Three of
-- them used to say something else, and the events hang off the names, so a
-- name that lies is a mapping that will be wired to the wrong gesture.
t.test("the scroll bar names match their constants", function()
  runner.eq(soundmap.bases["scrolltrack.press"], "sbtp")
  runner.isNil(soundmap.bases["scrollthumb.press"])
  runner.eq(soundmap.bases["scrollthumb.attack"], "sbth attack")
  runner.eq(soundmap.bases["scrollthumb.drag"], "sbth")
  runner.eq(soundmap.bases["scrollthumb.decay"], "sbth decay")
end)

t.test("slte is the end of the track, not a slider release", function()
  runner.eq(soundmap.bases["slider.endoftrack"], "slte")
  runner.isNil(soundmap.bases["slider.release"])
end)

-- 0.94 s, an order of magnitude longer than the 0.08 s clicks: a loop held
-- for as long as the ghost is being dragged, not a one-shot.
t.test("the slider ghost is a loop, not a click", function()
  runner.eq(soundmap.bases["slider.ghost"], "slgh")
  runner.isTrue(soundmap.sustained["slider.ghost"])
end)

t.test("the drag-over-icon names say what fdon and fdof mean", function()
  runner.eq(soundmap.bases["finder.dragonicon"], "fdon")
  runner.eq(soundmap.bases["finder.dragofficon"], "fdof")
  runner.isNil(soundmap.bases["finder.discloseon"])
  runner.isNil(soundmap.bases["finder.discloseoff"])
end)

t.test("dbtr and the little arrows carry their constants' names", function()
  runner.eq(soundmap.bases["defaultbutton.release"], "dbtr")
  runner.eq(soundmap.bases["littlearrow.uppress"], "laup")
  runner.eq(soundmap.bases["littlearrow.downrelease"], "ladr")
  runner.isNil(soundmap.bases["default.return"])
  runner.isNil(soundmap.bases["littlearrow.up"])
  runner.isNil(soundmap.bases["littlearrow.down"])
end)

-- Kept in the pack and in this table, wired to no event. Dropping them would
-- lose the decode; wiring them would need a guess or an AX round trip nobody
-- wants on a hot path.
t.test("the unowned sounds keep their bases", function()
  runner.eq(soundmap.bases["scrollarrow.press"], "sbap")
  runner.eq(soundmap.bases["scrollarrow.release"], "sbar")
  runner.eq(soundmap.bases["bevel.press"], "bevp")
  runner.eq(soundmap.bases["bevel.release"], "bevr")
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
