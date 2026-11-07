[English](README.md) | [日本語](README.ja.md)

# mirne

A macOS app for watching Japanese digital terrestrial television (ISDB-T) on a Mac
with a Sony CECH-ZD1 J (the terrestrial digital tuner for PlayStation).

- Tuner control is delegated to `coaxd` from [coax](https://github.com/Till0196/coax)
- Video and audio are played with the standard macOS frameworks (VideoToolbox, AudioToolbox and Metal)

## About conditional access (CAS)

**mirne does not include any conditional access (B-CAS) processing.** The video and audio of
Japanese digital terrestrial broadcasts are scrambled, so mirne alone cannot play them.

All mirne does is launch an external command specified in the settings (one that reads a TS
on standard input and writes a TS to standard output) and connect it to the stream. Whether
obtaining and using such a command is permitted under the card's license agreement and the
law is for each user to judge. This repository does not tell you where to get such a command
or how to configure one.

This is how mirne, coaxd and the external filter fit together:

```text
Sony CECH-ZD1 J
 │  USB
 ▼
coaxd (bundled with mirne; runs as a separate process)
 │  Unix socket (scrambled TS)
 ▼
mirne
 ├─ launches the external filter (the command set in Settings; provided by you)
 │   ├─ writes the received TS to its standard input and reads the TS back from its standard output
 │   └─ when enabled in Settings: launches coax pcsc and passes its socket path
 │      in the environment variable PCSCLITE_CSOCK_NAME
 ▼
video, audio, captions and program guide
```

## Features

- **Watching**: choose a station found by the channel scan from the sidebar, the number keys or ↑/↓. Switching to a subchannel on the same physical channel happens without retuning
- **Window**: resizes while keeping 16:9. Full screen and Always on Top. Remembers its position and size (and which display) and whether the sidebar is shown, and restores them the next time it opens
- **Captions**: drawn over the video with the colors, positions and sizes the broadcast specifies
- **Audio**: choose among dual mono (main, sub, main + sub) and multiple audio streams (secondary audio, audio description and so on). Stereo and 5.1ch
- **Program guide**: stations across, time down. Clicking a program tunes to its station. Opens in its own window or over the viewer window
- **Guide collection**: while the viewer window is closed, and while the program guide is shown over it, mirne tunes to each station in turn to collect the program guide
- **At launch**: tunes to the station you were watching last time (can be turned off in the settings)
- **Channel editing**: hide, reorder and rename stations
- **Other**: keeps the display awake while you are watching. Returns to the station you were watching after the tuner is unplugged and plugged back in, or after the Mac wakes from sleep

## Requirements

- A Mac with Apple silicon
- macOS 15 or later
- Sony CECH-ZD1 J

## Building

You need Xcode, [XcodeGen](https://github.com/yonaskolb/XcodeGen) and Go (to build coax).

```bash
scripts/fetch-coax.sh   # fetch coax and build coaxd and coax
./build.sh              # build the Debug configuration (./build.sh release for Release)
./build.sh test         # run the unit tests
```

The build puts the fetched `coaxd` and `coax` in `mirne.app/Contents/Helpers/`.
The app is written to `build/symroot/<configuration>/mirne.app`.

The app is ad-hoc signed by default. To sign it with your own certificate, copy
`Config/Local.xcconfig.example` to `Config/Local.xcconfig` and edit it.
With a Developer ID certificate and a notarytool profile name in `Config/Local.xcconfig`,
`scripts/notarize.sh` builds a notarized `build/notarized/mirne.app`.

The test TS files used by the playback measurement screen (opened only when the app is launched with environment variables such as `MIRNE_LAB_FILE`) can be generated as follows (requires ffmpeg).

```bash
scripts/make-fixtures.sh   # create test TS files in build/fixtures/
```

## Usage

1. Connect the tuner, launch mirne and choose 「チャンネルスキャン…」 (Channel Scan) from the 「チャンネル」 (Channel) menu to find stations
2. In Settings (⌘,), on the 「外部フィルタ」 (External Filter) tab, specify the command that the received TS is passed through
   - The command must read a TS from standard input and write a TS to standard output
   - **It must exit when standard input ends (EOF).** mirne restarts the command every time it tunes
   - With 「coax pcsc のソケットを渡す」 (pass the coax pcsc socket) turned on, mirne starts `coax pcsc` and passes its socket path in the environment variable `PCSCLITE_CSOCK_NAME`
3. Choose a station in the sidebar

The guide collection receives without the external filter, because the program information is not scrambled.
It asks coaxd for the tuner at a lower priority than watching, so it gives the tuner up when someone starts watching.

The app's menus and settings are in Japanese.

### How mirne handles the external filter

In addition to step 2 above, mirne handles the external filter as follows.

- **Launch**: The command is run with `/bin/sh -c`. The environment variables you set are added to mirne's environment, overriding any with the same name. GUI apps have a short `PATH`, so an absolute path is the reliable choice. Only standard input, output, and error are passed to the command; no other file descriptors are
- **Stopping**: mirne closes standard input. If the command has not exited after 1 second, mirne sends SIGTERM to its process group, then SIGKILL after another second (child processes the command started are stopped too)
- **When output stops**: If nothing arrives on standard output for 5 seconds, mirne treats the filter as stalled and retunes. It does the same when standard output ends (EOF) without mirne having stopped it. If reception ends in under 30 seconds 4 times in a row, mirne stops tuning and shows a message
- **Standard error**: The first 4 KB is shown on screen and in the log as the reason for the interruption. It may include things like the channel you were receiving, so take care when sharing logs

### Keys

| Key | Action |
| --- | --- |
| 1–9, 0, -, ^ | Choose the station on remote control key 1–12 (0 is 10, - is 11, ^ is 12) |
| ↑ / ↓ | Previous / next station |
| G / Shift+G | Program guide / program guide over the viewer window |
| F | Full screen |
| T | Always on Top |
| ⌘0 | Restore the default window size |
| C | Captions |
| I | Reception status |
| A | Switch audio |
| M | Mute |
| ⌘↑ / ⌘↓ | Volume |

### Where data is stored

The channel list and the program guide are kept in `~/Library/Application Support/mirne/`
(`channels.json` and `epg.sqlite`). Settings are in the app's UserDefaults (`com.slack-kingdom.mirne`).

## Documents

| Document | Contents |
| --- | --- |
| [RELEASE_NOTES.md](RELEASE_NOTES.md) | Changes for users |

The documents are written in Japanese.

## License

mirne is licensed under the Apache License 2.0 ([LICENSE](LICENSE)).
The decoding of program information text and the caption parsing are Swift ports of code from coax (Apache-2.0) ([NOTICE](NOTICE)).

Of coax, which is fetched at build time, `coaxd` is GPL-2.0-only and `coax` is Apache-2.0.
Neither is included in this repository.

Product and company names are used only to identify the supported hardware.
