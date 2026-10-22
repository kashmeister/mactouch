# Contributing to MacTouch

Thanks for helping. The most useful contributions are support for more touch screens, reports of
screens that work or don't, and bug fixes. This guide covers building and testing, how the code is
laid out, and how to add a touch controller, including one whose report format has to be worked out
by hand.

## Build and test

```sh
./build.sh                                         # builds build/MacTouch.app (--arch=x86_64, arm64 or universal)
build/MacTouch.app/Contents/MacOS/MacTouch --self-test
./install.sh                                       # installs and restarts the menu bar app
tail -f ~/Library/Logs/MacTouch.log
```

`--self-test` needs no hardware. It checks the panel-to-display transforms in every rotation, the
calibration maths, and every known controller's report layout against the reports recorded for it.
Run it before every pull request.

`MacTouch --help` lists the command line. These are the commands useful for development:

| Command | Use |
|---|---|
| `MacTouch --check` | What MacTouch sees: displays, touch screens and what it does with each, profiles, permissions |
| `MacTouch --probe` | Run without posting events; logs contacts |
| `MacTouch --probe --raw` | Also log every HID value, and every report from a driverless interface |
| `MacTouch --capture=VID:PID[:INTERFACE]` | Take a USB device from macOS and print its descriptors and reports (see below) |

Run from a terminal, these use the terminal's Input Monitoring and Accessibility permissions.

## How the code is laid out

All code is in `Sources/`, one area per file, with no dependencies beyond macOS.

| File | What it does |
|---|---|
| `main.swift` | Startup: command line, settings, then either a command-line action or the menu bar app |
| `Settings.swift` | Settings and command-line options, touchscreen profiles, calibration storage |
| `KnownDevices.swift` | **The table of controllers that need more than standard HID handling, and their report layouts** |
| `Touchscreens.swift` | Finding and classifying touch screens, profiles, reading HID input, taking single-touch screens from macOS |
| `RawUSB.swift` | Reading multi-touch interfaces macOS has no driver for, and taking a USB device from macOS |
| `Displays.swift` | Display lookup, panel-to-display transforms, calibration maths, window queries |
| `Gestures.swift` | The gesture engine (`commit`, once per report) and the events it posts |
| `Pairing.swift`, `Calibration.swift` | The pair-by-touch and calibration windows |
| `Keyboard.swift` | Accessibility Keyboard: keeping its position, Auto Keyboard |
| `Music.swift`, `Sketch.swift` | Music mode, Whiteboard and Draw on Screen |
| `App.swift` | Menu bar item and menu |
| `LoginItem.swift` | Start at Login (a launch agent inside the app, registered with SMAppService), and one copy running at a time |
| `Check.swift`, `SelfTest.swift`, `Capture.swift` | `--check`, `--self-test` and `--capture` |
| `Support.swift` | Logging and small helpers |

Touch input flows like this: a source (HID values in `valueCB`, or reports in
`RawDigitizer.report`) fills a `TouchDevice`'s contact slots, then calls `deliver`. That makes the
device active with its profile's settings, and runs `commit`, which maps contacts to screen points
(`frac`, `toScreen`) and turns them into clicks, drags, scrolls and gestures.

## Adding a touch screen

### 1. See what it is

Connect it and run `MacTouch --check`.

- **Listed as multi-touch or single touch** (or as `known controller connected` for one in
  `KnownDevices.swift`): it probably works already. Pair it when MacTouch asks
  (touch the orange target), then try the gestures. Please open an issue saying it works, with the
  `--check` lines for it, so it can be added to the README.
- **Listed as single touch, but the controller is a multi-touch screen on Windows:** it may also have
  a multi-touch mode that macOS has no driver for. Look for other USB IDs under the same hub
  (`ioreg -p IOUSB -w0`), especially right after it powers up.
- **Not listed, or touch does nothing:** look at its USB interfaces:

  ```sh
  system_profiler SPUSBHostDataType           # vendor and product IDs (SPUSBDataType on macOS 13 and 14)
  ioreg -r -c IOUSBHostDevice -n "<product name>" -t | grep -E "IOUSBHostInterface|HID"
  ```

  An `IOUSBHostInterface` with class 3 (HID) and no `AppleUserUSBHostHIDDevice` under it is an
  interface macOS gave up on. `log show --last 2m --predicate 'process == "kernel" AND eventMessage
  CONTAINS "<product name>"'` usually shows why, for example `pipe stalled` on the report descriptor
  request. That is the case `--capture` and a `KnownDevices.swift` entry are for.

### 2. A HID digitizer that behaves wrongly

If MacTouch reads the screen but touches are wrong (axes, ranges, missing fingers), run
`MacTouch --probe --raw` and touch the screen. Each line is one HID value with its usage page, usage
and parent collection. MacTouch expects each contact in a Finger collection (`0x0D/0x22`) with Tip
Switch (`0x0D/0x42`), X (`0x01/0x30`) and Y (`0x01/0x31`). Rotated or mirrored axes are fixed with the
display rotation or `--flip-x`, `--flip-y`, `--swap`, and offsets with the calibration wizard. Other
deviations need a code change in `valueCB`: open an issue with the log.

### 3. An interface without a driver: capture its reports

Quit the menu bar app so it does not take the device itself, then capture for 30 to 60 seconds. IDs
are hex, as `--check` and `system_profiler` show them; the interface number is decimal:

```sh
launchctl bootout gui/$(id -u)/local.mactouch
build/MacTouch.app/Contents/MacOS/MacTouch --capture=1234:5678:0 --seconds=60
./install.sh                                       # afterwards: starts the menu bar app again
```

While it runs, touch the screen in this order, pausing between each:

1. one finger, held still in the middle;
2. one finger dragged slowly from left to right, then from top to bottom;
3. two fingers held still, then lifted one at a time;
4. each corner in turn: top left, top right, bottom right, bottom left.

The capture prints the device's descriptors, then every report that differs from the one before.
At the end it asks for the interface's HID report descriptor. If the controller hands it over, the
capture saves it to a `.bin` file; decode that with a HID descriptor parser (for example `hidrd-convert -o spec`, or a web-based USB descriptor
parser) and it gives the layout directly. Many such controllers refuse the request. In that case, work
the layout out from the reports:

| Field | How to find it |
|---|---|
| Report ID | The first byte, the same in every touch report |
| X | Two bytes, usually little-endian, that rise steadily during the left-to-right drag |
| Y | Two bytes that rise during the top-to-bottom drag |
| Status | The byte before X. A bit (the tip bit, often bit 0) clears in the report where the finger lifts; the rest (often bits 1 to 7) is a contact ID that changes with every new touch |
| Contact size | With two fingers, the second contact's status, X and Y repeat the first's pattern this many bytes later |
| Contact count | A byte (often the last) that is 1 with one finger, 2 with two, and 0 when nothing touches |
| Maximum X and Y | From the corner touches, rounded up to a plausible range: 4095, 32767, or a range in the screen's proportions (32767 × 10/16 = 20479 for 16:10) |

Ranges and offsets need not be exact: the calibration wizard accepts a scale between 0.8 and 1.25
and an offset up to 15% per axis, and the self-test checks the layout against your samples.

### 4. Add an entry to `KnownDevices.swift`

Describe the controller in `knownControllers`. `ReportLayout`'s defaults match the common Windows
layout, so usually only the report ID and maximums need setting:

```swift
KnownController(name: "Example 15.6\" touch monitor",
                modes: [USBID(0x1234, 0x5678)],              // every USB ID it shows up under
                raw: RawInterface(id: USBID(0x1234, 0x5678), interface: 0,
                                  layout: ReportLayout(reportID: 2, maxX: 4095, maxY: 4095),
                                  samples: [
                                      RawSample(start: "02 03 10 08 00 04", length: 64, count: 1, contacts: [1: (2064, 1024)]),
                                      RawSample(start: "02 02 10 08 00 04", length: 64, count: 1, contacts: [:]),
                                  ])),
```

- **`modes`** lists every USB ID the controller uses. A controller that switches between a mouse mode
  and a multi-touch mode (like the CX158) gets one profile per mode, sharing the display paired with
  the first.
- **`takeDevice: true`** (between `layout:` and `samples:`) makes MacTouch take the whole USB device from macOS the moment it appears and
  configure it without drivers for its interfaces. Set it only if the controller changes mode, or
  stops reporting, once macOS's HID driver has read the interface. The CX158 needs it; most don't.
- **`samples`** are reports copied from your capture: the leading bytes as hex (the rest are taken as
  zeros), the report length, the contact count byte, and the contacts it holds as raw coordinates by
  contact ID. Include at least one finger, two fingers and a lift. `--self-test` decodes every sample.

If the reports don't fit `ReportLayout` (big-endian or 12-bit packed coordinates, a tip bit elsewhere,
contacts spread over several reports), extend `ReportLayout` with a new field whose default keeps
today's behaviour, and add samples that cover it.

### 5. Test it

1. `--self-test` passes.
2. `./install.sh`, plug the screen in, and pair it. The log should show `reading its multi-touch
   interface directly`.
3. Calibrate it (**Touchscreens ▸ name ▸ Calibrate Touch…**) and try tap, double-tap and drag, hold for
   right click, two-finger scroll, pinch, and three-finger swipes.
4. Unplug it and plug it back in: it should come back on its own, without asking to pair again.
5. Rotate the display in System Settings: touches should still land under your finger.

## Pull requests

- One topic per pull request, with the `--check` output and log lines that show it working.
- Update the README (hardware table, menu table, options) when behaviour changes.
- Keep the style: small functions, comments that say why rather than what, plain Swift in Swift 5 mode
  with no dependencies, and log lines a user can act on. User-visible text uses sentence case.
- Before posting a capture or log publicly, remove anything personal, such as serial numbers in
  the descriptors.

## Reporting a problem

Open an issue with your Mac model and macOS version, the screen's make and model, `MacTouch --check`
output, and the relevant lines of `~/Library/Logs/MacTouch.log`. For touch problems, a few seconds
of `MacTouch --probe --raw` output helps most.

By contributing you agree to license your work under the project's MIT license.
