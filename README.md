# FanMac

FanMac is a native macOS menu-bar app for Apple Silicon MacBooks. It reads one sensor—**CPU Core Average**—and uses a simple temperature curve to control the fans. You choose a minimum fan speed, a temperature at which boosting begins, and a temperature at which the fans reach full speed.

FanMac is intentionally conservative: every manual target is clamped to the limits reported by AppleSMC, and the app returns control to macOS when safety telemetry or fan writes cannot be verified.

<img width="862" height="1340" alt="image" src="https://github.com/user-attachments/assets/d0231cd8-16c3-4709-a8c3-51a17c34fcbf" />


## Requirements

- Apple Silicon MacBook (`arm64`)
- macOS 13 or newer
- Xcode Command Line Tools
- Administrator access the first time fan control is enabled

Intel Macs are not supported. FanMac uses the private AppleSMC IOKit service and depends on the sensors and fan controls exposed by each Apple Silicon model.

## Install

There are two ways to install FanMac: download the free GitHub release, or build the app yourself.

### Free GitHub release

The free release is ad-hoc signed and **not notarized** because notarization requires the paid Apple Developer Program. It is suitable for personal use and testing on Apple Silicon Macs, but macOS will require a one-time manual approval.

1. Download `FanMac-<version>.zip` from the repository’s [GitHub Releases](https://github.com/catalinstanciu92/fanmacmac/releases) page.
2. Optionally verify the checksum shown in the matching `.sha256` file:

   ```sh
   shasum -a 256 FanMac-<version>.zip
   ```

3. Open the ZIP and drag `FanMac.app` to `/Applications`.
4. In Finder, Control-click `FanMac.app`, choose **Open**, then choose **Open** again in the warning dialog. This approval is needed because the free build is not notarized.
5. Open FanMac from `/Applications`. It runs in the menu bar; there is no regular application window.
6. Turn on **Enable fan control** and approve the administrator authorization prompt to install the privileged helper.

If macOS does not show the second **Open** button, go to **System Settings → Privacy & Security** and choose **Open Anyway** for FanMac. Do not disable Gatekeeper globally. If helper installation fails, use **Restore system control**, quit FanMac, and report the error with the Mac model and macOS version.

### Build from source

FanMac must be launched as an `.app` bundle; launching the raw executable from `.build` cannot install the privileged helper.

#### 1. Build the app

From the repository root, run:

```sh
./scripts/package-app.sh
```

The script builds the arm64 app and privileged helper, assembles them into `dist/FanMac.app`, and applies an ad-hoc signature suitable for local use.

#### 2. Launch FanMac

You can run the app directly from the build output:

```sh
open dist/FanMac.app
```

For everyday use, drag `dist/FanMac.app` to `/Applications` in Finder and launch it from there. FanMac must be launched as an `.app` bundle; launching the raw executable from `.build` cannot install the privileged helper.

#### 3. Approve the privileged helper

The first time you turn on the **Enable fan control** switch:

1. macOS shows an administrator authorization dialog.
2. Approve it with an administrator account.
3. FanMac installs its narrowly scoped helper, `com.fanmac.helper`.

The helper performs only the privileged fan write and release operations. If authorization is cancelled or installation fails, FanMac leaves the switch off and does not apply a fan curve.

#### Signed builds

Ad-hoc signing is convenient for local development. For a build that can be installed more reliably or distributed to other Macs, sign both the app and helper with an Apple signing identity:

```sh
FANMAC_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
FANMAC_TEAM_ID="TEAMID" \
./scripts/package-app.sh
```

`FANMAC_TEAM_ID` is required whenever `FANMAC_SIGN_IDENTITY` is set.

## Use FanMac

### Enable the curve

1. Open the FanMac icon in the menu bar.
2. Check the CPU temperature and fan telemetry shown in the panel.
3. Turn on **Enable fan control**.
4. Adjust the curve settings if needed.

The panel shows the current CPU Core Average, a short temperature history, and each fan’s current and target RPM. Settings are saved automatically.

### Configure the curve

Open the control-curve settings to adjust:

- **Minimum speed** — the fan floor from `0%` to `70%`.
- **Begin boost** — the temperature where FanMac starts increasing above the floor.
- **Full speed** — the temperature where FanMac reaches the fan’s maximum safe RPM.

When the minimum is `0%`, FanMac leaves the fans under macOS automatic control at or below the boost temperature, then takes manual control only while the CPU is above that threshold. FanMac never writes a zero-RPM target.

When the minimum is greater than `0%`, FanMac maintains that floor and ramps linearly between the boost and full-speed temperatures. Targets are capped at each fan’s AppleSMC-reported minimum and maximum RPM.

### Restore macOS control

To stop the curve, turn off **Enable fan control** or choose **Restore system control**. FanMac also attempts to restore macOS control when it quits. The privileged helper treats the app connection as a lease and releases manual control if FanMac crashes or disconnects.

If the panel reports an error, keep FanMac open and use **Restore system control** again. Do not continue using a manual curve until the panel confirms that system control has been restored.

## Safety behavior and limitations

- FanMac uses only the CPU Core Average input; it does not build a curve from GPU, package, or other sensors.
- Manual targets are clamped to the minimum and maximum RPM reported by AppleSMC.
- Invalid or missing CPU, fan-count, or fan-limit telemetry disables the curve and attempts to restore macOS control.
- A failed target write immediately attempts to restore macOS control.
- FanMac verifies that manual mode has ended before presenting system control as restored.
- Apple Silicon firmware may gate fan writes through its thermal manager, and SMC keys can vary between Mac models.
- The app does not include Intel SMC fallbacks.

## Troubleshooting

### “Hardware unavailable” or “No fan controller”

Confirm that the Mac is Apple Silicon and that macOS exposes a controllable fan through AppleSMC. Some hardware or firmware revisions may expose a different set of sensors or no controllable fan at all.

### The helper cannot be installed

Make sure you launched `FanMac.app`, not the raw binary, and that you approved the administrator prompt. For distribution builds, use a valid Apple signing identity and matching team ID. Rebuild the app bundle after changing either bundle metadata or signing settings.

### Fan control remains enabled after a failed operation

This indicates that FanMac could not verify that manual mode ended. Leave the app running, use **Restore system control**, and wait for the fan rows to report system control before quitting or removing the app.

## Build and test from source

Run the unit tests and build the native arm64 executable with Swift Package Manager:

```sh
swift test
swift build --arch arm64
```

The packaging script builds the release app and helper:

```sh
./scripts/package-app.sh
```

The tests cover the control curve, SMC-limit clamping, telemetry failures, authorization failures, manual-mode recovery, and restoration of macOS control. See [AGENTS.md](AGENTS.md) for contributor guidance and repository conventions.
