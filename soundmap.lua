-- PURE. Semantic event name -> sound pack base name.
-- This table is the single place to correct a mapping after auditioning.
local soundmap = {}

soundmap.bases = {
  ["button.press"]        = "btnp",
  ["button.release"]      = "btnr",
  ["button.enter"]        = "btne",
  ["button.exit"]         = "btnx",
  ["bevel.press"]         = "bevp",
  ["bevel.release"]       = "bevr",
  ["default.return"]      = "dbtr",  -- guess: default button
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
  ["slider.press"]        = "sltp",
  ["slider.release"]      = "slte",
  ["slider.ghost"]        = "slgh",  -- guess
  ["scrollarrow.press"]   = "sbap",
  ["scrollarrow.release"] = "sbar",
  ["scrollthumb.press"]   = "sbtp",
  ["scrollthumb.attack"]  = "sbth attack",
  ["scrollthumb.drag"]    = "sbth",
  ["scrollthumb.decay"]   = "sbth decay",
  ["littlearrow.up"]      = "laup",
  ["littlearrow.down"]    = "ladr",
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
  -- droppable icon mid-drag rather than a list row opening -- so their
  -- semantic names are now misnomers, renamed with the rest in Task 11. Row
  -- disclosure has no sound in this pack and nothing is wired to it.
  ["finder.new"]          = "fnew",  -- kThemeSoundNewItem
  ["finder.select"]       = "fsel",  -- kThemeSoundSelectItem
  ["finder.drop"]         = "fdrp",  -- kThemeSoundReceiveDrop
  ["finder.copydone"]     = "fcpd",  -- kThemeSoundCopyDone
  ["finder.trash"]        = "ftrs",  -- kThemeSoundEmptyTrash
  ["finder.reveal"]       = "fral",  -- kThemeSoundResolveAlias, no signal
  ["finder.discloseon"]   = "fdon",  -- kThemeSoundFinderDragOnIcon
  ["finder.discloseoff"]  = "fdof",  -- kThemeSoundFinderDragOffIcon
  ["disk.insert"]         = "dski",
  ["disk.eject"]          = "dske",
  ["app.launch"]          = "flap",  -- kThemeSoundLaunchApp
  ["misc.threshold"]      = "tshd",  -- guess, unmapped to any event
  ["misc.delay"]          = "delay", -- guess, unmapped to any event
}

soundmap.sustained = {
  ["window.move"]      = true,
  ["window.moving"]    = true,
  ["scrollthumb.drag"] = true,
}

return soundmap
