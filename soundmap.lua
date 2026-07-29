-- PURE. Semantic event name -> sound pack base name.
-- This table is the single place to correct a mapping after auditioning.
local soundmap = {}

soundmap.bases = {
  ["button.press"]        = "btnp",
  ["button.release"]      = "btnr",
  ["button.enter"]        = "btne",
  ["button.exit"]         = "btnx",
  -- kThemeSoundBevelPress/Release. A bevel button was a Carbon control whose
  -- nearest modern relative is a button inside an AXToolbar -- and telling
  -- those apart needs an AXParent round trip on every button probe, which
  -- doubles the cost of the commonest probe there is for a variant nobody
  -- would name. Kept named, owned by nothing.
  ["bevel.press"]         = "bevp",
  ["bevel.release"]       = "bevr",
  ["defaultbutton.release"] = "dbtr",  -- kThemeSoundDefaultButtonRelease
  ["checkbox.press"]      = "chkp",
  ["checkbox.release"]    = "chkr",
  ["radio.press"]         = "radp",
  ["radio.release"]       = "radr",
  ["radio.enter"]         = "rade",
  ["radio.exit"]          = "radx",
  ["tab.press"]           = "tabp",
  ["tab.release"]         = "tabr",
  ["tab.enter"]           = "tabe",
  ["tab.exit"]            = "tabx",
  ["disclosure.press"]    = "dscp",
  ["disclosure.release"]  = "dscr",
  ["disclosure.enter"]    = "dsce",
  ["disclosure.exit"]     = "dscx",
  ["popup.press"]         = "popp",
  ["popup.release"]       = "popr",
  ["slider.press"]        = "sltp",  -- kThemeSoundSliderTrackPress
  -- kThemeSoundSliderEndOfTrack: the thumb reaching either stop, which needs
  -- the slider's value read against its minimum and maximum -- three extra
  -- accessibility reads on every tick of a drag. Owned by nothing.
  ["slider.endoftrack"]   = "slte",
  ["slider.ghost"]        = "slgh",  -- the ghost drag loop, 0.94 s
  -- kThemeSoundScrollArrowPress/Release. Modern macOS draws no scroll
  -- arrows, so there is nothing to press. Owned by nothing.
  ["scrollarrow.press"]   = "sbap",
  ["scrollarrow.release"] = "sbar",
  ["scrolltrack.press"]   = "sbtp",  -- kThemeSoundScrollTrackPress: the trough
  -- The thumb's own sound is this envelope rather than any one click.
  ["scrollthumb.attack"]  = "sbth attack",
  ["scrollthumb.drag"]    = "sbth",
  ["scrollthumb.decay"]   = "sbth decay",
  -- Two of the six little-arrow sounds are all the pack carries, so an up
  -- release and a down press have nothing honest to play.
  ["littlearrow.uppress"]   = "laup",  -- kThemeSoundLittleArrowUpPress
  ["littlearrow.downrelease"] = "ladr", -- kThemeSoundLittleArrowDnRelease
  ["menu.open"]           = "mnuo",
  ["menu.select"]         = "mnus",
  ["menu.item"]           = "mnui",
  ["menu.close"]          = "mnuc",
  ["window.open"]         = "wopn",
  ["window.close"]        = "wcls",
  ["window.activate"]     = "wact",
  ["window.collapse"]     = "wcol",
  ["window.expand"]       = "wexp",
  ["window.zoomin"]       = "wzmi",
  ["window.zoomout"]      = "wzmo",
  ["window.move"]         = "wmov idle",
  ["window.moving"]       = "wmov moving",
  ["closebox.press"]      = "wclp",
  ["closebox.release"]    = "wclr",
  ["closebox.enter"]      = "wcle",
  ["closebox.exit"]       = "wclx",
  -- No closebox.confirm: it would share `wcls` with window.close. The close
  -- box releasing already sounds `wclr`, and the window itself closing
  -- sounds window.close.
  ["palette.open"]        = "pwop",
  ["palette.close"]       = "pwcl",
  ["balloon.open"]        = "blno",
  ["balloon.close"]       = "blnc",
  -- No longer guesses: docs/sound-decode.md ties every one of these to a
  -- ThemeSoundKind constant. `ftrs` is the Trash being EMPTIED rather than an
  -- item being thrown into it, and `fdon`/`fdof` are the cursor crossing a
  -- droppable icon mid-drag rather than a list row opening. Row disclosure
  -- has no sound in this pack and nothing is wired to it.
  ["finder.new"]          = "fnew",  -- kThemeSoundNewItem
  ["finder.select"]       = "fsel",  -- kThemeSoundSelectItem
  ["finder.drop"]         = "fdrp",  -- kThemeSoundReceiveDrop
  ["finder.copydone"]     = "fcpd",  -- kThemeSoundCopyDone
  ["finder.trash"]        = "ftrs",  -- kThemeSoundEmptyTrash
  ["finder.reveal"]       = "fral",  -- kThemeSoundResolveAlias, no signal
  ["finder.dragonicon"]   = "fdon",  -- kThemeSoundFinderDragOnIcon
  ["finder.dragofficon"]  = "fdof",  -- kThemeSoundFinderDragOffIcon
  ["disk.insert"]         = "dski",
  ["disk.eject"]          = "dske",
  ["app.launch"]          = "flap",  -- kThemeSoundLaunchApp
  ["misc.threshold"]      = "tshd",  -- guess, unmapped to any event
  ["misc.delay"]          = "delay", -- guess, unmapped to any event
}

-- Loops rather than one-shots. Every one of them is around a second long
-- where the clicks are under a tenth, which is what identifies them: they
-- are held for as long as a gesture lasts and stopped when it ends.
soundmap.sustained = {
  ["window.move"]      = true,
  ["window.moving"]    = true,
  ["scrollthumb.drag"] = true,
  ["slider.ghost"]     = true,
}

return soundmap
