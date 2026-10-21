# MacTouch

A macOS menu bar app that makes USB touch screens usable as touchscreens: tap, drag, right click,
one- and two-finger scroll, pinch to zoom and multi-finger swipes, with a built-in calibration
wizard. It detects what kind of touch screen is connected, pairs each one with its display once, and
remembers its settings.

## Hardware

MacTouch handles three kinds of touch controller and tells them apart when they connect:

| Kind | What macOS does with it | Example | Gestures |
|---|---|---|---|
| HID multi-touch digitizer, the kind Windows drives without a driver | Claims it with its generic HID driver, but nothing happens on touch | Wisecoco 3840 × 1100 bar display: ILITEK controller, USB `222a:0001`, 10 contacts | All |
| Single-touch screen that presents an absolute-position mouse | Drives it, but puts each touch on whichever display the cursor is on | CX158 portable monitor in mouse mode, USB `0416:c169` | One finger: tap, drag, hold, one-finger scroll |
| Multi-touch interface macOS attaches no driver to | Nothing: the controller refuses the request for its HID descriptor | CX158 in digitizer mode, USB `eeef:2828`, 10 contacts | All |

The CX158 is the model name the panel reports; it is sold under several brands, for example the
UPERFECT 14" OLED 3K portable monitor. Its controller comes up in either mode.

To check a monitor, run `MacTouch --check` (see [Usage](#usage)): it lists the displays, the touch
screens it found and what it does with each. `hidutil list` shows USB IDs and usage pages (13 is a
digitizer). Most screens of the first two kinds work without any setup. A controller of the third
kind needs an entry describing its reports in `Sources/KnownDevices.swift`;
[CONTRIBUTING.md](CONTRIBUTING.md) explains how to work one out with `MacTouch --capture`, and how to
report a screen that works.

## Why

macOS has no touchscreen support. A HID multi-touch digitizer is claimed by the generic HID driver,
but touches go nowhere: the pointer does not move and nothing clicks. Screens that emulate a mouse do
move the pointer, but on the wrong display whenever there is more than one. Other drivers fix the
first case (see [Alternatives](#alternatives)); this one handles all three in about 3,700 lines of
Swift, with per-app behaviour, two-finger scrolling, calibration and per-screen settings.

## How it works

MacTouch reads each touch screen's contacts, maps them onto that screen's display, turning them with
the display's rotation and applying the screen's calibration, and posts mouse, scroll and gesture
events with CGEvent:

- **Digitizers** are opened with IOHIDManager, without seizing them; MacTouch reads the finger slots
  of each report: tip switch, X and Y. If a digitizer has an Input Mode feature, MacTouch sets it to
  multi-touch, as Windows does.
- **Single-touch screens** would otherwise move the pointer themselves, on whichever display the
  cursor is on. While MacTouch drives one (paired, display connected, not paused) it takes the device
  from macOS for itself (an exclusive HID open), reads it the same way, and posts its own events on
  the paired display. When MacTouch stops driving it, or quits, macOS handles it again. Should taking
  it fail, an event tap drops the clicks macOS makes from it instead.
- **Interfaces without a driver** are opened directly with IOUSBHost, which needs no driver or
  entitlement for an interface nobody has claimed, and their reports are decoded with the layout
  listed for the controller in `Sources/KnownDevices.swift`. For a controller that changes mode once
  macOS's HID driver reads it, like the CX158, MacTouch also takes the whole USB device from macOS
  the moment it appears and configures it without interface drivers, so that driver never gets to it.
  For the CX158: report ID 1, ten 5-byte contact slots (finger-down bit, contact ID, X 0–32767,
  Y 0–20479) and the contact count.

Only one screen drives the gestures at a time: the one whose touch starts while nothing else is
touched.

| Gesture | Default | With one-finger scroll |
|---|---|---|
| Tap, double-tap | Click, double click | same |
| Tap, then touch again and move | Select by word (a double-click drag); after a double tap, by line or paragraph | same |
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
under **Hold Ring Color** in the menu; the default is a warm gauge orange.

A tap clicks on lift, where the finger rested (the median of its positions), so a hold can still
become a right click. As a finger lifts, many panels report one last position 10 pt or more away;
a move counts only once the next report confirms it, so that jump never turns a tap into a drag.

A touch that lands within 0.75 s (or the system's double-click speed, if slower) and 60 pt of a
tap continues it: lifted, it is a double or triple click; moved, it selects by word or
by line, so text can be selected without turning one-finger scroll off. It may wobble 20 pt before
it counts as moving, and it never turns into a hold.

Pinch posts the same magnify gesture event as a trackpad, which Safari, Preview, Maps and most
native apps understand. The event fields are private, the technique used by
[Mac Mouse Fix](https://github.com/noah-nuebling/mac-mouse-fix). In apps listed as zoom-key apps,
pinch sends ⌘+ / ⌘− instead.

With one-finger scroll, some places need an immediate drag instead of a scroll. MacTouch looks up
the window under the finger at touch-down:

- the desktop drags at once, so icons can be selected and moved;
- the top 44 pt of a normal window (title bar or toolbar) drags at once, so windows move;
- within 12 pt of a window's side or bottom edge, or just above its top edge, the drag resizes the
  window. Touches scatter by about that much, so MacTouch moves the press onto the edge and keeps
  the finger's offset while you drag;
- in drag apps one finger always drags. The default is `AssistiveControl`, the macOS Accessibility
  Keyboard. Add apps whose sliders move the wrong way under scrolling, such as `eqMac`.

On the desktop a hold right-clicks too: the ring shows there whether or not one-finger scroll is on,
so moving while it shows drags as usual. In title bars, drag apps and at window edges a press only
ever drags.

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

Reading HID controllers needs Input Monitoring; posting events, and filtering a single-touch screen's
own events, needs Accessibility.

### Touchscreens and profiles

Each touch screen MacTouch meets gets a profile, keyed by its USB IDs (and serial number), holding
what belongs to that screen: its display, calibration, axis fixes, One-Finger Scroll, Long Press and
mode. Everything else is global. A screen that reconnects goes straight back to its profile; nothing
needs setting up again.

A new touch screen is paired with its display once. MacTouch shows an orange target on each
external display that has no touch screen yet, at a different spot on each; the first touch picks
the display whose target it lands nearest. A digitizer with only one such display is paired without
asking. Esc puts it off (**Touchscreens ▸ name ▸ Pair with Display…** asks again), and
**Not a Touchscreen** tells MacTouch to leave a device alone, for example a KVM's virtual mouse.
Single-touch screens are left to macOS until they are paired. New single-touch screens start with
One-Finger Scroll on, as one finger is all they have to scroll with.

A controller that shows up under different USB IDs in different modes, such as the CX158, gets one
profile per mode; the second one takes the first one's display.

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

MacTouch also replaces [cx158-touch-warp](https://github.com/kashmeister/cx158-touch-warp), which only
moved CX158 touches onto the right display; `install.sh` stops and removes it.

| | MacTouch | Touch Up | macTouchScreen | MacXeneonEdgeTouchDriver | UPDD |
|---|:-:|:-:|:-:|:-:|:-:|
| Free and open source (MIT) | ✅ | ✅ | ✅ | ✅ | ❌ paid license |
| Any HID multi-touch screen | ✅ | ✅ | ✅ | ❌ Xeneon Edge only | ✅ |
| Single-touch (absolute mouse) screens | ✅ | ❌ | ❌ | ✅ | ✅ |
| Multi-touch interfaces macOS has no driver for | ✅ known layouts (CX158) | ❌ | ❌ | ❌ | ❓ |
| Several touch screens, settings per screen | ✅ profiles, paired by touch | ❌ | ❌ | ❌ | ✅ |
| Multi-touch | ✅ | ✅ | ✅ | ❌ | ✅ |
| Tap, double-tap, drag | ✅ | ✅ | ✅ | ✅ | ✅ |
| One-finger scroll, hold to drag | ✅ | ✅ | ❌ one finger drags | ✅ | ✅ |
| Two-finger scroll | ✅ | ❌ two-finger drag | ✅ with momentum | ❌ | ✅ |
| Right click | ✅ long press; optional two-finger tap | ✅ two-finger tap | ✅ long press or two-finger tap | ❌ | ✅ |
| Pinch to zoom | ✅ trackpad zoom or ⌘+/⌘− | ✅ | ➖ ⌘+/⌘− only, off by default | ❌ | ✅ |
| Three- and four-finger swipes | ✅ Spaces, Mission Control | ❌ | ✅ Spaces, Mission Control | ❌ | ❓ |
| Follows display rotation | ✅ automatic | ✅ | ➖ manual swap/flip | ❌ landscape only | ✅ |
| Targets one display among several | ✅ paired by touch, by vendor and model | ✅ | ✅ by USB-C port or by touch | ✅ | ✅ |
| Calibration | ✅ built-in wizard | ❌ | ❌ | ❌ | ✅ |
| Per-app behaviour | ✅ drag apps, zoom-key apps | ❌ | ❌ | ❌ | ❓ |
| Title bars drag at once with one-finger scroll on | ✅ | ❌ | ➖ no one-finger scroll | ❌ | ❓ |
| Settings UI | ✅ menu bar | ✅ window | ✅ menu bar and window | ❌ JSON file | ✅ |
| Prebuilt download | ❌ build from source | ✅ notarized | ➖ not notarized | ❌ build from source | ✅ |
| Permissions survive updates | ✅ | ✅ signed app | ❌ re-add after updates | ❓ | ✅ signed app |
| Source size | ~3,700 lines of Swift with tests | ~4,200 lines | ~2,500 lines with tests | ~28,000 lines with tests | closed |

✅ supported · ➖ partly · ❌ not supported · ❓ not verified. Compiled from each project's source and README in
October 2026; UPDD from Touch-Base's documentation, not tested here. Corrections welcome.

## Requirements

- macOS 26 (tested); earlier versions from 13 may work but are untested
- Xcode Command Line Tools
- A touch screen of one of the kinds under [Hardware](#hardware)

## Install

```sh
git clone https://github.com/kashmeister/mactouch.git
cd mactouch
./install.sh --one-finger-scroll
```

This builds `MacTouch.app`, copies it to `~/Applications` and starts it at login. Options given to
`install.sh` are saved as settings; see [Configuration](#configuration). Everything can also be
changed later from the menu bar, and new touch screens are paired by touch (see
[Touchscreens and profiles](#touchscreens-and-profiles)).

Then enable **MacTouch** in System Settings → Privacy & Security under both **Input Monitoring** and
**Accessibility**. If it is not listed, add `~/Applications/MacTouch.app` with **+**. MacTouch
restarts itself every 20 s until Input Monitoring is granted, and picks up Accessibility within 2 s.
The grants are tied to the signing identifier `local.mactouch`, so they survive rebuilds.

MacTouch is ready when its menu bar icon shows a pointing hand and the menu says
**Touch active: … on …**, one line per touch screen. A crossed-out hand means a permission or the
touch screen is missing; the first lines of the menu say which.

## Usage

### Menu bar

| Item | Effect |
|---|---|
| Status lines | One per touch screen: active and on which display, waiting to be paired, or what is missing |
| Pause Touch | Ignore the touch screens until unpaused |
| One-Finger Scroll | iPad-style scrolling, see [How it works](#how-it-works). Per screen: with several connected, the item names the screen touched last |
| Two-Finger Tap Right-Clicks | Two-finger tap as a right click (multi-touch screens only) |
| Invert Scrolling | Reverse both scroll gestures |
| Accessibility Keyboard ▸ Show Keyboard | Turn the macOS Accessibility Keyboard on or off: the switch in System Settings ▸ Accessibility ▸ Keyboard, set through the private UniversalAccess function System Settings uses (greyed out on a macOS without it) |
| Accessibility Keyboard ▸ Off While No Touchscreen Is Connected | Turn the keyboard off once no touch screen has been connected for 10 s (not counting time with the displays asleep or the screen locked), and back on, minimized again if it was and where it was, when one connects. Only a keyboard MacTouch turned off comes back; once you switch it yourself, it is left alone until a touch screen connects |
| Accessibility Keyboard ▸ Keep Keyboard Position | Put the keyboard back where it was after display sleep, wake and unlock |
| Accessibility Keyboard ▸ Auto Keyboard | Expand the minimized keyboard when a tap puts the focus in a text field, and minimize it again after you leave |
| Pinch | Trackpad zoom, ⌘+ / ⌘− keys, or off (multi-touch screens only) |
| Long Press | Hold time, per screen |
| Scroll Speed | Scroll speed |
| Hold Ring Color | Colour of the hold cue ring |
| Multi-Finger Swipes | Three or four fingers, four only, or off (multi-touch screens only) |
| Resize Windows at Edges | Drags that start at a window edge resize it |
| Drag Apps, Zoom-Key Apps | Lists of apps with special handling. **Add …** adds the app that was in front when the menu opened; click an app to remove it |
| Music… | Open music mode: piano, drums, strum, theremin and loops; settings are in its bar |
| Whiteboard…, Draw on Screen… | Draw with your fingers on a board or over the screen |
| Calibrate Touch… | Run the calibration wizard on the screen touched last |
| Undo Calibration | Switch back to the calibration before the last change; choose it again to redo |
| Reset Calibration | Go back to an uncalibrated mapping; Undo restores the calibration |
| Touchscreens | One submenu per known screen, connected or not: its kind and display; Pair with Display…; Calibrate Touch…, Undo and Reset Calibration; One-Finger Scroll; Mode (Automatic, Multi-Touch, Single Touch, Not a Touchscreen); Forget This Touchscreen |
| Open Log | Open `~/Library/Logs/MacTouch.log` |
| Quit MacTouch | Quit until the next login |

### Music

**Music…** in the menu opens a full-screen instrument on the touch display. While it is open,
touches bypass mouse emulation and every finger plays on its own. The bar above the instrument
switches between four instruments and holds their settings:

| Instrument | How to play | Settings in the bar |
|---|---|---|
| **Piano** | Chords and both hands; slide across keys to play each one | ◀ ▶ octave shift, 1–6 octaves, Dynamics, sound (Grand Piano, Electric Piano, Harpsichord, Vibraphone, Organ, Strings, Choir), Sustain |
| **Drums** | 16 pads: kick, snare, clap, rim, hi-hats, crash, toms, ride, ride bell, tambourine, cowbell, shaker | Dynamics |
| **Strum** | Omnichord-style: tap a chord (12 roots in circle-of-fifths order × major, minor, 7th), then swipe across the strum plate; every string you cross sounds | Sound (Harp, Nylon Guitar, Steel Guitar, Music Box, Kalimba) |
| **Theremin** | Left–right is pitch over three octaves (C3–C6), up–down is volume; each finger is its own voice | Wave (Sine, Triangle, Saw), Snap to notes |

Notes play at a fixed volume. The glass cannot sense pressure, so with **Dynamics** on, the front of
a key or pad, lower on the screen, plays louder instead.

On the right of the bar:

| Control | Effect |
|---|---|
| Loop slots ○1–○4 | Tap an empty slot to arm it (●), then play: recording starts on your first note. Tap again to loop it (▶) and play over it. Tap to stop (‖) or restart. **Hold 0.7 s to clear.** |
| ♩ Metronome | Tap to cycle off, 80, 100, 120, 140 bpm |
| Save MIDI | Save every loop as a track of a MIDI file in `~/Music/MacTouch` |
| Done, or Esc | Close |

The first loop sets the cycle; with the metronome on, it starts on the nearest beat and is rounded to
whole beats. Later loops line up with the cycle they were started in and last a whole number of
cycles, so all loops stay in step. Loops record piano, drums and strum, not the theremin.

Keys and pads you play light up in the hold ring colour; notes from loops light up paler. The sounds
are the General MIDI set that ships with macOS. Piano, strum and drums also go out on a MIDI source
named **MacTouch Piano** (channels 1, 2 and 10), so GarageBand, Logic or any synth can play them with
better instruments.

### Whiteboard and Draw on Screen

**Whiteboard…** opens a full-screen board; **Draw on Screen…** puts a transparent layer over
everything. Each finger draws its own line. The bar has seven pen colours (Orange follows the hold
ring colour), line thickness, an eraser that removes the lines it touches, Undo, Clear (hold 0.7 s),
and Done.

- The whiteboard can be dark or light and is saved with **Save PNG** to `~/Pictures/MacTouch`, and
  copied to the clipboard.
- On screen, **Drawing / Using Mac** switches touches between drawing and working the Mac as usual,
  with the drawing left in place. The bar floats at the top centre and always responds to touch.
- To feel quicker, the line runs a little ahead of your finger, to where it is predicted to be
  8 ms later, but not while the finger slows down or turns; the guess is corrected on the next touch
  report. Change it with `--ink-predict=` (milliseconds, 0 turns it off).

### Calibration

Fingers land slightly below the point they aim at, and the touch layer may not line up exactly with
the picture. **Calibrate Touch…** shows a red cross at 18 positions on the screen touched last (or
**Touchscreens ▸ name ▸ Calibrate Touch…** for a given one): 9 inset from the edges, then 9 at the
edges and corners. Tap the centre of each one; Esc cancels. MacTouch fits a straight line per axis
from the inset taps. Touch panels read inward near their edges, often by 10 pt or more, so it also
measures that from the edge taps and corrects touches within 10% of each edge, which keeps menu bar
items and window buttons in the corners within reach. It saves the result in that screen's profile
and shows the average error before and after. The calibration is kept in the touch panel's own axes,
so it stays right when the display is rotated. Since 3.2 a tap counts where the finger rested rather
than where it first touched, so calibrate again after upgrading from an older version.

On the reference display, calibration moved the mean error from about 17 pt, mostly downward, to
about 10 pt with no bias. What is left is finger and controller scatter, about ±1 mm. A full affine
fit did no better than one line per axis.

### Command line

The app's executable is `~/Applications/MacTouch.app/Contents/MacOS/MacTouch`.

| Command | Effect |
|---|---|
| `MacTouch --check` | Print displays, touch screens and what MacTouch does with each, profiles, permissions and settings, then exit |
| `MacTouch --save [options]` | Store settings and exit; restart MacTouch to apply them |
| `MacTouch --reset` | Forget all settings and exit |
| `MacTouch --probe [--raw]` | Log contacts without posting events (`--raw`: also every HID value and every raw report) |
| `MacTouch --help` | List the commands and settings options |
| `MacTouch --self-test` | Check the coordinate maths and the known controllers' report layouts |
| `MacTouch --capture=VID:PID[:INTERFACE]` | Take a USB device from macOS and print its descriptors and reports, for adding a controller (see [CONTRIBUTING.md](CONTRIBUTING.md)) |
| `launchctl kickstart -k gui/$(id -u)/local.mactouch` | Restart MacTouch |
| `tail -f ~/Library/Logs/MacTouch.log` | Follow the log; taps, drags, scrolls and zooms are logged |
| `./uninstall.sh` | Stop and remove MacTouch |

## Troubleshooting

**Touch does nothing.** Open the menu and read the status lines. If no touch screen is connected,
check the USB cable: touch needs a data connection, not just video. If a permission is missing,
enable it. A single-touch screen that is not paired yet stays with macOS; pair it from
**Touchscreens**.

**Touch keeps dropping out (CX158).** Check the kernel log for USB errors:
`log show --last 5m --predicate 'process == "kernel" AND eventMessage CONTAINS "transaction error"'`.
Many errors mean a bad USB 2.0 link: the monitor's built-in hub keeps being reset and takes the
touch controller with it. On the reference setup, moving the cable to the Mac's other USB-C port
stopped the errors; a different cable or powering the monitor separately can help too. The CX158's
controller then comes up in digitizer mode, which MacTouch reads directly.

**The CX158 works with one finger only.** Its controller picks a mode each time it powers up. It
stays in digitizer mode (multi-touch) only if macOS's own HID driver never gets its touch interface;
otherwise it switches to mouse mode within a second, and only removing power changes that. MacTouch
takes the USB device from macOS within a few milliseconds of it appearing and sets it up without
drivers for its interfaces, which kept digitizer mode on 4 of 5 power-ups in testing; MacTouch
restarts keep it too. If the menu says single touch, unplug the monitor for about 15 seconds and
plug it back in. (Software cannot power-cycle it: macOS does not give up the monitor's USB hub.)

**Touches land mirrored or rotated.** MacTouch follows the display rotation set in System Settings →
Displays. 0° and 180° are tested; for 90° or 270°, or a panel mounted differently, use `--swap`,
`--flip-x` or `--flip-y`.

**Touches are offset.** Run **Calibrate Touch…**.

**Part of the screen is dead, or touches there jump to the nearest edge or keep dropping out.**
Unplug the monitor, wait 15 s and plug it back in without touching the screen. A capacitive panel
measures its untouched state when it powers up; a hand or cable on it at that moment leaves that area
misread until the next power-up. `MacTouch --probe --raw` shows the raw positions, if it persists.
Calibrate again afterwards, as calibration taps in that area were misread too.

**Touches go to the wrong display.** Choose **Touchscreens ▸ name ▸ Pair with Display…** and touch
the screen. The status line names the display each screen uses; `--check` lists vendor and model.

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
| `--vid=`, `--pid=` | `0x222a`, any | USB IDs of the touch controller whose profile `--save` changes |
| `--display=VENDOR:MODEL` | paired by touch | CoreGraphics vendor and model (optionally `:serial`) of its display, or `main` |
| `--flip-x`, `--flip-y`, `--swap` | off | Axis fixes applied after the display rotation |
| `--cal=ax,bx,ay,by[,x0,x1,y0,y1]` | none | Calibration as `touched = a × target + b`, in fractions of the touch panel's own axes (before rotation), so it holds in every rotation, optionally with the touched values 2% from each edge; set by the wizard |
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
| `--ink-predict=` | `8` | How far ahead, in ms, whiteboard lines are drawn past the finger (0 to 50; 0 is off) |
| `--piano-octaves=` | `3` | Music piano size, 1 to 6 octaves |
| `--piano-sound=` | `0` | Music piano General MIDI program; the bar lists the built-in choices |
| `--auto-keyboard` | on | Expand the minimized Accessibility Keyboard for text fields focused by touch |
| `--keep-keyboard` | on | Restore the Accessibility Keyboard's position after display sleep |
| `--keyboard-follows-touch` | on | Turn the Accessibility Keyboard off while no touch screen is connected, and back on with one |
| `--swipes=` | `3` | Multi-finger swipes with three or four fingers (`3`), four only (`4`), or `off` |

App names are window owner names, usually the name shown in Activity Monitor.

`--vid`, `--pid`, `--display`, the axis fixes, `--cal`, `--one-finger-scroll` and `--hold` are
screen settings: `--save` stores them in the profile for `--vid`/`--pid` (made if missing), or in the
only profile when no `--vid` is given. Settings from 3.0 and older become the first screen's profile.

Other touch screens work if their controller is a HID digitizer with Finger collections (usage page
`0x0D`, usage `0x22`) holding tip switch and X/Y, or an absolute-position mouse (X/Y not relative,
plus a button). Interfaces without a driver need an entry in `Sources/KnownDevices.swift`; see
[CONTRIBUTING.md](CONTRIBUTING.md).

## Contributing

Support for more screens, reports of screens that work, and fixes are welcome. See
[CONTRIBUTING.md](CONTRIBUTING.md) for the code layout, testing, and adding a touch controller.

## Uninstall

```sh
./uninstall.sh
```

Then remove the MacTouch entries from Accessibility and Input Monitoring.

## License

MIT
