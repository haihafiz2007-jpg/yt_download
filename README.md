# XDZ Download

A desktop app for downloading video or audio from sites supported by yt-dlp. The
app uses XDZ Download branding.

## Features
- MP4, MP3, M4A, or original-format output where supported
- Video-quality selection, optional playlists, and subtitle downloads
- Multi-link sequential queue with saved jobs, reorder, retry, and removal
- Clipboard paste, custom download folder, progress, speed, ETA, and bandwidth cap
- Searchable history with open, show-in-folder, and delete-file actions
- Dark mode and low-storage warning

## Requirements
- Python 3.9+
- `yt-dlp`
- FFmpeg for audio conversion and merged MP4 downloads

## Install

1. Install Python.
2. Install the packages:

```bash
python -m pip install -r requirements.txt
```

3. Install FFmpeg and ensure `ffmpeg` is on your PATH.

On Windows, a common option is:

```powershell
winget install --id Gyan.FFmpeg -e
```

## Run

```bash
python main.py
```

Then:
- paste one or more supported links (one per line)
- choose the format, quality, and optional playlist/subtitle settings
- add them to the queue and start it

## Android APK

A standalone Android app is in `android_app/`. It downloads directly on the phone and saves files to `Downloads/YT Downloader`; the PC does not need to stay on.
The Android app includes clipboard/share-link intake, a saved sequential queue with reorder/retry/remove controls, searchable history with file actions, MP4/MP3/M4A/original output, playlist/subtitle options, Wi-Fi-only setting, storage warning, and light/dark themes. Progress details depend on source support.

From the repository root, build a release APK with:

```powershell
cd android_app
flutter pub get
flutter build apk --release
```

The APK is written to `android_app/build/app/outputs/flutter-apk/app-release.apk`. The Android app bundles `youtubedl-android` and FFmpeg under GPL-3.0; see [the Android app notes](android_app/README.md) before redistributing it.

## Notes
- MP4 merge and MP3/M4A conversion require FFmpeg.
- yt-dlp supports many sites, but no downloader can guarantee every website or link; DRM and access restrictions are not bypassed.
- Android queue entries are restored after restart, but interrupted active downloads may need retrying.
- Closing the desktop app can stop its current download.

## License

This project is licensed under the MIT License.
