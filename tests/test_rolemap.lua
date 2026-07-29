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

-- A radio button is a radio button. The tab entries below are a refinement
-- of this role, not a replacement for it, so the plain case has to keep
-- sounding exactly as it did.
t.test("radio buttons have the full tracking cycle", function()
  runner.eq(rolemap.semantic("AXRadioButton", "press"), "radio.press")
  runner.eq(rolemap.semantic("AXRadioButton", "release"), "radio.release")
  runner.eq(rolemap.semantic("AXRadioButton", "enter"), "radio.enter")
  runner.eq(rolemap.semantic("AXRadioButton", "exit"), "radio.exit")
end)

-- AXCloseButton and AXTab are SYNTHETIC roles. macOS reports neither as an
-- AXRole: the probe mints them when a button's AXSubrole says AXCloseButton,
-- and when a radio button's parent is an AXTabGroup. Refining the role
-- string is what keeps this table a plain role lookup.
t.test("a close box has the full tracking cycle", function()
  runner.eq(rolemap.semantic("AXCloseButton", "press"), "closebox.press")
  runner.eq(rolemap.semantic("AXCloseButton", "release"), "closebox.release")
  runner.eq(rolemap.semantic("AXCloseButton", "enter"), "closebox.enter")
  runner.eq(rolemap.semantic("AXCloseButton", "exit"), "closebox.exit")
end)

-- The pack has dedicated tab sounds, so a tab sounding like a radio button
-- was a mapping the decode disproved rather than a judgement call.
t.test("a tab has the full tracking cycle", function()
  runner.eq(rolemap.semantic("AXTab", "press"), "tab.press")
  runner.eq(rolemap.semantic("AXTab", "release"), "tab.release")
  runner.eq(rolemap.semantic("AXTab", "enter"), "tab.enter")
  runner.eq(rolemap.semantic("AXTab", "exit"), "tab.exit")
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

-- Pressing a menu bar title is the commonest gesture in the whole shell, and
-- without an entry of its own it fell through to the generic click: `btnp` on
-- the press, `mnuo` from the observer, `btnr` on the release. Three sounds
-- where OS 9 gave one. AXMenuItem already had an entry for exactly this
-- reason; the menu BAR item was the one that was missed.
--
-- The panel role goes with it. A press that lands on the menu's own background
-- rather than on one of its items is not a button either.
t.test("a menu bar item is silent, leaving the open sound to the observer",
  function()
    runner.isNil(rolemap.semantic("AXMenuBarItem", "press"))
    runner.isNil(rolemap.semantic("AXMenuBarItem", "release"))
    runner.isNil(rolemap.semantic("AXMenu", "press"))
    runner.isNil(rolemap.semantic("AXMenu", "release"))
  end)

-- The silencing above is by role, not a widening of the fallthrough. An
-- ordinary button must still click, or the entries above have gone too far.
t.test("silencing the menu bar leaves the generic click intact", function()
  runner.eq(rolemap.semantic("AXButton", "press"), "button.press")
  runner.eq(rolemap.semantic("AXButton", "release"), "button.release")
  runner.eq(rolemap.semantic("AXGroup", "press"), "button.press")
  runner.eq(rolemap.semantic("AXGroup", "release"), "button.release")
end)

-- Leafness for the menu bar title, which is a cost question rather than a
-- sound one. Without it the hover loop puts a cursor resting on the Apple menu
-- on the short container ceiling and re-probes it five times a second.
t.test("a menu bar item is a leaf, so hovering it stops re-probing", function()
  runner.isTrue(rolemap.isLeafRole("AXMenuBarItem"))
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

-- Ten of the pack's sounds are owned by nothing on purpose, and this is the
-- list. `sbap`/`sbar` are the arrows of a scroll bar modern macOS no longer
-- draws; `slte` needs the slider's value compared against its bounds on every
-- drag tick; `bevp`/`bevr` would need an AXParent round trip on every button
-- probe -- the commonest probe there is -- to tell a toolbar button from any
-- other; `blno`/`blnc` are balloon help, and macOS does not announce tooltips;
-- `fral` is alias resolution, which surfaces nowhere observable; and `tshd`
-- and `delay` are sound-track internals rather than events at all. This guards
-- the decision against a role quietly acquiring one of them again.
--
-- The AXParent read the tab refinement does costs the same as the one `bevp`
-- was rejected for, but it is charged only on a radio button rather than on
-- every button, which is why one is affordable and the other is not.
t.test("no role produces a deliberately unmapped sound", function()
  local banned = {
    ["scrollarrow.press"] = true, ["scrollarrow.release"] = true,
    ["slider.endoftrack"] = true,
    ["bevel.press"] = true, ["bevel.release"] = true,
    ["balloon.open"] = true, ["balloon.close"] = true,
    ["finder.reveal"] = true,
    ["misc.threshold"] = true, ["misc.delay"] = true,
  }
  local roles = {"AXButton", "AXCheckBox", "AXRadioButton",
                 "AXDisclosureTriangle", "AXPopUpButton", "AXSlider",
                 "AXScrollBar", "AXValueIndicator", "AXIncrementor",
                 "AXMenuItem", "AXToolbar", "AXGroup", "AXStaticText",
                 "AXCloseButton", "AXTab", "AXTabGroup"}
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

-- The synthetic roles refine a leaf, so they are leaves too. It has to be
-- said out loud: a missing entry drops them to the short container ceiling,
-- and a cursor resting on a close box would then re-probe five times a second
-- -- each probe now carrying the extra attribute read this refinement costs.
-- AXTabGroup, the container the probe reads to mint AXTab, stays a non-leaf.
t.test("the synthetic roles are leaves", function()
  runner.isTrue(rolemap.isLeafRole("AXCloseButton"))
  runner.isTrue(rolemap.isLeafRole("AXTab"))
  runner.eq(rolemap.isLeafRole("AXTabGroup"), false)
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
