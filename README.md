[English](README.md) | [日本語](README.ja.md)

# mirne mobile

A macOS app for using a nasne (official firmware) on the local network: browse the program guide,
manage recording schedules, and watch recorded programs or live broadcasts on a Mac. An iOS / iPadOS
version is planned.

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
- **Schedules (予約)**: list, create (by station and time, or from a program in the guide), change the quality of, and delete recording schedules. Overlapping schedules are checked before creating one
- **Recordings (録画)**: search, sort, and group recordings by title. The previous list appears at once and is replaced when the nasne answers. Viewing state (unplayed, in progress, finished) is marked, and an unfinished recording resumes where you left off. Recordings can also be deleted
- **Playback**: plays DR, 3x (3倍), and mobile-quality recordings, including recordings still in progress
  - Captions, dual-mono audio (main, sub, main + sub), and audio track switching
  - Seeking, 10-second skip back / forward, switching quality while playing, and playback speed (1, 1.25, 1.5, 2x, with the pitch preserved)
  - Full screen, always on top, and back to the standard size
- **Live viewing (ライブ)**: watch what is on the air. Change stations from the menu in the controls, ↑↓, or the number keys
- **Info (情報)**: shows the nasne itself, free HDD space, programs being recorded, notices, and schedules that failed to record
- **Also**: looks for the nasne again by itself when its address changes or when you switch networks. Remembers window positions and sizes. Keeps the display awake while playing, and stops playback when the Mac goes to sleep

## Installation

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

## Usage

1. **Register your nasne**: on first launch the app looks for a nasne on the same network. If none is
   found, scan the network or enter the nasne's IP address (or its device description URL). If this
   Mac is not allowed by the nasne, allow it in the media server settings of nasne HOME
2. **Import credentials** (only for watching recordings and live broadcasts): in Settings (設定) →
   Credentials (資格情報（DTCP-IP）), choose the two files of a certificate and private key obtained from
   your own device (a `credentials.env` file also works). The program guide, schedules, and recording
   list work without credentials
3. **Watch**: switch between Program guide, Schedules, Recordings, and Info in the middle of the toolbar.
   Select a recording and press Play (再生), or double-click its row or press Return. Start live viewing
   with Live (ライブ) in the toolbar or the button next to a station name in the program guide

Main keys in the viewer window:

| Key | Action |
| --- | --- |
| Space | Pause / resume |
| ← / → | 10 seconds back / forward (recordings) |
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

## About DTCP-IP credentials

Playing recordings and live broadcasts requires a DTCP-IP device credential pair (a DTLA certificate
and its device private key). **mirne mobile does not include any credentials.** Playback is enabled only
after you import your own pair, obtained from your own device, in the settings. The imported pair
is stored only in the macOS Keychain (this Mac only, not synced), and session keys are kept in memory
only. Decrypted content is never written to disk.

Whether obtaining and using such a pair is permitted under the applicable license and law is for
each user to judge. This repository does not tell you where to get one or how to extract it.

## Requirements

- A Mac with Apple silicon
- macOS 15 or later
- A nasne with the official firmware on the same local network

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

## Acknowledgments

- [torne mobile HomeBrew edition](https://github.com/mar1mo-41414/TorneMobileHomeBrew) (mar1mo-41414, MIT):
  the communication with the nasne and the DTCP-IP implementation were ported to Swift from its measurements and code
- [pydtcpip](https://github.com/tsukumijima/pydtcpip) (tsukumi, MIT): the reference implementation that the DTCP-IP code of torne mobile HomeBrew edition is based on
- [mirne](https://github.com/EVAtiter/mirne) (Apache-2.0): the playback, program guide, and caption parts come from it
- [coax](https://github.com/Till0196/coax) (Till0196, Apache-2.0): the ARIB text and caption decoding derives from it, through mirne

See [NOTICE](NOTICE) for details.

## License

Apache License 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
