# PlatinumSnd.spoon

Mac OS 9 interface sounds on modern macOS, as a [Hammerspoon](https://www.hammerspoon.org) Spoon.

Click a button and hear `btnp`. Slide down a menu and hear each item highlight.
Drag a window and hear the sustained scrape that changes timbre when you pause.
Throw a disk on the desktop, collapse a window, click a close box. If you used a
Mac between 1997 and 2001, you know exactly what this sounds like.

## Why this is harder than it looks

In Mac OS 9 the Appearance Manager drew every widget in the system, so the
theming layer already knew that the thing you just pressed was a button rather
than a checkbox. Sounds were part of the theme, and the OS handed you the widget
identity for free.

Modern macOS has no such layer. Each application draws its own controls in its
own process and nothing announces "the user pressed a checkbox". The one tool
that did this properly, Unsanity's Xounds, worked by injecting code into every
running process, and System Integrity Protection ended that whole category
permanently.

What is left is the accessibility API. This Spoon asks macOS what sits under
your cursor, reads its role, and picks the sound Apple's own Appearance Manager
would have played for that control. It is an approximation, but a surprisingly
close one.

## What you need

* macOS with [Hammerspoon](https://www.hammerspoon.org) installed
* Accessibility permission for Hammerspoon, which everything depends on
* Full Disk Access for Hammerspoon, but only if you want the Finder sounds
* The Platinum sound pack, which is not included (see below)

## The sound pack is not in this repository

The sounds are Apple's, extracted from the Platinum Sounds file that shipped
inside `System Folder:Appearance:Sound Sets` in Mac OS 8.5 through 9.2.2. They
are not mine to redistribute, so `snd/` is empty here and you supply your own
copy.

Download a set from the web. The Internet Archive has one under
[Mac OS 8.5 to 9.2.2 Platinum Sounds](https://archive.org/details/mac-os-85-9-platinum-sounds),
and the sounds also turn up in various OS 9 sound set collections. Any copy
works as long as the names match.

Put them here:

```
snd/
  wav/   67 files, named <base>_mp3-to.wav
  mp3/   68 files, named <base>.mp3
```

WAV is preferred because it decodes instantly, and the loader falls back to the
MP3 for any sound whose WAV is missing. In practice that is only `bevp`, which
was never converted in the set most people have.

Note that four names contain a space, so quote them if you are moving files
around on the command line.

<details>
<summary>Every file, if you want to check your copy</summary>

`snd/wav/` (67):

```
bevr_mp3-to.wav  blnc_mp3-to.wav  blno_mp3-to.wav  btne_mp3-to.wav
btnp_mp3-to.wav  btnr_mp3-to.wav  btnx_mp3-to.wav  chkp_mp3-to.wav
chkr_mp3-to.wav  dbtr_mp3-to.wav  delay_mp3-to.wav dsce_mp3-to.wav
dscp_mp3-to.wav  dscr_mp3-to.wav  dscx_mp3-to.wav  dske_mp3-to.wav
dski_mp3-to.wav  fcpd_mp3-to.wav  fdof_mp3-to.wav  fdon_mp3-to.wav
fdrp_mp3-to.wav  flap_mp3-to.wav  fnew_mp3-to.wav  fral_mp3-to.wav
fsel_mp3-to.wav  ftrs_mp3-to.wav  ladr_mp3-to.wav  laup_mp3-to.wav
mnuc_mp3-to.wav  mnui_mp3-to.wav  mnuo_mp3-to.wav  mnus_mp3-to.wav
popp_mp3-to.wav  popr_mp3-to.wav  pwcl_mp3-to.wav  pwop_mp3-to.wav
rade_mp3-to.wav  radp_mp3-to.wav  radr_mp3-to.wav  radx_mp3-to.wav
sbap_mp3-to.wav  sbar_mp3-to.wav  sbth_mp3-to.wav  sbtp_mp3-to.wav
slgh_mp3-to.wav  slte_mp3-to.wav  sltp_mp3-to.wav  tabe_mp3-to.wav
tabp_mp3-to.wav  tabr_mp3-to.wav  tabx_mp3-to.wav  tshd_mp3-to.wav
wact_mp3-to.wav  wcle_mp3-to.wav  wclp_mp3-to.wav  wclr_mp3-to.wav
wcls_mp3-to.wav  wclx_mp3-to.wav  wcol_mp3-to.wav  wexp_mp3-to.wav
wopn_mp3-to.wav  wzmi_mp3-to.wav  wzmo_mp3-to.wav
"sbth attack_mp3-to.wav"  "sbth decay_mp3-to.wav"
"wmov idle_mp3-to.wav"    "wmov moving_mp3-to.wav"
```

`snd/mp3/` (68):

```
bevp.mp3  bevr.mp3  blnc.mp3  blno.mp3  btne.mp3  btnp.mp3  btnr.mp3
btnx.mp3  chkp.mp3  chkr.mp3  dbtr.mp3  delay.mp3 dsce.mp3  dscp.mp3
dscr.mp3  dscx.mp3  dske.mp3  dski.mp3  fcpd.mp3  fdof.mp3  fdon.mp3
fdrp.mp3  flap.mp3  fnew.mp3  fral.mp3  fsel.mp3  ftrs.mp3  ladr.mp3
laup.mp3  mnuc.mp3  mnui.mp3  mnuo.mp3  mnus.mp3  popp.mp3  popr.mp3
pwcl.mp3  pwop.mp3  rade.mp3  radp.mp3  radr.mp3  radx.mp3  sbap.mp3
sbar.mp3  sbth.mp3  sbtp.mp3  slgh.mp3  slte.mp3  sltp.mp3  tabe.mp3
tabp.mp3  tabr.mp3  tabx.mp3  tshd.mp3  wact.mp3  wcle.mp3  wclp.mp3
wclr.mp3  wcls.mp3  wclx.mp3  wcol.mp3  wexp.mp3  wopn.mp3  wzmi.mp3
wzmo.mp3
"sbth attack.mp3"  "sbth decay.mp3"  "wmov idle.mp3"  "wmov moving.mp3"
```

</details>

Once they are in place, run `spoon.PlatinumSnd:audition()` from the Hammerspoon
console. It plays all 68 in sequence with their names printed, which both proves
the copy loaded and tells you what each one actually sounds like.

## Install

```sh
git clone https://github.com/eploko/PlatinumSnd.spoon.git \
  ~/.hammerspoon/Spoons/PlatinumSnd.spoon
```

Or download the zip, unpack it, and double click the `PlatinumSnd.spoon`
folder. Hammerspoon installs a double clicked Spoon into
`~/.hammerspoon/Spoons/` for you.

Then add this to `~/.hammerspoon/init.lua`:

```lua
hs.loadSpoon("PlatinumSnd")
spoon.PlatinumSnd:bindHotkeys({toggle = {{"cmd", "alt", "ctrl"}, "9"}})
spoon.PlatinumSnd:start()
```

Reload the config from the Hammerspoon menu and start clicking.

## Using it

`ctrl-alt-cmd-9` toggles the whole thing. Off means off: the event taps, timers
and observers are torn down rather than muted, so a silenced Spoon costs
nothing.

Two things are worth knowing about from the Hammerspoon console:

```lua
spoon.PlatinumSnd:audition()      -- play all 68 sounds in sequence, named
spoon.PlatinumSnd:dryRun(true)    -- log decisions instead of playing them
```

Dry run is how you find out why something sounded wrong. It prints lines like
`AXCheckBox -> checkbox.press (chkp)` as you click, so you can see what the
Spoon thought you were touching.

## What makes noise

Buttons, checkboxes, radio buttons, tabs, popup buttons, disclosure triangles,
sliders, scroll bars and steppers, each with the press and release sounds Apple
assigned them, and enter and exit sounds for the families that had them.

Menus opening, items highlighting as you slide past, selection, dismissal. The
close box gets its full tracking cycle, which is the detail that most gives the
period away.

Windows opening, closing, zooming, collapsing and activating. Window dragging
holds a loop that crossfades between an idle and a moving timbre depending on
whether the window is actually moving. Disks mounting and ejecting.
Applications launching.

In the Finder: selection, new items, a copy finishing, the Trash being emptied,
files being dragged over icons and dropped.

58 of the pack's 68 sounds are wired to a real event.

## What stays silent, deliberately

Ten sounds have no honest modern trigger, and inventing one would be worse than
leaving them alone:

| Sound | Why |
| --- | --- |
| `blno`, `blnc` | Balloon help. Its descendant is the tooltip, which macOS does not announce. |
| `sbap`, `sbar` | Scroll arrows, removed from macOS in 10.7. |
| `bevp`, `bevr` | Bevel buttons. Detecting one needs a parent lookup on every button probe, which is not worth the accessibility traffic. |
| `fral` | Alias resolution, which produces no observable signal. |
| `slte` | Slider end of track, which needs polling the slider's value on every drag tick. |
| `tshd`, `delay` | Sound track internals rather than events. `tshd` is unidentified even in Apple's own header. |

## How it works

Five sources feed one playback engine. All the decision logic lives in modules
that never import Hammerspoon, so it runs under stock Lua and is covered by 154
tests.

The interesting part is the cost. Asking macOS what is under the cursor is a
synchronous round trip into another process, on Hammerspoon's single thread, and
doing it on every mouse movement would be both slow and rude. So the hover layer
caches the element's frame and skips the question entirely while the cursor
stays inside it. On real hardware that removes about 95% of the accessibility
traffic, and the machine is completely idle when your hands are off the mouse.

Cached answers expire on a timer that depends on what was cached. A button
cannot contain something that is not a button, so its answer is trusted for two
seconds. A container such as a toolbar or a scroll area encloses children with
different roles, so its answer only survives 200 milliseconds.

A per-application circuit breaker stops probing any app that times out
repeatedly, which keeps one beachballed process from taking the sound layer down
with it.

For the full picture, `docs/` has the design, the mapping of every four letter
name to Apple's `ThemeSoundKind` constants, and a verification checklist.

## The sound names

The four letter names are not arbitrary. They are Apple's `ThemeSoundKind`
four character codes from the Appearance Manager, so every one has a documented
meaning: `btnp` is `kThemeSoundButtonPress`, `flap` is `kThemeSoundLaunchApp`,
`ftrs` is `kThemeSoundEmptyTrash`. 60 of the 68 map to a constant in
`Appearance.h`. The other eight are sound track internals, and every one of them
turns out to be a continuous sound rather than a one shot, which is why the
engine has a sustained playback path at all.

`docs/sound-decode.md` has the full table.

## Known behaviour that is not a bug

A cursor resting on a control never re-checks what it is sitting on, which keeps
the machine silent while you read. The cost is that a control replaced in place
under a motionless pointer can sound wrong on the next click.

Moving a file between two watched folders sounds like a new item, because from
the destination's point of view it is one.

Clicking a close box makes two sounds, the release and then the window closing.
Apple's constants define both, so this is faithful, but you may not want it.

Overlay scroll bars are in the accessibility tree while hidden but are not
hit testable, so scroll bar sounds mostly need System Settings > Appearance >
Show scroll bars > Always.

## Development

```sh
cd tests
lua5.4 -e 'for _,s in ipairs{"test_resolver","test_soundmap","test_axpolicy",
  "test_rolemap","test_fgate","test_menugate"} do require(s) end;
  os.exit(require("runner").run())'
```

No Hammerspoon needed. The pure modules take time, geometry and file existence
as parameters rather than reaching for them, which is what lets the whole
decision layer be tested off a Mac.

`spoon.PlatinumSnd:diagnose()` runs a diagnostic harness against a live
Hammerspoon: permissions, asset loading, the accessibility assumptions, the
decision chain over whatever is on screen, the cache hit rate, and teardown. It
writes a report to your desktop. Add `{guided = true}` for the checks that need
you to open a menu or drag a file.

## Licence

MIT for the code.

The sounds are Apple's and are not covered by it, are not included here, and
were never mine to license.
