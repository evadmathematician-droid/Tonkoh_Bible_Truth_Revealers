package com.tbtrapp.util

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.util.Log

// Fallback actions for a device contact that isn't a registered app user
// yet (no uid) — ContactActionSheet still shows Message/Voice/Video for
// them, and "Message" routes here instead of in-app chat.
object PhoneActions {
    fun sendSms(context: Context, phone: String) {
        val intent = Intent(Intent.ACTION_SENDTO, Uri.parse("smsto:$phone"))
        try {
            context.startActivity(intent)
        } catch (e: Exception) {
            Log.e("PhoneActions", "No SMS app found for $phone", e)
        }
    }
}
