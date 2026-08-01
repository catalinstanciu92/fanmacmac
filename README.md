# FanMac

FanMac is a small native macOS menu-bar app for Apple Silicon MacBooks. It uses one input only: **CPU Core Average**. A simple curve keeps the fans at a user-set floor, begins increasing speed at a chosen temperature, and reaches full speed at a second temperature. A minimum of `0%` means macOS automatic control below the boost threshold; FanMac never requests zero RPM.

## Build

Requirements:

- Apple Silicon Mac
- macOS 13 or newer
- Xcode command-line tools

Run the unit tests and build the native arm64 executable:

```sh
swift test
swift build --arch arm64
```

Package a menu-bar `.app`:

```sh
./scripts/package-app.sh
open dist/FanMac.app
```

On first use, click the FanMac switch to enable fan control. macOS displays its administrator authorization dialog and installs the bundled privileged helper. No Terminal or `sudo` command is required.

For a reliably installable development or distribution build, sign both the app and helper with an Apple signing identity:

```sh
FANMAC_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
FANMAC_TEAM_ID="TEAMID" \
./scripts/package-app.sh
```

## Hardware note

FanMac talks to the private AppleSMC IOKit service to read the CPU sensor and fan telemetry. On Apple Silicon, fan writes are privileged and can also be gated by the firmware thermal manager. The bundled launchd helper runs only the narrowly scoped fan write/release operations as root. The switch remains off if authorization or installation fails, and FanMac verifies that manual mode has ended before showing system control as restored.

The app intentionally targets only `arm64` and does not include Intel SMC fallbacks.

## Safety behavior

- Every manual target is clamped to the minimum and maximum RPM reported by AppleSMC.
- Losing CPU or fan-limit telemetry restores macOS control and disables the curve.
- A failed target write immediately attempts to restore macOS control.
- Turning the switch off or quitting restores and verifies system control.
- The privileged helper treats the app connection as a lease and restores macOS control if FanMac crashes or disconnects.
