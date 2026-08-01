# FanMac contributor guide

## Project overview

FanMac is a native Swift menu-bar app for Apple Silicon MacBooks running macOS 13 or newer. It reads the CPU Core Average sensor through AppleSMC, computes a temperature-based fan curve, and applies fan targets through a narrowly scoped privileged launchd helper. A minimum speed of `0%` means that macOS keeps automatic control below the boost temperature; FanMac must never write a zero-RPM target.

The project intentionally supports `arm64` only. Hardware-facing changes should be treated as safety-sensitive: losing telemetry, exceeding firmware limits, or failing to verify control release must leave the fans under macOS control whenever possible.

## Repository layout

- `Sources/FanMac/` — SwiftUI/AppKit menu-bar UI and presentation state.
- `Sources/FanMacCore/` — control model, curve math, backend abstractions, AppleSMC access, and privileged-helper client.
- `Sources/SMCBridge/` — small C bridge for the private AppleSMC IOKit interface.
- `Sources/FanMacHelper/` — root launchd/XPC helper that performs privileged fan writes and restores automatic control when its client disconnects.
- `Tests/FanMacTests/` — unit tests for curve math and model safety behavior, using a fake backend.
- `AppBundle/` — app/helper metadata and launchd configuration used by packaging.
- `scripts/package-app.sh` — builds, assembles, and signs `dist/FanMac.app`.

## Common commands

Run the tests and arm64 build from the repository root:

```sh
swift test
swift build --arch arm64
```

Build and open a local app bundle:

```sh
./scripts/package-app.sh
open dist/FanMac.app
```

For a distribution-capable helper installation, provide both `FANMAC_SIGN_IDENTITY` and `FANMAC_TEAM_ID` when running the packaging script. Ad-hoc signing is intended for local development only.

## Development conventions

- Keep curve calculations and control-state transitions in `FanMacCore` so they remain testable without AppleSMC hardware.
- Extend `FanControlBackend` and the fake backend in tests when adding control behavior; avoid coupling model tests to real hardware.
- Clamp every manual target to the minimum and maximum RPM reported by SMC. Reject invalid telemetry rather than inventing a target.
- Preserve the fail-safe paths: missing CPU or fan-limit telemetry releases system control, failed writes attempt release, and release operations verify that manual mode has ended.
- Keep the privileged helper limited to the operations required for fan control and keep its bundle identifiers, signing requirements, and authorization metadata synchronized across `AppBundle/` and Swift code.
- Update or add tests for any curve or safety-state change. Do not assume a development Mac exposes the same SMC keys as another Apple Silicon model.
- Do not commit generated `.build/`, `.build-helper/`, or `dist/` contents.

