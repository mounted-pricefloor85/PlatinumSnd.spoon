# PlatinumSnd.spoon — design

Date: 2026-07-29
Status: approved, not yet implemented

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

```
PlatinumSnd.spoon/
  init.lua          lifecycle, hotkey, wiring
  sound.lua         preload, pooling, playback        (shared service)
  axprobe.lua       hit-test, timeout, circuit breaker (shared service)
  src_pointer.lua   click tap + hover cache + enter/exit
  src_menus.lua     per-pid observer fleet
  src_windows.lua   window filter, app switch
  src_finder.lua    Finder AX + path watchers
  snd/              moved from Spoons/platinumsnd/snd/
  docs/
```

Each source exposes `:start()` and `:stop()` and nothing else. The six sources
have different failure modes — the hover layer can stall on a hung app, the
Finder watcher can false-positive, the observer fleet can leak — so isolating
them behind a uniform interface means a misbehaving source can be disabled
individually while bisecting.

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

**Role mapping.**

| AX role | press / release | enter / exit |
|---|---|---|
| `AXButton` | `btnp` / `btnr` | `btne` / `btnx` |
| `AXCheckBox` | `chkp` / `chkr` | — |
| `AXRadioButton` | `radp` / `radr` | `rade` / `radx` |
| tab in `AXTabGroup` | `tabp` / `tabr` | `tabe` / `tabx` |
| `AXDisclosureTriangle` | `dscp` / `dscr` | `dsce` / `dscx` |
| `AXPopUpButton` | `popp` / `popr` | — |
| `AXSlider` | `sltp` / `slte` | — |
| `AXScrollBar` arrow | `sbap` / `sbar` | — |
| scrollbar thumb | `sbtp` + sustained `sbth` | — |
| `AXMenuItem` | — (see below) | `mnui` on highlight |
| anything else | `btnp` / `btnr` | — |

**Menu items are deliberately silent on click in this layer.** `mnus` is owned
by the menu observer, which also catches keyboard-driven selection that the
pointer layer never sees. If both emitted it, clicking a menu item would sound
twice from two subsystems unaware of each other. The pointer layer contributes
only the `mnui` highlight.

The same single-owner rule applies to `wact`: it is emitted by window focus
changes in `src_windows`, never additionally by app activation, since switching
apps raises both.

## Guardrails

`axprobe` sets a 50 ms AX messaging timeout. `hs.axuielement:setTimeout()` takes
**seconds**, so the value is `0.05`.

**Per-pid circuit breaker.** Three timeouts or errors from one pid within a
rolling 10-second window cuts that pid off from probing for 30 seconds, logged
once rather than repeatedly. A cut-off app still gets generic click sounds from the fallback
path; it just stops being interrogated.

**Global budget.** If total probe time in any one-second window exceeds ~100 ms,
hover polling backs off to a slower interval until it recovers.

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

An observer on Finder's pid gives `AXSelectedChildrenChanged` → `fsel` and row
expand/collapse → `fdon` / `fdof`. Path watchers on Desktop, Documents,
Downloads and `~/.Trash` give `fnew` and `ftrs`. `fdrp` comes from the pointer
layer noticing a drag that ended over a Finder window.

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
  printed. This is how the `fral` / `fcpd` / `fdon` / `fdof` decoding gaps get
  closed.

## Unverified assumptions

Recorded so implementation can confirm rather than inherit them:

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
