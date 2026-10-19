package com.tbtrapp.platform

import android.content.Context
import org.json.JSONObject

/**
 * Native reader for the contact naming rule (lib/data/display_names.dart):
 * a number saved in this phone's contacts shows under the saved name;
 * anything else shows as the bare number — never the sender's self-chosen
 * profile name.
 *
 * Flutter's contact sync persists the saved-name map through
 * shared_preferences ("display_names_v1"), which on Android lands in the
 * FlutterSharedPreferences file with a "flutter." key prefix. Reading it
 * here lets notifications posted while the Flutter engine isn't running
 * (app killed) follow the same rule.
 */
object ContactDisplayNames {
    private const val PREFS_FILE = "FlutterSharedPreferences"
    private const val KEY = "flutter.display_names_v1"

    fun nameFor(ctx: Context, uid: String): String {
        if (uid.isBlank()) return "Unknown"
        val saved = try {
            val raw = ctx.getSharedPreferences(PREFS_FILE, Context.MODE_PRIVATE)
                .getString(KEY, null)
            if (raw == null) null else JSONObject(raw).optString(uid).ifBlank { null }
        } catch (_: Exception) {
            null
        }
        return saved ?: formatForDisplay(uid)
    }

    /**
     * Same grouping as formatPhoneForDisplay in lib/util/phone_utils.dart
     * for Sierra Leone numbers ("+23231932652" → "+232 31 932 652");
     * anything else is shown as stored.
     */
    fun formatForDisplay(uid: String): String {
        val m = Regex("^\\+232(\\d{2})(\\d{3})(\\d{3})$").find(uid.trim())
            ?: return uid
        val (a, b, c) = m.destructured
        return "+232 $a $b $c"
    }
}
