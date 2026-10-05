# YouTube Downloader

A simple desktop app for downloading YouTube videos or audio on a local machine.

## Features
- MP4 or MP3 output
- Quality selection
- Local desktop interface
- Downloaded files saved in a `downloads/` folder

## Requirements
- Python 3.9+
- `yt-dlp`
- FFmpeg for MP4 downloads

## Install

1. Install Python.
2. Install the package:

```bash
python -m pip install yt-dlp
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
- paste a YouTube URL
- choose the file type
- choose the quality
- click Download

## Notes
- MP4 downloads require FFmpeg because the application merges video and audio streams.
- The app is designed for local use on this device.

## License

This project is licensed under the MIT License.
