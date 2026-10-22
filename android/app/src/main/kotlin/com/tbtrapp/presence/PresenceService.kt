package com.tbtrapp.presence

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import com.google.firebase.database.DataSnapshot
import com.google.firebase.database.DatabaseError
import com.google.firebase.database.DatabaseReference
import com.google.firebase.database.ServerValue
import com.google.firebase.database.ValueEventListener
import com.tbtrapp.MainActivity
import com.tbtrapp.platform.AppDatabase

/**
 * Keeps the user "Online" while TBTR is in the background (another app open,
 * screen off), as long as the phone has internet — the "Stay online in
 * background" setting, on by default.
 *
 * Android freezes or kills a backgrounded app within seconds to minutes;
 * its database socket then times out and the server's `onDisconnect` marks
 * the user offline. This small foreground service ("TBTR is active",
 * lowest-priority notification) keeps the process — and so the Realtime
 * Database connection Flutter shares — alive. It writes
 * `presence/{uid} = {online: true, lastSeen}` on every (re)connect and
 * arms `onDisconnect` to write `{online: false, lastSeen}`, so the server
 * still flips the user to "Last seen" the moment the connection really
 * drops (data off, no signal, phone off).
 *
 * Restarted after reboot and app update by [PresenceBootReceiver]. Dart
 * drives it through the `com.tbtrapp/presence` channel (see
 * `lib/screens/auth/presence_manager.dart`).
 */
class PresenceService : Service() {

    private var presenceRef: DatabaseReference? = null
    private var connectedRef: DatabaseReference? = null
    private var connectedListener: ValueEventListener? = null
    private var keepAliveListener: ValueEventListener? = null
    private var uid: String? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val prefs = prefs(this)
        val wanted = prefs.getString(KEY_UID, null)
        if (wanted.isNullOrBlank() || !prefs.getBoolean(KEY_ENABLED, true)) {
            stopSelf()
            return START_NOT_STICKY
        }
        try {
            ServiceCompat.startForeground(
                this, NOTIF_ID, buildNotification(),
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
                } else {
                    0
                },
            )
        } catch (e: Exception) {
            // Not allowed to start in the foreground from here (background
            // start restrictions). Flutter starts it again next time the app
            // is opened.
            Log.w(TAG, "couldn't run in the foreground", e)
            stopSelf()
            return START_NOT_STICKY
        }
        if (wanted != uid) attach(wanted)
        return START_STICKY
    }

    private fun attach(newUid: String) {
        detach()
        uid = newUid
        val db = AppDatabase.get()
        val ref = db.getReference("presence").child(newUid)
        presenceRef = ref

        val connected = db.getReference(".info/connected")
        connectedRef = connected
        connectedListener = object : ValueEventListener {
            override fun onDataChange(snapshot: DataSnapshot) {
                if (snapshot.getValue(Boolean::class.java) != true) return
                ref.onDisconnect().setValue(offlineValue())
                ref.setValue(onlineValue())
            }

            override fun onCancelled(error: DatabaseError) {}
        }.also { connected.addValueEventListener(it) }

        // `.info/connected` is local-only; a listener on a real path is what
        // keeps the SDK from closing an idle connection.
        keepAliveListener = object : ValueEventListener {
            override fun onDataChange(snapshot: DataSnapshot) {}

            override fun onCancelled(error: DatabaseError) {
                Log.w(TAG, "presence listener cancelled: ${error.message}")
            }
        }.also { ref.addValueEventListener(it) }
        Log.d(TAG, "keeping $newUid online in the background")
    }

    private fun detach() {
        connectedListener?.let { connectedRef?.removeEventListener(it) }
        keepAliveListener?.let { presenceRef?.removeEventListener(it) }
        connectedListener = null
        keepAliveListener = null
        connectedRef = null
        presenceRef = null
        uid = null
    }

    override fun onDestroy() {
        detach()
        super.onDestroy()
    }

    private fun buildNotification() = run {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val mgr = getSystemService(NotificationManager::class.java)
            if (mgr.getNotificationChannel(CHANNEL_ID) == null) {
                mgr.createNotificationChannel(
                    NotificationChannel(
                        CHANNEL_ID, "Background connection",
                        NotificationManager.IMPORTANCE_MIN,
                    ).apply {
                        description = "Keeps you online so messages and calls arrive at once"
                        setShowBadge(false)
                    },
                )
            }
        }
        val open = PendingIntent.getActivity(
            this, NOTIF_ID,
            Intent(this, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(applicationInfo.icon)
            .setContentTitle("TBTR is active")
            .setContentText("You stay online for messages and calls")
            .setPriority(NotificationCompat.PRIORITY_MIN)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setOngoing(true)
            .setShowWhen(false)
            .setContentIntent(open)
            .build()
    }

    companion object {
        private const val TAG = "PresenceService"
        private const val NOTIF_ID = 4260
        private const val CHANNEL_ID = "tbtr_active"
        private const val PREFS = "tbtr_presence"
        private const val KEY_UID = "uid"
        private const val KEY_ENABLED = "enabled"

        private fun prefs(ctx: Context) =
            ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

        private fun onlineValue() =
            mapOf("online" to true, "lastSeen" to ServerValue.TIMESTAMP)

        private fun offlineValue() =
            mapOf("online" to false, "lastSeen" to ServerValue.TIMESTAMP)

        /**
         * Saves who is signed in and whether to stay online in the
         * background, then starts or stops the service to match. [uid] null
         * means signed out.
         */
        fun configure(ctx: Context, uid: String?, enabled: Boolean) {
            prefs(ctx).edit()
                .putString(KEY_UID, uid)
                .putBoolean(KEY_ENABLED, enabled)
                .apply()
            if (uid != null && enabled) startIfEnabled(ctx) else stop(ctx)
        }

        fun startIfEnabled(ctx: Context) {
            val prefs = prefs(ctx)
            if (prefs.getString(KEY_UID, null).isNullOrBlank()) return
            if (!prefs.getBoolean(KEY_ENABLED, true)) return
            try {
                ContextCompat.startForegroundService(
                    ctx, Intent(ctx, PresenceService::class.java),
                )
            } catch (e: Exception) {
                Log.w(TAG, "couldn't start", e)
            }
        }

        fun stop(ctx: Context) {
            ctx.stopService(Intent(ctx, PresenceService::class.java))
        }
    }
}
