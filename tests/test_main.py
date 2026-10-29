import os
import tempfile
import unittest

from main import DownloadManagerApp, build_options, read_json, write_json


class BuildOptionsTests(unittest.TestCase):
    def test_video_quality_and_playlist_settings(self):
        options = build_options(
            r"C:\downloads",
            "mp4",
            "720p",
            None,
            playlist=True,
        )

        self.assertFalse(options["noplaylist"])
        self.assertEqual(
            options["format"],
            "bestvideo[height<=720]+bestaudio/best",
        )
        self.assertEqual(options["merge_output_format"], "mp4")

    def test_audio_subtitles_and_speed_limit(self):
        options = build_options(
            r"C:\downloads",
            "m4a",
            "best",
            r"C:\ffmpeg\bin\ffmpeg.exe",
            subtitles=True,
            subtitle_language="en,es",
            speed_limit=1024,
        )

        self.assertEqual(options["postprocessors"][0]["preferredcodec"], "m4a")
        self.assertEqual(options["subtitleslangs"], ["en", "es"])
        self.assertEqual(options["ratelimit"], 1024)
        self.assertEqual(options["ffmpeg_location"], r"C:\ffmpeg\bin\ffmpeg.exe")


class PersistenceTests(unittest.TestCase):
    def test_queue_and_history_json_round_trip(self):
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "state.json")
            value = [{"url": "https://example.com/video", "status": "Queued"}]

            write_json(path, value)

            self.assertEqual(read_json(path, []), value)
            self.assertFalse(os.path.exists(path + ".tmp"))

    def test_invalid_json_returns_default(self):
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "state.json")
            with open(path, "w", encoding="utf-8") as file:
                file.write("{")

            self.assertEqual(read_json(path, []), [])


class DownloadDiscoveryTests(unittest.TestCase):
    def test_new_and_modified_outputs_are_discovered(self):
        with tempfile.TemporaryDirectory() as directory:
            existing = os.path.join(directory, "existing.mp4")
            with open(existing, "w", encoding="utf-8") as file:
                file.write("before")
            before = {existing: -1}
            with open(existing, "a", encoding="utf-8") as file:
                file.write("after")
            created = os.path.join(directory, "subtitle.en.vtt")
            with open(created, "w", encoding="utf-8") as file:
                file.write("caption")

            app = DownloadManagerApp.__new__(DownloadManagerApp)
            app.active_output_directory = directory

            found = app._new_output_files(before)

            self.assertCountEqual(found, [existing, created])


if __name__ == "__main__":
    unittest.main()
