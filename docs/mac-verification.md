# PlatinumSnd — Mac verification checklist

Every line of this Spoon that touches Hammerspoon was written on a Linux
machine with no macOS. The pure logic has 123 passing assertions; **none of the
`hs` code has ever executed**. This is the ordered list for the first real run.

Ordered by what a failure costs, not by task number. Work down it. If something
in §1 or §2 fails, stop and fix it — everything below assumes those hold.

---

## Before you start

**1. Config.** `~/.hammerspoon/init.lua` should already contain exactly:

```lua
hs.loadSpoon("PlatinumSnd")
spoon.PlatinumSnd:bindHotkeys({toggle = {{"cmd", "alt", "ctrl"}, "9"}})
spoon.PlatinumSnd:start()
```

**2. Permissions.** Two, both for Hammerspoon.app:

- **Accessibility** (System Settings → Privacy & Security → Accessibility).
  Without it `:start()` refuses to run, alerts once and fires the system
  prompt. Everything in this Spoon depends on it.
- **Full Disk Access.** `~/Desktop`, `~/Documents` and `~/Downloads` are
  TCC-protected. Without it the Finder path watchers never fire and the
  symptom is silence with no error in the console.

**3. Reload.** Hammerspoon menu bar → Reload Config, or `hs.reload()` in the
Console. `hs.loadSpoon` re-`dofile`s the Spoon, so a reload always gets a fresh
`obj` with an empty source list.

**4. Source indices.** Console snippets below index `spoon.PlatinumSnd.sources`.
Registration order is fixed in `init.lua`:

| index | source |
|---|---|
| 1 | `src_pointer` (hover, clicks, drags, gestures — owns `.probe`) |
| 2 | `src_windows` (window filter, disks, app launch, window drag) |
| 3 | `src_menus` (per-pid observer fleet) |
| 4 | `src_finder` |
| 5 | `src_keys` (default button) |

---

## Run the harness first

```lua
spoon.PlatinumSnd:diagnose()               -- about a minute, hands off the mouse
spoon.PlatinumSnd:diagnose({guided = true})  -- adds the steps needing a human
spoon.PlatinumSnd:diagnose({delay = 10})     -- wait, so another app can be fronted
```

It writes `~/Desktop/platinumsnd-diagnostics.txt` and prints the same report to
the Console. Everything it reports is machine-recorded: a role the probe
actually returned, a file that actually resolved, a probe count actually
measured. Nothing in it is an impression.

It answers, without a single click: §1.2, §1.3, all of §2 except 2.5, 2.6 and
2.9, the decision half of §3.4, §3.6 and §3.9 (which role was found and which
sound the maps chose for it — never whether that sound is right), §3.17, §4.2,
and §5.4, §5.6, §5.8 and §5.10. `{guided = true}` records what arrives during
§3.19, §3.20, §3.22, §3.24 and §3.27 without judging it.

What it cannot answer is everything §1.5 and §6 are about, and every "does it
sound right" in §3 and §4. Those are the ears' work and the reason the rest of
this document exists. Run the harness, paste the report, then work down what it
could not reach.

Read the report bottom-up: the summary lists only the FAIL and WARN lines.
`[----]` means not tested — usually a role that was not on screen, which is a
gap in the test rather than a defect.

**What it touches.** The cursor, which Phase C moves over the controls it finds
and puts back; this Spoon's own state, which it silences and restarts; and the
report file. It opens, closes, moves and focuses **no** window — including the
Console, which is why E1 and E2 read `[SKIP]` when you run `:diagnose()` from
the Console you already had open. It writes no other file, never clicks or
types, and never acts on an accessibility element: it reads and it hovers, so
apps may show a tooltip as the cursor passes and nothing more. If Calculator is
not running it is launched in the background and quit again, for `flap`.

Two things happen only under `{guided = true}`: the steps that ask you to act,
and one step that creates and removes a single scratch file on your Desktop —
printing the exact path before it does either.

## The two diagnostic tools

Everything else is diagnosable through these. Learn them first.

**Dry run** — logs the mapping instead of playing it, so you can click around an
app in silence and read what it *would* have done:

```lua
spoon.PlatinumSnd:dryRun(true)
-- ... click around, watch the Hammerspoon Console ...
-- lines read: DRYRUN play checkbox.press (chkp)
spoon.PlatinumSnd:dryRun(false)
```

Note `dryRun` suppresses `play` and `sustain` but not `release` — harmless,
since nothing was started. An unknown semantic name logs as `(nil)`, which is
how a typo in an event name surfaces.

**Audition** — plays all 68 sounds in alphabetical order by semantic name, one
every 1.2 s (about 82 seconds total), printing `semantic  base  path`:

```lua
spoon.PlatinumSnd:audition()
```

This is the check that settles which sound is which. `soundmap.lua` is the one
file to correct if a name is wrong.

---

## 1. Does it load and make any sound at all

- [ ] **1.1 The Spoon starts.** Reload. Check `print(spoon.PlatinumSnd.running)`.
  - Expect: `true`, no errors in the Console.
  - Fails: `false` plus the alert `PlatinumSnd needs Accessibility permission`
    means the permission is not granted — grant it and reload. A traceback
    naming `hs.spoons.resourcePath` means the Spoon directory name or layout is
    wrong. A traceback out of `engine:load()` escapes uncaught by design
    (`load()` sits outside the per-source `pcall`), so a sound-loading failure
    takes the whole start down rather than half-starting.

- [ ] **1.2 The pack resolves.** Read the Console log from the reload.
  - Expect: **no** `unresolved sounds:` warning. All 68 bases were confirmed
    resolvable against the files on disk; 67 to WAV, `bevp` to MP3 via the
    fallback.
  - Fails: any name listed means the root path is wrong, not the map — check
    `hs.spoons.resourcePath("snd")`. If macOS's case-insensitive filesystem
    changes resolution (all base names are lower case, so this is unlikely),
    it would show up here as a name that resolves on APFS but not on ext4.

- [ ] **1.3 One sound plays.**
    `spoon.PlatinumSnd.engine:play("button.press")`
  - Expect: an audible click.
  - Fails: silence with `0 unresolved` means `hs.sound.getByFile` returned nil
    for a path that exists — the engine swallows that with no log and no entry
    in `missing`, so it is invisible. Check `spoon.PlatinumSnd.engine.pools`
    is non-empty.

- [ ] **1.4 Dry run reports mappings.** `:dryRun(true)`, click a button, a
    checkbox and empty desktop, `:dryRun(false)`.
  - Expect: `DRYRUN play button.press (btnp)`, `checkbox.press (chkp)`,
    `button.press (btnp)` respectively.
  - Fails: all three identical means the AX probe is returning nil for
    everything — see §2. Nothing at all in the Console means the tap is not
    receiving events (Accessibility, or another tap-consuming app).

- [ ] **1.5 Audition all 68.** `spoon.PlatinumSnd:audition()`, and listen to
    the whole run.
  - Expect: 68 printed lines and 68 audible sounds, ending `audition complete`.
  - Fails: lines print but you hear little or nothing → the retention fix on
    `self.auditionSound` is not enough and objects are being collected
    mid-playback. Individual silent entries → that one file did not load.
  - **While you are here**, settle the names. `docs/sound-decode.md` decoded 60
    of the 68 from Apple's `ThemeSoundKind` constants and the `-- guess`
    markers are gone, but nothing in the pack has actually been *heard*. Pay
    attention to: `dbtr` (default button?), `slgh` (a drag loop?), `fcpd`,
    `fral`, `fdon`/`fdof`, `tshd`, `delay`, and the four sustain loops. Correct
    `soundmap.lua` if a name is wrong — it is the single place.

---

## 2. Assumptions that would invalidate the architecture

Each of these is load-bearing and unverified. A failure here is a redesign, not
a tuning change.

- [ ] **2.1 `AXFrame` is a flat `{x, y, w, h}`.** Park the cursor over a push
    button and run:

    ```lua
    hs.timer.doAfter(3, function()
      local p = hs.mouse.absolutePosition()
      local e = hs.axuielement.systemWideElement():elementAtPosition(p.x, p.y)
      print(hs.inspect({
        role    = e:attributeValue("AXRole"),
        subrole = e:attributeValue("AXSubrole"),
        frame   = e:attributeValue("AXFrame"),
        pid     = e:pid(),
      }))
    end)
    ```

  - Expect: a table with numeric `x`, `y`, `w`, `h`. (Read off Hammerspoon's
    `common.m` on master, but not off your installed build.)
  - Fails: an `origin`/`size` nesting, a userdata or nil means
    `axpolicy.isInsideFrame` returns false forever. The elision then silently
    never fires — no error, no sound change, just the full IPC cost on every
    tick. The fix is three lines normalising the shape in `axprobe.lua`,
    keeping `axpolicy` strict.

- [ ] **2.2 `AXFrame` and `hs.mouse.absolutePosition` share an origin.** Repeat
    2.1 on a **secondary display placed above or to the left of the primary**,
    so the coordinates go negative.
  - Expect: the frame's `x`/`y` bracket the cursor position.
  - Fails: this is the worst failure in the document. A mismatched origin means
    the elision either never fires (harmless, just slow) or fires on the wrong
    widget (sounds a control you are not over). The whole hover cache rests on
    it and there is no cheap workaround — it would need per-screen translation
    in `axprobe.lua`.

- [ ] **2.3 The elision actually elides.** Hover a large button or toolbar and
    jiggle the cursor continuously *inside it* for 30 seconds without leaving:

    ```lua
    local before = spoon.PlatinumSnd.sources[1].probe:stats().probes
    hs.timer.doAfter(30, function()
      print(spoon.PlatinumSnd.sources[1].probe:stats().probes - before)
    end)
    ```

  - Expect: **roughly 15** — one probe every two seconds, the
    `cacheRevalidateSeconds` ceiling rearming.
  - **Reports disagree:** task-6's original text expects "a small single-digit
    number"; task-6 fix round 1 added the 2 s revalidation ceiling and revised
    it to ~15. The shipped code has the ceiling, so ~15 is right and the
    single-digit figure is stale.
  - Fails: **hundreds** means the frame elision is not firing at all — check
    2.1 first. **Zero** means `probedAt` is being refreshed by elisions and the
    ceiling is dead, which would let a wrong role persist indefinitely.

- [ ] **2.4 Idle cost is genuinely zero.** Same snippet, cursor completely
    motionless for the 30 seconds.
  - Expect: `0`. The timer fires 16 times a second but the position
    short-circuit returns before any IPC.
  - Fails: non-zero means the position comparison is broken and the Spoon is
    doing an AX round-trip 16 times a second forever.

- [ ] **2.5 Menu observers fire when registered on the application element.**
    Pull down any app's menu.
  - Expect: `mnuo` on open.
  - Fails: **total silence from menus in every app** means `AXMenuOpened` is
    not delivered to the application element. Registering there is the
    documented and common practice, but the notification is posted by the menu
    element, and that hop is unverified. The remedy is registering
    `hs.axuielement.observer` on the menu bar element instead — a change to
    `src_menus.lua:attach`. This is the single most likely architectural
    failure in Task 8.
  - **Settled on a real Mac:** `AXMenuOpened` and `AXMenuClosed` both arrive at
    the application element. `AXMenuItemSelected`, documented identically,
    mostly does not — see 3.22 for what was done about it.

- [ ] **2.6 `AXSelectedChildrenChanged` reaches Finder's application element.**
    Click a file in a Finder window.
  - Expect: `fsel`.
  - Fails: silent selection with everything else in Finder working means
    Finder posts it from the container (`AXOutline`/`AXBrowser`) rather than
    the application. Remedy: register per Finder window as windows appear,
    rather than on the application element. Same class of unknown as 2.5 and
    the likeliest failure in Task 9.

- [ ] **2.7 `hs.sound` pooling really overlaps.**

    ```lua
    local e = spoon.PlatinumSnd.engine
    for i = 1, 5 do hs.timer.doAfter(i * 0.06, function() e:play("button.press") end) end
    ```

  - Expect: five distinct clicks layering.
  - Fails: fewer than five means NSSound is restarting one object rather than
    the pool rotating. Rapid clicking will swallow sounds everywhere. Check
    `poolSize` and that `pool.nextIndex` advances; raising `poolSize` in
    `obj.tuning` is the dial.

- [ ] **2.8 Sustained loops loop.**

    ```lua
    local e = spoon.PlatinumSnd.engine
    e:sustain("window.move"); hs.timer.doAfter(3, function() e:release("window.move") end)
    ```

  - Expect: a continuous sound for three seconds, then silence.
  - Fails: plays once and stops → `loopSound(true)` is not taking effect. Every
    sustained path breaks: window drag, scroll thumb, slider ghost. The
    workaround is retriggering on a timer, which means reworking `sound.lua`'s
    sustain path and the three sources that use it.

- [ ] **2.9 `load()` is idempotent.** `:start()` calls it, and the toggle calls
    `:start()`.

    ```lua
    local e = spoon.PlatinumSnd.engine
    e:load(); e:sustain("window.move")
    e:load()                    -- must silence the sustainer
    e:release("window.move")    -- must be a no-op, not an error
    e:play("button.press")      -- must still click
    ```

  - Expect: the loop stops at the second `load()`, nothing errors, one-shots
    still play. Re-run 2.7 afterwards to confirm the rebuilt pools behave.
  - Fails: a loop still playing after the second `load()` is an orphaned
    sustainer that `release()` can no longer reach — an audible stuck sound
    with no way to stop it short of quitting Hammerspoon.

- [ ] **2.10 `hs.axuielement:pid()` exists and answers.** From 2.1's output,
    with the cursor over a **Finder window while another app is frontmost**.
  - Expect: Finder's pid, not the frontmost app's.
  - Fails: nil or the wrong pid means `Probe:pidAt` cannot tell who owns the
    element under a drop. `pidAt` pcalls it, so the degradation is silent — you
    just never get `fdrp`. This is what §3's drop checks exercise by ear.

- [ ] **2.11 `hs.pathwatcher` delivers flag tables.** Covered by 3.24; noted
    here because the failure is invisible. A path arriving with no flag table is
    skipped, so the symptom is total silence from `fnew`/`fcpd` with no error.

---

## 3. Whether each source produces its sounds

### Pointer — hover and click

- [ ] **3.1 Enter and exit.** Move the cursor slowly onto a push button and off.
  - Expect: `btne` entering, `btnx` leaving.
  - Fails: silence means the hover timer or the probe is dead — check 2.3.

- [ ] **3.2 Widget-aware clicks.** Click a dialog's OK, a System Settings
    checkbox, and empty desktop.
  - Expect: three distinguishable sounds — `btnp`/`btnr`, `chkp`/`chkr`, and
    the generic click on the desktop.
  - Fails: all identical → the probe returns nil for everything. Run
    `hs.inspect(spoon.PlatinumSnd.sources[1].probe:stats())`; failures tracking
    probes one-for-one means the `hs.axuielement` calls in `axprobe.new` are
    wrong (`systemWideElement`, `setTimeout`, `elementAtPosition`).

- [ ] **3.3 Clicks are instant, including after a pause.** Click a button you
    are already hovering. Then rest on one for three or four seconds without
    moving and click again.
  - Expect: no perceptible gap either time. The motionless path refreshes the
    cache's validation stamp so the click stays on the instant path.
  - Fails: a lag on the second means the motionless refresh is not firing —
    check the pid comparison in the hover loop's first branch.
  - Compare with clicking immediately after a fast cursor jump: that correctly
    takes the deferred probe and may lag slightly.

- [ ] **3.4 Close box.** Move onto a window's red traffic light, then off.
    Then press and hold on it and release.
  - Expect: `wcle` entering (not `btne`), `wclx` leaving; `wclp` on press,
    `wclr` on release, then `wcls` from `src_windows` as the window goes.
  - Fails: `btne`/`btnp` instead means `AXSubrole` on the traffic light is not
    `AXCloseButton` (the refinement in `axpolicy.refinedRole` produces the
    synthetic role from it). Confirm with 2.1's `subrole` field.
  - Moving from the red light onto the yellow one should give `wclx` then
    `btne` — only the close button refines.

- [ ] **3.5 Minimise and zoom stay plain buttons.** The yellow and green lights.
  - Expect: `btne`/`btnp`/`btnr`/`btnx`, with `wcol`/`wexp` or `wzmi`/`wzmo`
    arriving separately from `src_windows`.
  - Fails: close-box sounds here means `REFINE` is matching too broadly.

- [ ] **3.6 Tabs.** A real tab bar — System Settings, Terminal's Settings, an
    `NSTabView`. Hover, leave, click.
  - Expect: `tabe`, `tabx`, `tabp`, `tabr`. Sliding along the bar blips per tab.
  - Fails: `rade`/`radp` means the `AXParent` → `AXRole` hop is not returning
    `AXTabGroup`. That is two round trips, the most expensive probe in the
    Spoon; if it fails, tabs simply sound as radio buttons.

- [ ] **3.7 Radio buttons unchanged.** A genuine radio group, not tabs.
  - Expect: `rade`/`radp`/`radr`/`radx`.
  - Fails: tab sounds here means the refinement is firing where it should not.

- [ ] **3.8 The remaining widget families.** Disclosure triangles (`dsc*`, full
    enter/press/release/exit cycle) and pop-up buttons (`popp`/`popr`, no
    enter/exit).
  - Expect: distinct from the generic click.
  - Fails: generic clicks mean the AX roles differ from
    `AXDisclosureTriangle`/`AXPopUpButton` in the app you tried — try another
    before concluding the mapping is wrong.

- [ ] **3.9 Steppers.** An `AXIncrementor` (Date & Time). Click its upper half,
    then its lower half.
  - Expect: `laup` on the upper press and **silence on its release**; silence on
    the lower press and `ladr` on its release. The pack carries only two of the
    six little-arrow sounds, so the other two halves have nothing honest to
    play.
  - Fails: a generic click means the frame-half geometry in
    `littleArrowSemantic` is not being reached.

- [ ] **3.10 Scroll trough versus thumb.** Click the scrollbar *trough* in a
    long document. Then drag the *thumb*, hold it, release.
  - Expect: a single `sbtp` for the trough. For the thumb, an attack, a
    sustained loop while held, and a decay on release.
  - Fails: the same sound for both means `AXValueIndicator` is not being
    distinguished from `AXScrollBar`.

- [ ] **3.11 Slider.** Drag a volume or brightness slider slowly. Then click one
    without dragging.
  - Expect: `sltp` on the press, then the `slgh` loop while the ghost moves,
    silence on release. The plain click gives `sltp` alone, no loop.
  - Fails: no loop means `slider.ghost` is not sustaining — check 2.8 first.

- [ ] **3.12 Default button.** Open a save sheet or confirmation dialog and
    press Return (and keypad Enter).
  - Expect: `dbtr`.
  - Fails: silence means `focusedIsDialog` is not matching — the gate tests the
    focused window's subrole against `AXDialog`, `AXSystemDialog`, `AXSheet`.
  - Also: hold Return down in TextEdit for several seconds. Expect silence
    throughout and no perceptible input lag.

### Windows and disks

- [ ] **3.13 Window lifecycle.** Open a new Finder window, minimise, restore,
    close.
  - Expect: `wopn`, `wcol`, `wexp`, `wcls`.
  - Fails: silence on minimise/restore means the window filter's default rule
    is rejecting them. `src_windows` replaces the shipped default with
    `setDefaultFilter{allowRoles = WINDOW_ROLES}` precisely to fix this; if it
    is still silent, inspect what the filter admits.

- [ ] **3.14 Fullscreen.** Fullscreen a window and come back.
  - Expect: `wzmi` then `wzmo`. Known to lag ~0.5 s behind the animation,
    because Hammerspoon coalesces those events itself.

- [ ] **3.15 Palette windows.** Open and close a floating utility panel (an
    Xcode or Preview inspector).
  - Expect: `pwop` then `pwcl`.
  - Fails: `wopn`/`wcls` instead means `AXFloatingWindow` is not the subrole
    that panel reports. The close half depends on `win:id()` still being
    readable at `windowDestroyed`; if that assumption is wrong, palettes close
    with `wcls` — degraded, not silent.

- [ ] **3.16 `wact` fires once, not twice.** Switch between two apps with the
    keyboard.
  - Expect: exactly one `wact` per switch. It is emitted from exactly one
    place — `windowFocused` — and deliberately not from app activation.
  - Fails: two means a second emitter appeared.

- [ ] **3.17 App launch.** Launch an app that is not running.
  - Expect: one `flap`. (Plus `wopn` and `wact` as its window appears — three
    sounds in quick succession. Judge that stack by ear; see §6.)
  - Fails: silence means `app:kind() == 1` is not matching. A `flap` from a
    menu-bar helper or an updater means the gate is not working.

- [ ] **3.18 Window drag.** Drag a window slowly, pause mid-drag while still
    holding, release.
  - Expect: a continuous sound that audibly changes between the moving and idle
    timbres, stopping on release.
  - Fails: a loop that does not stop → either `:stop()` on the sustainers is
    not reached (check the `elseif self.dragging` branch) or the tap never
    received `leftMouseUp`. `hs.eventtap.checkMouseButtons()` in the Console
    during the stuck state tells the two apart. The sampler's own watchdog
    should clear it within 100 ms regardless.

- [ ] **3.19 Disks.** `hdiutil attach` any `.dmg`, then eject it.
  - Expect: `dski` then `dske`.

### Menus

- [ ] **3.20 Menu open and close.** Pull down a menu, then dismiss another with
    Escape.
  - Expect: `mnuo` on open, `mnuc` on dismissal — and on the press, **`mnuo`
    alone**. `AXMenuBarItem` and `AXMenu` are mapped to silence, so the menu
    bar no longer layers `btnp` on the press and `btnr` on the release around
    the observer's sound. Three sounds for one gesture, on the most frequent
    gesture in the shell, was the defect.
  - Fails: a click either side of `mnuo` means the role under the cursor is not
    `AXMenuBarItem` — confirm with the 2.1 snippet parked on a menu title.
  - **Knowingly accepted:** menu extras and status items belong to accessory
    apps, which get no observer (`kind() ~= 1`), so there is no `mnuo` to defer
    to and those menus are now **silent** rather than wrong. Expected.
  - Fails: `mnuc` missing for a given app is **expected and known** — not every
    app emits `AXMenuClosed`. Record which apps do and do not. `mnuo` missing
    everywhere is 2.5.

- [ ] **3.21 Item highlight.** Slide slowly from the first menu item to the
    last, then back up.
  - Expect: `mnui` on **every** item, both directions. This comes from the
    hover layer's `AXMenuItem` frame transitions, not from `src_menus`.
  - Fails: only the first item blips means `transitionSounds` is comparing
    roles rather than frames — every item is `AXMenuItem`, so the frame is the
    only thing that distinguishes them.

- [ ] **3.22 Selection sounds exactly once.** Click a menu item. Then select one
    with the keyboard.
  - Expect: exactly one `mnus`, both ways. The keyboard case is why `mnus` is
    owned by the observer and not the pointer layer.
  - There are now TWO watchers behind this one sound. Apple's header says
    `AXMenuItemSelected` carries "the selected menu item UIElement" — the item
    posts it — and separately that an observer on the application element hears
    from any element in the app. The second half does not hold up in practice:
    F2 recorded `mnuo`, four `mnui` and `mnuc` with no `mnus` between them,
    while a later capture in the same run did get one. So `src_menus` keeps the
    application-level registration and adds one on each menu as it opens,
    taking it off again on `AXMenuClosed`, and dedupes on the element within
    `menuSelectDedupeSeconds`.
  - Fails: **two** `mnus` for one selection means the dedupe is not matching
    the two deliveries — most likely the element handles are comparing unequal.
    **Still none** in a given app means one of two things, and they need
    telling apart: either that app does not forward the notification to the
    menu either — in which case the watcher has to go on the menu items
    themselves — or it posts `AXMenuItemSelected` *after* `AXMenuClosed`, by
    which point the menu's watcher has already come off. For the second, hold
    the watcher for a grace period past the close instead of removing it
    there. Record which apps fall in which camp.
  - Fails: see also 4.1.

### Finder

- [ ] **3.23 Selection.** Click a file. → `fsel`. (Same check as 2.6.)
  - Gated on Finder having been frontmost within `finderGraceSeconds`, the same
    rule the filesystem watchers use — see 4.2. Deliberately not gated on
    Finder being frontmost *right now*: clicking a background Finder window to
    select something makes Finder frontmost as part of the same gesture, and
    the notification can outrun the front-app reading.
  - Fails: the FIRST click on a background Finder window being silent, with
    later clicks sounding, means that race is real on this machine and the
    grace window is not covering it — the stamp is arriving after the
    notification rather than before.

- [ ] **3.24 One new item.** With Finder frontmost, create a new folder on the
    Desktop, or copy a single file in.
  - Expect: one `fnew`.
  - Fails: silence with no error → either Full Disk Access is missing or
    `hs.pathwatcher` is not delivering flag tables (2.11). Both fail the same
    silent way.

- [ ] **3.25 A multi-file copy sounds once.** With Finder frontmost, copy
    several files into the Desktop.
  - Expect: exactly one `fcpd` — not one sound per file, and not a run of
    `fnew`s. Two or more paths appearing inside the 200 ms coalesce window is
    what makes it a copy rather than a new item.
  - Fails: a run of `fnew`s means the files landed more than 200 ms apart.
    `finderCoalesceSeconds` is the dial; see §6.

- [ ] **3.26 Empty Trash.** Put something in the Trash, then Finder → Empty
    Trash. Then repeat with **another app frontmost**.
  - Expect: `ftrs` both times. `ftrs` is `kThemeSoundEmptyTrash` and is
    deliberately exempt from the frontmost gate — that exemption cannot be
    tested any other way.
  - Fails: silence means the tri-state emptiness tracking never got a
    successful read of `~/.Trash` (which is TCC-protected in its own right).

- [ ] **3.27 Drop into Finder.** Three drags: Desktop file → an open Finder
    window; a file → a non-Finder app; a file **from** a non-Finder app → a
    Finder window.
  - Expect: `fdrp`, then no `fdrp`, then `fdrp`.
  - Fails: the third case is the one that matters. Getting it backwards (sound
    on the second, silence on the third) means `pidAt` is answering about the
    frontmost app rather than the element's owner — dragging does not bring the
    window under the cursor to the front, which is exactly why `pidAt` exists.
    See 2.10.

- [ ] **3.28 Drag over icons.** In Finder, drag a file slowly across a window
    full of icons. Then repeat the same drag with a non-Finder app frontmost.
  - Expect: `fdon` entering each element and `fdof` leaving it, with **no**
    button enter/exit during the drag. With a non-Finder app frontmost, the
    ordinary `btne`/`btnx` behaviour instead.
  - **Reports disagree:** the design doc says `fdon`/`fdof` come from Finder
    row expand/collapse, and task 9 wired them to nothing on that reading.
    Task 10/11 rewired them to drag-over-element transitions after the decode
    identified them as `kThemeSoundFinderDragOn/OffIcon`. The decode governs
    and the design doc is stale.

---

## 4. Whether anything sounds when it must not

- [ ] **4.1 A menu item click sounds once.** Click a menu item and count.
  - Expect: one `mnus` and nothing else.
  - Fails: a **second `mnus`** means the pointer layer is also emitting it —
    confirm `rolemap` still returns nil for `AXMenuItem` press and release.
    A **generic click alongside `mnus`** means the release consulted the probe
    rather than the cache: by then the menu has dismissed and the hit-test
    landed on whatever was revealed underneath.
  - **Reports disagree on the dwell case.** Task-6 fix round 1 declared that
    dwelling on an item for more than 250 ms before clicking no longer causes
    this; fix round 3 **retracted that and reinstated the caveat**. What
    shipped: `AXMenuItem` is a leaf role, so a cache holding the *item* stays
    fresh and the click is silent; a cache holding the enclosing `AXMenu`
    *panel* is a container, ages out at 250 ms, and the click correctly defers
    to a probe. So dwelling and clicking is silent when the probe landed on the
    item, and may produce a late stray click when it landed on panel chrome.
    Report what you actually hear rather than assuming either.

- [ ] **4.2 Background file activity is silent.** With Finder **not** frontmost
    and more than 2 seconds since it was:
    `touch ~/Desktop/quiet-test.txt && sleep 3 && rm ~/Desktop/quiet-test.txt`
  - Expect: silence — including no `fsel`. A file arriving on the Desktop
    changes what that window considers selected, so `AXSelectedChildrenChanged`
    fires whether or not anyone is looking; a real run recorded exactly that,
    with `com.highcaffeinecontent.radio` frontmost. Selection now answers to
    the same grace window as the filesystem watchers.
  - Fails: a sound means the frontmost gate is not consulting app state — check
    the Finder app watcher is firing. Without this, Dropbox syncing and
    background downloads chatter constantly.

- [ ] **4.3 Renaming is silent.** Rename a file in place in Finder. Then do the
    full new-folder flow: create it, type a name, press Return.
  - Expect: silence for the rename. **Exactly one `fnew`** for the new folder,
    not two.
  - Fails: two `fnew`s means the gate is not netting departures against
    arrivals per parent directory — `itemRenamed` fires on both ends of a move
    and the burst accumulator is what cancels them.

- [ ] **4.4 Dragging to the Trash is silent.** Drag a file to the Trash.
  - Expect: **silence**. `ftrs` is `kThemeSoundEmptyTrash`, not "item trashed".
  - **Reports disagree:** the task-9 brief's original Steps 7 and 9 expected
    `ftrs` here; the revision that governs corrected it. The corrected reading
    is what shipped.

- [ ] **4.5 Modifying a file is silent.** Save over an existing file on the
    Desktop with Finder frontmost.
  - Expect: silence. `itemModified` is deliberately not an existence change.

- [ ] **4.6 A drag's release is not a click.** Select text by dragging in any
    text field.
  - Expect: a press sound and **no** release sound. A press and release within
    `dragThresholdPx` (10 px) is still a click and sounds both.
  - Fails: a release sound after every drag means the suppression is not
    firing, and every scroll-thumb and window drag will end in a button noise.
  - This is a behaviour change affecting every app, not just the ones these
    sounds are about — see §6 for whether it is right.

- [ ] **4.7 No phantom exit.** Hover a control in an app that is beachballing,
    or trip the breaker until `probe:stats().openPids` is non-empty, then keep
    the cursor on a button and move it slightly.
  - Expect: **no** `btnx` while the pointer is still on the button.
  - Fails: a blip means `transitionSounds` is not gating on the probe result. A
    failed probe means "could not ask", not "left the widget", and must leave
    the cache entirely alone.

- [ ] **4.8 A plain click never starts a drag loop.** Hold the mouse down on a
    button and on a window title bar without moving, then release.
  - Expect: silence from the window-drag path in both cases. The idle timbre is
    only entered once the frame is actually seen to move.

- [ ] **4.9 The shell has not become chatty.** Hover over tooltips,
    autocomplete popovers, notification banners and menu panels.
  - Expect: silence. `src_windows` widened the window filter's role list to
    make `pwop`/`pwcl` and `wexp` reachable, which is the change most likely to
    have admitted something it should not.
  - Fails: a window sound from a tooltip means a role was admitted in error —
    `WINDOW_ROLES` in `src_windows.lua` is the list.

- [ ] **4.10 Rubber-band selection on the Desktop.** Press on empty desktop,
    sweep a selection rectangle, release.
  - Expect (known risk): this **will** sound `fdrp` — it is a release more than
    10 px from its press over a Finder-owned element, which is exactly the
    test. Nothing available at the release distinguishes "let go of a file"
    from "finished sweeping a selection".
  - If it grates, the fix is requiring the press to have landed on an
    image-or-icon element, which is an untested heuristic nobody wanted to
    invent blind.
  - **Scope.** Window move and resize used to fail the same way and no longer
    do — `src_windows` publishes that the focused window's frame is actually
    moving, and `src_pointer` skips both the drop probe and its transition
    sounds while it is set. A rubber band moves no window, so it is not covered
    by that and remains the open case. See 4.11.

- [ ] **4.11 Dragging a Finder window is one sound, not three.** Drag a Finder
    window by its title bar across other Finder windows and release. Then
    resize one from its left or top edge. Then repeat both with a non-Finder
    app's window.
  - Expect: the `wmov` loop and **nothing else** — no `fdrp` on release, no
    `fdon`/`fdof` while crossing, no `btne`/`btnx` either.
  - Fails: an `fdrp` on release means the published flag is not reaching
    `src_pointer` — check that `src_windows` started at all, since a source
    that fails to start never writes it and the layer degrades to its old
    behaviour. Intermittent `fdrp` (some drags, not others) would mean the
    clear had moved back onto the release, where it races the reader.
  - Then confirm the suppression is confined to the gesture: after a window
    drag, hover an ordinary button. `btne`/`btnx` must still sound. Silence
    there means the flag is being read outside an open gesture.

---

## 5. Behaviour under stress and teardown

- [ ] **5.1 A slow or hung app does not kill the tap.** Click repeatedly in an
    app that is beachballing, or one stopped under a debugger.
  - Expect: some clicks make no sound, the breaker opens for that pid, and
    click sounds keep working **everywhere else**.
  - Fails: **all click sounds stop permanently, everywhere, with nothing in the
    Console.** That is macOS having disabled the tap with
    `kCGEventTapDisabledByTimeout`. Nothing in `src_pointer.lua` listens for
    that event type, so recovery needs a Spoon restart. The 50 ms AX timeout
    bound on the system-wide element exists precisely to prevent this; if it
    happens anyway, the timeout is not propagating to the hit-test.

- [ ] **5.2 The breaker does not fire in normal use.** After a few minutes of
    ordinary clicking:
    `hs.inspect(spoon.PlatinumSnd.sources[1].probe:stats())`
  - Expect: `openPids` empty and `failures` a small fraction of `probes`.
  - Fails: a high failure ratio means `axTimeoutSeconds = 0.05` is too tight
    for this machine — the bound now covers the hit-test as well as the
    attribute read, and the hit-test is the expensive one. Raise
    `axTimeoutSeconds` in `obj.tuning` and record the change.

- [ ] **5.3 The breaker recovers.** Once a pid is in `openPids`, wait 30 s and
    re-check.
  - Expect: it closes and probing resumes. Three failures in a 10 s window
    opens it; the cooldown always runs its course, and a success never reopens
    it early.

- [ ] **5.4 The toggle actually tears down.** Press `⌘⌥⌃9` twice.
  - Expect: `PlatinumSnd off` then `PlatinumSnd on` alerts, and complete silence
    while off — no clicks, no hover sounds, no Finder sounds.
  - Fails: any sound while off means a tap, timer or observer survived
    `:stop()`. "Off" must mean no tap, no polling and no IPC, not volume zero.

- [ ] **5.5 Toggling mid-drag leaves no stuck loop.** Start a scroll-thumb drag
    or a window drag, and press the toggle hotkey while still holding.
  - Expect: immediate silence, no loop left playing.
  - Fails: a stuck loop means a sustainer was not released on `stop()`.
    `Sound:load()` also silences every sustainer, so even a restart should not
    inherit one.

- [ ] **5.6 Idempotent stop.**

    ```lua
    spoon.PlatinumSnd:stop(); print(spoon.PlatinumSnd.running)
    spoon.PlatinumSnd:stop(); print(spoon.PlatinumSnd.running)
    ```

  - Expect: `false` twice, no error. Also try `:stop()` before any `:start()`.

- [ ] **5.7 The toggle never lies about state.** Revoke Accessibility in System
    Settings, reload, press `⌘⌥⌃9`.
  - Expect: the permission alert, then `PlatinumSnd off` — **never**
    `PlatinumSnd on`. This is the only user-facing surface that could report a
    state it did not reach.

- [ ] **5.8 Observers do not leak.**

    ```lua
    print(spoon.PlatinumSnd.sources[3]:observerCount())
    ```

    Note the count, launch and quit an app such as TextEdit, wait for the 60 s
    sweep, print again.
  - Expect: back to the original number.
  - Fails: a climbing count means the sweep is not reconciling against the live
    process list — an app can die without a clean `terminated` notification.

- [ ] **5.9 A slow app's menus heal.** Launch something heavy (Xcode, an
    Electron editor) and immediately use its menus.
  - Expect: they may be **silent for up to a minute**, until the sweep attaches
    the observer that `launched` was too early for. That delay is the accepted
    cost of the retry, not a bug.
  - Note the sweep retries unbounded: an app that can never register has an
    observer built, refused and discarded once a minute for as long as it runs.

- [ ] **5.10 The AX timeout is handed back on stop.**

    ```lua
    spoon.PlatinumSnd:stop()
    hs.window.filter.new():getWindows()
    ```

  - Expect: no truncated or empty results. `obj:stop()` calls
    `axprobe.resetTimeout`, which sets the system-wide element's timeout to
    `0.0` — what Hammerspoon documents as restoring the global default.
  - Fails: the 50 ms bound is a **process-global** mutation. If it is not
    handed back it outlives the Spoon and keeps applying to `hs.window`,
    `hs.uielement` and every other AX consumer in Hammerspoon. There is no
    getter for it, so the realistic check is that `hs.window` behaves after a
    PlatinumSnd stop the way it did before PlatinumSnd was ever started.
  - The install and the reset both log at error level if they throw, so check
    the Console before concluding from behaviour alone.
  - **Ownership moved.** This used to be `Probe:release()`, called from
    `src_pointer:stop()`. The bound is process-global and `src_windows` and
    `src_keys` rely on it too, so it is now installed in `obj:start()` before
    any source starts and reset in `obj:stop()` after all of them stop. One
    owner, and it is not a source.

- [ ] **5.11 Idle CPU.** With the Spoon running and nothing happening, compare
    Hammerspoon's CPU use against a run with the Spoon stopped.
  - Expect: no meaningful difference. The drag sampler is demand-driven (armed
    by a mouse-down, not free-running), the hover loop short-circuits on a
    motionless cursor, and no timer should be doing AX work at rest.

---

## 6. Cosmetic and tuning

All matters of taste. Every dial named here lives in `obj.tuning` in
`init.lua`, except sound names, which live in `soundmap.lua`.

- [ ] **6.1 Master volume.** `volume = 0.5`. Too loud, too quiet, or right.

- [ ] **6.2 Toolbar sweep rate.** Sweep quickly across a toolbar.
  - Expect: one `btne` per button crossed, rate-limited by the 60 ms poll —
    distinct blips, not machine-gun fire and not silence.
  - **Reports disagree.** The design doc (and task-6 rounds 1–2) says sweeping
    a toolbar should be **silent** between same-role buttons, sounding only the
    control you stop on. Task-6 fix round 3 changed transitions to be keyed on
    the frame rather than the role, so adjacent buttons now blip individually —
    which is also what made `mnui` fire per menu item (3.21). The two cannot be
    separated: they are the same rule. Frame-keyed is what shipped; the design
    doc is stale. If the toolbar chatter grates, `hoverIntervalSeconds` is the
    dial, not the transition rule.

- [ ] **6.3 Copy coalescing.** Is 200 ms long enough for a real copy? If a
    copy's files land further apart, it sounds as a run of `fnew`s rather than
    one `fcpd`. `finderCoalesceSeconds` is the dial.

- [ ] **6.4 The generic fallback.** Clicking anything unrecognised — text, a web
    view, the desktop — sounds like a button. Intended, but only the ear can say
    whether it is too chatty. If it is, the fix is narrowing `GENERIC` in
    `rolemap.lua`, which means accepting silence in a lot of places.

- [ ] **6.5 Launch stack.** An app launching gives `flap` + `wopn` + `wact` in
    quick succession. Authentic, or too dense?

- [ ] **6.6 Close box double.** Clicking the red light gives `wclr` then `wcls`.
    Deliberate — the box releasing and the window closing are different events
    with different constants. If it reads as one clumsy double-click noise, the
    fix is a suppression window in `src_windows`, not a mapping change.

- [ ] **6.7 New folder stack.** Creating a folder in Finder gives `fsel` **and**
    `fnew` (Finder selects the new folder for renaming as it creates it), plus
    the pointer layer's generic click. Cluttered or right?

- [ ] **6.8 Drag-over chatter.** `fdon`/`fdof` fire on **every** element
    crossing, not only over droppable icons — nothing in the accessibility tree
    says "this accepts a drop". A fast drag across a crowded Finder window will
    chatter. This may want a minimum interval of its own.

- [ ] **6.9 Segmented controls.** The one most worth listening to. Some
    `NSSegmentedControl`s report as `AXTabGroup` and some as `AXRadioGroup`, so
    a segmented control that is not conceptually tabs may now sound like tabs.
    If it grates, the refinement needs a tighter test than "parent is an
    `AXTabGroup`".

- [ ] **6.10 Resizing sounds like moving.** Resizing a window from its left or
    top edge changes `frame.x`/`frame.y`, so it drives the `wmov` loop. There is
    no separate resize sound in the pack, so this may be fine.

- [ ] **6.11 Slider ghost trigger.** The `slgh` loop starts on the **first**
    cursor movement after any slider press, including one pixel. If a
    jump-to-here click with a shaky hand starts a brief loop, a threshold there
    is the fix.

- [ ] **6.12 Held Return.** Holding Return in a text editor costs one subrole
    read per 200 ms (about five a second) rather than one per keystroke.
    Filtering autorepeat outright would take it to a single check; the rate
    limit was chosen instead. Confirm it is not perceptible.

- [ ] **6.13 Cost, felt rather than measured.** Sweep quickly across a crowded
    toolbar, then a tab bar, and confirm no new lag or stutter and no growth in
    `failures`/`openPids`. A radio-button probe costs five round trips
    (hit-test, `AXRole`, `AXFrame`, `AXParent`, that parent's `AXRole`) — the
    most expensive probe in the Spoon, paid on every radio button in every
    dialog, because the parent read is how you find out it is *not* a tab.

---

## The ten sounds deliberately left unmapped

These have a base name in `soundmap.lua` and are owned by no event. They will
never play outside `audition()`. Do not go hunting for them. A test in
`test_rolemap.lua` fails if any role starts producing one.

| sound | constant | why silent |
|---|---|---|
| `bevp` | `kThemeSoundBevelPress` | telling a toolbar button from any other button needs an `AXParent` read on **every** button probe — the commonest probe there is — for a cosmetic variant. (Tabs pay the same hop, but it is billed to `AXRadioButton` probes only.) |
| `bevr` | `kThemeSoundBevelRelease` | same |
| `blno` | `kThemeSoundBalloonOpen` | balloon help; macOS does not announce tooltips |
| `blnc` | `kThemeSoundBalloonClose` | same |
| `fral` | `kThemeSoundResolveAlias` | alias resolution surfaces nowhere observable |
| `sbap` | `kThemeSoundScrollArrowPress` | modern macOS draws no scroll arrows, so there is nothing to press |
| `sbar` | `kThemeSoundScrollArrowRelease` | same |
| `slte` | `kThemeSoundSliderEndOfTrack` | needs the slider's value read against its minimum and maximum — three extra accessibility reads on every tick of a drag, to sound something that fires twice per slider at most |
| `tshd` | — | sound-track internal, not an event at all |
| `delay` | — | spacer used in composite tracks, not an event at all |

58 of the pack's 68 sounds are reachable from a real event.

Note the design doc's role table is stale on two of these: it maps `AXSlider`
release to `slte` and an `AXScrollBar` arrow to `sbap`/`sbar`. What shipped:
a slider is silent on release, and `AXScrollBar` press is `sbtp`
(`kThemeSoundScrollTrackPress`, the trough).

---

## Known judgement calls

Deliberate trade-offs. Report these as taste, not as bugs.

- **A motionless cursor over a leaf control never revalidates.** The position
  short-circuit returns before the revalidation ceiling is consulted, so a UI
  that changes under a genuinely still cursor keeps its old role until the
  cursor twitches — at which point it corrects immediately. Fixing it would
  give up the zero-idle-cost property in 2.4.

- **Container roles carry a 200 ms wrong-role window.** A probe landing on
  container-only space (toolbar background, the panel of a menu between its
  items) caches a frame that encloses children with other roles. Inside
  `containerRevalidateSeconds = 0.2`, a click on a child can be served the
  container's role. Setting it to `0` eliminates the window at the cost of
  probing every tick over chrome.

- **A cross-directory file move sounds like a new item.** Dragging a file from
  `~/Downloads` to `~/Desktop` sounds `fnew`, on the reasoning that the item did
  appear where it now is. The alternative reading — a move is not a creation —
  is equally defensible; making it silent would also silence a genuine drag-in
  from an unwatched folder.

- **A rename coinciding with a genuine arrival under the same parent silences
  one of the two.** Cancellation is per parent directory and one for one, so
  the burst reports one appearance where a human might count two. Renaming and
  dropping into the same folder inside 200 ms is not a real gesture, but the
  hole is there.

- **Clicking the close box makes two sounds** — `wclr` then `wcls`. Different
  events, different constants. See 6.6.

- **Menu-bar-only (accessory) apps get no menu observer.** `kind() ~= 1` skips
  them, so status-item menus are silent. Relaxing it is a one-character change
  with an unknown observer-count cost.

- **`mnuc` is unreliable by app.** Not every app emits `AXMenuClosed`. Record
  which do; there is no fix from this side.

- **Two event taps watch `leftMouseDown`/`leftMouseUp`** — the pointer layer's
  and the window source's. Both return `false` immediately, so it should be
  invisible, but it is worth knowing if tap-related weirdness appears.

- **`sbap`/`sbar`, `slte`, `bevp`/`bevr` staying silent is not a bug.** See the
  table above.
