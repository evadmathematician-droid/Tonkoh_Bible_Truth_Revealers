package com.tbtrapp.platform

import android.content.Context
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.telephony.SubscriptionManager
import android.util.Log
import androidx.core.content.ContextCompat

/**
 * Reads contacts stored on the SIM card(s).
 *
 * `flutter_contacts` (and the AOSP Contacts provider it reads) only exposes
 * `ContactsContract` rows. Contacts saved directly on a SIM live in a
 * separate, older provider — `content://icc/adn` — and on a multi-SIM device
 * each SIM has its own table at `content://icc/adn/subId/<subscriptionId>`.
 * Neither is surfaced through `ContactsContract` unless the user has
 * explicitly imported them, which most people on Africell / Orange SIMs in
 * the field have not done. This reader queries those providers directly and
 * hands the rows back to Dart, which merges them into the same device-contact
 * list used for matching and display.
 *
 * Permissions: needs `READ_CONTACTS` (already requested by the contacts
 * flow). `SubscriptionManager` additionally needs `READ_PHONE_STATE` to
 * enumerate SIM slots; without it we fall back to the un-slotted
 * `content://icc/adn` which still returns the first SIM's contacts on most
 * devices.
 */
class SimContactsReader(private val context: Context) {

    fun readAll(): List<Map<String, String>> {
        if (!hasPermission(android.Manifest.permission.READ_CONTACTS)) {
            Log.d(TAG, "READ_CONTACTS not granted — returning no SIM contacts")
            return emptyList()
        }

        val out = LinkedHashMap<String, Map<String, String>>()

        for (uri in candidateUris()) {
            queryUri(uri, out)
        }

        Log.d(TAG, "readAll() -> ${out.size} SIM contacts across ${candidateUris().size} providers")
        return out.values.toList()
    }

    /** Every SIM-contact content URI worth trying, most specific first. */
    private fun candidateUris(): List<Uri> {
        val uris = mutableListOf<Uri>()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP_MR1 &&
            hasPermission(android.Manifest.permission.READ_PHONE_STATE)
        ) {
            try {
                val sm = ContextCompat.getSystemService(context, SubscriptionManager::class.java)
                val active = sm?.activeSubscriptionInfoList
                if (active != null) {
                    for (info in active) {
                        uris.add(Uri.parse("content://icc/adn/subId/${info.subscriptionId}"))
                    }
                }
            } catch (e: Exception) {
                Log.w(TAG, "SubscriptionManager enumeration failed: ${e.message}")
            }
        }

        // Always also try the un-slotted table — some OEMs only populate this
        // one, and it's the only option on single-SIM / pre-22 devices.
        uris.add(Uri.parse("content://icc/adn"))

        return uris.distinct()
    }

    private fun queryUri(uri: Uri, out: LinkedHashMap<String, Map<String, String>>) {
        try {
            context.contentResolver.query(uri, null, null, null, null)?.use { cursor ->
                val nameIdx = cursor.getColumnIndex("name")
                val numberIdx = cursor.getColumnIndex("number")
                if (numberIdx < 0) {
                    Log.d(TAG, "$uri has no 'number' column — skipping")
                    return
                }
                while (cursor.moveToNext()) {
                    val number = cursor.getString(numberIdx)?.trim().orEmpty()
                    if (number.isEmpty()) continue
                    val name = if (nameIdx >= 0) {
                        cursor.getString(nameIdx)?.trim().orEmpty()
                    } else {
                        ""
                    }
                    val key = number.filter { it.isDigit() }
                    if (key.length < 4) continue
                    if (!out.containsKey(key)) {
                        out[key] = mapOf("name" to name, "number" to number)
                    }
                }
            }
        } catch (e: Exception) {
            // Providers throw on locked/absent SIMs, restricted OEM builds,
            // etc. — a missing SIM table is not an error worth surfacing.
            Log.d(TAG, "query $uri failed: ${e.message}")
        }
    }

    private fun hasPermission(permission: String): Boolean =
        ContextCompat.checkSelfPermission(context, permission) ==
            PackageManager.PERMISSION_GRANTED

    companion object {
        private const val TAG = "SimContactsReader"
    }
}
