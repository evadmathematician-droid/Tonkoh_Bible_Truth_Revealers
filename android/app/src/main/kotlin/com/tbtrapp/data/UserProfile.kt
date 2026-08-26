package com.tbtrapp.data

// Mirrors lib/data/user_profile.dart field-for-field so a profile saved by
// either platform reads back identically on the other. `uid` IS the E.164
// phone number (see AuthManager.saveProfile) — there is no separate
// numeric user id.
//
// @JvmOverloads is required, not decorative: Firebase's
// snapshot.getValue(UserProfile::class.java) deserializes via reflection
// and needs a true zero-arg constructor. A Kotlin data class with only
// default-valued parameters does NOT generate one on its own — without
// @JvmOverloads every fetchProfile()/getValue() call would throw at
// runtime ("No matching constructor found").
data class UserProfile @JvmOverloads constructor(
    val uid: String = "",
    val name: String = "",
    val phone: String = "",
    val country: String = "",
    val photoUrl: String = "",
    val createdAt: Long = 0L
)
