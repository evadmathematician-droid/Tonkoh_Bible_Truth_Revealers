package com.tbtrapp.data 

// A phone-book contact matched against the app's registered users
data class AppContact(
    val name: String,
    val phone: String,
    val uid: String? = null,
    val photoUrl: String? = null,   // Base64 profile photo, same format as UserProfile.photoUrl
    val source: String = "UNKNOWN"
)