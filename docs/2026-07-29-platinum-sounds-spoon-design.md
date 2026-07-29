# PlatinumSnd.spoon — design

Date: 2026-07-29
Status: **implemented.** This is the design as approved, revised in place where
implementation disproved it; sections carrying a "revised after implementation"
note are the ones that moved.

**This document is not the authority on behaviour.** Two others outrank it:

- **`sound-decode.md`** settles what every sound *means*. The pack's names are
  Apple `ThemeSoundKind` four-char codes, which retired several mappings this
  document originally guessed at. Where the two disagree, the decode governs.
- **`mac-verification.md`** is the record of what has actually been *checked*.
  Every `hs` call in this Spoon was written on Linux and none of it has run on
  a Mac, so that document holds the ordered first-run list, the load-bearing
  assumptions still unverified, and the deliberate trade-offs filed under
  "Known judgement calls". Where this document describes intent and that one
  describes an observed or accepted behaviour, that one governs.

Read this for *why* the design is shaped the way it is. Read those two for what
the thing does.

## Goal

Reproduce Mac OS 9's Platinum interface sounds on modern macOS as a Hammerspoon
Spoon, driving the sound pack already vendored at `Spoons/platinumsnd/snd/`.

## Why this is only partly possible

In OS 9 the Appearance Manager drew every widget system-wide, so the theming
layer inherently knew "this is a button being pressed". Sound sets were a facet
of the theme. Modern macOS has no equivalent hook: each app draws its own
controls in-process, and nothing reports "the user pressed a checkbox"
globally. The System Settings "Play user interface sound effects" checkbox
covers only a handful of hardcoded events.

Xounds did this properly in 10.2–10.4 by injecting code into every process via
Application Enhancer. SIP and library validation killed that category
permanently.

What remains available to a non-sandboxed agent with Accessibility permission:

- `CGEventTap` for global mouse events (`hs.eventtap`)
- `AXObserver` notifications per process (`hs.axuielement.observer`)
- Hit-testing the element under the cursor
  (`hs.axuielement.systemElementAtPosition`)

The third recovers some of the widget awareness the theme layer used to give
away for free. It is also the expensive one: a synchronous IPC round-trip into
the target app.

## The sound pack

68 sounds, present as `mp3/` and `mov/`; `wav/` has 67 — `bevp` was never
converted. Total WAV size 1.7 MB.

Names follow OS 9 sound-set resource conventions, where the trailing letter is
the tracking state: `p` press, `r` release, `e` enter, `x` exit. So
`btnp btnr btne btnx` is the full tracking cycle for a button, including the
cursor entering and leaving it mid-drag.

Families present: buttons, bevel buttons, default button, checkbox, radio,
tabs, disclosure triangles, sliders, scrollbar arrows and thumb, little arrows,
menus, popups, windows, palette windows, balloon help, Finder file operations,
disk insert/eject.

Four names contain spaces and imply sustained rather than one-shot playback:
`wmov idle`, `wmov moving`, `sbth attack`, `sbth decay`.

## Decisions

| Decision | Choice |
|---|---|
| Widget awareness | Full: hit-test and pick per-widget sounds |
| Hit-test timing | Hover cache, with deferred post-click fallback |
| Scope | Full shell including Finder file operations |
| Finder detection | AX for UI state, filesystem watchers for file events |
| Controls | A single master toggle hotkey; no config table |

The hover cache was chosen over a simpler post-click probe specifically because
it makes `btne`/`btnx` reachable. Enter/exit tracking is the behaviour the pack
was built around and the thing a click-only implementation cannot reproduce.

Declining per-app suppression means the only manual protection is the hotkey,
so automatic protection is built in as a circuit breaker (below) rather than
exposed as settings.

## Layout

Revised after implementation: the pure decision modules were split out of the
files that call them, so they could be tested without Hammerspoon.

```
PlatinumSnd.spoon/
  init.lua          lifecycle, tuning table, hotkey, wiring; owns the
                    process-wide AX messaging timeout
  soundmap.lua      PURE. semantic name -> pack base name
  resolver.lua      PURE. base name -> on-disk path, WAV then MP3
  rolemap.lua       PURE. AX role + action -> semantic name; leafness
  axpolicy.lua      PURE. cache staleness, frame containment, revalidation
                    ceiling, role refinement, circuit breaker, probe budget
  fgate.lua         PURE. Finder burst coalescing and frontmost gate
  sound.lua         preload, pooling, one-shot + sustained playback
  axprobe.lua       hit-test and attribute reads, bounded; wraps axpolicy's
                    breaker                            (shared service)
  src_pointer.lua   click tap + hover cache + enter/exit + gestures
  src_windows.lua   window filter, disks, app launch, window drag
  src_menus.lua     per-pid observer fleet
  src_finder.lua    Finder AX + path watchers
  src_keys.lua      default button on Return
  diagnose.lua      on-demand diagnostic harness
  snd/              moved from Spoons/platinumsnd/snd/
  docs/
  tests/            the pure suites, run under stock lua
```

Each source exposes `:start()` and `:stop()` and nothing else. The **five**
sources have different failure modes — the hover layer can stall on a hung app,
the Finder watcher can false-positive, the observer fleet can leak — so
isolating them behind a uniform interface means a misbehaving source can be
disabled individually while bisecting. `init.lua` hands each the same context
table, which is also how the one fact two sources must share travels: the
window source publishes that a window is being dragged, and the pointer source
reads it so a window move is not also reported as a file drop.

## Sound engine

Sources never name files. They emit semantic events (`button.press`,
`window.move`) and one table maps semantic names to pack filenames. Several
name decodes are guesses; when auditioning corrects them, the fix is one line
in one table rather than a change spread across six modules. Swapping in a
different sound set touches only that table.

**Format.** WAV first, MP3 fallback. WAV is uncompressed so there is no decode
on first play, and the fallback transparently covers the missing `bevp`. An
unresolvable name is logged once at startup and mapped to silence, so a missing
file degrades one event instead of erroring at play time. `mov/` is ignored.

**Preload and pooling.** Everything loads at `:start()`. NSSound cannot overlap
an object with itself, so each name owns a round-robin pool of 3 objects and
rapid clicking layers instead of restarting one object and swallowing sounds.

**Two playback modes.** One-shot for nearly everything. Sustained for window
dragging and scrollbar thumb drags: `sustain(name)` starts and holds the
idle/attack layer, `release(name)` plays the decay and stops. Sustained sounds
use dedicated objects outside the pool because they need a stable handle.

**Volume** is a single master constant applied at load.

## Pointer layer

Two independent drivers share one cache.

```
hover timer (60ms)                  click tap (event tap)
  |                                   |
  | cursor moved?                     | return false IMMEDIATELY
  v                                   v
axprobe:roleAt(x,y)                 cache fresh & matching?
  |                                   |         |
  v                                  yes        no
cache = {role, pid, x, y, at}         |         |
  |                                   v         v
  | role changed?                  play now   defer one tick,
  v                                (0ms)      probe, play late
emit exit(old) + enter(new)
```

The hover driver is a timer polling `hs.mouse.absolutePosition`, not an event
tap on mouse-moved. It never touches the event stream, so it cannot be disabled
by the OS for slowness and cannot delay input, and the timer is its own
throttle. A 60 ms interval also gives "settled on a control" semantics: sweeping
across a toolbar sounds the control you stop on rather than blipping six times.
The cost is up to 60 ms before an enter sound and genuinely fast passes going
unsounded.

The click driver stays an event tap because clicks are discrete and must not be
missed. Its callback returns `false` immediately and all AX work happens on a
later tick, so a hung app can make a sound late but can never delay a click.

**Staleness rule.** The cache is trusted only when all three hold:

1. sampled less than 250 ms ago
2. cursor within 4 px of the sampled position
3. frontmost app unchanged

Any failure routes to the deferred probe instead of guessing. The pixel check is
what catches a fast click following a cursor jump, where a 60 ms-old answer
describes a control the cursor has already left.

**Enter and exit** fire only for families with those sounds: buttons, bevel
buttons, radios, tabs, disclosure triangles. Transitions into other roles are
recorded silently, since sounding every transition would blip constantly over
text and empty space.

**Role mapping.** Revised after implementation against `sound-decode.md`, which
identified the pack's names as Apple `ThemeSoundKind` constants and disproved
several guesses this table originally carried. This is what shipped:

| AX role | press / release | enter / exit |
|---|---|---|
| `AXButton` | `btnp` / `btnr` | `btne` / `btnx` |
| `AXCloseButton` (synthetic) | `wclp` / `wclr` | `wcle` / `wclx` |
| `AXCheckBox` | `chkp` / `chkr` | — |
| `AXRadioButton` | `radp` / `radr` | `rade` / `radx` |
| `AXTab` (synthetic) | `tabp` / `tabr` | `tabe` / `tabx` |
| `AXDisclosureTriangle` | `dscp` / `dscr` | `dsce` / `dscx` |
| `AXPopUpButton` | `popp` / `popr` | — |
| `AXSlider` | `sltp`, then sustained `slgh` while dragging | — |
| `AXScrollBar` (the trough) | `sbtp` | — |
| `AXValueIndicator` (the thumb) | sustained `sbth`, with attack and decay | — |
| `AXIncrementor` | `laup` upper half / `ladr` lower half | — |
| `AXMenuItem` | — (see below) | `mnui` on highlight |
| anything else | `btnp` / `btnr` | — |

Two roles are **synthetic**: macOS reports neither. `AXCloseButton` is an
`AXButton` whose `AXSubrole` says so, and `AXTab` is an `AXRadioButton` whose
parent is an `AXTabGroup`. `axprobe` refines the role string rather than
widening the cache, so the subrole read happens only for buttons, the parent
read only for radio buttons, and neither ever happens on the elision path.

Three corrections worth naming, since the original table had them wrong:
`sbtp` is `ScrollTrackPress` — clicking the trough, not pressing the thumb;
`slte` is `SliderEndOfTrack`, which needs per-tick value polling and is
therefore left unmapped; and `sbap`/`sbar` are scroll *arrow* sounds, for
which modern macOS has no equivalent.

**Menu items are deliberately silent on click in this layer.** `mnus` is owned
by the menu observer, which also catches keyboard-driven selection that the
pointer layer never sees. If both emitted it, clicking a menu item would sound
twice from two subsystems unaware of each other. The pointer layer contributes
only the `mnui` highlight.

The same single-owner rule applies to `wact`: it is emitted by window focus
changes in `src_windows`, never additionally by app activation, since switching
apps raises both.

## Guardrails

A 50 ms AX messaging timeout is set on the system-wide element, which makes it
the default for every AX message the process sends.
`hs.axuielement:setTimeout()` takes **seconds**, so the value is `0.05`.

Revised after implementation: **`init.lua` owns it**, not `axprobe`. The bound
is process-global and three sources rely on it — the pointer probe, the window
source's frame and subrole reads, and the key source's subrole read — so
installing it from any one source's constructor made the other two depend on
that source having started. It is installed in `:start()` before any source
starts and handed back in `:stop()` after all of them stop.

**Per-pid circuit breaker.** Three timeouts or errors from one pid within a
rolling 10-second window cuts that pid off from probing for 30 seconds, logged
once rather than repeatedly. A cut-off app still gets generic click sounds from the fallback
path; it just stops being interrogated.

**Global budget.** If total probe time in any one-second window exceeds ~100 ms,
probing stops until it recovers.

Revised after implementation: this section originally specified backing the
hover poll off to a slower interval. What shipped **skips the probe entirely**
while over budget — `roleAt` returns no role and the hover loop leaves the whole
cache untouched, stamps included, so the next tick tries again rather than
settling for the failure. Changing the timer's interval would have meant
restarting the timer from inside its own callback; declining to probe reaches
the same spend with none of that, and it keeps the recovery test in one pure
function.

Every number here is a starting point chosen to be tunable in one place, not a
measured value. The breaker exists precisely because which apps are slow cannot
be predicted.

**Accessibility permission** is checked at `:start()`. Without it every probe
returns nil and the Spoon is silently useless, so it refuses to start, alerts
once, and offers the system prompt.

## Menus

An `hs.application.watcher` maintains observers keyed by pid: created on launch,
reaped on terminate, seeded from running apps at start. Each observer watches
its app element for `AXMenuOpened` → `mnuo`, `AXMenuItemSelected` → `mnus`,
`AXMenuClosed` → `mnuc`. Only apps with a UI get observers.

Observers can leak when an app dies without a clean terminate notification, so a
periodic sweep reconciles the table against running apps.

Item highlighting (`mnui`) needs nothing here — it falls out of the hover
layer's `AXMenuItem` transitions.

## Windows

`hs.window.filter` covers created → `wopn`, destroyed → `wcls`, minimised →
`wcol`, unminimised → `wexp`, fullscreened → `wzmi` / `wzmo`, focused → `wact`.

Windows whose AX subrole is floating use the palette pair `pwop` / `pwcl`
instead.

Dragging uses the sustained path: pressing on a title bar starts `wmov idle`,
crossfading to `wmov moving` while the position is actually changing. That
distinction is why both files exist.

Balloon help (`blno` / `blnc`) has no clean modern equivalent and is unmapped.

## Finder

Revised after implementation against `sound-decode.md`, which disproved three of
this section's original mappings.

An observer on Finder's pid gives `AXSelectedChildrenChanged` → `fsel`. Path
watchers on Desktop, Documents, Downloads and `~/.Trash` give `fnew` for a
single item appearing and `fcpd` for two or more together — a copy finishing.
`ftrs` is `kThemeSoundEmptyTrash`, so it fires when `~/.Trash` goes from
non-empty to empty, **not** when something is thrown into it; dragging a file
to the Trash is silent. `fdrp` comes from the pointer layer noticing a drag
that ended over a Finder window.

`fdon` / `fdof` are `FinderDragOnIcon` / `OffIcon` — they fire while dragging,
as the cursor crosses a droppable element with Finder frontmost. They belong to
the pointer layer, not here. Row expand and collapse, which this section
originally claimed them for, have no sound in this pack at all.

An arrival is netted against a departure under the same parent directory before
the burst is counted, so renaming a file in place is silent — a renamed item did
not appear. That also stops the standard new-folder flow sounding twice, once on
creation and again when the name is typed.

Two mitigations for false positives, which are inherent to filesystem signals:

- bursts are coalesced within 200 ms, so a multi-file operation sounds once
- filesystem sounds fire only if Finder was frontmost within the last ~2 s,
  which keeps Dropbox syncing and background downloads quiet

`fcpd` and `fral` stay unmapped until the sounds have been auditioned.

## Lifecycle

Standard Spoon contract: `name`, `version`, `author`, `license`, `:init()`,
`:start()`, `:stop()`, `:bindHotkeys({toggle = ...})`.

`:start()` checks permission, loads sounds, starts each source. `:stop()` tears
down every tap, timer and observer. Both idempotent. The toggle hotkey calls
them directly, so "off" means no tap, no polling and no IPC, not volume zero.

## Testing

Hammerspoon has no test runner, so the decisions live outside the `hs` calls.
These are pure functions over plain tables and run under stock `lua` from the
terminal with no Hammerspoon involved:

- the staleness predicate
- the circuit-breaker state machine
- role-to-semantic mapping
- WAV-to-MP3 filename resolution
- the Finder debounce-and-gate rule

Modules touching `hs` stay thin adapters that gather inputs and call those
functions.

Two manual affordances, because the interesting failures are perceptual. Both
are methods called from the Hammerspoon console, not settings — they add no
configuration surface:

- `spoon.PlatinumSnd:dryRun(true)` logs `AXButton → button.press (btnp)`
  instead of playing, so mappings can be checked by clicking around an app
  without noise.
- `spoon.PlatinumSnd:audition()` plays all 68 sounds in sequence with names
  printed.

The decoding gaps this section was written to close were instead closed from
Apple's own header — see `sound-decode.md`. Auditioning remains worth doing to
confirm each file sounds like its name says, but it is no longer how the
meanings get established.

## Unverified assumptions

Recorded so implementation could confirm rather than inherit them. Several were
settled during the build, from Hammerspoon's documentation and source rather
than from a Mac:

- **Settled.** The pack's names are Apple `ThemeSoundKind` four-char codes; 60
  of the 68 map to a documented constant and the other 8 are sound-track
  internals, every one of them a continuous sound. See `sound-decode.md`.
- **Settled.** `AXFrame` is pushed as a flat table with numeric `x`, `y`, `w`,
  `h` (`extensions/axuielement/common.m`).
- **Settled.** A messaging timeout set on the system-wide element becomes the
  global default, and elements without their own timeout resolve to it — so
  bounding it once at construction covers every subsequent AX call.
- **Settled.** `hs.window.filter`'s default rule restricts to standard, visible
  windows, which made three sounds unreachable until the rule was replaced. It
  runs observers rather than a poll, so it carries no standing AX cost.
- **Settled.** `hs.timer` stops a timer whose callback raises, so both repeating
  callbacks are `pcall`-wrapped.

Still genuinely unverified, and all of them macOS-only:

- Hammerspoon's docs do not state whether an `hs.eventtap` callback blocks event
  delivery, nor whether macOS disables slow taps. The design assumes standard
  `CGEventTap` semantics (active taps are synchronous in the delivery path and
  the OS disables ones that exceed the timeout). This is why the click callback
  returns immediately; if the assumption is wrong the design is merely
  conservative, not broken.
- NSSound's behaviour when replaying an object that is already playing is not
  documented by Hammerspoon. Pooling assumes it does not overlap.
- `AXMenuClosed` is not emitted by every app; `mnuc` may be unreliable.
- The exact AX notification names for Finder row expand/collapse need
  confirming against a live Finder.
- Meanings of `fral`, `fcpd`, `fdon`, `fdof`, `tshd`, `flap`, `delay`, `dbtr`
  and `slgh` are inferred from their abbreviations, not from listening.
- The sustained/looping behaviour of `wmov idle`, `wmov moving`, `sbth attack`
  and `sbth decay` is inferred from their names.

## Out of scope

- Balloon help, and any sound with no modern event to hang it on
- Per-app suppression, per-family volume, auto-muting during calls
- Distribution as a public Spoon (personal use; the sounds remain Apple's
  assets)
- Reproducing OS 9 tracking fidelity inside scroll bars and text fields, which
  macOS does not expose at all
