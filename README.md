# AppsAudio

A macOS menu-bar mixer that sets the speaker volume of each app on its own, without changing what gets recorded.

Mute an app in AppsAudio and it goes quiet on your speakers only. The app keeps producing audio, so anything capturing it (ScreenCaptureKit, another audio tap, a screen recorder) still gets the full signal. That's the whole point: turn something down in your ears without dropping it from the recording.

## Status

Working and in daily use. [Download the DMG](https://github.com/Alyetama/AppsAudio/releases/latest/download/AppsAudio.dmg) or build from source below.

The app is unsigned — there is no Apple Developer ID behind it — so macOS blocks it on first open. Right-click AppsAudio in Applications, choose Open, then confirm. Tested on Apple silicon under macOS 26.5; there is no architecture restriction in the build, but it has not been run on Intel.

## How it works

macOS 14.4 added Core Audio process taps. When you lower or mute an app, AppsAudio:

1. Creates a muted tap on that app. This pulls its audio out of the output-device mix but leaves the source alone, so recorders are unaffected.
2. Re-renders that audio at your chosen volume through a private aggregate device wrapping whatever output you're using.

Apps sitting at 100% and unmuted are never tapped. They play untouched with no added latency. The engine only steps in once you actually move a slider.

## Build and install

```sh
./build_app.sh
cp -R build/AppsAudio.app /Applications/
open /Applications/AppsAudio.app
```

Needs macOS 14.4 or later. The build is ad-hoc signed with a stable identity, so macOS remembers the audio-capture permission between launches.

## First launch

AppsAudio lives in the menu bar as a small mixer-sliders icon. No Dock icon, no window.

The first time you mute or lower an app, macOS asks "AppsAudio wants to record this computer's audio." Click Allow. This is the system-audio-capture permission, separate from the microphone one. Volume and mute changes do nothing until you grant it.

## Checking that recording still works

1. Play music in Spotify or a browser.
2. Start something that records that app's audio (RecordAudio, or QuickTime screen recording with system audio).
3. Mute the app in AppsAudio. It goes silent on your speakers.
4. Stop the recording. The app's audio is still there at full volume.

## Notes

- Per-app settings are saved under the owning app's bundle ID and reapplied when it plays again. Apps that play through helper processes (Electron apps like Vesktop or Discord) are saved under the parent app, so all their helpers share one setting.
- Switch output device (speakers to headphones) and the routing rebuilds itself.
- If AppsAudio quits or crashes, macOS drops the taps, so nothing is ever left stuck on mute.
