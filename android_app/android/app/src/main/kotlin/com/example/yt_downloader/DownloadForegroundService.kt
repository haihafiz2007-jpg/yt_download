package com.example.yt_downloader

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

class DownloadForegroundService : Service() {
	// Android requires an ongoing notification while a long download runs in the background.
	private val notificationManager by lazy {
		getSystemService(NotificationManager::class.java)
	}

	override fun onCreate() {
		super.onCreate()
		if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
			notificationManager.createNotificationChannel(
				NotificationChannel(
					CHANNEL_ID,
					"Downloads",
					NotificationManager.IMPORTANCE_LOW,
				).apply {
					description = "Shows media download progress"
				},
			)
		}
	}

	override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
		// The download worker sends start, progress, and finished messages to this service.
		when (intent?.action) {
			ACTION_UPDATE -> {
				notificationManager.notify(
					NOTIFICATION_ID,
					buildNotification(
						intent.getStringExtra(EXTRA_STATUS) ?: "Downloading",
						intent.getIntExtra(EXTRA_PROGRESS, -1),
						ongoing = true,
					),
				)
			}
			ACTION_FINISH -> {
				notificationManager.notify(
					NOTIFICATION_ID,
					buildNotification(
						intent.getStringExtra(EXTRA_STATUS) ?: "Download finished",
						intent.getIntExtra(EXTRA_PROGRESS, -1),
						ongoing = false,
					),
				)
				stopForeground(false)
				stopSelf(startId)
			}
			else -> {
				val notification = buildNotification("Preparing download", -1, ongoing = true)
				if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
					startForeground(
						NOTIFICATION_ID,
						notification,
						ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
					)
				} else {
					startForeground(NOTIFICATION_ID, notification)
				}
			}
		}
		return START_NOT_STICKY
	}

	override fun onBind(intent: Intent?): IBinder? = null

	private fun buildNotification(status: String, progress: Int, ongoing: Boolean): Notification {
		val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
			Notification.Builder(this, CHANNEL_ID)
		} else {
			@Suppress("DEPRECATION")
			Notification.Builder(this)
		}
		val openAppIntent = Intent(this, MainActivity::class.java).apply {
			flags = Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
		}
		val openAppPendingIntent = PendingIntent.getActivity(
			this,
			OPEN_APP_REQUEST_CODE,
			openAppIntent,
			PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
		)
		return builder
			.setSmallIcon(android.R.drawable.stat_sys_download)
			.setContentTitle("xdz_360 yt")
			.setContentText(status)
			.setContentIntent(openAppPendingIntent)
			.setOnlyAlertOnce(true)
			.setOngoing(ongoing)
			.setAutoCancel(!ongoing)
			.apply {
				if (progress >= 0) setProgress(100, progress.coerceIn(0, 100), false)
				else if (ongoing) setProgress(0, 0, true)
				else setProgress(0, 0, false)
			}
			.build()
	}

	companion object {
		private const val CHANNEL_ID = "media_downloads"
		private const val NOTIFICATION_ID = 1001
		private const val ACTION_START = "com.example.yt_downloader.START_DOWNLOAD"
		private const val ACTION_UPDATE = "com.example.yt_downloader.UPDATE_DOWNLOAD"
		private const val ACTION_FINISH = "com.example.yt_downloader.FINISH_DOWNLOAD"
		private const val EXTRA_STATUS = "status"
		private const val EXTRA_PROGRESS = "progress"
		private const val OPEN_APP_REQUEST_CODE = 1002

		fun start(context: Context) {
			val intent = Intent(context, DownloadForegroundService::class.java).apply {
				action = ACTION_START
			}
			if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
				context.startForegroundService(intent)
			} else {
				context.startService(intent)
			}
		}

		fun update(context: Context, status: String, progress: Int = -1) {
			context.startService(
				Intent(context, DownloadForegroundService::class.java).apply {
					action = ACTION_UPDATE
					putExtra(EXTRA_STATUS, status)
					putExtra(EXTRA_PROGRESS, progress)
				},
			)
		}

		fun finish(context: Context, status: String, succeeded: Boolean) {
			context.startService(
				Intent(context, DownloadForegroundService::class.java).apply {
					action = ACTION_FINISH
					putExtra(EXTRA_STATUS, status)
					putExtra(EXTRA_PROGRESS, if (succeeded) 100 else -1)
				},
			)
		}
	}
}
