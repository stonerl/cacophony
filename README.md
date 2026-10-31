# Cacophony

System-wide AirPlay 2 output for macOS. Cacophony installs a virtual CoreAudio
output device named **Cacophony** and streams everything played through it to
one or more AirPlay 2 speakers, in sync.

Cacophony operates on the Mac's system output as a whole, not on individual
apps. Audio from all apps using the selected output is mixed together.

macOS only lets the system output go to a single AirPlay speaker. Cacophony
adds the missing output device and uses macOS's own AirPlay 2 engine for the
multi-room part.

## Requirements

- macOS 26 or later
- `Cacophony.app` in `/Applications`
- Administrator approval for driver installation
- AirPlay 2-compatible speakers on the same network

For development:

- Xcode 27 / Swift 6
- CMake 3.28 or newer
- Git submodules

## Install

1. Download `Cacophony-1.0.0.zip`.
2. Move `Cacophony.app` to `/Applications`.
3. Launch Cacophony.
4. When prompted, click **Install** to install the audio driver.
5. Approve the background helper in **System Settings → General → Login Items & Extensions** if prompted.
6. Click the Cacophony menu bar icon and select your AirPlay speakers.

If you choose **Later**, you can install the driver from the right-click menu.

Cacophony must run from `/Applications` for the SMAppService helper and Launch
at Login to work reliably. If launched elsewhere, it shows a warning and quits.

## Use

Left-click the Cacophony menu bar icon to open the audio panel. Right-click or
Control-click it to open the menu for driver management, Launch at Login, and
Quit.

1. Click the AirPlay icon beside the status line and select one or more AirPlay 2 speakers. The system picker handles pairing and multi-room grouping.
2. Selecting speakers automatically makes Cacophony the system output. Deselecting all speakers restores the previous output. You can still choose another output manually while speakers remain selected.
3. Play audio. The panel shows the selected speakers and per-speaker volume.

Launch at Login is enabled on first launch and can be changed from the
right-click menu. Quitting Cacophony restores the previous system output when
Cacophony is current.

## Driver management

The driver is installed and removed entirely from the app; there are no CMake
or terminal driver install targets.

- **Install Driver…** – installs or updates the bundled driver.
- **Uninstall Driver…** – removes the driver and unregisters the helper.
- Installing or updating the driver briefly restarts Core Audio.

## Uninstall

1. Right-click the Cacophony menu bar icon and choose **Uninstall Driver…**.
2. Disable **Launch at Login** from the same menu.
3. Quit Cacophony.
4. Remove `Cacophony.app` from `/Applications`.

## Build

```sh
git submodule update --init --recursive
make app
make run
```

`make run` launches the development build with the `/Applications` guard
disabled. To launch the built app normally, copy it to `/Applications` first.

The app and driver version come from the root `VERSION` file.

The `app` target builds the Swift app, builds and signs the driver, assembles
`Cacophony.app`, embeds the driver, and signs the app. To use a Developer ID
certificate, configure with:

```sh
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release \
  -DCODESIGN_ID="Developer ID Application: Your Name (TEAMID)"
cmake --build build --target app
```

For development, launch the development build with `make run`. The in-app
driver installer requires a notarized app; use the notarized build when testing
helper approval or driver installation.

## Make targets

A thin `Makefile` wraps the CMake targets for editors that discover Makefiles:

```sh
make configure
make app
make driver
make icon
make notarize
make run
make distclean
```

`make clean` removes the CMake build directory. `make distclean` removes both
the CMake and SwiftPM build artifacts.

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

Then configure and notarize:

```sh
make notarize
```

The notarize target rebuilds the app, signs it with a secure timestamp and
hardened runtime, submits it, staples the ticket, and writes
`build/Cacophony-<version>.zip`. `build/Cacophony.zip` is the temporary
notarization upload and is not the distribution artifact.

Credentials stay in the keychain, not in the repository.

## Architecture

```text
Apps → CacophonyAudio.driver (CoreAudio HAL plugin, in coreaudiod)
        │ localhost UDP, 48 kHz stereo Float32, sequence + timestamps
        ▼
   Cacophony.app (menu bar helper)
        ├─ ring buffer
        └─ AVSampleBufferAudioRenderer
              └─ private AVOutputContext → airplayd → AirPlay 2 group
```

- **Driver** – a CoreAudio AudioServerPlugIn built with
  [libASPL](https://github.com/gavv/libASPL). It publishes a 48 kHz, stereo,
  Float32 output device and sends the mixed output to `127.0.0.1:47833`.
- **App** – receives the PCM, buffers it, and feeds an
  `AVSampleBufferAudioRenderer` attached to a private `AVOutputContext`.
  `airplayd` owns the AirPlay 2 session, buffering, pairing, and multi-room
  synchronization.
- **Latency** – the app holds the stream 0.5 s behind the driver, and the
  driver reports that as stream latency so players can delay video. Device
  latency would not work: the AirPlay engine adds the default output's
  device latency to the speakers' delay, which doubles it.
- **Speaker picker** – `AVRoutePickerView` plus the private
  `setOutputContextID:` SPI. The picker runs in Apple's entitled
  `AirPlayUIAgent`; that is how an unentitled app can select HomePods.

The protocol header lives in `Sources/CacophonyProtocol/include/CacophonyProtocol.h`.

## Troubleshooting

- **Cacophony quits immediately** – move `Cacophony.app` to `/Applications` and launch it again.
- **Driver installation fails** – approve Cacophony in **System Settings → General → Login Items & Extensions**, then retry from the right-click menu.
- **No speakers are listed** – open the audio panel, click the AirPlay picker, and check that the speakers are on the same network.
- **The speaker picker keeps spinning** – close and reopen the picker. Cacophony resets stale picker state automatically.
- **No audio** – make sure Cacophony is selected as the system output and at least one speaker is selected.

## Limitations

- Uses private `AVOutputContext` APIs and route-picker SPI; may break on future macOS releases.
- Audio plays about half a second late. Cacophony reports the delay to macOS, so video players that account for output latency (Chrome, AVFoundation-based players) stay in sync, but games and other interactive audio lag.
- Speaker selections cannot be restored programmatically; choose speakers again after restarting Cacophony. Keeping Cacophony running avoids this.
- If Cacophony is the system output and the app is not running, audio is silent. Launch at Login is enabled by default; quit from the menu so the previous output is restored.
- The driver installs into `/Library/Audio/Plug-Ins/HAL` and requires administrator approval. Installing or updating it restarts Core Audio.

## Credits

Cacophony is based on [Airlift](https://github.com/jgarms/airlift) (MIT) for the
AirPlay 2 routing and speaker picker, and uses
[libASPL](https://github.com/gavv/libASPL) (MIT) for the HAL driver. See
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

AirPlay, HomePod, and macOS are trademarks of Apple Inc.

## License

Cacophony is released under the MIT License. See [LICENSE](LICENSE).
