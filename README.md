[English](README.md) | [日本語](README.ja.md)

# mirne mobile

A macOS and iPadOS app for using a nasne (official firmware) on the local network: browse the program
guide, manage recording schedules, and watch recorded programs or live broadcasts on a Mac or an iPad.
The iPad version has the same screens as the Mac version.

The app's interface is in Japanese; the Japanese labels are shown in parentheses below.

## An unofficial app

**mirne mobile is an independent, unofficial app.** It is not affiliated with, endorsed by, or
certified by Sony Interactive Entertainment, Buffalo, the Digital Transmission Licensing
Administrator (DTLA), or any other standards organization or manufacturer. "nasne" and "DTCP-IP"
are trademarks of their respective owners.

The license of this source code does not grant any patent or trademark license relating to
DTCP-IP or other technologies, and it gives no warranty of non-infringement.

## Features

- **Program guide (番組表)**: shows the nasne's digital terrestrial program guide for 8 days, with station logos. Scheduled programs are marked. Click a program for its details and schedule a recording from there
- **Schedules (予約)**: list, create (by station and time, or from a program in the guide), change the quality of, and delete recording schedules. Overlapping schedules are checked before creating one. Each row starts with the station logo, and the selected schedule is shown in an information card
- **Recordings (録画)**: search, sort, and group recordings by title. Each row starts with the station logo, and the viewing state (unplayed, in progress, finished) is shown with a mark and a light row color. The selected recording is shown in a card with its information and buttons to play, protect, and delete it. The previous list appears at once and is brought up to date with the nasne in about a second
  - An unfinished recording resumes where you left off. The position is also saved on the nasne and shared with other Macs, iPads, and torne (can be turned off in Settings)
  - Recordings can be protected / unprotected and deleted
- **Playback**: plays DR, 3x (3倍), and mobile-quality recordings, including recordings still in progress
  - Captions, dual-mono audio (main, sub, main + sub), and audio track switching
  - Seeking, 10-second skip back / forward, jumping to the previous / next chapter (the chapters the nasne sets, marked on the position slider), switching quality while playing, and playback speed (1, 1.25, 1.5, 2x, with the pitch preserved)
  - Full screen, always on top, and back to the standard size
- **Live viewing (ライブ)**: watch what is on the air. Change stations from the menu in the controls, ↑↓, or the number keys. While the nasne is recording, live viewing starts on the station being recorded
- **Info (情報)**: shows the nasne itself, free HDD space, programs being recorded, notices, and schedules that failed to record
- **Also**: looks for the nasne again by itself when its address changes or when you switch networks. Remembers window positions and sizes. Keeps the display awake while playing, and stops playback when the Mac goes to sleep
- **iPad**: the same program guide, schedules, recordings, info, playback, and live viewing. Tap a recording or schedule to select it and show its card, and double-tap a recording to play it. Playback covers the whole screen; tap to show the controls, and double-tap the left or right half to go 10 seconds back or forward (recordings). Playback stops when the app goes to the background and resumes from the same position when you come back

## Installation

### Mac

Download `mirne-mobile-<version>.zip` from [Releases](https://github.com/EVAtiter/mirne-mobile/releases/latest),
unzip it, and move `mirne mobile.app` to the Applications folder. The app is notarized by Apple.

Or install it with [Homebrew](https://brew.sh/):

```bash
brew install --cask EVAtiter/tap/mirne-mobile
```

If Homebrew reports an "untrusted tap", trust the cask first and then install it again:

```bash
brew trust --cask evatiter/tap/mirne-mobile
```

### iPad

The iPad version is not on the App Store. Download `mirne-mobile-<version>.ipa` from
[Releases](https://github.com/EVAtiter/mirne-mobile/releases/latest). The IPA is not signed: sign and
install it yourself with a sideloading tool such as LiveContainer, AltStore, or SideStore.

The same Release also has the source code of FFmpeg that the iPad version includes
(`ffmpeg-<version>.tar.xz`). See [NOTICE](NOTICE).

## Usage

1. **Register your nasne**: on first launch the app looks for a nasne on the same network. If none is
   found, scan the network or enter the nasne's IP address (or its device description URL). If this
   Mac is not allowed by the nasne, allow it in the media server settings of nasne HOME
2. **Import credentials** (only for watching recordings and live broadcasts): in Settings (設定) →
   Credentials (資格情報（DTCP-IP）), choose the two files of a certificate and private key obtained from
   your own device (a `credentials.env` file also works). The program guide, schedules, and recording
   list work without credentials
3. **Watch**: switch between Program guide, Schedules, Recordings, and Info in the middle of the toolbar.
   Select a recording and press a play button in its card, or double-click its row or press Return. Start live viewing
   with Live (ライブ) in the toolbar or the button next to a station name in the program guide

Main keys in the viewer window:

| Key | Action |
| --- | --- |
| Space | Pause / resume |
| ← / → | 10 seconds back / forward (recordings) |
| Shift + ← / → | Previous / next chapter (recordings) |
| ↑ / ↓, number keys | Change station (live) |
| ⌘↑ / ⌘↓ | Volume |
| M | Mute |
| A | Switch audio |
| C | Show / hide captions |
| Q | Switch quality |
| S | Playback speed (recordings) |
| F | Full screen |
| T | Always on top |
| ⌘0 | Back to the standard size |

In the main window, ⌘1–⌘4 switch screens, ⌘R refreshes, and ⌘N creates a new schedule.

On the iPad:

- When you register a nasne, the app first asks for permission to use the local network, and then
  scans the network (the iPad version does not use SSDP). Allow it; if you denied it, allow
  mirne mobile in Settings → Privacy & Security → Local Network
- Import the credential files from the Files app
- In the playback screen, tap to show or hide the controls and close it with × at the top left. The
  volume follows the iPad's volume buttons. With a hardware keyboard, the keys above work, except F, T,
  and ⌘0
- With a hardware keyboard, ⌘1–⌘4, ⌘R, ⌘N, ⌘F (search recordings), ⌘L (live), and ⌘, (settings)
  work in the main screen

## About DTCP-IP credentials

Playing recordings and live broadcasts requires a DTCP-IP device credential pair (a DTLA certificate
and its device private key). **mirne mobile does not include any credentials.** Playback is enabled only
after you import your own pair, obtained from your own device, in the settings. The imported pair
is stored only in the Keychain of that Mac or iPad (not synced), and session keys are kept in memory
only. Decrypted content is never written to disk.

Whether obtaining and using such a pair is permitted under the applicable license and law is for
each user to judge. This repository does not tell you where to get one or how to extract it.

## Requirements

- A Mac with Apple silicon and macOS 15 or later, or an iPad with iPadOS 18 or later
- A nasne with the official firmware on the same local network

The iPad version was tested on an iPad Air with iPadOS 27.

Tested with a Buffalo nasne (system software 4.50). Support for the Sony Interactive Entertainment
nasne is based on the measurements of torne mobile HomeBrew edition (system software 2.60).

## Building

You need Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
./build.sh          # build the Debug configuration (./build.sh release for Release)
./build.sh test     # run the unit tests
```

The app is written to `build/symroot/<configuration>/mirne mobile.app`. It is ad-hoc signed by
default. To sign it with your own certificate, copy `Config/Local.xcconfig.example` to
`Config/Local.xcconfig` and edit it.

The iPad version is the `mirne-mobile-iOS` scheme. On the first build, `scripts/build-ffmpeg-ios.sh`
downloads FFmpeg from ffmpeg.org, checks its SHA-256, and builds the MPEG-2 video decoder as dynamic
frameworks (it takes a few minutes). `scripts/build-ipa.sh` makes the unsigned IPA in `build/ipa`.

## Acknowledgments

- [torne mobile HomeBrew edition](https://github.com/mar1mo-41414/TorneMobileHomeBrew) (mar1mo-41414, MIT):
  the communication with the nasne and the DTCP-IP implementation were ported to Swift from its measurements and code
- [pydtcpip](https://github.com/tsukumijima/pydtcpip) (tsukumi, MIT): the reference implementation that the DTCP-IP code of torne mobile HomeBrew edition is based on
- [mirne](https://github.com/EVAtiter/mirne) (Apache-2.0): the playback, program guide, and caption parts come from it
- [coax](https://github.com/Till0196/coax) (Till0196, Apache-2.0): the ARIB text and caption decoding derives from it, through mirne
- [FFmpeg](https://ffmpeg.org/) (LGPL-2.1): the iPad version decodes MPEG-2 video (DR recordings and live broadcasts) with it

See [NOTICE](NOTICE) for details.

## License

Apache License 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
