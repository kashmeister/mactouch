# MacTouch

A macOS menu bar app that makes a USB multi-touch screen usable as a touchscreen: tap, drag, right
click, one- and two-finger scroll, and pinch to zoom, with a built-in calibration wizard.

## Hardware

Any touch screen whose controller is a standard HID multi-touch digitizer, the kind Windows drives
without a driver. The defaults are set for a Wisecoco 3840 × 1100 bar display, whose touch layer is
an ILITEK controller, USB `222a:0001`, reporting up to 10 contacts.

To check a monitor, run `MacTouch --check` (see [Usage](#usage)) and look for display vendor
`0x2613`, model `0x2023`, and a touch device named `ILITEK-TP`, or run `hidutil list` and look for
USB IDs `0x222a 0x1` with usage page 13 (digitizer). For other screens, see
[Configuration](#configuration).

## Why

These controllers enumerate as HID multi-touch digitizers. macOS claims them with its generic HID
driver but has no touchscreen support, so touches go nowhere: the pointer does not move and nothing
clicks. Other drivers fix this too (see [Alternatives](#alternatives)); this one is about 900 lines
of Swift, with per-app behaviour, two-finger scrolling and calibration.

## How it works

MacTouch opens the controller with IOHIDManager, without seizing it, and reads the finger slots of
each report: tip switch, X and Y. It maps them onto the touch display, turning them with the
display's rotation and applying the calibration, and posts mouse, scroll and gesture events with
CGEvent:

| Gesture | Default | With one-finger scroll |
|---|---|---|
| Tap, double-tap | Click, double click | same |
| One finger, move | Drag | Scroll |
| One finger, hold 0.6 s | Right click | Hold then move: drag. Hold then lift, or keep holding still another 0.5 s: right click |
| Two fingers, move | Scroll | same |
| Two fingers, pinch | Zoom | same |
| Two fingers, tap | Right click if enabled | same |
| Three or four fingers, swipe left/right | Switch Space | same |
| Three or four fingers, swipe up/down | Mission Control / App Exposé | same |
| One finger at a window edge, move | Resize the window | same |

With one-finger scroll, a ring appears under the finger when the hold registers and fills over the
next 0.5 s. Move while it shows to drag; when it is full, the right click fires. Its colour is set
under **Hold Ring Color** in the menu; the default is BMW instrument-cluster orange.

A tap clicks on lift, at the point where the finger landed, so a hold can still become a right
click.

Pinch posts the same magnify gesture event as a trackpad, which Safari, Preview, Maps and most
native apps understand. The event fields are private, the technique used by
[Mac Mouse Fix](https://github.com/noah-nuebling/mac-mouse-fix). In apps listed as zoom-key apps,
pinch sends ⌘+ / ⌘− instead.

With one-finger scroll, some places need an immediate drag instead of a scroll. MacTouch looks up
the window under the finger at touch-down:

- the top 44 pt of a normal window (title bar or toolbar) drags at once, so windows move;
- within 12 pt of a window's side or bottom edge, or just above its top edge, the drag resizes the
  window. Touches scatter by about that much, so MacTouch moves the press onto the edge and keeps
  the finger's offset while you drag;
- in drag apps one finger always drags. The default is `AssistiveControl`, the macOS Accessibility
  Keyboard. Add apps whose sliders move the wrong way under scrolling, such as `eqMac`.

Posted events do not count as user activity, so MacTouch also declares activity on every
touch-down. That keeps the display awake while you use it and wakes it from display sleep. A touch
on a sleeping display only wakes it; it does not click.

Touch also works on the lock screen. With the Accessibility Keyboard turned on, you can wake the Mac
and type your password by touch, without a mouse or keyboard attached. Turn off the keyboard's fade
first; see [Troubleshooting](#troubleshooting).

Swipes send ⌃← / ⌃→ for Spaces, with the modifier key presses a keyboard makes, and launch Mission
Control directly for Mission Control and App Exposé, the approach used by
[macTouchScreen](https://github.com/hasanbahadirkoca/macTouchScreen). Switching Spaces needs the
"Move left/right a space" shortcuts enabled in System Settings → Keyboard → Keyboard Shortcuts →
Mission Control, and at least two Spaces.

Some displays drop off the bus while they sleep. macOS then moves windows to a stand-in display, and
the Accessibility Keyboard comes back centred. MacTouch remembers where the keyboard's panels sit
while the display is settled and moves them back a few seconds after it returns.

Reading the controller needs Input Monitoring; posting events needs Accessibility.

## Alternatives

Other ways to get a touchscreen working on macOS:

- [Touch Up](https://github.com/shueber/Touch-Up), from the RWTH Aachen HCI group: a general-purpose,
  open-source driver app with a settings window and notarized releases. A good choice for screens
  this project has not been tested with.
- [macTouchScreen](https://github.com/hasanbahadirkoca/macTouchScreen) (app name TouchRemap): a menu
  bar app with a settings window, built for the same ILITEK controller in an ARZOPA portable
  monitor. It finds the right display by USB-C port and adds three- and four-finger swipes for
  Spaces and Mission Control. Prebuilt but not notarized.
- [MacXeneonEdgeTouchDriver](https://github.com/ajvwhite/MacXeneonEdgeTouchDriver): a launch agent
  for the Corsair Xeneon Edge, which reports a single contact.
- [UPDD](https://touch-base.com/download-macos) by Touch-Base: the commercial driver many monitor
  makers ship.

Some touch monitors are a different case: macOS already drives them as an absolute-position mouse,
but sends each touch to whichever display the cursor is on. MacTouch does not handle those; for the
CX158 portable monitor, [cx158-touch-warp](https://github.com/kashmeister/cx158-touch-warp) redirects
touches to the right display.

| | MacTouch | Touch Up | macTouchScreen | MacXeneonEdgeTouchDriver | UPDD |
|---|:-:|:-:|:-:|:-:|:-:|
| Free and open source (MIT) | ✅ | ✅ | ✅ | ✅ | ❌ paid license |
| Any HID multi-touch screen | ✅ | ✅ | ✅ | ❌ Xeneon Edge only | ✅ |
| Multi-touch | ✅ | ✅ | ✅ | ❌ | ✅ |
| Tap, double-tap, drag | ✅ | ✅ | ✅ | ✅ | ✅ |
| One-finger scroll, hold to drag | ✅ | ✅ | ❌ one finger drags | ✅ | ✅ |
| Two-finger scroll | ✅ | ❌ two-finger drag | ✅ with momentum | ❌ | ✅ |
| Right click | ✅ long press; optional two-finger tap | ✅ two-finger tap | ✅ long press or two-finger tap | ❌ | ✅ |
| Pinch to zoom | ✅ trackpad zoom or ⌘+/⌘− | ✅ | ➖ ⌘+/⌘− only, off by default | ❌ | ✅ |
| Three- and four-finger swipes | ✅ Spaces, Mission Control | ❌ | ✅ Spaces, Mission Control | ❌ | ❓ |
| Follows display rotation | ✅ automatic | ✅ | ➖ manual swap/flip | ❌ landscape only | ✅ |
| Targets one display among several | ✅ by vendor and model | ✅ | ✅ by USB-C port or by touch | ✅ | ✅ |
| Calibration | ✅ built-in wizard | ❌ | ❌ | ❌ | ✅ |
| Per-app behaviour | ✅ drag apps, zoom-key apps | ❌ | ❌ | ❌ | ❓ |
| Title bars drag at once with one-finger scroll on | ✅ | ❌ | ➖ no one-finger scroll | ❌ | ❓ |
| Settings UI | ✅ menu bar | ✅ window | ✅ menu bar and window | ❌ JSON file | ✅ |
| Prebuilt download | ❌ build from source | ✅ notarized | ➖ not notarized | ❌ build from source | ✅ |
| Permissions survive updates | ✅ | ✅ signed app | ❌ re-add after updates | ❓ | ✅ signed app |
| Source size | ~900 lines of Swift | ~4,200 lines | ~2,500 lines with tests | ~28,000 lines with tests | closed |

✅ supported · ➖ partly · ❌ not supported · ❓ not verified. Compiled from each project's source and README in
October 2026; UPDD from Touch-Base's documentation, not tested here. Corrections welcome.

## Requirements

- macOS 26 (tested); earlier versions from 13 may work but are untested
- Xcode Command Line Tools
- A touch screen whose controller is a HID multi-touch digitizer

## Install

```sh
git clone https://github.com/kashmeister/mactouch.git
cd mactouch
./install.sh --one-finger-scroll
```

This builds `MacTouch.app`, copies it to `~/Applications` and starts it at login. Options given to
`install.sh` are saved as settings; see [Configuration](#configuration). Everything except the USB
IDs can also be changed later from the menu bar.

Then enable **MacTouch** in System Settings → Privacy & Security under both **Input Monitoring** and
**Accessibility**. If it is not listed, add `~/Applications/MacTouch.app` with **+**. MacTouch
restarts itself every 20 s until Input Monitoring is granted, and picks up Accessibility within 2 s.
The grants are tied to the signing identifier `local.mactouch`, so they survive rebuilds.

MacTouch is ready when its menu bar icon shows a pointing hand and the menu says
**Touch active on …**. A crossed-out hand means a permission or the touch screen is missing; the
first line of the menu says which.

## Usage

### Menu bar

| Item | Effect |
|---|---|
| Status line | Touch active, paused, or what is missing |
| Pause Touch | Ignore the touch screen until unpaused |
| One-Finger Scroll | iPad-style scrolling, see [How it works](#how-it-works) |
| Two-Finger Tap Right-Clicks | Two-finger tap as a right click |
| Invert Scrolling | Reverse both scroll gestures |
| Keep Keyboard Position | Put the Accessibility Keyboard back where it was after display sleep, wake and unlock |
| Pinch | Trackpad zoom, ⌘+ / ⌘− keys, or off |
| Long Press, Scroll Speed | Hold time and scroll speed |
| Hold Ring Color | Colour of the hold cue ring |
| Multi-Finger Swipes | Three or four fingers, four only, or off |
| Resize Windows at Edges | Drags that start at a window edge resize it |
| Drag Apps, Zoom-Key Apps | Lists of apps with special handling. **Add …** adds the app that was in front when the menu opened; click an app to remove it |
| Calibrate Touch… | Run the calibration wizard |
| Undo Calibration | Switch back to the calibration before the last change; choose it again to redo |
| Reset Calibration | Go back to an uncalibrated mapping; Undo restores the calibration |
| Open Log | Open `~/Library/Logs/MacTouch.log` |
| Quit MacTouch | Quit until the next login |

### Calibration

Fingers land slightly below the point they aim at, and the touch layer may not line up exactly with
the picture. **Calibrate Touch…** shows a red cross at 9 positions, twice each. Tap the centre of
each one; Esc cancels. MacTouch fits a straight line per axis from where the taps landed, saves it,
and shows the average error before and after.

On the reference display, calibration moved the mean error from about 17 pt, mostly downward, to
about 10 pt with no bias. What is left is finger and controller scatter, about ±1 mm. A full affine
fit did no better than one line per axis.

### Command line

The app's executable is `~/Applications/MacTouch.app/Contents/MacOS/MacTouch`.

| Command | Effect |
|---|---|
| `MacTouch --check` | Print displays, touch device, permissions and settings, then exit |
| `MacTouch --save [options]` | Store settings and exit; restart MacTouch to apply them |
| `MacTouch --reset` | Forget all settings and exit |
| `MacTouch --probe [--raw]` | Log contacts (or every HID value) without posting events |
| `launchctl kickstart -k gui/$(id -u)/local.mactouch` | Restart MacTouch |
| `tail -f ~/Library/Logs/MacTouch.log` | Follow the log; taps, drags, scrolls and zooms are logged |
| `./uninstall.sh` | Stop and remove MacTouch |

## Troubleshooting

**Touch does nothing.** Open the menu and read the status line. If no touch screen is connected,
check the USB cable: touch needs a data connection, not just video. If a permission is missing,
enable it.

**Touches land mirrored or rotated.** MacTouch follows the display rotation set in System Settings →
Displays. 0° and 180° are tested; for 90° or 270°, or a panel mounted differently, use `--swap`,
`--flip-x` or `--flip-y`.

**Touches are offset.** Run **Calibrate Touch…**.

**Touches go to the wrong display.** MacTouch targets the display set by `--display`, falling back to
the main display; the status line names the display in use. Find vendor and model with `--check`.

**A swipe left or right does nothing.** Enable "Move left a space" and "Move right a space" in
System Settings → Keyboard → Keyboard Shortcuts → Mission Control, and make sure there are at least
two Spaces.

**A drag near the edge of a maximized window does not scroll.** Window edges resize. Start the drag
further in, or turn off **Resize Windows at Edges**.

**A slider or control moves the wrong way.** With one-finger scroll, that app receives scrolls.
Switch to the app, open the MacTouch menu and choose **Drag Apps → Add …**.

**The Accessibility Keyboard fades out and touch cannot bring it back.** The keyboard reappears on
pointer movement from real hardware, and MacTouch's events are synthetic. On the lock screen a faded
keyboard disappears completely. In System Settings → Accessibility → Keyboard, click ⓘ next to
Accessibility Keyboard and turn off **Fade after inactivity**, or choose **Panel Options…** from the
keyboard's own options menu.

**A permission is enabled but MacTouch says it is missing.** Privacy & Security can list several
entries from earlier builds, or from the older `touchbridge` version. Remove them all with **−**,
then add `~/Applications/MacTouch.app` once.

**`swiftc` fails with `redefinition of module 'SwiftBridging'`.** A stale
`/Library/Developer/CommandLineTools/usr/include/swift/module.modulemap` from an older Command Line
Tools install conflicts with `bridging.modulemap`. Reinstall the Command Line Tools, or remove the
stale file.

## Configuration

Settings are stored in the defaults domain `local.mactouch`. Set them from the menu, with
`./install.sh [options]`, or with `MacTouch --save [options]`. Numbers may be decimal or `0x` hex;
switches take `=false` to turn them off.

| Option | Default | Meaning |
|---|---|---|
| `--vid=`, `--pid=` | `0x222a`, any | USB IDs of the touch controller |
| `--display=VENDOR:MODEL` | `0x2613:0x2023` | CoreGraphics vendor and model of the touch display, or `main` |
| `--flip-x`, `--flip-y`, `--swap` | off | Axis fixes applied after the display rotation |
| `--cal=ax,bx,ay,by` | none | Calibration as `touched = a × target + b`, in fractions of the display; set by the wizard |
| `--one-finger-scroll` | off | iPad-style one-finger scrolling |
| `--two-finger-tap` | off | Two-finger tap right clicks |
| `--hold=` | `0.6` | Long-press time in seconds |
| `--scroll-scale=`, `--invert-scroll` | `1.0`, off | Scroll speed and direction |
| `--zoom=` | `gesture` | Pinch as trackpad magnify (`gesture`), ⌘+/⌘− (`keys`) or `off` |
| `--zoom-scale=` | `1.0` | Pinch sensitivity |
| `--zoom-key-apps=` | none | Apps where pinch sends ⌘+/⌘− |
| `--drag-apps=` | `AssistiveControl` | Apps where one finger always drags |
| `--titlebar=` | `44` | Height in points of the drag zone at the top of each window; `0` turns it off |
| `--edge=` | `12` | Distance in points from a window edge within which a drag resizes; `0` turns it off |
| `--ring-color=` | `#FF6A00` | Hold cue ring colour, `#RRGGBB` or `accent` |
| `--keep-keyboard` | on | Restore the Accessibility Keyboard's position after display sleep |
| `--swipes=` | `3` | Multi-finger swipes with three or four fingers (`3`), four only (`4`), or `off` |

App names are window owner names, usually the name shown in Activity Monitor.

Other touch screens work if their controller is a HID digitizer with Finger collections (usage page
`0x0D`, usage `0x22`) holding tip switch and X/Y. Set `--vid`, `--pid` and `--display` for them.

## Uninstall

```sh
./uninstall.sh
```

Then remove the MacTouch entries from Accessibility and Input Monitoring.

## License

MIT
