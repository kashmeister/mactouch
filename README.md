# wisecoco-touchbridge

A macOS launch agent that makes a Wisecoco touch display usable as a touchscreen: tap, drag,
right click, one- and two-finger scroll, and pinch to zoom.

## Hardware

Wisecoco sells high-resolution bar and ultrawide displays with a capacitive touch layer. The one
this was built for is a 5120 × 1466 panel whose touch layer is an ILITEK controller, USB
`222a:0001`, reporting up to 10 contacts.

To check a monitor, run `bin/touchbridge --check` and look for display vendor `0x2613`, model
`0x2023`, and a touch device named `ILITEK-TP`, or run `hidutil list` and look for USB IDs
`0x222a 0x1` with usage page 13 (digitizer).

## Why

The controller enumerates as a HID multi-touch digitizer. macOS claims it with its generic HID
driver but has no touchscreen support, so touches go nowhere: the pointer does not move and nothing
clicks. The commercial fix is a third-party driver; this agent does the same job in about 400 lines
of Swift.

## How it works

The agent opens the controller with IOHIDManager, without seizing it, and reads the 10 finger
slots of each report: tip switch, X and Y, logical range 0–16384. It maps them onto the touch
display, turning them with the display's rotation, and posts mouse, scroll and gesture events with
CGEvent:

| Gesture | Default | With `--one-finger-scroll` |
|---|---|---|
| Tap, double-tap | Click, double click | same |
| One finger, move | Drag | Scroll |
| One finger, hold 0.6 s | Right click | Hold then move: drag. Hold then lift: right click |
| Two fingers, move | Scroll | same |
| Two fingers, pinch | Zoom | same |
| Two fingers, tap | Right click if `--two-finger-tap` | same |

A tap clicks on lift, at the point where the finger landed, so a hold can still become a right
click.

Pinch posts the same magnify gesture event as a trackpad, which Safari, Preview, Maps and most
native apps understand. The event fields are private, the technique used by
[Mac Mouse Fix](https://github.com/noah-nuebling/mac-mouse-fix). For apps that ignore it,
`--zoom-key-apps` sends ⌘+ / ⌘− instead.

With `--one-finger-scroll`, some places need an immediate drag instead of a scroll. The agent looks
up the window under the finger at touch-down:

- the top 44 pt of a normal window (title bar or toolbar) drags at once, so windows move;
- apps listed in `--drag-apps` always drag. The default is `AssistiveControl`, the macOS
  Accessibility Keyboard. Add apps whose sliders move the wrong way under scrolling, such as
  `eqMac`.

Reading the controller needs Input Monitoring; posting events needs Accessibility.

## Requirements

- macOS 26 (tested); earlier versions are untested
- Xcode Command Line Tools
- A touch display whose controller is a HID multi-touch digitizer (for others, see
  [Configuration](#configuration))

## Install

```sh
git clone https://github.com/kashmeister/wisecoco-touchbridge.git
cd wisecoco-touchbridge
./install.sh --one-finger-scroll
```

Options given to `install.sh` are passed to the agent; see [Configuration](#configuration).

Then enable `touchbridge` in System Settings → Privacy & Security under both **Input Monitoring**
and **Accessibility**. If it is not listed, add `bin/touchbridge` with **+**. The agent restarts
itself once Input Monitoring is granted and picks up Accessibility within 2 s. The grants are tied
to the signing identifier `local.touchbridge`, so they survive rebuilds.

The agent is ready when `~/Library/Logs/touchbridge.log` shows:

```
Input Monitoring granted; HID manager open
ready; display 1 rotation 180
```

## Usage

| Command | Effect |
|---|---|
| `./install.sh [options]` | Rebuild and reinstall with these options. |
| `bin/touchbridge --check` | Print displays, touch device and permission status, then exit. |
| `launchctl kickstart -k gui/$(id -u)/local.touchbridge` | Restart the agent. |
| `tail -f ~/Library/Logs/touchbridge.log` | Follow the log. Taps, drags, scrolls and zooms are logged. |
| `./uninstall.sh` | Stop and remove the agent. |

## Calibration

Fingers land slightly below the point they aim at, and the touch layer may not line up exactly with
the picture. `--cal=ax,bx,ay,by` corrects a per-axis error model `touched = a × target + b`, in
fractions of the display. To measure it, show targets at known positions, record where taps land,
and fit a line per axis. On the reference display 54 taps gave:

```
--cal=1.0062,-0.0039,1.0309,0.0049
```

That moved the mean error from about 17 pt, mostly downward, to about 10 pt with no bias. What is
left is finger and controller scatter, about ±1 mm. A full affine fit did no better.

## Troubleshooting

**Touch does nothing.** Run `bin/touchbridge --check`. If no touch device is listed, check the USB
cable: touch needs a data connection, not just video. If the log says a permission is missing,
enable it.

**Touches land mirrored or rotated.** The agent follows the display rotation set in System Settings
→ Displays. 0° and 180° are tested; for 90° or 270°, or a panel mounted differently, add
`--swap`, `--flip-x` or `--flip-y`.

**Touches go to the wrong display.** The agent targets the display set by `--display`, falling back
to the main display, and logs which one it uses. Find the vendor and model with `--check`.

**A slider or control moves the wrong way.** With `--one-finger-scroll`, that app receives scrolls.
Add it to `--drag-apps`. Use the process name shown in Activity Monitor; the log shows it too,
as `down in <app>: drag mode`, once an app is listed.

**A permission is enabled but the log says it is missing.** Privacy & Security can list several
`touchbridge` entries from earlier builds. Remove them all with **−**, then add `bin/touchbridge`
once.

**`swiftc` fails with `redefinition of module 'SwiftBridging'`.** A stale
`/Library/Developer/CommandLineTools/usr/include/swift/module.modulemap` from an older Command Line
Tools install conflicts with `bridging.modulemap`. Reinstall the Command Line Tools, or remove the
stale file.

## Configuration

All options are optional. Numbers may be decimal or `0x` hex.

| Option | Default | Meaning |
|---|---|---|
| `--vid=`, `--pid=` | `0x222a`, any | USB IDs of the touch controller |
| `--display=VENDOR:MODEL` | `0x2613:0x2023` | CoreGraphics vendor and model of the touch display, or `main` |
| `--flip-x`, `--flip-y`, `--swap` | off | Axis fixes applied after the display rotation |
| `--cal=ax,bx,ay,by` | none | Calibration, see [Calibration](#calibration) |
| `--one-finger-scroll` | off | iPad-style one-finger scrolling |
| `--two-finger-tap` | off | Two-finger tap right clicks |
| `--hold=` | `0.6` | Long-press time in seconds |
| `--scroll-scale=`, `--invert-scroll` | `1.0`, off | Scroll speed and direction |
| `--zoom=` | `gesture` | Pinch as trackpad magnify (`gesture`), ⌘+/⌘− (`keys`) or `off` |
| `--zoom-scale=` | `1.0` | Pinch sensitivity |
| `--zoom-key-apps=` | none | Apps where pinch sends ⌘+/⌘− |
| `--drag-apps=` | `AssistiveControl` | Apps where one finger always drags |
| `--titlebar=` | `44` | Height in points of the drag zone at the top of each window; `0` turns it off |
| `--probe`, `--raw` | off | Log contacts or raw HID values and post no events |

Other touch displays work if their controller is a HID digitizer with Finger collections
(usage page `0x0D`, usage `0x22`) holding tip switch and X/Y. Set `--vid`, `--pid` and
`--display` for them.

## Uninstall

```sh
./uninstall.sh
```

Then remove the `touchbridge` entries from Accessibility and Input Monitoring.

## License

MIT
