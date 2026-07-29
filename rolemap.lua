-- PURE. AX role -> semantic sound name, per action.
--
-- Two of the roles below are SYNTHETIC: `AXCloseButton` and `AXTab`. macOS
-- reports neither as an AXRole -- `axprobe` mints them from a second
-- attribute (a button's AXSubrole, a radio button's parent role) and hands
-- them on in the role slot, so this table stays a plain role lookup. See
-- `axpolicy.refinedRole` for the rule that produces them.
local rolemap = {}

local TABLE = {
  AXButton = {
    press = "button.press", release = "button.release",
    enter = "button.enter", exit = "button.exit",
  },
  -- SYNTHETIC ROLE. The window's red traffic light, an AXButton whose
  -- AXSubrole is AXCloseButton. `wclp`/`wclr`/`wcle`/`wclx` are the four
  -- kThemeSoundWindowClose* constants -- OS 9 tracked the close box the same
  -- way it tracked a push button, press through release and enter through
  -- exit, and the pack carries all four.
  --
  -- Distinct from `window.close`: `wcls` is the window actually going away,
  -- which src_windows owns and which also fires for a Cmd-W nobody clicked.
  AXCloseButton = {
    press = "closebox.press", release = "closebox.release",
    enter = "closebox.enter", exit = "closebox.exit",
  },
  AXCheckBox = {press = "checkbox.press", release = "checkbox.release"},
  AXRadioButton = {
    press = "radio.press", release = "radio.release",
    enter = "radio.enter", exit = "radio.exit",
  },
  -- SYNTHETIC ROLE. A tab, which macOS models as an AXRadioButton child of
  -- an AXTabGroup. Without the refinement these sound as radio buttons, and
  -- the pack has four dedicated tab sounds saying they should not.
  AXTab = {
    press = "tab.press", release = "tab.release",
    enter = "tab.enter", exit = "tab.exit",
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
  -- The menu bar title, and the panel a menu opens as. Both silent, and both
  -- need an entry to say so -- without one they fall through to the generic
  -- click below, and pressing a menu bar title gave three sounds for one
  -- gesture: `btnp` from here, `mnuo` from the observer, then `btnr` on the
  -- release. OS 9 gave `mnuo` alone, and this is the most frequent gesture in
  -- the whole shell to have got it wrong.
  --
  -- No enter or exit either. The bar is not a tracking surface in this pack:
  -- `mnui` is kThemeSoundMenuItemHilite and belongs to items inside an open
  -- menu, which AXMenuItem above owns.
  --
  -- KNOWINGLY ACCEPTED. Menu extras and status items belong to accessory apps,
  -- which src_menus skips on `kind() ~= 1`, so those menus have no observer to
  -- supply the `mnuo` this defers to. For them these two entries turn a wrong
  -- sound into no sound. That is the better failure of the two, and it is the
  -- same trade already recorded under "Known judgement calls" in
  -- docs/mac-verification.md for accessory-app menus generally.
  AXMenuBarItem = {},
  AXMenu = {},
}

local GENERIC = {press = "button.press", release = "button.release"}

-- Roles treated as unable to hold a differently-roled child. Accessibility
-- elements nest and a hit-test descends to the deepest one at the point, so a
-- probe landing on container-only space -- toolbar background, a scroll area,
-- the panel of a menu between its items -- caches a frame that ENCLOSES
-- children with other roles. Frame containment is only a sound proxy for "the
-- answer cannot have changed" when the cached role is one of these.
--
-- ONE EXCEPTION, listed knowingly: AXSlider encloses its AXValueIndicator
-- thumb. So a slider cached by the hover loop keeps answering "slider" for
-- the cursor moving onto its own thumb, and a click there inside
-- `cacheRevalidateSeconds` plays `slider.press` rather than falling through
-- to the thumb's silence. Benign -- `sltp` is kThemeSoundSliderTrackPress and
-- a press on a slider is what happened -- and the alternative costs a probe
-- every fifth of a second for every cursor resting anywhere on a slider. What
-- is NOT affected is grabbing the thumb to drag it: the press is what opens
-- the `sbth` envelope, and reaching the thumb means moving onto it, which is
-- exactly what makes the hover loop probe and re-cache.
--
-- This is a containment question, not a sound question. AXStaticText and
-- AXValueIndicator are leaves with no entry in TABLE at all, while
-- AXScrollBar has one and is still a container: it holds the indicator and
-- the two arrow buttons. Anything absent -- every container, every role
-- nobody has mapped, and nil -- is not a leaf, which is the safe answer
-- because it only costs a probe.
--
-- The two synthetic roles are leaves because the roles they refine are, and
-- refining a role cannot give it children. Listing them matters: a missing
-- entry would put a close box or a tab on the short container ceiling, so the
-- hover loop would re-probe one the cursor is sitting on every fifth of a
-- second -- and each of those probes now carries the extra attribute read.
-- Leafness is what keeps that cost to once per crossing.
-- AXMenuBarItem is here for the cost reason above rather than the sound one:
-- a cursor resting on a menu bar title would otherwise sit on the short
-- container ceiling and re-probe five times a second. AXMenu is deliberately
-- absent -- it is the panel, and it holds the items.
local LEAF = {
  AXButton = true, AXCloseButton = true, AXCheckBox = true,
  AXRadioButton = true, AXTab = true,
  AXDisclosureTriangle = true, AXPopUpButton = true, AXSlider = true,
  AXMenuItem = true, AXMenuBarItem = true, AXValueIndicator = true,
  AXIncrementor = true, AXStaticText = true,
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
