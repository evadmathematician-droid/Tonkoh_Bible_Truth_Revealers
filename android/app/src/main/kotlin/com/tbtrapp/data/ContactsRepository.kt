package com.tbtrapp.data

import android.content.Context
import android.provider.ContactsContract
import android.util.Log
import com.google.firebase.database.FirebaseDatabase
import com.tbtrapp.auth.AuthManager
import com.tbtrapp.util.defaultRegion
import com.tbtrapp.util.normalizePhone
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.tasks.await
import kotlinx.coroutines.withContext

/**
 * Native equivalent of lib/data/contacts_repository.dart. Reads the
 * device's address book via ContactsContract (Android's Contacts Provider,
 * which already merges SIM-imported contacts on virtually every OEM), then
 * matches it against every registered user in Firebase — same shape and
 * same dedup rule (later entries win on a duplicate number) as the Dart
 * version, just backed by a native content-resolver query instead of
 * flutter_contacts.
 */
object ContactsRepository {

    private data class DeviceEntry(val name: String, val source: String)

    private fun readDeviceContacts(context: Context): List<Pair<String, String>> {
        val results = mutableListOf<Pair<String, String>>()
        val cursor = context.contentResolver.query(
            ContactsContract.CommonDataKinds.Phone.CONTENT_URI,
            arrayOf(
                ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME,
                ContactsContract.CommonDataKinds.Phone.NUMBER
            ),
            null, null, null
        )
        cursor?.use {
            val nameIdx = it.getColumnIndex(ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME)
            val numberIdx = it.getColumnIndex(ContactsContract.CommonDataKinds.Phone.NUMBER)
            while (it.moveToNext()) {
                val name = it.getString(nameIdx) ?: continue
                val number = it.getString(numberIdx) ?: continue
                if (name.isBlank() || number.isBlank()) continue
                results.add(name to number)
            }
        }
        return results
    }

    /**
     * Prefer the current user's OWN registered country over device-locale
     * guessing: normalizePhone() needs a region hint to interpret a locally
     * formatted number (no "+" — the overwhelmingly common way real address
     * books store local contacts), and defaultRegion() can only infer that
     * from SIM/locale. Since a user's registered country is exactly what
     * every OTHER user's own number was normalized against at signup, and
     * the people in someone's address book are overwhelmingly likely to
     * share that same country, this is the far more reliable primary hint —
     * same reasoning as the Dart version's fetchMatchedContacts().
     */
    suspend fun fetchMatchedContacts(context: Context): List<AppContact> = withContext(Dispatchers.IO) {
        val cachedProfile = AuthManager.getCachedProfile(context)
        val region = if (!cachedProfile?.country.isNullOrBlank()) {
            cachedProfile!!.country
        } else {
            defaultRegion(context)
        }

        val deviceContacts = readDeviceContacts(context)
        val deviceByPhone = LinkedHashMap<String, DeviceEntry>()
        for ((name, number) in deviceContacts) {
            val normalized = normalizePhone(number, region) ?: continue
            deviceByPhone[normalized] = DeviceEntry(name = name, source = "DEVICE")
        }

        try {
            val snapshot = FirebaseDatabase.getInstance().getReference("users").get().await()
            val matched = mutableListOf<AppContact>()

            for (child in snapshot.children) {
                val profile = child.getValue(UserProfile::class.java) ?: continue
                if (profile.phone.isBlank()) continue
                val entry = deviceByPhone[profile.phone] ?: continue
                matched.add(
                    AppContact(
                        name = entry.name,
                        phone = profile.phone,
                        uid = profile.uid.ifBlank { child.key ?: profile.phone },
                        photoUrl = profile.photoUrl,
                        source = entry.source
                    )
                )
            }

            matched.sortedBy { it.name.lowercase() }
        } catch (e: Exception) {
            Log.e("ContactsRepository", "fetchMatchedContacts failed", e)
            emptyList()
        }
    }
}
