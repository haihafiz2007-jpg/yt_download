import os
import shutil
import threading
import tkinter as tk
from tkinter import ttk, messagebox

import yt_dlp


def find_ffmpeg():
    """Find a usable ffmpeg executable on the local machine."""
    ffmpeg_path = shutil.which("ffmpeg")
    if ffmpeg_path:
        return ffmpeg_path

    path_dirs = os.environ.get("PATH", "").split(os.pathsep)
    for folder in path_dirs:
        candidate = os.path.join(folder, "ffmpeg.exe")
        if os.path.exists(candidate):
            return candidate

    common_locations = [
        r"C:\ffmpeg\bin\ffmpeg.exe",
        r"C:\Program Files\ffmpeg\bin\ffmpeg.exe",
        r"C:\Program Files (x86)\ffmpeg\bin\ffmpeg.exe",
    ]

    for path in common_locations:
        if os.path.exists(path):
            return path

    return None


def build_options(download_dir, file_type, quality, ffmpeg_path):
    outtmpl = os.path.join(download_dir, "%(title)s.%(ext)s")
    options = {
        "outtmpl": outtmpl,
        "noplaylist": True,
        "quiet": False,
    }

    if ffmpeg_path:
        options["ffmpeg_location"] = ffmpeg_path

    if file_type == "mp4":
        quality_map = {
            "best": "bestvideo+bestaudio/best",
            "1080p": "bestvideo[height<=1080]+bestaudio/best",
            "720p": "bestvideo[height<=720]+bestaudio/best",
            "480p": "bestvideo[height<=480]+bestaudio/best",
            "360p": "bestvideo[height<=360]+bestaudio/best",
        }
        options["format"] = quality_map.get(quality, "bestvideo+bestaudio/best")
        options["merge_output_format"] = "mp4"
    elif file_type == "mp3":
        options["format"] = "bestaudio/best"
        options["postprocessors"] = [{
            "key": "FFmpegExtractAudio",
            "preferredcodec": "mp3",
            "preferredquality": "0",
        }]

    return options


def download_from_url(url, file_type, quality, status_label, download_button):
    if not url:
        messagebox.showerror("Missing URL", "Please paste a YouTube URL first.")
        return

    try:
        download_dir = os.path.join(os.getcwd(), "downloads")
        os.makedirs(download_dir, exist_ok=True)

        ffmpeg_path = find_ffmpeg()
        if file_type == "mp4" and not ffmpeg_path:
            raise RuntimeError("FFmpeg was not found. Install FFmpeg and make sure 'ffmpeg' is available on PATH.")

        options = build_options(download_dir, file_type, quality, ffmpeg_path)

        status_label.config(text="Downloading...")
        download_button.config(state="disabled")

        with yt_dlp.YoutubeDL(options) as ydl:
            ydl.download([url])

        status_label.config(text="Download finished.")
    except Exception as exc:
        status_label.config(text=f"Error: {exc}")
    finally:
        download_button.config(state="normal")


def create_gui():
    root = tk.Tk()
    root.title("YouTube Downloader")
    root.geometry("520x220")
    root.resizable(False, False)

    frame = ttk.Frame(root, padding=18)
    frame.pack(fill="both", expand=True)

    ttk.Label(frame, text="YouTube URL:").pack(anchor="w")
    url_entry = ttk.Entry(frame, width=60)
    url_entry.pack(fill="x", pady=(4, 12))

    quality_row = ttk.Frame(frame)
    quality_row.pack(fill="x")

    ttk.Label(quality_row, text="File type:").pack(side="left")
    file_type = tk.StringVar(value="mp4")
    ttk.Combobox(
        quality_row,
        textvariable=file_type,
        values=["mp4", "mp3"],
        state="readonly",
        width=12,
    ).pack(side="left", padx=(10, 0))

    ttk.Label(quality_row, text="Quality:").pack(side="left", padx=(18, 0))
    quality = tk.StringVar(value="best")
    ttk.Combobox(
        quality_row,
        textvariable=quality,
        values=["best", "1080p", "720p", "480p", "360p"],
        state="readonly",
        width=12,
    ).pack(side="left", padx=(10, 0))

    status_label = ttk.Label(frame, text="Ready", foreground="darkgreen")
    status_label.pack(anchor="w", pady=(16, 8))

    def on_download():
        url = url_entry.get().strip()
        threading.Thread(
            target=download_from_url,
            args=(url, file_type.get(), quality.get(), status_label, download_button),
            daemon=True,
        ).start()

    download_button = ttk.Button(frame, text="Download", command=on_download)
    download_button.pack(anchor="center", pady=(10, 0))

    root.mainloop()


if __name__ == "__main__":
    create_gui()