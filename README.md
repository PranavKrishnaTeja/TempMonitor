# TempMonitor

A small macOS menu bar app that monitors your Mac's temperatures, fans, power, usage, memory and battery, refreshing every 2 seconds, with 7-day history graphs and a built-in thermal stress test.

The menu bar shows labeled readings, e.g. `CPU 58°  GPU 56°` (switchable to CPU only or hottest part). Click it for three tabs:

- **Temps**: CPU, GPU, SSD, Battery and Power & Board temperatures, each with a 1-hour sparkline, plus an expandable list of every raw sensor.
- **System**:
  - Fan RPM against each fan's min/max.
  - Power draw (whole system, CPU, GPU, Neural Engine, memory).
  - CPU usage (performance vs efficiency cores) and GPU usage.
  - Memory used, pressure and swap.
  - macOS thermal state (shows whether the Mac is throttling).
  - Battery charge, live watts, health, cycle count and charger wattage.
- **Stress**: loads the CPU, GPU or both for 1–10 minutes. It then saves a report with peak/average temperatures, max fan speed and when the fans started, average/peak power, the worst thermal state, a GFLOPS score, and *sustained performance* (final minute vs first 30 s; below ~90% means throttling). It aborts automatically at 105 °C or a critical thermal state. The last 10 reports are kept.

Click any row to open its history graph: 1H / 6H / 24H / 7D ranges, average and peak lines, hover for exact values, and Now / Average / Peak stats. History is saved as 1-minute averages and peaks for 7 days in `~/Library/Application Support/TempMonitor/history.json`, and stress reports are saved next to it. History only records while the app is running.

## Requirements
- A Mac with Apple Silicon (M1 or later). Intel Macs are not supported.
- macOS 13 Ventura or later.
- Apple's command line developer tools (free). You don't need the full Xcode app.

## Install

All commands go in the **Terminal** app (Applications → Utilities → Terminal). Paste each block and press Return.

### 1. Install the developer tools (one time)
```bash
xcode-select --install
```
Click **Install** in the dialog that appears, and wait for it to finish (a few minutes). If it says the tools are already installed, skip ahead. Check that it worked:
```bash
swift --version
```
This should print a Swift version (5.9 or newer).

### 2. Get the code
Put the `TempMonitor` folder somewhere, e.g. your Desktop, and go into it:
```bash
cd ~/Desktop/TempMonitor
```
The folder must look like this. The app's code has to be inside `Sources/TempMonitor/`, or the build fails:
```
TempMonitor/
├── Package.swift
├── README.md
├── Icon/                  app icon and the script that draws it
├── scripts/test.sh        runs the tests
├── Sources/TempMonitor/
│   ├── App/               app entry point and MonitorStore (polls the sensors)
│   ├── Hardware/          sensor, SMC, power, CPU/memory and battery readers
│   ├── History/           7-day history storage and chart downsampling
│   ├── Model/             components, metrics and formatting
│   ├── Persistence/       JSON files in Application Support
│   ├── Stress/            stress test, load generator and reports
│   └── Views/             the SwiftUI screens
└── Tests/TempMonitorTests/
```
The app icon is `Icon/AppIcon.icns`. To change it, edit `Icon/make_icon.swift` and run `swift Icon/make_icon.swift`.

### 3. Build
```bash
swift build -c release
```
The first build takes a minute or two and ends with `Build complete!`. To try the app without installing it, run `.build/release/TempMonitor`; temperatures appear in the menu bar. Press Ctrl+C in Terminal to stop it.

### 4. Package it as an app
This wraps the program in a `TempMonitor.app` bundle that lives only in the menu bar, with no Dock icon:
```bash
rm -rf TempMonitor.app
mkdir -p TempMonitor.app/Contents/MacOS TempMonitor.app/Contents/Resources
cp .build/release/TempMonitor TempMonitor.app/Contents/MacOS/
cp Icon/AppIcon.icns TempMonitor.app/Contents/Resources/
cat > TempMonitor.app/Contents/Info.plist <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>TempMonitor</string>
  <key>CFBundleExecutable</key><string>TempMonitor</string>
  <key>CFBundleIdentifier</key><string>local.tempmonitor</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSUIElement</key><true/>
</dict></plist>
EOF
codesign --force --sign - TempMonitor.app
```
The last line signs the app locally so macOS will run it. Always sign *after* the bundle is complete.

### 5. Install and launch
```bash
rm -rf /Applications/TempMonitor.app
cp -R TempMonitor.app /Applications/
open /Applications/TempMonitor.app
```
A reading like `CPU 58°  GPU 56°` appears in the menu bar. Click it to open the app. No password or sudo is needed. To quit, click **Quit** at the bottom of the popup.

### 6. Start at login (optional)
Open **System Settings → General → Login Items**, click **+** under "Open at Login", and choose **TempMonitor** from Applications. This lets the 7-day history keep recording.

## Updating
After changing the code, repeat steps 3–5 (build, package, install). Step 5 replaces the old copy, so quit the running app first or run `pkill -x TempMonitor`. Your history and stress reports are kept.

## Uninstalling
```bash
pkill -x TempMonitor
rm -rf /Applications/TempMonitor.app
rm -rf ~/Library/Application\ Support/TempMonitor   # deletes history and stress reports
defaults delete local.tempmonitor                  # deletes settings (°C/°F, menu bar mode)
```
Also remove it from Login Items if you added it.

## Running the tests
```bash
./scripts/test.sh              # run all tests
./scripts/test.sh --coverage   # also print line coverage per file
```
Use the script rather than plain `swift test`. With only the Command Line Tools installed (no Xcode), `swift test` can't find the Swift Testing framework, and the script adds its location. Most tests use fakes and sample data. A few read this Mac's real sensors, and two briefly run the stress load, so the fans may spin up for a few seconds. Tests never touch your saved history or reports.

## Troubleshooting
- **`xcrun: error: invalid active developer path`**: the developer tools aren't installed. Do step 1.
- **Build error about `Sources/TempMonitor`** (e.g. "could not find source files"): the code isn't in `Sources/TempMonitor/`. Move it there (see step 2).
- **"TempMonitor can't be opened" / "Apple could not verify…"**: this happens when the app was copied from another Mac or downloaded, so macOS quarantines it. Don't run a copy you got from someone else; build it yourself on this Mac from the source (steps 3–5). Only if it's a copy you built yourself on another Mac can you clear the flag with `xattr -dr com.apple.quarantine /Applications/TempMonitor.app`.
- **Nothing appears in the menu bar**: on a crowded menu bar (especially on notched MacBooks), icons can be hidden behind the notch. Quit some other menu bar apps, or hold ⌘ and drag icons to make room. Check that it's running with `pgrep -l TempMonitor`.
- **"No sensors found" or a missing section**: the private Apple interfaces this app relies on may have changed in your macOS version, or your chip may use different sensor names (see Notes).

## Notes
- Everything runs without sudo, using private Apple interfaces (the same approach as Stats and macmon):
  - IOKit HID sensors for board, SSD and battery temperatures.
  - The SMC for CPU/GPU core temperatures, fan RPM and system power.
  - IOReport for CPU/GPU/ANE/DRAM power.
  These interfaces can change between macOS releases; any section that can't be read is hidden.
- CPU/GPU temperatures come from the SMC core sensors (`Tp…`/`Tg…` keys). The HID sensors named `PMU tdie…`/`PMU TP…` are power-management chip temperatures. They read ~30 °C cooler than the cores under load, so they're listed under Power & Board.
- Sensor keys were verified on an M1 Pro. The M2/M3 key lists come from other open-source monitors and haven't been tested here.
- On M1 Pro/Max the fans stay off (0 rpm, shown as "Off") until the chip is quite hot, often 85–90 °C.
- The stress test's GFLOPS figures are a synthetic, app-specific score for comparing runs on the same Mac, not a standard benchmark.
- Intel Macs are not supported.
