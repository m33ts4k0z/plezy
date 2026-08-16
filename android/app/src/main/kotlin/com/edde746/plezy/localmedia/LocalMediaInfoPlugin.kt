package com.edde746.plezy.localmedia

import android.content.Context
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException

/** Probes the physical downloaded media file, including SAF content URIs. */
class LocalMediaInfoPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
  companion object {
    private const val TAG = "LocalMediaInfoPlugin"
    private const val CHANNEL = "com.plezy/local_media_info"
  }

  private var context: Context? = null
  private var channel: MethodChannel? = null
  private val mainHandler = Handler(Looper.getMainLooper())
  private val executor = Executors.newSingleThreadExecutor { runnable ->
    Thread(runnable, "plezy-local-media-info").apply { isDaemon = true }
  }

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    context = binding.applicationContext
    channel = MethodChannel(binding.binaryMessenger, CHANNEL).also { it.setMethodCallHandler(this) }
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    channel?.setMethodCallHandler(null)
    channel = null
    context = null
    executor.shutdownNow()
  }

  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    if (call.method != "probe") {
      result.notImplemented()
      return
    }

    val source = call.argument<String>("source")
    val appContext = context
    if (source.isNullOrBlank() || appContext == null) {
      result.error("invalid_source", "A readable media source is required", null)
      return
    }

    try {
      executor.execute {
        try {
          val info = probe(appContext, source)
          mainHandler.post { result.success(info) }
        } catch (error: Exception) {
          Log.w(TAG, "Could not probe downloaded media", error)
          mainHandler.post {
            result.error("probe_failed", error.message ?: "Could not read downloaded media", null)
          }
        }
      }
    } catch (error: RejectedExecutionException) {
      result.error("probe_unavailable", "Downloaded media probe is shutting down", null)
    }
  }

  private fun probe(context: Context, source: String): Map<String, Any> {
    val uri = Uri.parse(source)
    val contentSource = uri.scheme.equals("content", ignoreCase = true)
    val filePath = when {
      uri.scheme.equals("file", ignoreCase = true) -> uri.path
      uri.scheme.isNullOrBlank() -> source
      else -> null
    }
    val result = linkedMapOf<String, Any>()

    if (contentSource) {
      readContentStat(context, uri)?.let { stat ->
        stat.displayName?.let { result["displayName"] = it }
        if (stat.size > 0L) result["fileSizeBytes"] = stat.size
      }
      context.contentResolver.getType(uri)?.let { result["mimeType"] = it }
    } else if (!filePath.isNullOrBlank()) {
      val file = File(filePath)
      result["displayName"] = file.name
      if (file.exists()) result["fileSizeBytes"] = file.length()
    }

    val retriever = MediaMetadataRetriever()
    try {
      if (contentSource) {
        retriever.setDataSource(context, uri)
      } else {
        retriever.setDataSource(filePath ?: source)
      }
      metadata(retriever, MediaMetadataRetriever.METADATA_KEY_MIMETYPE)?.let { result["mimeType"] = it }
      metadataLong(retriever, MediaMetadataRetriever.METADATA_KEY_DURATION)?.let { result["durationMs"] = it }
      metadataLong(retriever, MediaMetadataRetriever.METADATA_KEY_BITRATE)?.let { result["bitrateBps"] = it }
      metadataLong(retriever, MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.let { result["width"] = it }
      metadataLong(retriever, MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.let { result["height"] = it }
      metadataDouble(retriever, MediaMetadataRetriever.METADATA_KEY_CAPTURE_FRAMERATE)?.let {
        result["frameRate"] = it
      }
      metadataLong(retriever, MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.let { result["rotation"] = it }
    } catch (error: RuntimeException) {
      // A provider may expose the size/name but reject random access needed by
      // MediaMetadataRetriever. Return the exact stat rather than losing all
      // useful local information.
      if (result.isEmpty()) throw error
      Log.w(TAG, "Media metadata unavailable for $source; returning file stat", error)
    } finally {
      try {
        retriever.release()
      } catch (_: RuntimeException) {
      }
    }

    if (result.isEmpty()) throw IllegalStateException("Downloaded media is not readable")
    return result
  }

  private fun metadata(retriever: MediaMetadataRetriever, key: Int): String? =
    retriever.extractMetadata(key)?.trim()?.takeIf { it.isNotEmpty() }

  private fun metadataLong(retriever: MediaMetadataRetriever, key: Int): Long? =
    metadata(retriever, key)?.toLongOrNull()?.takeIf { it > 0L }

  private fun metadataDouble(retriever: MediaMetadataRetriever, key: Int): Double? =
    metadata(retriever, key)?.toDoubleOrNull()?.takeIf { it > 0.0 }

  private fun readContentStat(context: Context, uri: Uri): ContentStat? {
    return try {
      context.contentResolver.query(
        uri,
        arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE),
        null,
        null,
        null
      )?.use { cursor ->
        if (!cursor.moveToFirst()) return@use null
        val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
        val sizeIndex = cursor.getColumnIndex(OpenableColumns.SIZE)
        ContentStat(
          displayName = if (nameIndex >= 0 && !cursor.isNull(nameIndex)) cursor.getString(nameIndex) else null,
          size = if (sizeIndex >= 0 && !cursor.isNull(sizeIndex)) cursor.getLong(sizeIndex) else -1L
        )
      }
    } catch (error: Exception) {
      Log.w(TAG, "Could not stat SAF media $uri", error)
      null
    }
  }

  private data class ContentStat(val displayName: String?, val size: Long)
}
