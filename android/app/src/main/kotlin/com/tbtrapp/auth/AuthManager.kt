package com.tbtrapp.auth

import android.content.Context
import android.net.Uri
import android.util.Base64
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.database.FirebaseDatabase
import com.tbtrapp.data.ProfilePhotoCache
import com.tbtrapp.data.UserProfile
import com.tbtrapp.util.normalizePhone
import java.io.File

object AuthManager {

    private val auth: FirebaseAuth
        get() = FirebaseAuth.getInstance()

    private val usersRef
        get() = FirebaseDatabase.getInstance().getReference("users")

    private const val MAX_PHOTO_BYTES = 600_000
    private const val ADMIN_PIN = "2222"
    private const val PREFS_NAME = "auth_cache"

    fun isAdminPinCorrect(pin: String): Boolean = pin == ADMIN_PIN

    fun ensureSignedIn(
        onReady: () -> Unit,
        onError: (String) -> Unit = {}
    ) {
        val existing = auth.currentUser
        if (existing != null) {
            onReady()
            return
        }

        auth.signInAnonymously()
            .addOnSuccessListener { result ->
                if (result.user != null) {
                    onReady()
                } else {
                    onError("Sign-in succeeded but no user was returned")
                }
            }
            .addOnFailureListener { e ->
                onError(e.message ?: "Anonymous sign-in failed")
            }
    }

    fun currentUid(context: Context): String? = getCachedProfile(context)?.uid

    fun getCachedProfile(context: Context): UserProfile? {
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val uid = prefs.getString("uid", null) ?: return null
        return UserProfile(
            uid = uid,
            name = prefs.getString("name", "") ?: "",
            phone = prefs.getString("phone", "") ?: "",
            country = prefs.getString("country", "") ?: "",
            photoUrl = prefs.getString("photoUrl", "") ?: "",
            createdAt = prefs.getLong("createdAt", 0L)
        )
    }

    private fun cacheProfileLocally(context: Context, profile: UserProfile) {
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putString("uid", profile.uid)
            .putString("name", profile.name)
            .putString("phone", profile.phone)
            .putString("country", profile.country)
            .putString("photoUrl", profile.photoUrl)
            .putLong("createdAt", profile.createdAt)
            .apply()
    }

    private fun clearCachedProfile(context: Context) {
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .clear()
            .apply()
    }

    fun fetchProfile(
        context: Context,
        phoneKey: String,
        onResult: (UserProfile?) -> Unit,
        onError: (String) -> Unit = {}
    ) {
        usersRef.child(phoneKey).get()
            .addOnSuccessListener { snapshot ->
                val profile = snapshot.getValue(UserProfile::class.java)
                if (profile != null) {
                    cacheProfileLocally(context, profile)
                }
                onResult(profile)
            }
            .addOnFailureListener { e ->
                onError(e.message ?: "Could not load profile")
            }
    }

    private fun encodeCroppedPhotoToBase64(photoUri: Uri): String {
        val path = photoUri.path
            ?: throw IllegalStateException("Cropped photo Uri has no path: $photoUri")
        val file = File(path)
        if (!file.exists()) {
            throw IllegalStateException("Cropped photo file does not exist: $path")
        }
        val bytes = file.readBytes()
        if (bytes.size > MAX_PHOTO_BYTES) {
            throw IllegalStateException(
                "Cropped photo is ${bytes.size / 1024}KB, over the ${MAX_PHOTO_BYTES / 1024}KB limit"
            )
        }
        return Base64.encodeToString(bytes, Base64.NO_WRAP)
    }

    /**
     * FIX: previously parsed the phone with a raw, single-region
     * PhoneNumberUtil.parse(phone, countryIso) call — completely separate
     * logic from util.normalizePhone (used for contact matching), with no
     * fallback. If the picker's country guess was ever wrong and the user
     * didn't correct it, this either rejected registration outright or
     * silently produced a technically-valid E.164 under the WRONG
     * country — permanently unmatchable no matter how contacts are saved
     * on any other device, since fallback-region matching on the contacts
     * side can't recover from a wrong value already stored in Firebase.
     *
     * Now shares the exact same normalizePhone(raw, regionHint) function
     * used by ContactsRepository — same primary-region-then-fallback
     * logic, so there is structurally one phone-normalization path in the
     * whole app, not two that merely happen to agree.
     */
    fun saveProfile(
        context: Context,
        name: String,
        phone: String,
        countryIso: String,
        newPhotoBase64: String? = null,
        onSuccess: () -> Unit,
        onError: (String) -> Unit = {}
    ) {
        val e164Phone = normalizePhone(phone.trim(), countryIso)
            ?: run {
                onError("That doesn't look like a valid phone number")
                return
            }

        usersRef.child(e164Phone).get()
            .addOnSuccessListener { snapshot ->
                val existing = snapshot.getValue(UserProfile::class.java)

                val finalPhotoUrl = when {
                    newPhotoBase64 != null -> newPhotoBase64
                    existing != null -> existing.photoUrl
                    else -> ""
                }
                val finalCreatedAt = existing?.createdAt ?: System.currentTimeMillis()

                val profile = UserProfile(
                    uid = e164Phone,
                    name = name.trim(),
                    phone = e164Phone,
                    country = countryIso,
                    photoUrl = finalPhotoUrl,
                    createdAt = finalCreatedAt
                )

                usersRef.child(e164Phone).setValue(profile)
                    .addOnSuccessListener {
                        cacheProfileLocally(context, profile)
                        if (profile.photoUrl.isNotBlank()) {
                            ProfilePhotoCache.updateOwn(context, e164Phone, profile.photoUrl)
                        }
                        com.onesignal.OneSignal.User.pushSubscription.id?.let { playerId ->
                            usersRef.child(e164Phone).child("oneSignalId").setValue(playerId)
                        }
                        onSuccess()
                    }
                    .addOnFailureListener { e ->
                        onError(e.message ?: "Could not save profile")
                    }
            }
            .addOnFailureListener { e ->
                onError(e.message ?: "Could not check existing profile")
            }
    }

    fun saveProfileWithPhoto(
        context: Context,
        name: String,
        phone: String,
        countryIso: String,
        newPhotoUri: Uri?,
        onSuccess: () -> Unit,
        onError: (String) -> Unit = {}
    ) {
        val newPhotoBase64: String? = if (newPhotoUri != null) {
            try {
                encodeCroppedPhotoToBase64(newPhotoUri)
            } catch (e: Exception) {
                android.util.Log.e("ProfilePhoto", "Base64 encode failed for $newPhotoUri", e)
                onError(e.message ?: "Could not process photo")
                return
            }
        } else {
            null
        }

        saveProfile(
            context = context,
            name = name,
            phone = phone,
            countryIso = countryIso,
            newPhotoBase64 = newPhotoBase64,
            onSuccess = onSuccess,
            onError = onError
        )
    }

    fun deleteAccount(
        context: Context,
        phoneKey: String,
        onSuccess: () -> Unit,
        onError: (String) -> Unit = {}
    ) {
        usersRef.child(phoneKey).removeValue()
            .addOnSuccessListener {
                clearCachedProfile(context)
                onSuccess()
            }
            .addOnFailureListener { e ->
                onError(e.message ?: "Could not delete account")
            }
    }
}
