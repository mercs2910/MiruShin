package com.emp0ry.mirushin

import android.app.Activity
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.media.MediaMetadata
import android.media.session.MediaController
import android.media.session.MediaSessionManager
import android.media.session.PlaybackState
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import android.service.notification.NotificationListenerService
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject

/** Observes only the launched player package; never reads notification content. */
class ExternalPlaybackListener : NotificationListenerService() {
    private val handler = Handler(Looper.getMainLooper())
    private val tick = object : Runnable {
        override fun run() {
            ExternalPlayback.sample(applicationContext)
            handler.postDelayed(this, 1000)
        }
    }
    override fun onListenerConnected() { handler.post(tick) }
    override fun onListenerDisconnected() { handler.removeCallbacks(tick) }
    override fun onDestroy() {
        handler.removeCallbacks(tick)
        super.onDestroy()
    }
}

/** The journal contains episode identity and positions, never stream URLs or headers. */
object ExternalPlayback {
    const val REQUEST = 4817
    private const val PREFS = "external_playback"
    private const val KEY = "checkpoint"
    private var current: JSONObject? = null
    private var lastCommit = 0L
    private var controller: MediaController? = null

    private fun prefs(context: Context) = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    private fun listener(context: Context) = ComponentName(context, ExternalPlaybackListener::class.java)
    private fun allowed(context: Context): Boolean =
        Settings.Secure.getString(context.contentResolver, "enabled_notification_listeners")
            ?.split(':')?.any { ComponentName.unflattenFromString(it) == listener(context) } == true

    fun handle(activity: Activity, call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "access" -> result.success(allowed(activity))
                "settings" -> {
                    activity.startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
                    result.success(null)
                }
                "pending" -> result.success(prefs(activity).getString(KEY, null)?.let { toMap(JSONObject(it)) })
                "ack" -> {
                    val saved = prefs(activity).getString(KEY, null)?.let { JSONObject(it) }
                    val id = call.argument<String>("sessionId")
                    val revision = call.argument<Number>("revision")?.toLong()
                    // A late database save must not erase a newer native checkpoint.
                    if (saved != null && saved.optString("sessionId") == id && saved.optLong("revision") == revision &&
                        current?.optBoolean("active") != true) {
                        check(prefs(activity).edit().remove(KEY).commit()) { "Checkpoint acknowledgement failed" }
                    }
                    result.success(null)
                }
                "start" -> start(activity, call, result)
                "state" -> {
                    sample(activity)
                    result.success(current?.takeIf { it.optString("sessionId") == call.argument<String>("sessionId") }?.let(::toMap))
                }
                "command" -> {
                    check(current?.optString("sessionId") == call.argument<String>("sessionId")) { "External playback session changed" }
                    val c = controller ?: error("The player has not published media controls")
                    val actions = c.playbackState?.actions ?: 0L
                    when (call.argument<String>("command")) {
                        "seek" -> {
                            require(actions and PlaybackState.ACTION_SEEK_TO != 0L) { "This player does not expose seeking" }
                            c.transportControls.seekTo(call.argument<Number>("positionMs")!!.toLong())
                        }
                        "play" -> c.transportControls.play()
                        "pause" -> c.transportControls.pause()
                        "speed" -> if (Build.VERSION.SDK_INT >= 29 && actions and PlaybackState.ACTION_SET_PLAYBACK_SPEED != 0L) {
                            c.transportControls.setPlaybackSpeed(call.argument<Number>("speed")!!.toFloat())
                        }
                    }
                    result.success(null)
                }
                "detach" -> {
                    if (current?.optString("sessionId") == call.argument<String>("sessionId")) {
                        controller = null
                        current?.put("active", false)
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            // Never include Intent/URL arguments in errors or logs.
            result.error("external_player", e.message ?: "External playback failed", null)
        }
    }

    private fun start(activity: Activity, call: MethodCall, result: MethodChannel.Result) {
        check(allowed(activity)) { "Enable MiruShin playback access in Android notification access settings first" }
        check(prefs(activity).getString(KEY, null) == null) { "Save the previous external playback checkpoint before starting another video" }
        val target = call.argument<String>("target")!!
        val pkg = when (target) {
            "vimu" -> "net.gtvbox.videoplayer"
            "mx", "mxSoftware" -> "com.mxtech.videoplayer.ad"
            else -> error("Unsupported player")
        }
        val uri = Uri.parse(call.argument<String>("url")!!)
        require(uri.scheme in listOf("http", "https")) { "External playback currently supports network streams only" }
        val position = call.argument<Number>("positionMs")!!.toLong().coerceIn(0, Int.MAX_VALUE.toLong()).toInt()
        val title = call.argument<String>("title") ?: "MiruShin"
        val intent = Intent(Intent.ACTION_VIEW).setDataAndType(uri, call.argument<String>("mime") ?: "video/*")
        if (target == "vimu") {
            intent.setPackage(pkg)
            intent.putExtra("forcename", title)
            intent.putExtra("startfrom", position)
            intent.putExtra("forceresume", true)
        } else {
            // MX omits HTTP result callbacks without an explicit activity component.
            intent.setClassName(pkg, "$pkg.ActivityScreen")
            intent.putExtra("title", title)
            intent.putExtra("position", position)
            intent.putExtra("return_result", true)
            intent.putExtra("video_list", arrayOf(uri))
            intent.putExtra("video_list_is_explicit", true)
            if (target == "mxSoftware") intent.putExtra("decode_mode", 2.toByte())
            val headers = call.argument<Map<String, String>>("headers") ?: emptyMap()
            intent.putExtra("headers", headers.flatMap { listOf(it.key, it.value) }.toTypedArray())
        }
        check(intent.resolveActivity(activity.packageManager) != null) { "Install the selected external player first" }
        current = JSONObject().apply {
            put("sessionId", call.argument<String>("sessionId"))
            put("context", JSONObject(call.argument<Map<String, Any?>>("context")!!))
            put("package", pkg)
            put("target", target)
            put("positionMs", position)
            put("durationMs", 0)
            put("revision", 0L)
            put("launchElapsed", SystemClock.elapsedRealtime())
            put("active", true)
            put("observed", false)
            put("returned", false)
            put("completed", false)
        }
        controller = null
        commit(activity)
        try {
            @Suppress("DEPRECATION")
            activity.startActivityForResult(intent, REQUEST)
        } catch (e: Exception) {
            current = null
            prefs(activity).edit().remove(KEY).commit()
            throw e
        }
        result.success(null)
    }

    fun sample(context: Context) {
        val s = current ?: return
        if (!s.optBoolean("active") || !allowed(context)) return
        try {
            val manager = context.getSystemService(Context.MEDIA_SESSION_SERVICE) as MediaSessionManager
            val launch = s.getLong("launchElapsed")
            val candidates = manager.getActiveSessions(listener(context)).filter {
                it.packageName == s.getString("package") && (it.playbackState?.lastPositionUpdateTime ?: 0L) >= launch
            }
            val c = candidates.firstOrNull { it.playbackState?.state == PlaybackState.STATE_PLAYING }
                ?: candidates.firstOrNull() ?: return
            val ps = c.playbackState ?: return
            if (ps.position < 0 || SystemClock.elapsedRealtime() - launch < 500) return
            controller = c
            val duration = c.metadata?.getLong(MediaMetadata.METADATA_KEY_DURATION) ?: 0L
            val playing = ps.state == PlaybackState.STATE_PLAYING
            // Android states often update only on play/pause/seek. Use their monotonic clock.
            val elapsed = (SystemClock.elapsedRealtime() - ps.lastPositionUpdateTime).coerceAtLeast(0)
            val position = ps.position + if (playing) (elapsed * ps.playbackSpeed).toLong() else 0L
            s.put("positionMs", if (duration > 0) position.coerceIn(0, duration) else position.coerceAtLeast(0))
            if (duration > 0) s.put("durationMs", duration)
            s.put("observed", true)
            s.put("playing", playing)
            s.put("buffering", ps.state == PlaybackState.STATE_BUFFERING || ps.state == PlaybackState.STATE_CONNECTING)
            s.put("speed", ps.playbackSpeed.toDouble())
            s.put("canSeek", ps.actions and PlaybackState.ACTION_SEEK_TO != 0L)
            if (SystemClock.elapsedRealtime() - lastCommit >= 5000) commit(context)
        } catch (_: SecurityException) {
            controller = null
        }
    }

    fun onResult(context: Context, resultCode: Int, data: Intent?) {
        val s = current ?: return
        sample(context)
        val vimu = s.optString("target") == "vimu"
        val valid = if (vimu) data?.action == "net.gtvbox.videoplayer.result"
            else data?.action == "com.mxtech.intent.result.VIEW"
        val completed = valid && if (vimu) resultCode == 1
            else resultCode == Activity.RESULT_OK && data?.getStringExtra("end_by") == "playback_completion"
        if (valid) {
            if (data!!.hasExtra("position")) {
                s.put("positionMs", data.getIntExtra("position", 0).coerceAtLeast(0))
                s.put("observed", true)
            }
            if (data.hasExtra("duration")) {
                val duration = data.getIntExtra("duration", 0)
                if (duration > 0) s.put("durationMs", duration)
            }
        }
        s.put("completed", completed)
        if (completed) s.put("observed", true)
        s.put("active", false)
        s.put("playing", false)
        s.put("returned", true)
        s.put("error", valid && if (vimu) resultCode == 4 else resultCode == Activity.RESULT_FIRST_USER)
        controller = null
        commit(context)
    }

    private fun commit(context: Context) {
        val s = current ?: return
        s.put("revision", s.optLong("revision") + 1)
        s.put("updatedAtMs", System.currentTimeMillis())
        check(prefs(context).edit().putString(KEY, s.toString()).commit()) { "Could not save playback checkpoint" }
        lastCommit = SystemClock.elapsedRealtime()
    }

    private fun toMap(json: JSONObject): Map<String, Any?> = json.keys().asSequence().associateWith {
        when (val value = json.get(it)) {
            is JSONObject -> toMap(value)
            JSONObject.NULL -> null
            else -> value
        }
    }
}
