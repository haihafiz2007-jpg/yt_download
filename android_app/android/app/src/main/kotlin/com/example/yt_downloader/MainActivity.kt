package com.example.yt_downloader

import android.Manifest
import android.content.ContentValues
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Environment
import android.net.Uri
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.provider.MediaStore
import androidx.core.app.ActivityCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import com.yausername.ffmpeg.FFmpeg
import com.yausername.youtubedl_android.YoutubeDL
import com.yausername.youtubedl_android.YoutubeDLRequest
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

class MainActivity : FlutterActivity() {
	// Flutter calls this Android code for downloads, saved data, and file actions.
	// Method names in configureFlutterEngine must match the calls in main.dart.
	private val processId = "yt-downloader-process"
	private val executor = Executors.newSingleThreadExecutor()
	private val isDownloading = AtomicBoolean(false)
	private lateinit var methodChannel: MethodChannel
	private var pendingSharedText: String? = null
	private var pendingPermissionResult: MethodChannel.Result? = null

	override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
		super.configureFlutterEngine(flutterEngine)
		val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "yt_downloader")
		methodChannel = channel
		channel.setMethodCallHandler { call, result ->
			when (call.method) {
				"consumeSharedText" -> {
					result.success(pendingSharedText)
					pendingSharedText = null
				}
				"requestStoragePermission" -> requestStoragePermission(result)
				"getWifiOnly" -> result.success(
					getSharedPreferences(SETTINGS_PREFERENCES, MODE_PRIVATE)
						.getBoolean(WIFI_ONLY_KEY, false),
				)
				"setWifiOnly" -> {
					getSharedPreferences(SETTINGS_PREFERENCES, MODE_PRIVATE)
						.edit()
						.putBoolean(WIFI_ONLY_KEY, call.argument<Boolean>("enabled") ?: false)
						.apply()
					result.success(null)
				}
				"getDarkMode" -> result.success(
					getSharedPreferences(SETTINGS_PREFERENCES, MODE_PRIVATE)
						.getBoolean(DARK_MODE_KEY, false),
				)
				"setDarkMode" -> {
					getSharedPreferences(SETTINGS_PREFERENCES, MODE_PRIVATE)
						.edit()
						.putBoolean(DARK_MODE_KEY, call.argument<Boolean>("enabled") ?: false)
						.apply()
					result.success(null)
				}
				"getStorageInfo" -> result.success(getStorageInfo())
				"openLink" -> openLink(call.argument("url"), result)
				"openFile" -> handleDownloadedFile(call.argument("location"), "open", result)
				"shareFile" -> handleDownloadedFile(call.argument("location"), "share", result)
				"deleteFile" -> handleDownloadedFile(call.argument("location"), "delete", result)
				"getHistory" -> try {
					result.success(readHistory())
				} catch (error: Exception) {
					result.error("history_read_failed", error.message, null)
				}
				"getQueue" -> try {
					result.success(readQueue())
				} catch (error: Exception) {
					result.error("queue_read_failed", error.message, null)
				}
				"saveQueue" -> try {
					saveQueue(call.arguments as? List<*>)
					result.success(null)
				} catch (error: Exception) {
					result.error("queue_write_failed", error.message, null)
				}
				"recordHistory" -> {
					try {
						recordHistory(call.arguments as? Map<*, *>)
						result.success(null)
					} catch (error: Exception) {
						result.error("history_write_failed", error.message, null)
					}
				}
				"removeHistoryLocation" -> try {
					removeHistoryLocation(call.argument("location"))
					result.success(null)
				} catch (error: Exception) {
					result.error("history_write_failed", error.message, null)
				}
				"clearHistory" -> {
					getSharedPreferences(HISTORY_PREFERENCES, MODE_PRIVATE)
						.edit()
						.remove(HISTORY_KEY)
						.apply()
					result.success(null)
				}
				"download" -> startDownload(
					call.argument("url"),
					call.argument("fileType"),
					call.argument("quality"),
					call.argument<Boolean>("playlist") ?: false,
					call.argument<Boolean>("subtitles") ?: false,
					call.argument("subtitleLanguage"),
					result,
					channel,
				)
				"cancelDownload" -> result.success(YoutubeDL.getInstance().destroyProcessById(processId))
				else -> result.notImplemented()
			}
		}
		deliverSharedText(intent, channel)
	}

	override fun onNewIntent(intent: Intent) {
		super.onNewIntent(intent)
		setIntent(intent)
		if (::methodChannel.isInitialized) deliverSharedText(intent, methodChannel)
	}

	private fun deliverSharedText(intent: Intent?, channel: MethodChannel) {
		if (intent?.action != Intent.ACTION_SEND || intent.type != "text/plain") return
		val text = intent.getStringExtra(Intent.EXTRA_TEXT) ?: return
		pendingSharedText = text
		channel.invokeMethod("sharedLink", text)
	}

	private fun getStorageInfo(): Map<String, Long> {
		val stats = android.os.StatFs(Environment.getExternalStorageDirectory().path)
		return mapOf("availableBytes" to stats.availableBytes, "totalBytes" to stats.totalBytes)
	}

	private fun openLink(url: String?, result: MethodChannel.Result) {
		val uri = url?.let(Uri::parse)
		if (uri == null || uri.scheme !in setOf("http", "https") || uri.host.isNullOrBlank()) {
			result.error("invalid_url", "A valid web link is required.", null)
			return
		}
		try {
			startActivity(Intent(Intent.ACTION_VIEW, uri))
			result.success(null)
		} catch (error: android.content.ActivityNotFoundException) {
			result.error("no_browser", "No app is available to open this link.", null)
		}
	}

	private fun handleDownloadedFile(location: String?, action: String, result: MethodChannel.Result) {
		// Android uses a content URI to safely open/share files with other apps.
		// If adding a new file action, add its method-channel name above and a
		// matching action in the history menu in main.dart.
		if (location.isNullOrBlank()) {
			result.error("invalid_file", "The saved file location is missing.", null)
			return
		}
		try {
			val displayName = location.substringAfterLast('/').substringAfterLast('\\')
			val contentUri = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
				val relativePath = location.substringBeforeLast('/') + "/"
				contentResolver.query(
					MediaStore.Downloads.EXTERNAL_CONTENT_URI,
					arrayOf(MediaStore.MediaColumns._ID),
					"${MediaStore.MediaColumns.DISPLAY_NAME} = ? AND ${MediaStore.MediaColumns.RELATIVE_PATH} = ?",
					arrayOf(displayName, relativePath),
					null,
				)?.use { cursor ->
					if (cursor.moveToFirst()) {
						MediaStore.Downloads.EXTERNAL_CONTENT_URI.buildUpon()
							.appendPath(cursor.getLong(0).toString())
							.build()
					} else null
				}
			} else null

			if (action == "delete") {
				val deleted = if (contentUri != null) {
					contentResolver.delete(contentUri, null, null) > 0
				} else {
					File(
						Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS),
						"YT Downloader/$displayName",
					).delete()
				}
				if (!deleted) throw IllegalStateException("Could not delete the downloaded file.")
				result.success(true)
				return
			}

			val uri = contentUri ?: throw IllegalStateException(
				"Opening files from this Android version is not supported yet.",
			)
			val mimeType = when (displayName.substringAfterLast('.', "").lowercase()) {
				"mp3" -> "audio/mpeg"
				"m4a" -> "audio/mp4"
				"webm" -> "video/webm"
				"vtt" -> "text/vtt"
				"srt" -> "application/x-subrip"
				"mkv" -> "video/x-matroska"
				else -> "video/mp4"
			}
			val intent = if (action == "share") {
				Intent(Intent.ACTION_SEND).apply {
					type = mimeType
					putExtra(Intent.EXTRA_STREAM, uri)
				}
			} else {
				Intent(Intent.ACTION_VIEW).apply {
					setDataAndType(uri, mimeType)
				}
			}.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
			startActivity(
				if (action == "share") Intent.createChooser(intent, "Share download") else intent,
			)
			result.success(true)
		} catch (error: Exception) {
			result.error("file_action_failed", error.message ?: "Could not access the file.", null)
		}
	}

	private fun readHistory(): List<Map<String, Any?>> {
		return readEntries(HISTORY_PREFERENCES, HISTORY_KEY)
	}

	private fun readQueue(): List<Map<String, Any?>> {
		return readEntries(QUEUE_PREFERENCES, QUEUE_KEY)
	}

	private fun readEntries(preferences: String, key: String): List<Map<String, Any?>> {
		// Queue and history are small JSON lists saved in this app's private settings.
		val encoded = getSharedPreferences(preferences, MODE_PRIVATE).getString(key, null)
			?: return emptyList()
		return try {
			val entries = JSONArray(encoded)
			(0 until entries.length()).mapNotNull { index ->
				val item = entries.optJSONObject(index) ?: return@mapNotNull null
				val values = mutableMapOf<String, Any?>()
				val keys = item.keys()
				while (keys.hasNext()) {
					val key = keys.next()
					values[key] = item.opt(key).let { if (it == JSONObject.NULL) null else it }
				}
				values
			}
		} catch (error: org.json.JSONException) {
			throw IllegalStateException("Saved download history is invalid.", error)
		}
	}

	private fun recordHistory(entry: Map<*, *>?) {
		if (entry == null) throw IllegalArgumentException("History entry is required.")
		val json = JSONObject()
		entry.forEach { (key, value) ->
			if (key is String) json.put(key, value)
		}
		val entries = JSONArray()
		entries.put(json)
		readHistory().take(99).forEach { entries.put(JSONObject(it)) }
		getSharedPreferences(HISTORY_PREFERENCES, MODE_PRIVATE)
			.edit()
			.putString(HISTORY_KEY, entries.toString())
			.apply()
	}

	private fun removeHistoryLocation(location: String?) {
		if (location.isNullOrBlank()) {
			throw IllegalArgumentException("File location is required.")
		}
		val remaining = readHistory().filterNot { it["location"] == location }
		val json = JSONArray()
		remaining.forEach { json.put(JSONObject(it)) }
		getSharedPreferences(HISTORY_PREFERENCES, MODE_PRIVATE)
			.edit()
			.putString(HISTORY_KEY, json.toString())
			.apply()
	}

	private fun saveQueue(entries: List<*>?) {
		if (entries == null) throw IllegalArgumentException("Queue entries are required.")
		val json = JSONArray()
		entries.take(100).forEach { entry ->
			if (entry !is Map<*, *>) {
				throw IllegalArgumentException("Queue entries must be objects.")
			}
			val item = JSONObject()
			entry.forEach { (key, value) ->
				if (key is String) item.put(key, value)
			}
			json.put(item)
		}
		getSharedPreferences(QUEUE_PREFERENCES, MODE_PRIVATE)
			.edit()
			.putString(QUEUE_KEY, json.toString())
			.apply()
	}

	private fun requestStoragePermission(result: MethodChannel.Result) {
		if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q ||
			checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED
		) {
			result.success(true)
			return
		}
		pendingPermissionResult = result
		ActivityCompat.requestPermissions(
			this,
			arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE),
			STORAGE_PERMISSION_REQUEST,
		)
	}

	override fun onRequestPermissionsResult(
		requestCode: Int,
		permissions: Array<out String>,
		grantResults: IntArray,
	) {
		super.onRequestPermissionsResult(requestCode, permissions, grantResults)
		if (requestCode == STORAGE_PERMISSION_REQUEST) {
			pendingPermissionResult?.success(
				grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED,
			)
			pendingPermissionResult = null
		}
	}

	private fun startDownload(
		url: String?,
		fileType: String?,
		quality: String?,
		playlist: Boolean,
		subtitles: Boolean,
		subtitleLanguage: String?,
		result: MethodChannel.Result,
		channel: MethodChannel,
	) {
		// A single background worker runs yt-dlp so the app screen stays responsive.
		// The arguments here must match the job fields sent from _processQueue in
		// main.dart. Add a new download option to both sides to pass it through.
		if (url.isNullOrBlank() || fileType !in setOf("mp4", "mp3", "m4a", "original")) {
			result.error("invalid_request", "A valid URL and file type are required.", null)
			return
		}
		if (subtitles && !SUBTITLE_LANGUAGES.matches(subtitleLanguage ?: "en")) {
			result.error("invalid_request", "Subtitle languages must be comma-separated codes like en,es.", null)
			return
		}
		if (!isDownloading.compareAndSet(false, true)) {
			result.error("already_downloading", "A download is already running.", null)
			return
		}

		DownloadForegroundService.start(this)
		executor.execute {
			var finalStatus = "Download failed"
			var succeeded = false
			try {
				val wifiOnly = getSharedPreferences(SETTINGS_PREFERENCES, MODE_PRIVATE)
					.getBoolean(WIFI_ONLY_KEY, false)
				if (wifiOnly && !isWifiConnected()) {
					throw IllegalStateException("Wi-Fi-only is enabled. Connect to Wi-Fi or turn it off in settings.")
				}
				YoutubeDL.getInstance().init(applicationContext)
				FFmpeg.getInstance().init(applicationContext)
				runOnUiThread { channel.invokeMethod("status", "Checking downloader updates") }
				DownloadForegroundService.update(this, "Checking downloader updates")
				try {
					YoutubeDL.getInstance().updateYoutubeDL(
						applicationContext,
						YoutubeDL.UpdateChannel.STABLE,
					)
				} catch (updateError: Exception) {
					runOnUiThread {
						channel.invokeMethod("status", "Update unavailable; using installed downloader")
					}
					DownloadForegroundService.update(
						this,
						"Update unavailable; using installed downloader",
					)
				}
				runOnUiThread { channel.invokeMethod("status", "Starting download") }
				DownloadForegroundService.update(this, "Starting download")

				val downloadDirectory = File(
					getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS) ?: filesDir,
					"pending-downloads",
				)
				if (!downloadDirectory.exists() && !downloadDirectory.mkdirs()) {
					throw IllegalStateException("Could not prepare download storage.")
				}
				downloadDirectory.listFiles()?.forEach { it.delete() }

				fun createRequest(includeSubtitles: Boolean): YoutubeDLRequest {
					val request = YoutubeDLRequest(url)
						.addOption("--no-mtime")
						.addOption("-o", File(downloadDirectory, "%(title)s.%(ext)s").absolutePath)

					if (playlist) {
						request.addOption("--yes-playlist")
					} else {
						request.addOption("--no-playlist")
					}
					if (includeSubtitles) {
						// Captions are optional; retry without them if their server rate-limits us.
						request.addOption("--write-subs")
							.addOption("--write-auto-subs")
							.addOption("--sub-langs", subtitleLanguage ?: "en")
					}

					if (fileType == "mp3" || fileType == "m4a") {
						request.addOption("-x")
							.addOption("--audio-format", fileType)
						if (fileType == "mp3") request.addOption("--audio-quality", "0")
					} else if (fileType == "original") {
						request.addOption("-f", "bestvideo+bestaudio/best")
					} else {
						val maxHeight = when (quality) {
							"1080p" -> 1080
							"720p" -> 720
							"480p" -> 480
							"360p" -> 360
							else -> null
						}
						val heightFilter = maxHeight?.let { "[height<=$it]" } ?: ""
						request.addOption(
							"-f",
							"bestvideo$heightFilter+bestaudio/best$heightFilter/best",
						).addOption("--merge-output-format", "mp4")
					}
					return request
				}

				fun executeRequest(request: YoutubeDLRequest) {
					var lastNotificationProgress = -1
					// Keep Flutter progress and the ongoing Android notification in sync.
					YoutubeDL.getInstance().execute(request, processId) { progress, eta, line ->
						val speed = SPEED_PATTERN.find(line)
							?.groupValues
							?.getOrNull(1)
							?.replace(Regex("\\s+"), "")
						val percent = progress.toInt().coerceIn(0, 100)
						if (percent != lastNotificationProgress) {
							lastNotificationProgress = percent
							DownloadForegroundService.update(this, "Downloading", percent)
						}
						runOnUiThread {
							channel.invokeMethod(
								"progress",
								mapOf("progress" to progress, "eta" to eta, "speed" to speed),
							)
						}
					}
				}

				var warning: String? = null
				try {
					executeRequest(createRequest(subtitles))
				} catch (downloadError: Exception) {
					val message = downloadError.message.orEmpty()
					val subtitleRateLimited = subtitles &&
						SUBTITLE_RATE_LIMIT_PATTERN.containsMatchIn(message)
					if (!subtitleRateLimited) throw downloadError

					warning = "Video downloaded without subtitles because the site rate-limited captions."
					runOnUiThread { channel.invokeMethod("status", warning) }
					DownloadForegroundService.update(this, "Retrying without subtitles")
					downloadDirectory.listFiles()?.forEach { file ->
						if (!file.delete()) {
							throw IllegalStateException("Could not clear the partial download before retrying.")
						}
					}
					executeRequest(createRequest(includeSubtitles = false))
				}
				val downloadedFiles = downloadDirectory.listFiles()
					?.filter {
						it.isFile &&
							!it.name.endsWith(".part") &&
							!it.name.endsWith(".ytdl") &&
							!it.name.endsWith(".tmp") &&
							it.extension.lowercase() in SUPPORTED_OUTPUT_EXTENSIONS
					}
					?.sortedWith(
						compareBy<File> { it.extension.lowercase() in SUBTITLE_EXTENSIONS }
							.thenBy { it.lastModified() },
					)
					?: emptyList()
				if (downloadedFiles.isEmpty()) {
					throw IllegalStateException("The download completed without creating a file.")
				}
				val relativePath = "${Environment.DIRECTORY_DOWNLOADS}/YT Downloader"
				val savedFiles = downloadedFiles.map { file ->
					mapOf(
						"location" to publishDownloadedFile(file, relativePath),
						"sizeBytes" to file.length(),
					)
				}
				finalStatus = if (warning == null) {
					"Download complete"
				} else {
					"Download complete; subtitles unavailable"
				}
				succeeded = true
				runOnUiThread {
					result.success(
						mapOf(
							"location" to savedFiles.first()["location"],
							"sizeBytes" to savedFiles.first()["sizeBytes"],
							"files" to savedFiles,
							"warning" to warning,
						),
					)
				}
			} catch (error: Exception) {
				finalStatus = error.message ?: "Download failed"
				runOnUiThread {
					if (!isFinishing && !isDestroyed) {
						channel.invokeMethod("status", finalStatus)
						result.error("download_failed", finalStatus, null)
					}
				}
			} catch (error: LinkageError) {
				finalStatus = error.message ?: "Downloader initialization failed."
				runOnUiThread {
					if (!isFinishing && !isDestroyed) {
						channel.invokeMethod("status", finalStatus)
						result.error("download_failed", finalStatus, null)
					}
				}
			} finally {
				DownloadForegroundService.finish(this, finalStatus, succeeded)
				isDownloading.set(false)
			}
		}
	}

	private fun isWifiConnected(): Boolean {
		val connectivityManager = getSystemService(ConnectivityManager::class.java)
		val network = connectivityManager.activeNetwork ?: return false
		val capabilities = connectivityManager.getNetworkCapabilities(network) ?: return false
		return capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)
	}

	private fun publishDownloadedFile(downloadedFile: File, relativePath: String): String {
		// Put finished files in the phone's public Downloads folder so they are easy to find.
		// Update the MIME-type mapping when adding new output or subtitle formats.
		if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
			val extension = downloadedFile.extension.lowercase()
			val mimeType = when (extension) {
				"mp3" -> "audio/mpeg"
				"m4a" -> "audio/mp4"
				"vtt" -> "text/vtt"
				"srt" -> "application/x-subrip"
				"mp4" -> "video/mp4"
				"webm" -> "video/webm"
				"mkv" -> "video/x-matroska"
				else -> "video/mp4"
			}
			val values = ContentValues().apply {
				put(MediaStore.MediaColumns.DISPLAY_NAME, downloadedFile.name)
				put(MediaStore.MediaColumns.MIME_TYPE, mimeType)
				put(MediaStore.MediaColumns.RELATIVE_PATH, relativePath)
				put(MediaStore.MediaColumns.IS_PENDING, 1)
			}
			val uri = contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
				?: throw IllegalStateException("Could not add ${downloadedFile.name} to Downloads.")
			try {
				contentResolver.openOutputStream(uri)?.use { output ->
					downloadedFile.inputStream().use { input -> input.copyTo(output) }
				} ?: throw IllegalStateException("Could not write ${downloadedFile.name}.")
				val publishedValues = ContentValues().apply {
					put(MediaStore.MediaColumns.IS_PENDING, 0)
				}
				contentResolver.update(uri, publishedValues, null, null)
				return "$relativePath/${downloadedFile.name}"
			} catch (error: Exception) {
				contentResolver.delete(uri, null, null)
				throw error
			}
		}
		val publicDirectory = File(
			Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS),
			"YT Downloader",
		)
		if (!publicDirectory.exists() && !publicDirectory.mkdirs()) {
			throw IllegalStateException("Could not create the Downloads folder.")
		}
		return downloadedFile.copyTo(
			File(publicDirectory, downloadedFile.name),
			overwrite = true,
		).absolutePath
	}

	companion object {
		private const val STORAGE_PERMISSION_REQUEST = 42
		private const val HISTORY_PREFERENCES = "download_history"
		private const val HISTORY_KEY = "entries"
		private const val QUEUE_PREFERENCES = "download_queue"
		private const val QUEUE_KEY = "entries"
		private const val SETTINGS_PREFERENCES = "app_settings"
		private const val WIFI_ONLY_KEY = "wifi_only"
		private const val DARK_MODE_KEY = "dark_mode"
		private val SUBTITLE_EXTENSIONS = setOf("vtt", "srt", "ass", "ssa", "ttml")
		private val SUPPORTED_OUTPUT_EXTENSIONS = SUBTITLE_EXTENSIONS + setOf(
			"mp4", "mkv", "webm", "mov", "mp3", "m4a", "opus", "ogg", "wav", "flac",
		)
		private val SUBTITLE_LANGUAGES = Regex("[A-Za-z0-9,*._-]{1,80}")
		private val SPEED_PATTERN =
			Regex("""(?:at\s+)?([0-9]+(?:\.[0-9]+)?\s*[KMGT]?i?B/s)""", RegexOption.IGNORE_CASE)
		private val SUBTITLE_RATE_LIMIT_PATTERN =
			Regex("""(?is)(?:subtitle|subtitles).*(?:429|too many requests)""")
	}
}
