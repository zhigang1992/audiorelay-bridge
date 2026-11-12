# AudioRelay Bridge

A small macOS menu-bar app that plays **BlackHole 2ch** through your Mac’s selected headphones or speakers. Built to work around Bluetooth playback failures in AudioRelay’s Mac player when the source and output sample rates differ.

AudioRelay Bridge is an independent community project, not affiliated with AudioRelay or BlackHole.

## What it does

- Follows the output you choose in the macOS Sound menu, including Bluetooth headphones.
- Converts sample rates without asking your headphones to change their hardware rate.
- Reconnects when devices change and waits when a headset is using its call connection.
- Shows connection status in a native menu-bar app and setup window.
- Offers **Pause / Resume**, **Quit**, and optional **Launch at Login**.
- Runs locally, with no accounts, analytics, recording, or network audio transmission.

## Requirements

- macOS 13 Ventura or newer; Apple Silicon or Intel.
- [BlackHole 2ch](https://existential.audio/blackhole/) installed separately.
- [AudioRelay](https://audiorelay.net/) or another app that can play into BlackHole.

BlackHole and AudioRelay are not included in this repository or app bundle.

## Build and install

Install Xcode or Apple’s Command Line Tools with a Swift 5.9+ toolchain, then:

```sh
git clone https://github.com/zhigang1992/audiorelay-bridge.git
cd audiorelay-bridge
./scripts/build.sh
open dist
```

Drag **AudioRelay Bridge.app** into your **Applications** folder, then open it. The headphone icon appears in the menu bar. The setup window opens on first launch; click the menu-bar icon to open it again.

The default build is for your Mac’s architecture and is ad-hoc signed. For a universal app:

```sh
UNIVERSAL=1 ./scripts/build.sh
```

For a stable signing identity, use your own certificate from Keychain:

```sh
CODE_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./scripts/build.sh
```

Ad-hoc signing is suitable for local builds. Rebuilding can cause macOS to ask for microphone access again. A Developer ID signature alone is not notarization: public downloads need a separate notarization and stapling step. CI artifacts are ad-hoc signed development builds, not notarized releases.

## Set up audio

1. Install **BlackHole 2ch** and restart if its installer asks.
2. Open AudioRelay Bridge and allow microphone access. macOS classifies reading a virtual audio input as microphone access; the bridge reads BlackHole, not your physical microphone.
3. In **AudioRelay**, set the playback device to **BlackHole 2ch**.
4. In your Mac’s **Sound menu**, choose headphones or speakers. Keep that output off BlackHole to avoid a loop.
5. Play audio through AudioRelay.

For Bluetooth music quality, use the built-in Mac microphone or a separate microphone. Selecting the headset microphone can switch the headset to a low-rate call connection; the bridge waits for the music connection to return.

The bridge adds roughly 200 ms of initial buffering at common sample rates (less at very high rates) on top of AudioRelay and Bluetooth latency. It is intended for listening, not low-latency monitoring.

## App controls

- **Open AudioRelay Bridge…** shows status, setup instructions, and controls. Closing this window keeps the bridge running in the menu bar.
- **Pause Bridge** closes the audio streams without quitting. **Resume Bridge** reconnects. Pause applies to the current app session.
- **Launch at Login** uses macOS’s native login-item service. It is off by default. Keep the app in Applications before enabling it. If macOS requires approval, open System Settings → General → Login Items. A mixed checkbox means approval is pending; click it to cancel the pending registration.
- **Quit AudioRelay Bridge** stops audio and exits. There is no keep-alive daemon to reopen it. If Launch at Login is enabled, it starts at your next sign-in; quitting does not change that preference.

## Troubleshooting

**Waiting for BlackHole 2ch:** Install the 2-channel version. The app deliberately does not fall back to a physical microphone.

**Microphone access is off:** Enable AudioRelay Bridge in System Settings → Privacy & Security → Microphone, then reopen the app if requested.

**Bridge active but silent:** “Active” means the audio devices are open, not that AudioRelay is sending non-silent samples. Check that AudioRelay is connected, playing, and targeting BlackHole 2ch. Also check volume on the source and Mac.

**Waiting for a music connection:** Stop using the Bluetooth headset as an input. Select the built-in microphone and reselect the headphones as output.

**Mac output includes BlackHole:** Select headphones or speakers directly in the Sound menu. The app refuses BlackHole and aggregate / Multi-Output Devices containing BlackHole to prevent an audio loop.

**Upgrading from the original script:** Unload your old bridge LaunchAgent and move its plist out of `~/Library/LaunchAgents` before opening this app. Otherwise two bridges may play simultaneously, and the old keep-alive job will restart when killed. Preserve the old install until the app works. This app does not modify existing launch agents automatically.

To inspect devices without opening any audio stream:

```sh
"/Applications/AudioRelay Bridge.app/Contents/MacOS/AudioRelayBridge" --list
```

## Development

```sh
swift test
./scripts/build.sh
```

`Package.swift` can also be opened in Xcode. Use the bundled `.app` for permission and Launch at Login testing; a bare Swift executable has no app identity for those features.

The audio engine uses separate CoreAudio HAL units for capture and playback, an in-memory ring buffer, and an `AudioConverter`. It follows default-output and device-format changes. Unit tests cover device selection, loop prevention, ring wrap/overflow, fault reporting, and shutdown guards. Real Bluetooth routing, microphone permission, sleep/wake, and login-item behavior also need testing on a Mac.

## Privacy

The app reads BlackHole’s virtual input into memory and plays it locally. It does not save audio or send it anywhere. Setup buttons open external websites or System Settings only when clicked. Device names and sample rates can appear in local diagnostic output; review diagnostics before sharing them. No credentials or machine-specific installation files are needed to build the project.

## License

MIT. See [LICENSE](LICENSE). BlackHole and AudioRelay have their own licenses and distribution terms.
