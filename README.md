# Cacophony

System-wide AirPlay 2 output for macOS. Cacophony installs a virtual CoreAudio
output device named **Cacophony** and streams everything played to it to one or
more AirPlay 2 speakers, in sync.

macOS only lets the system output go to a single AirPlay speaker. Cacophony
adds the missing output device and uses macOS's own AirPlay 2 engine for the
multi-room part.

## Requirements

- macOS 26
- Xcode 27 / Swift 6
- CMake 3.28 or newer
- Admin rights to install the HAL driver

## Build

```sh
git submodule update --init --recursive
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build --target app
open build/Cacophony.app
```

The `app` target builds the Swift app, builds and signs the driver, assembles
`Cacophony.app`, embeds the driver, and signs the app. To use a Developer ID
certificate, configure with:

```sh
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release \
  -DCODESIGN_ID="Developer ID Application: Your Name (TEAMID)"
cmake --build build --target app
```

## Make targets

A thin `Makefile` wraps the CMake targets for editors that discover Makefiles:

```sh
make configure
make app
make notarize
make run
```

For local signing settings, create an ignored `Makefile.local`:

```make
CODESIGN_ID = Developer ID Application: Your Name (TEAMID)
NOTARY_PROFILE = cacophony-notary
```

## Notarized build

Notarization requires a Developer ID Application certificate and a
`notarytool` keychain profile. Create the profile once with an app-specific
password from appleid.apple.com:

```sh
xcrun notarytool store-credentials cacophony-notary \
  --apple-id "you@example.com" \
  --team-id "TEAMID" \
  --password "app-specific-password"
```

Then configure and build:

```sh
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release \
  -DCODESIGN_ID="Developer ID Application: Your Name (TEAMID)" \
  -DNOTARY_PROFILE=cacophony-notary
cmake --build build --target notarize
```

The `notarize` target re-signs the embedded driver and app with a secure
timestamp and hardened runtime, submits a zip, staples the ticket, and writes
`build/Cacophony-0.1.0.zip`. Credentials stay in the keychain, not in the
repository.

## Install the driver

Right-click or Control-click the Cacophony menu bar icon and choose
**Install Driver…**. Cacophony registers a background helper; if macOS asks,
approve Cacophony in System Settings > General > Login Items & Extensions. Core
Audio restarts, so audio stops briefly. Cacophony detects the device
automatically; no app restart is needed.

The SMAppService helper is most reliable when `Cacophony.app` is in
`/Applications`. Apps containing LaunchDaemons must be notarized, so build the
notarized package before testing the in-app installer.

## Use

1. Install the driver.
2. Click the Cacophony menu bar icon, then click the AirPlay icon beside the
   status line. Select one or several AirPlay 2 speakers. The list is the
   system AirPlay picker, so pairing and multi-room grouping are handled by
   macOS.
3. Selecting speakers automatically makes Cacophony the system output.
   Deselecting all speakers restores the previous output. While speakers stay
   selected, you can still choose another output manually.
4. Play audio. The panel shows the selected speakers and per-speaker volume.

Quitting Cacophony restores the previous system output when Cacophony is current.
Cacophony enables **Launch at Login** on first launch; right-click or
Control-click the menu bar icon to change it.

The menu also contains the driver actions and **Quit Cacophony**.

## Architecture

```
Apps → CacophonyAudio.driver (CoreAudio HAL plugin, in coreaudiod)
        │ localhost UDP, 48 kHz stereo Float32, sequence + timestamps
        ▼
   Cacophony.app (menu bar helper)
        ├─ ring buffer
        └─ AVSampleBufferAudioRenderer
              └─ private AVOutputContext → airplayd → AirPlay 2 group
```

- **Driver** — a CoreAudio AudioServerPlugIn built with
  [libASPL](https://github.com/gavv/libASPL). It publishes a 48 kHz, stereo,
  Float32 output device and sends the mixed output to `127.0.0.1:47833`.
- **Helper** — receives the PCM, buffers it, and feeds an
  `AVSampleBufferAudioRenderer` attached to a private `AVOutputContext`.
  `airplayd` owns the AirPlay 2 session, buffering, pairing, and multi-room
  synchronization.
- **Speaker picker** — `AVRoutePickerView` plus the private
  `setOutputContextID:` SPI. The picker runs in Apple's entitled
  `AirPlayUIAgent`; that is how an unentitled app can select HomePods.

The protocol header lives in `Sources/CacophonyProtocol/include/CacophonyProtocol.h`.

## Limitations

- Uses private API (`AVOutputContext`, route-picker SPI). It is for personal
  use, not the App Store, and can break on macOS updates.
- Speaker selections cannot be restored programmatically. After restarting
  Cacophony, choose speakers again. Keeping Cacophony running avoids this.
- AirPlay buffers about two seconds. Music is fine; video and games will be out
  of sync.
- If Cacophony is the system output and the helper is not running, audio is
  silent. Launch at Login is enabled by default; quit from the menu so the
  previous output is restored.
- The driver installs into `/Library/Audio/Plug-Ins/HAL` and requires admin
  rights. Installing or updating it restarts Core Audio.

## Why not an AUv3 plug-in?

This project started from an AUv3 skeleton, but AUv3 plug-ins run inside a host
app and never become system output devices. A system output device must be a
CoreAudio HAL driver. The AUv3 extension target is not used.

## Credits

Cacophony is based on [Airlift](https://github.com/jgarms/airlift) (MIT) for the
AirPlay 2 routing and speaker picker, and uses
[libASPL](https://github.com/gavv/libASPL) (MIT) for the HAL driver. See
`THIRD_PARTY_NOTICES.md`.

AirPlay, HomePod, and macOS are trademarks of Apple Inc.
