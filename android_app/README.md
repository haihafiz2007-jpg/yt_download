# XDZ Download for Android

Standalone Android app for downloading media directly to the phone. It supports MP4 video with selectable quality and MP3 audio from sites supported by yt-dlp. Downloads are saved under `Downloads/YT Downloader`. The 🤪📥 branding appears in the app, with a matching launcher icon on Android 8.0 and newer.

yt-dlp supports many sites, but not every website or link is downloadable. TeraBox share pages are not extractable by the bundled downloader; when a TeraBox link is pasted, the app offers to open it in the official app or browser instead. The app does not bypass DRM, logins, paid limits, or other access restrictions.

Downloads continue in the background with an Android foreground notification while a download is active. Keep XDZ Download installed and do not force-stop the app during a download.

The app also supports pasting and sharing links into XDZ Download, a saved sequential queue with reorder/retry/remove controls, searchable history with open/share/delete actions, MP4/MP3/M4A/original output options, playlists, subtitles, a Wi-Fi-only setting, low-storage warning, dark mode, and progress percentage/ETA/speed when yt-dlp provides them. Queue and history are saved locally; if Android stops an active download, reopen the app and retry the interrupted item.

## Build the APK

Install Flutter and Android Studio with the Android SDK, then run from this directory:

```powershell
flutter pub get
flutter build apk --release
```

The APK is created at `build/app/outputs/flutter-apk/app-release.apk`.

The app uses yt-dlp and bundled FFmpeg to download, merge, and convert media.

## Third-party license

The Android app bundles `youtubedl-android` and its FFmpeg module, which are licensed under GPL-3.0: https://github.com/yausername/youtubedl-android. Distribution of the combined APK and its corresponding source must comply with GPL-3.0. The existing desktop application remains under the root MIT license.