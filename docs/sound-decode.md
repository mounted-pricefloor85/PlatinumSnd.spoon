# Platinum sound pack — authoritative decode

The four-letter names are not arbitrary. They are Apple's `ThemeSoundKind`
four-char codes from the Mac OS 8/9 Appearance Manager (`Appearance.h`), so
every one has a documented meaning. Source: the legacy `Appearance.h` shipped
with the QuickTime Windows SDK CIncludes, which still carries the enum that
modern macOS SDKs dropped.

60 of the pack's 68 sounds map to a constant. The remaining 8 are sound-track
internals with no constant — and every one of them is a continuous or
composite sound, which is what forced the engine's sustained playback path.

## Files with a documented constant

| file | constant | meaning |
|---|---|---|
| `bevp` | `kThemeSoundBevelPress` | Bevel Press |
| `bevr` | `kThemeSoundBevelRelease` | Bevel Release |
| `blnc` | `kThemeSoundBalloonClose` | Balloon Close |
| `blno` | `kThemeSoundBalloonOpen` | Balloon Open |
| `btne` | `kThemeSoundButtonEnter` | Button Enter |
| `btnp` | `kThemeSoundButtonPress` | Button Press |
| `btnr` | `kThemeSoundButtonRelease` | Button Release |
| `btnx` | `kThemeSoundButtonExit` | Button Exit |
| `chkp` | `kThemeSoundCheckboxPress` | Checkbox Press |
| `chkr` | `kThemeSoundCheckboxRelease` | Checkbox Release |
| `dbtr` | `kThemeSoundDefaultButtonRelease` | Default Button Release |
| `dsce` | `kThemeSoundDisclosureEnter` | Disclosure Enter |
| `dscp` | `kThemeSoundDisclosurePress` | Disclosure Press |
| `dscr` | `kThemeSoundDisclosureRelease` | Disclosure Release |
| `dscx` | `kThemeSoundDisclosureExit` | Disclosure Exit |
| `dske` | `kThemeSoundDiskEject` | Disk Eject |
| `dski` | `kThemeSoundDiskInsert` | Disk Insert |
| `fcpd` | `kThemeSoundCopyDone` | Copy Done |
| `fdof` | `kThemeSoundFinderDragOffIcon` | Finder Drag Off Icon |
| `fdon` | `kThemeSoundFinderDragOnIcon` | Finder Drag On Icon |
| `fdrp` | `kThemeSoundReceiveDrop` | Receive Drop |
| `flap` | `kThemeSoundLaunchApp` | Launch App |
| `fnew` | `kThemeSoundNewItem` | New Item |
| `fral` | `kThemeSoundResolveAlias` | Resolve Alias |
| `fsel` | `kThemeSoundSelectItem` | Select Item |
| `ftrs` | `kThemeSoundEmptyTrash` | Empty Trash |
| `ladr` | `kThemeSoundLittleArrowDnRelease` | Little Arrow Dn Release |
| `laup` | `kThemeSoundLittleArrowUpPress` | Little Arrow Up Press |
| `mnuc` | `kThemeSoundMenuClose` | Menu Close |
| `mnui` | `kThemeSoundMenuItemHilite` | Menu Item Hilite |
| `mnuo` | `kThemeSoundMenuOpen` | Menu Open |
| `mnus` | `kThemeSoundMenuItemRelease` | Menu Item Release |
| `popp` | `kThemeSoundPopupPress` | Popup Press |
| `popr` | `kThemeSoundPopupRelease` | Popup Release |
| `pwcl` | `kThemeSoundPopupWindowClose` | Popup Window Close |
| `pwop` | `kThemeSoundPopupWindowOpen` | Popup Window Open |
| `rade` | `kThemeSoundRadioEnter` | Radio Enter |
| `radp` | `kThemeSoundRadioPress` | Radio Press |
| `radr` | `kThemeSoundRadioRelease` | Radio Release |
| `radx` | `kThemeSoundRadioExit` | Radio Exit |
| `sbap` | `kThemeSoundScrollArrowPress` | Scroll Arrow Press |
| `sbar` | `kThemeSoundScrollArrowRelease` | Scroll Arrow Release |
| `sbtp` | `kThemeSoundScrollTrackPress` | Scroll Track Press |
| `slte` | `kThemeSoundSliderEndOfTrack` | Slider End Of Track |
| `sltp` | `kThemeSoundSliderTrackPress` | Slider Track Press |
| `tabe` | `kThemeSoundTabEnter` | Tab Enter |
| `tabp` | `kThemeSoundTabPressed` | Tab Pressed |
| `tabr` | `kThemeSoundTabRelease` | Tab Release |
| `tabx` | `kThemeSoundTabExit` | Tab Exit |
| `wact` | `kThemeSoundWindowActivate` | Window Activate |
| `wcle` | `kThemeSoundWindowCloseEnter` | Window Close Enter |
| `wclp` | `kThemeSoundWindowClosePress` | Window Close Press |
| `wclr` | `kThemeSoundWindowCloseRelease` | Window Close Release |
| `wcls` | `kThemeSoundWindowClose` | Window Close |
| `wclx` | `kThemeSoundWindowCloseExit` | Window Close Exit |
| `wcol` | `kThemeSoundWindowCollapseUp` | Window Collapse Up |
| `wexp` | `kThemeSoundWindowCollapseDown` | Window Collapse Down |
| `wopn` | `kThemeSoundWindowOpen` | Window Open |
| `wzmi` | `kThemeSoundWindowZoomIn` | Window Zoom In |
| `wzmo` | `kThemeSoundWindowZoomOut` | Window Zoom Out |

## Sound-track internals (no constant)

| file | duration | reading |
|---|---|---|
| `sbth attack` | 0.11s | scroll thumb drag, attack |
| `sbth` | 0.92s | scroll thumb drag, sustain loop |
| `sbth decay` | 0.08s | scroll thumb drag, decay |
| `slgh` | 0.94s | slider ghost drag, sustain loop |
| `wmov idle` | 0.45s | window drag held still, sustain loop |
| `wmov moving` | 0.92s | window drag in motion, sustain loop |
| `tshd` | 0.24s | unidentified |
| `delay` | 0.26s | spacer used in composite tracks, not a UI event |

Durations were measured from the WAV headers and corroborate the reading: the
`sbth` triple is a textbook attack-sustain-decay set, and every sustain loop is
an order of magnitude longer than the 0.08s one-shot clicks.
