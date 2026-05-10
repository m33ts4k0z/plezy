package com.edde746.plezy.medianotification

import android.app.ActivityOptions
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Build
import android.support.v4.media.MediaMetadataCompat
import android.support.v4.media.session.MediaSessionCompat
import android.support.v4.media.session.PlaybackStateCompat
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.media.app.NotificationCompat.MediaStyle
import com.edde746.plezy.MainActivity
import com.edde746.plezy.R
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Posts a MediaStyle Notification linked to a MediaSession so third-party
 * launchers (Niagara, KISS, etc.) that read media via NotificationListener
 * can render plezy's currently-playing item with artwork on the home screen.
 *
 * The companion plugin `os_media_controls` only manages a MediaSession —
 * privileged system surfaces (lock screen, OnePlus peek bar) read sessions
 * directly, but third-party launchers can only see Notifications. This
 * plugin closes that gap.
 *
 * The session here is a separate MediaSessionCompat; control events from
 * the user (lock-screen / launcher buttons) are forwarded to Dart via
 * [eventChannel] and the Dart side bridges them into the existing
 * MediaControlsManager event stream.
 */
class MediaNotificationPlugin : FlutterPlugin {
    companion object {
        private const val TAG = "MediaNotificationPlugin"
        private const val METHOD_CHANNEL = "com.plezy/media_notification"
        private const val EVENT_CHANNEL = "com.plezy/media_notification/events"
        private const val NOTIFICATION_CHANNEL_ID = "plezy_media_playback"
        private const val NOTIFICATION_CHANNEL_NAME = "Now playing"
        private const val NOTIFICATION_ID = 7341

        /// Intent extra carrying the requested media action when MainActivity
        /// is launched from the notification. MainActivity routes it to
        /// [dispatchActionFromIntent] so the running plugin instance can
        /// emit an event for the Dart-side resume coordinator.
        const val EXTRA_ACTION = "com.plezy.media_notification.action"
        const val ACTION_PLAY_PAUSE = "playPause"
        const val ACTION_NEXT = "next"
        const val ACTION_PREV = "previous"
        const val ACTION_STOP = "stop"
        const val ACTION_RESUME = "resume"

        /// The currently-attached plugin instance, if any. Set in
        /// [onAttachedToEngine] so MainActivity can dispatch intent actions
        /// without traversing the FlutterEngine plugin registry.
        @Volatile private var current: MediaNotificationPlugin? = null

        /// Forward an Activity-intent extra (carried from a notification tap)
        /// to whichever plugin instance is currently attached. Called from
        /// MainActivity.onCreate / onNewIntent.
        @JvmStatic
        fun dispatchActionFromIntent(intent: Intent?) {
            val action = intent?.getStringExtra(EXTRA_ACTION) ?: return
            current?.handleAction(action) ?: Log.w(TAG, "No attached plugin for action $action")
        }

        /// Clear the home-screen / lock-screen tile from native code. Used by
        /// MainActivity when the user dismisses PiP via its X button — that
        /// gesture is treated as a full stop, not a resumable pause. We also
        /// emit a "stop" event so the Dart side clears the parallel
        /// `os_media_controls` session (third-party launchers like Niagara
        /// also read MediaSessionManager directly, so we have to take both
        /// sessions down to make the tile actually disappear).
        @JvmStatic
        fun clearFromNative() {
            current?.let {
                it.clearNotification()
                it.releaseSession()
                it.emitEvent("stop")
            }
        }
    }

    private var context: Context? = null
    private var methodChannel: MethodChannel? = null
    private var eventChannel: EventChannel? = null
    private var eventSink: EventChannel.EventSink? = null
    private var session: MediaSessionCompat? = null

    // Last-known snapshot, kept so `setPlaybackState` can re-render the
    // notification without forcing the caller to resend metadata.
    private var lastTitle: String? = null
    private var lastArtist: String? = null
    private var lastArtwork: Bitmap? = null
    private var lastDurationMs: Long = 0
    private var lastCanGoNext: Boolean = false
    private var lastCanGoPrevious: Boolean = false

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        methodChannel = MethodChannel(binding.binaryMessenger, METHOD_CHANNEL).apply {
            setMethodCallHandler { call, result -> handleMethodCall(call, result) }
        }
        eventChannel = EventChannel(binding.binaryMessenger, EVENT_CHANNEL).apply {
            setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    eventSink = events
                }

                override fun onCancel(arguments: Any?) {
                    eventSink = null
                }
            })
        }
        ensureNotificationChannel()
        current = this
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        if (current === this) current = null
        clearNotification()
        releaseSession()
        lastTitle = null
        lastArtist = null
        lastArtwork = null
        lastDurationMs = 0
        lastCanGoNext = false
        lastCanGoPrevious = false
        methodChannel?.setMethodCallHandler(null)
        eventChannel?.setStreamHandler(null)
        methodChannel = null
        eventChannel = null
        eventSink = null
        context = null
    }

    private fun handleMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "update" -> {
                    val title = call.argument<String>("title") ?: ""
                    val artist = call.argument<String>("artist")
                    val artwork = call.argument<ByteArray>("artwork")
                    val isPlaying = call.argument<Boolean>("isPlaying") ?: false
                    val positionMs = (call.argument<Number>("positionMs") ?: 0L).toLong()
                    val durationMs = (call.argument<Number>("durationMs") ?: 0L).toLong()
                    val speed = (call.argument<Number>("speed") ?: 1.0).toFloat()
                    val canGoNext = call.argument<Boolean>("canGoNext") ?: false
                    val canGoPrevious = call.argument<Boolean>("canGoPrevious") ?: false
                    update(title, artist, artwork, isPlaying, positionMs, durationMs, speed, canGoNext, canGoPrevious)
                    result.success(null)
                }
                "setPlaybackState" -> {
                    val isPlaying = call.argument<Boolean>("isPlaying") ?: false
                    val positionMs = (call.argument<Number>("positionMs") ?: 0L).toLong()
                    val speed = (call.argument<Number>("speed") ?: 1.0).toFloat()
                    setPlaybackStateOnly(isPlaying, positionMs, speed)
                    result.success(null)
                }
                "clear" -> {
                    clearNotification()
                    releaseSession()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            Log.w(TAG, "Method call failed: ${call.method}", e)
            result.error("MEDIA_NOTIFICATION_ERROR", e.message, null)
        }
    }

    private fun ensureNotificationChannel() {
        val ctx = context ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (nm.getNotificationChannel(NOTIFICATION_CHANNEL_ID) == null) {
                val channel = NotificationChannel(
                    NOTIFICATION_CHANNEL_ID,
                    NOTIFICATION_CHANNEL_NAME,
                    NotificationManager.IMPORTANCE_LOW,
                ).apply {
                    description = "Currently-playing media controls"
                    setShowBadge(false)
                    setSound(null, null)
                    enableVibration(false)
                }
                nm.createNotificationChannel(channel)
            }
        }
    }

    private fun ensureSession(): MediaSessionCompat {
        val ctx = context ?: error("Plugin not attached")
        val existing = session
        if (existing != null) return existing
        val newSession = MediaSessionCompat(ctx, "PlezyMediaNotification").apply {
            // When a notification has MediaStyle linked to a session token,
            // launchers (Niagara, Android system media controls) route action
            // taps through this callback INSTEAD of the notification's
            // PendingIntents. So the callback is responsible for both
            // dispatching the action to Dart AND bringing MainActivity to
            // foreground — without that, "play" silently starts audio in
            // the background and the user never sees the player UI.
            setCallback(object : MediaSessionCompat.Callback() {
                override fun onPlay() = handleSessionAction(ACTION_PLAY_PAUSE, "play")
                override fun onPause() = handleSessionAction(ACTION_PLAY_PAUSE, "pause")
                override fun onSkipToNext() = handleSessionAction(ACTION_NEXT, "next")
                override fun onSkipToPrevious() = handleSessionAction(ACTION_PREV, "previous")
                override fun onStop() = handleSessionAction(ACTION_STOP, "stop")
                override fun onSeekTo(pos: Long) = emitEvent("seek", mapOf("positionMs" to pos))
                override fun onFastForward() = emitEvent("fastForward")
                override fun onRewind() = emitEvent("rewind")
            })
            isActive = true
        }
        session = newSession
        return newSession
    }

    private fun releaseSession() {
        session?.apply {
            isActive = false
            release()
        }
        session = null
    }

    private fun update(
        title: String,
        artist: String?,
        artworkBytes: ByteArray?,
        isPlaying: Boolean,
        positionMs: Long,
        durationMs: Long,
        speed: Float,
        canGoNext: Boolean,
        canGoPrevious: Boolean,
    ) {
        val ctx = context ?: return
        val mediaSession = ensureSession()

        val artworkBitmap: Bitmap? = artworkBytes?.let {
            try {
                BitmapFactory.decodeByteArray(it, 0, it.size)
            } catch (e: Exception) {
                Log.w(TAG, "Failed to decode artwork bytes", e)
                null
            }
        } ?: lastArtwork

        lastTitle = title
        lastArtist = artist
        lastArtwork = artworkBitmap
        lastDurationMs = durationMs
        lastCanGoNext = canGoNext
        lastCanGoPrevious = canGoPrevious

        val metadataBuilder = MediaMetadataCompat.Builder()
            .putString(MediaMetadataCompat.METADATA_KEY_TITLE, title)
        if (!artist.isNullOrEmpty()) {
            metadataBuilder.putString(MediaMetadataCompat.METADATA_KEY_ARTIST, artist)
        }
        if (durationMs > 0) {
            metadataBuilder.putLong(MediaMetadataCompat.METADATA_KEY_DURATION, durationMs)
        }
        if (artworkBitmap != null) {
            metadataBuilder.putBitmap(MediaMetadataCompat.METADATA_KEY_ART, artworkBitmap)
            metadataBuilder.putBitmap(MediaMetadataCompat.METADATA_KEY_ALBUM_ART, artworkBitmap)
        }
        mediaSession.setMetadata(metadataBuilder.build())

        var actions = PlaybackStateCompat.ACTION_PLAY or
            PlaybackStateCompat.ACTION_PAUSE or
            PlaybackStateCompat.ACTION_PLAY_PAUSE or
            PlaybackStateCompat.ACTION_STOP or
            PlaybackStateCompat.ACTION_SEEK_TO
        if (canGoNext) actions = actions or PlaybackStateCompat.ACTION_SKIP_TO_NEXT
        if (canGoPrevious) actions = actions or PlaybackStateCompat.ACTION_SKIP_TO_PREVIOUS

        val state = if (isPlaying) PlaybackStateCompat.STATE_PLAYING else PlaybackStateCompat.STATE_PAUSED
        val playbackState = PlaybackStateCompat.Builder()
            .setActions(actions)
            .setState(state, positionMs, speed)
            .build()
        mediaSession.setPlaybackState(playbackState)

        // Niagara (and other third-party launchers) require the MediaStyle
        // to be linked to a session token in order to render this as a
        // home-screen media tile — without the link, they ignore the
        // notification entirely. Action-button taps therefore route through
        // the session callback rather than firing our PendingIntents
        // directly; the callback compensates by using `MainActivity.current`
        // to launch the activity in the existing task.
        val style = MediaStyle()
            .setMediaSession(mediaSession.sessionToken)
            .setShowActionsInCompactView(*compactActionIndices(canGoPrevious, canGoNext))

        val builder = NotificationCompat.Builder(ctx, NOTIFICATION_CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_notification)
            .setContentTitle(title)
            .setContentText(artist ?: "")
            .setLargeIcon(artworkBitmap)
            .setStyle(style)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setCategory(NotificationCompat.CATEGORY_TRANSPORT)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setOngoing(isPlaying)
            .setContentIntent(buildContentIntent(ctx))
            .setDeleteIntent(buildActionIntent(ctx, ACTION_STOP))
            .setAutoCancel(false)

        if (canGoPrevious) {
            builder.addAction(
                NotificationCompat.Action(
                    android.R.drawable.ic_media_previous,
                    "Previous",
                    buildActionIntent(ctx, ACTION_PREV),
                ),
            )
        }
        builder.addAction(
            NotificationCompat.Action(
                if (isPlaying) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play,
                if (isPlaying) "Pause" else "Play",
                buildActionIntent(ctx, ACTION_PLAY_PAUSE),
            ),
        )
        if (canGoNext) {
            builder.addAction(
                NotificationCompat.Action(
                    android.R.drawable.ic_media_next,
                    "Next",
                    buildActionIntent(ctx, ACTION_NEXT),
                ),
            )
        }

        try {
            NotificationManagerCompat.from(ctx).notify(NOTIFICATION_ID, builder.build())
        } catch (e: SecurityException) {
            // POST_NOTIFICATIONS not granted on Android 13+. Nothing to do.
            Log.w(TAG, "Failed to post media notification (permission denied)", e)
        }
    }

    /// Update only the playback state and re-render the notification. Used by
    /// the resume coordinator to flip to "paused" after the player exits,
    /// without re-shipping the artwork bytes.
    private fun setPlaybackStateOnly(isPlaying: Boolean, positionMs: Long, speed: Float) {
        val title = lastTitle ?: return
        update(
            title,
            lastArtist,
            null, // reuse lastArtwork via the fallback in `update`
            isPlaying,
            positionMs,
            lastDurationMs,
            speed,
            lastCanGoNext,
            lastCanGoPrevious,
        )
    }

    private fun clearNotification() {
        val ctx = context ?: return
        try {
            NotificationManagerCompat.from(ctx).cancel(NOTIFICATION_ID)
        } catch (_: Exception) {
        }
        lastTitle = null
        lastArtist = null
        lastArtwork = null
        lastDurationMs = 0
        lastCanGoNext = false
        lastCanGoPrevious = false
    }

    private fun compactActionIndices(canPrev: Boolean, canNext: Boolean): IntArray {
        // Indices into the action list we add below: [(prev?), playPause, (next?)]
        return when {
            canPrev && canNext -> intArrayOf(0, 1, 2)
            canPrev -> intArrayOf(0, 1)
            canNext -> intArrayOf(0, 1)
            else -> intArrayOf(0)
        }
    }

    /// All notification taps (action buttons + body) launch MainActivity so
    /// the user is brought to foreground in the same gesture that resumes
    /// playback. The chosen action is carried as an intent extra and
    /// dispatched to Dart by [dispatchActionFromIntent].
    private fun buildContentIntent(ctx: Context): PendingIntent =
        buildActionIntent(ctx, ACTION_RESUME)

    private fun buildActionIntent(ctx: Context, action: String): PendingIntent {
        val launchIntent = ctx.packageManager.getLaunchIntentForPackage(ctx.packageName)
            ?: Intent()
        // NEW_TASK is required when the PendingIntent is sent from a
        // non-activity context (the session callback path).
        launchIntent.flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_NEW_TASK
        launchIntent.putExtra(EXTRA_ACTION, action)
        // Distinct request codes so action buttons don't collide on a stale
        // PendingIntent — Android caches by (requestCode, intent components,
        // intent action), and our intent action is identical across buttons.
        val requestCode = action.hashCode()
        return PendingIntent.getActivity(
            ctx,
            requestCode,
            launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    /// Dispatch an action received from a notification tap (via MainActivity).
    private fun handleAction(action: String) {
        when (action) {
            ACTION_PLAY_PAUSE, ACTION_RESUME -> emitEvent("togglePlayPause")
            ACTION_NEXT -> emitEvent("next")
            ACTION_PREV -> emitEvent("previous")
            ACTION_STOP -> emitEvent("stop")
        }
    }

    /// Bring MainActivity to the foreground via the same PendingIntent the
    /// notification's action buttons use. Sending the PendingIntent (rather
    /// than `context.startActivity`) bypasses Android's background-activity-
    /// launch restrictions because PendingIntents inherit the privileges of
    /// their creator. The activity's `onNewIntent` then dispatches the
    /// action back to Dart via `dispatchActionFromIntent`, so we don't
    /// emit here — that would produce a duplicate event.
    private fun handleSessionAction(activityAction: String, eventType: String) {
        val activity = MainActivity.current
        val ctx = context
        // Always emit the event first so the resume coordinator can act
        // even if the activity launch is silently blocked by background-
        // activity-launch policy. The activity launch is best-effort.
        emitEvent(eventType)

        if (activity != null) {
            // Live activity available: start the intent from its context so
            // Android reuses the existing task (no NEW_TASK needed) and
            // re-enters via `onNewIntent`. This is the path that keeps the
            // current FlutterEngine alive after PiP-X.
            val intent = Intent(activity, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP
                putExtra(EXTRA_ACTION, activityAction)
            }
            try {
                activity.startActivity(intent)
                return
            } catch (e: Exception) {
                Log.w(TAG, "Activity-context startActivity failed for $activityAction", e)
            }
        }

        if (ctx == null) return
        try {
            // Fallback: PendingIntent send from application context. On
            // Android 14+, opt into background-activity-launch via options
            // since the session callback is a background context.
            val options = ActivityOptions.makeBasic().also {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                    it.pendingIntentBackgroundActivityStartMode =
                        ActivityOptions.MODE_BACKGROUND_ACTIVITY_START_ALLOWED
                }
            }
            buildActionIntent(ctx, activityAction).send(ctx, 0, null, null, null, null, options.toBundle())
        } catch (e: Exception) {
            Log.w(TAG, "Failed to send PendingIntent for $activityAction", e)
        }
    }

    private fun emitEvent(type: String, extra: Map<String, Any?> = emptyMap()) {
        val sink = eventSink ?: return
        val payload = HashMap<String, Any?>(extra.size + 1)
        payload["type"] = type
        payload.putAll(extra)
        sink.success(payload)
    }
}
