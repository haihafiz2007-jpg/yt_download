import json
import os
import queue
import shutil
import threading
import time
import tkinter as tk
import uuid
from tkinter import filedialog, messagebox, ttk

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

    candidates = [
        os.path.join(os.environ.get("LOCALAPPDATA", ""), "Microsoft", "WinGet", "Links"),
        os.path.join(os.environ.get("LOCALAPPDATA", ""), "Microsoft", "WinGet", "Packages"),
        r"C:\ffmpeg\bin",
        r"C:\Program Files\ffmpeg\bin",
        r"C:\Program Files (x86)\ffmpeg\bin",
    ]

    for base_dir in candidates:
        if not base_dir or not os.path.exists(base_dir):
            continue
        for root, _, files in os.walk(base_dir):
            if "ffmpeg.exe" in files:
                return os.path.join(root, "ffmpeg.exe")

    common_locations = [
        r"C:\ffmpeg\bin\ffmpeg.exe",
        r"C:\Program Files\ffmpeg\bin\ffmpeg.exe",
        r"C:\Program Files (x86)\ffmpeg\bin\ffmpeg.exe",
    ]
    return next((path for path in common_locations if os.path.exists(path)), None)


def build_options(
    download_dir,
    file_type,
    quality,
    ffmpeg_path,
    playlist=False,
    subtitles=False,
    subtitle_language="en",
    speed_limit=None,
):
    """Translate the choices in the window into settings yt-dlp understands."""
    # Keep format/quality rules here so the window and download worker share
    # one place to decide how a file should be fetched and converted.
    options = {
        "outtmpl": os.path.join(download_dir, "%(title)s.%(ext)s"),
        "noplaylist": not playlist,
        "quiet": True,
        "no_warnings": True,
        "overwrites": False,
    }

    if ffmpeg_path:
        options["ffmpeg_location"] = ffmpeg_path
    if speed_limit:
        options["ratelimit"] = speed_limit
    if subtitles:
        options.update({
            "writesubtitles": True,
            "writeautomaticsub": True,
            "subtitleslangs": [part.strip() for part in subtitle_language.split(",") if part.strip()],
            "subtitlesformat": "best",
        })

    if file_type == "mp4":
        quality_map = {
            "best": "bestvideo+bestaudio/best",
            "1080p": "bestvideo[height<=1080]+bestaudio/best",
            "720p": "bestvideo[height<=720]+bestaudio/best",
            "480p": "bestvideo[height<=480]+bestaudio/best",
            "360p": "bestvideo[height<=360]+bestaudio/best",
        }
        options["format"] = quality_map.get(quality, quality_map["best"])
        options["merge_output_format"] = "mp4"
    elif file_type in {"mp3", "m4a"}:
        options["format"] = "bestaudio/best"
        options["postprocessors"] = [{
            "key": "FFmpegExtractAudio",
            "preferredcodec": file_type,
            "preferredquality": "0",
        }]
    else:
        options["format"] = "bestvideo+bestaudio/best"

    return options


def app_data_directory():
    """Keep queue and history files in the user's Windows application-data folder."""
    base = os.environ.get("APPDATA") or os.path.expanduser("~")
    directory = os.path.join(base, "XDZ Download")
    os.makedirs(directory, exist_ok=True)
    return directory


def read_json(path, default):
    """Load saved app data; use a safe starting value if no file exists yet."""
    try:
        with open(path, "r", encoding="utf-8") as file:
            return json.load(file)
    except FileNotFoundError:
        return default
    except (OSError, json.JSONDecodeError):
        return default


def write_json(path, value):
    """Save through a temporary file so an interrupted write won't replace good data."""
    temporary_path = path + ".tmp"
    with open(temporary_path, "w", encoding="utf-8") as file:
        json.dump(value, file, ensure_ascii=False, indent=2)
    os.replace(temporary_path, path)


class DownloadManagerApp:
    def __init__(self, root):
        # Restore the last queue and history so they survive closing the window.
        # Queue and history files are separate, making either feature easier to
        # change without altering the other one's saved data.
        self.root = root
        self.root.title("XDZ Download")
        self.root.geometry("840x700")
        self.root.minsize(720, 580)
        self.events = queue.Queue()
        self.data_directory = app_data_directory()
        self.queue_path = os.path.join(self.data_directory, "queue.json")
        self.history_path = os.path.join(self.data_directory, "history.json")
        self.settings_path = os.path.join(self.data_directory, "settings.json")
        settings = read_json(self.settings_path, {})
        self.jobs = read_json(self.queue_path, [])
        self.jobs = [job for job in self.jobs if isinstance(job, dict)] if isinstance(self.jobs, list) else []
        for job in self.jobs:
            if job.get("status") == "Downloading":
                job["status"] = "Queued"
        self.history = read_json(self.history_path, [])
        self.history = self.history if isinstance(self.history, list) else []
        self.worker = None
        self.stop_after_current = threading.Event()
        self.output_directory = tk.StringVar(
            value=os.path.join(os.getcwd(), "downloads")
        )
        self.file_type = tk.StringVar(value="mp4")
        self.quality = tk.StringVar(value="best")
        self.playlist = tk.BooleanVar(value=False)
        self.subtitles = tk.BooleanVar(value=False)
        self.subtitle_language = tk.StringVar(value="en")
        self.speed_limit = tk.StringVar(value="")
        self.status = tk.StringVar(value="Ready")
        self.progress = tk.DoubleVar(value=0)
        self.search = tk.StringVar(value="")
        self.dark_mode = tk.BooleanVar(value=bool(settings.get("dark_mode", False)))
        self.active_output_directory = self.output_directory.get()
        self._queue_edit_buttons = []

        self._build_ui()
        self._apply_theme()
        self._refresh_queue()
        self._refresh_history()
        self.root.after(100, self._poll_events)
        self.root.protocol("WM_DELETE_WINDOW", self._close)

    def _build_ui(self):
        """Create the app's tabs, download form, library, and progress area."""
        container = ttk.Frame(self.root, padding=16)
        container.pack(fill="both", expand=True)
        header = ttk.Frame(container)
        header.pack(fill="x", pady=(0, 12))
        ttk.Label(header, text="🤪📥", font=("Segoe UI Emoji", 24)).pack(side="left")
        ttk.Label(header, text="XDZ Download", font=("Segoe UI", 18, "bold")).pack(
            side="left", padx=(8, 0)
        )
        ttk.Checkbutton(
            header,
            text="Dark mode",
            variable=self.dark_mode,
            command=self._toggle_theme,
        ).pack(side="right")

        self.tabs = ttk.Notebook(container)
        self.tabs.pack(fill="both", expand=True)
        self.download_tab = ttk.Frame(self.tabs, padding=12)
        self.history_tab = ttk.Frame(self.tabs, padding=12)
        self.tabs.add(self.download_tab, text="Download")
        self.tabs.add(self.history_tab, text="Library")
        self._build_download_tab()
        self._build_history_tab()

        footer = ttk.Frame(container)
        footer.pack(fill="x", pady=(10, 0))
        self.progress_bar = ttk.Progressbar(
            footer, variable=self.progress, maximum=100, mode="determinate"
        )
        self.progress_bar.pack(fill="x", pady=(0, 6))
        ttk.Label(footer, textvariable=self.status).pack(anchor="w")

    def _build_download_tab(self):
        """Build the controls for link entry and queue management."""
        tab = self.download_tab
        ttk.Label(tab, text="Paste one or more links (one per line):").pack(anchor="w")
        url_row = ttk.Frame(tab)
        url_row.pack(fill="x", pady=(5, 10))
        self.url_text = tk.Text(url_row, height=3, wrap="word")
        self.url_text.pack(side="left", fill="x", expand=True)
        ttk.Button(url_row, text="Paste", command=self._paste).pack(
            side="left", padx=(8, 0), anchor="n"
        )

        folder_row = ttk.Frame(tab)
        folder_row.pack(fill="x", pady=(0, 10))
        ttk.Label(folder_row, text="Save to:").pack(side="left")
        ttk.Entry(folder_row, textvariable=self.output_directory).pack(
            side="left", fill="x", expand=True, padx=8
        )
        ttk.Button(folder_row, text="Browse…", command=self._choose_folder).pack(
            side="left"
        )

        options = ttk.Frame(tab)
        options.pack(fill="x", pady=(0, 10))
        ttk.Label(options, text="Format").pack(side="left")
        ttk.Combobox(
            options,
            textvariable=self.file_type,
            values=["mp4", "mp3", "m4a", "original"],
            state="readonly",
            width=11,
        ).pack(side="left", padx=(6, 12))
        ttk.Label(options, text="Video quality").pack(side="left")
        ttk.Combobox(
            options,
            textvariable=self.quality,
            values=["best", "1080p", "720p", "480p", "360p"],
            state="readonly",
            width=10,
        ).pack(side="left", padx=(6, 12))
        ttk.Checkbutton(options, text="Playlist", variable=self.playlist).pack(side="left")
        ttk.Checkbutton(options, text="Subtitles", variable=self.subtitles).pack(
            side="left", padx=(8, 0)
        )

        extra = ttk.Frame(tab)
        extra.pack(fill="x", pady=(0, 10))
        ttk.Label(extra, text="Subtitle languages:").pack(side="left")
        ttk.Entry(extra, textvariable=self.subtitle_language, width=12).pack(
            side="left", padx=(6, 14)
        )
        ttk.Label(extra, text="Speed limit (KB/s, optional):").pack(side="left")
        ttk.Entry(extra, textvariable=self.speed_limit, width=10).pack(
            side="left", padx=6
        )
        ttk.Label(extra, text="(FFmpeg required for MP3/M4A and merged MP4)").pack(
            side="left"
        )

        controls = ttk.Frame(tab)
        controls.pack(fill="x", pady=(0, 6))
        add_button = ttk.Button(controls, text="Add to queue", command=self._add_jobs)
        add_button.pack(side="left")
        self.start_button = ttk.Button(controls, text="Start queue", command=self._start_queue)
        self.start_button.pack(side="left", padx=6)
        self.stop_button = ttk.Button(
            controls,
            text="Stop after current",
            command=self._stop_queue,
        )
        self.stop_button.pack(side="left")
        retry_button = ttk.Button(controls, text="Retry failed", command=self._retry_failed)
        retry_button.pack(side="left", padx=6)
        self._queue_edit_buttons.extend([add_button, retry_button])

        ttk.Label(tab, text="Queue").pack(anchor="w", pady=(6, 4))
        columns = ("status", "format", "url")
        self.queue_tree = ttk.Treeview(tab, columns=columns, show="headings", height=10)
        self.queue_tree.heading("status", text="Status")
        self.queue_tree.heading("format", text="Format")
        self.queue_tree.heading("url", text="Link")
        self.queue_tree.column("status", width=100, stretch=False)
        self.queue_tree.column("format", width=80, stretch=False)
        self.queue_tree.column("url", width=450)
        self.queue_tree.pack(fill="both", expand=True)
        queue_controls = ttk.Frame(tab)
        queue_controls.pack(fill="x", pady=(6, 0))
        for label, callback in (
            ("Remove", self._remove_selected),
            ("Move up", lambda: self._move_selected(-1)),
            ("Move down", lambda: self._move_selected(1)),
        ):
            button = ttk.Button(queue_controls, text=label, command=callback)
            button.pack(side="left", padx=(0, 6))
            self._queue_edit_buttons.append(button)

    def _build_history_tab(self):
        """Build the searchable list of downloaded files."""
        top = ttk.Frame(self.history_tab)
        top.pack(fill="x", pady=(0, 8))
        ttk.Label(top, text="Search downloads:").pack(side="left")
        search_entry = ttk.Entry(top, textvariable=self.search)
        search_entry.pack(side="left", fill="x", expand=True, padx=8)
        self.search.trace_add("write", lambda *_: self._refresh_history())
        ttk.Button(top, text="Clear history", command=self._clear_history).pack(side="left")

        columns = ("date", "format", "status", "file")
        self.history_tree = ttk.Treeview(
            self.history_tab, columns=columns, show="headings", height=20
        )
        for column, title in zip(columns, ("Date", "Format", "Status", "File")):
            self.history_tree.heading(column, text=title)
        self.history_tree.column("date", width=140, stretch=False)
        self.history_tree.column("format", width=80, stretch=False)
        self.history_tree.column("status", width=100, stretch=False)
        self.history_tree.column("file", width=420)
        self.history_tree.pack(fill="both", expand=True)
        actions = ttk.Frame(self.history_tab)
        actions.pack(fill="x", pady=(8, 0))
        ttk.Button(actions, text="Open file", command=self._open_history_file).pack(side="left")
        ttk.Button(actions, text="Show in folder", command=self._show_history_file).pack(
            side="left", padx=6
        )
        ttk.Button(actions, text="Delete file", command=self._delete_history_file).pack(
            side="left"
        )

    def _paste(self):
        try:
            text = self.root.clipboard_get()
        except tk.TclError:
            self.status.set("Clipboard does not contain text.")
            return
        current = self.url_text.get("1.0", "end-1c").strip()
        self.url_text.insert("end", ("\n" if current else "") + text.strip())

    def _choose_folder(self):
        selected = filedialog.askdirectory(initialdir=self.output_directory.get())
        if selected:
            self.output_directory.set(selected)

    def _add_jobs(self):
        """Check each pasted link, then save it as a waiting queue item."""
        urls = [
            line.strip()
            for line in self.url_text.get("1.0", "end-1c").splitlines()
            if line.strip()
        ]
        if not urls:
            self.status.set("Paste at least one link first.")
            return
        invalid = [
            url for url in urls
            if not url.lower().startswith(("http://", "https://"))
        ]
        if invalid:
            self.status.set(f"Invalid web link: {invalid[0]}")
            return
        try:
            speed_limit = self._speed_limit_bytes()
        except ValueError as error:
            self.status.set(str(error))
            return

        for url in urls:
            self.jobs.append({
                "id": uuid.uuid4().hex,
                "url": url,
                "file_type": self.file_type.get(),
                "quality": self.quality.get(),
                "playlist": self.playlist.get(),
                "subtitles": self.subtitles.get(),
                "subtitle_language": self.subtitle_language.get().strip() or "en",
                "speed_limit": speed_limit,
                "status": "Queued",
            })
        self._save_queue()
        self._refresh_queue()
        self.status.set(f"Added {len(urls)} link(s) to the queue.")
        self.url_text.delete("1.0", "end")

    def _toggle_theme(self):
        settings = read_json(self.settings_path, {})
        settings["dark_mode"] = self.dark_mode.get()
        write_json(self.settings_path, settings)
        self._apply_theme()

    def _apply_theme(self):
        style = ttk.Style(self.root)
        if "clam" in style.theme_names():
            style.theme_use("clam")
        if self.dark_mode.get():
            background, foreground, field = "#20251f", "#f4f5ef", "#343a32"
            accent, selected = "#bce96b", "#46533b"
        else:
            background, foreground, field = "#f4f5ef", "#20251f", "#ffffff"
            accent, selected = "#627d3c", "#eaf2de"
        self.root.configure(background=background)
        style.configure(".", background=background, foreground=foreground)
        style.configure("TFrame", background=background)
        style.configure("TLabel", background=background, foreground=foreground)
        style.configure("TNotebook", background=background)
        style.configure("TNotebook.Tab", background=field, foreground=foreground)
        style.map("TNotebook.Tab", background=[("selected", selected)])
        style.configure("TButton", background=field, foreground=foreground)
        style.map("TButton", background=[("active", selected)])
        style.configure("TCheckbutton", background=background, foreground=foreground)
        style.configure("TEntry", fieldbackground=field, foreground=foreground)
        style.configure("TCombobox", fieldbackground=field, foreground=foreground)
        style.configure(
            "Treeview",
            background=field,
            fieldbackground=field,
            foreground=foreground,
            rowheight=25,
        )
        style.map("Treeview", background=[("selected", accent)], foreground=[("selected", "#20251f")])
        self.url_text.configure(
            background=field,
            foreground=foreground,
            insertbackground=foreground,
        )

    def _speed_limit_bytes(self):
        value = self.speed_limit.get().strip()
        if not value:
            return None
        try:
            limit = int(value)
        except ValueError as error:
            raise ValueError("Speed limit must be a whole number in KB/s.") from error
        if limit < 1:
            raise ValueError("Speed limit must be at least 1 KB/s.")
        return limit * 1024

    def _start_queue(self):
        """Start one background worker; it downloads queued links one at a time."""
        if self.worker and self.worker.is_alive():
            return
        if not any(job.get("status") == "Queued" for job in self.jobs):
            self.status.set("There are no queued downloads.")
            return
        try:
            os.makedirs(self.output_directory.get(), exist_ok=True)
            free_space = shutil.disk_usage(self.output_directory.get()).free
        except OSError as error:
            self.status.set(f"Cannot access download folder: {error}")
            return
        if free_space < 500 * 1024 * 1024 and not messagebox.askyesno(
            "Low storage",
            f"Only {free_space / (1024 * 1024):.0f} MB is free. Continue anyway?",
        ):
            return
        self.stop_after_current.clear()
        self.active_output_directory = os.path.abspath(self.output_directory.get())
        self.start_button.configure(state="disabled")
        for button in self._queue_edit_buttons:
            button.configure(state="disabled")
        self.worker = threading.Thread(target=self._run_queue, daemon=True)
        self.worker.start()
        self.status.set("Starting queue…")

    def _stop_queue(self):
        if self.worker and self.worker.is_alive():
            self.stop_after_current.set()
            self.status.set("Queue will stop after the current download.")

    def _run_queue(self):
        # This worker performs network work away from the window's main thread.
        # It sends messages back so only the main thread updates the screen.
        # A queue item is a dictionary; when adding options, update this method
        # and _add_jobs so the saved item carries the new setting to yt-dlp.
        while not self.stop_after_current.is_set():
            job = next(
                (item for item in self.jobs if item.get("status") == "Queued"),
                None,
            )
            if job is None:
                break
            job["status"] = "Downloading"
            self._save_queue()
            self.events.put(("refresh_queue", None))
            self.events.put(("status", f"Downloading {job['url']}"))
            os.makedirs(self.active_output_directory, exist_ok=True)
            before = self._output_snapshot()
            ffmpeg_path = find_ffmpeg()
            if job["file_type"] in {"mp3", "m4a"} and not ffmpeg_path:
                job["status"] = "Failed"
                job["error"] = "FFmpeg is required for audio conversion."
                self._save_queue()
                self.events.put(("refresh_queue", None))
                self.events.put(("status", job["error"]))
                continue

            options = build_options(
                self.active_output_directory,
                job["file_type"],
                job["quality"],
                ffmpeg_path,
                playlist=job["playlist"],
                subtitles=job["subtitles"],
                subtitle_language=job["subtitle_language"],
                speed_limit=job.get("speed_limit"),
            )
            options["progress_hooks"] = [self._progress_hook]
            try:
                with yt_dlp.YoutubeDL(options) as ydl:
                    ydl.download([job["url"]])
                status = "Complete"
                error = ""
            except Exception as exc:
                status = "Failed"
                error = str(exc)
            job["status"] = status
            job["error"] = error
            self._save_queue()
            new_files = self._new_output_files(before)
            if new_files:
                for path in new_files:
                    self.history.insert(0, {
                        "timestamp": time.time(),
                        "url": job["url"],
                        "file_type": job["file_type"],
                        "status": status,
                        "path": path,
                        "size": os.path.getsize(path),
                    })
                self.history = self.history[:500]
                write_json(self.history_path, self.history)
            self.events.put(("job_finished", {"job": job, "status": status, "error": error}))
        self.events.put(("queue_finished", None))

    def _progress_hook(self, data):
        """Turn yt-dlp's progress updates into readable progress-bar details."""
        # yt-dlp reports bytes, speed, and ETA here; missing estimates are normal.
        if data.get("status") == "downloading":
            downloaded = data.get("downloaded_bytes") or 0
            total = data.get("total_bytes") or data.get("total_bytes_estimate") or 0
            percent = downloaded * 100 / total if total else 0
            speed = data.get("speed")
            eta = data.get("eta")
            self.events.put(("progress", {
                "percent": percent,
                "speed": speed,
                "eta": eta,
            }))

    def _output_snapshot(self):
        try:
            return {
                os.path.join(self.active_output_directory, name): os.path.getmtime(
                    os.path.join(self.active_output_directory, name)
                )
                for name in os.listdir(self.active_output_directory)
                if os.path.isfile(os.path.join(self.active_output_directory, name))
            }
        except FileNotFoundError:
            return {}

    def _new_output_files(self, before):
        paths = []
        try:
            names = os.listdir(self.active_output_directory)
        except FileNotFoundError:
            return paths
        for name in names:
            path = os.path.join(self.active_output_directory, name)
            if not os.path.isfile(path) or name.endswith((".part", ".ytdl")):
                continue
            modified = os.path.getmtime(path)
            if path not in before or modified > before[path]:
                paths.append(path)
        return paths

    def _poll_events(self):
        """Apply worker messages to the UI safely on Tkinter's main thread."""
        while True:
            try:
                event, payload = self.events.get_nowait()
            except queue.Empty:
                break
            if event == "status":
                self.status.set(payload)
            elif event == "progress":
                percent = payload["percent"]
                self.progress.set(percent)
                details = [f"{percent:.1f}%"]
                if payload["speed"]:
                    details.append(f"{payload['speed'] / 1024:.1f} KB/s")
                if payload["eta"] is not None:
                    details.append(f"{payload['eta']}s remaining")
                self.status.set(" · ".join(details))
            elif event == "refresh_queue":
                self._refresh_queue()
            elif event == "job_finished":
                self._refresh_queue()
                self._refresh_history()
                self.progress.set(100 if payload["status"] == "Complete" else 0)
                self.status.set(
                    f"{payload['status']}: {payload['job']['url']}"
                    + (f" — {payload['error']}" if payload["error"] else "")
                )
            elif event == "queue_finished":
                self.progress.set(0)
                self.status.set("Queue stopped." if self.stop_after_current.is_set() else "Queue finished.")
                self.start_button.configure(state="normal")
                for button in self._queue_edit_buttons:
                    button.configure(state="normal")
        self.root.after(100, self._poll_events)

    def _save_queue(self):
        """Persist the queue so unfinished links can be continued next time."""
        write_json(self.queue_path, self.jobs)

    def _refresh_queue(self):
        if not hasattr(self, "queue_tree"):
            return
        self.queue_tree.delete(*self.queue_tree.get_children())
        for job in self.jobs:
            self.queue_tree.insert(
                "", "end", iid=job["id"],
                values=(job.get("status", "Queued"), job.get("file_type", ""), job.get("url", "")),
            )

    def _selected_job_index(self):
        selected = self.queue_tree.selection()
        if not selected:
            return None
        return next((i for i, job in enumerate(self.jobs) if job["id"] == selected[0]), None)

    def _remove_selected(self):
        index = self._selected_job_index()
        if index is None:
            return
        if self.jobs[index].get("status") == "Downloading":
            self.status.set("A running download cannot be removed.")
            return
        self.jobs.pop(index)
        self._save_queue()
        self._refresh_queue()

    def _move_selected(self, direction):
        index = self._selected_job_index()
        if index is None:
            return
        target = index + direction
        if target < 0 or target >= len(self.jobs):
            return
        if self.jobs[index].get("status") != "Queued" or self.jobs[target].get("status") != "Queued":
            return
        self.jobs[index], self.jobs[target] = self.jobs[target], self.jobs[index]
        self._save_queue()
        self._refresh_queue()
        self.queue_tree.selection_set(self.jobs[target]["id"])

    def _retry_failed(self):
        count = 0
        for job in self.jobs:
            if job.get("status") == "Failed":
                job["status"] = "Queued"
                job.pop("error", None)
                count += 1
        if count:
            self._save_queue()
            self._refresh_queue()
            self.status.set(f"Reset {count} failed download(s) to queued.")

    def _refresh_history(self):
        """Redraw the library list, applying the user's current search text."""
        if not hasattr(self, "history_tree"):
            return
        self.history_tree.delete(*self.history_tree.get_children())
        query = self.search.get().strip().lower()
        for index, entry in enumerate(self.history):
            path = entry.get("path", "")
            if query and query not in path.lower() and query not in entry.get("url", "").lower():
                continue
            date = time.strftime(
                "%Y-%m-%d %H:%M",
                time.localtime(entry.get("timestamp", time.time())),
            )
            self.history_tree.insert(
                "", "end", iid=str(index),
                values=(date, entry.get("file_type", ""), entry.get("status", ""), path),
            )

    def _selected_history_entry(self):
        selected = self.history_tree.selection()
        if not selected:
            return None
        try:
            return self.history[int(selected[0])]
        except (ValueError, IndexError):
            return None

    def _open_history_file(self):
        entry = self._selected_history_entry()
        if not entry:
            return
        path = entry.get("path", "")
        if not os.path.isfile(path):
            messagebox.showerror("File not found", "This file is no longer available.")
            return
        os.startfile(path)

    def _show_history_file(self):
        entry = self._selected_history_entry()
        if entry and os.path.exists(entry.get("path", "")):
            os.startfile(os.path.dirname(entry["path"]))

    def _delete_history_file(self):
        entry = self._selected_history_entry()
        if not entry:
            return
        path = entry.get("path", "")
        if not os.path.isfile(path):
            messagebox.showerror("File not found", "This file is no longer available.")
            return
        if not messagebox.askyesno("Delete download", f"Delete this file?\n\n{path}"):
            return
        try:
            os.remove(path)
        except OSError as error:
            messagebox.showerror("Could not delete file", str(error))
            return
        self.history.remove(entry)
        write_json(self.history_path, self.history)
        self._refresh_history()

    def _clear_history(self):
        if not self.history:
            return
        if not messagebox.askyesno("Clear history", "Clear history entries? Downloaded files will remain."):
            return
        self.history.clear()
        write_json(self.history_path, self.history)
        self._refresh_history()

    def _close(self):
        if self.worker and self.worker.is_alive():
            if not messagebox.askyesno(
                "Download in progress",
                "A download is running. Close the app? The current download may stop.",
            ):
                return
            self.stop_after_current.set()
        self.root.destroy()


def create_gui():
    root = tk.Tk()
    DownloadManagerApp(root)
    root.mainloop()


if __name__ == "__main__":
    create_gui()
