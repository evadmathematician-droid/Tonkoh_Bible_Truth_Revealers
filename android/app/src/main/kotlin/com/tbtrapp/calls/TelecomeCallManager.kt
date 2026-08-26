package com.tbtrapp.calls

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.telecom.PhoneAccount
import android.telecom.PhoneAccountHandle
import android.telecom.TelecomManager
import androidx.core.content.ContextCompat

object TelecomCallManager {

    private const val ACCOUNT_ID = "tbtrapp_self_managed"

    const val EXTRA_CALL_ID = "extra_telecom_call_id"
    const val EXTRA_CALLER_NAME = "extra_telecom_caller_name"
    const val EXTRA_CALL_TYPE = "extra_telecom_call_type"
    const val EXTRA_CALLER_ID = "extra_telecom_caller_id"
    const val EXTRA_CHAT_ID = "extra_telecom_chat_id"
    const val EXTRA_CALLER_PHOTO = "extra_telecom_caller_photo"

    fun getPhoneAccountHandle(context: Context): PhoneAccountHandle =
        PhoneAccountHandle(ComponentName(context, CallConnectionService::class.java), ACCOUNT_ID)

    /** Call from Application.onCreate(). Idempotent — safe to call on every process start. */
    fun registerPhoneAccount(context: Context) {
        val telecomManager = context.getSystemService(Context.TELECOM_SERVICE) as TelecomManager
        val handle = getPhoneAccountHandle(context)
        val account = PhoneAccount.builder(handle, "TBTR Calls")
            .setCapabilities(PhoneAccount.CAPABILITY_SELF_MANAGED)
            .setShortDescription("TBTR voice and video calls")
            .build()
        telecomManager.registerPhoneAccount(account)
    }

    fun isAccountEnabled(context: Context): Boolean {
        val telecomManager = context.getSystemService(Context.TELECOM_SERVICE) as TelecomManager
        return try {
            telecomManager.getPhoneAccount(getPhoneAccountHandle(context))?.isEnabled == true
        } catch (e: SecurityException) {
            false
        }
    }

    /** Opens system settings where the user flips the calling account on. One-time, not per-call. */
    fun requestEnableAccount(context: Context) {
        context.startActivity(
            Intent(TelecomManager.ACTION_CHANGE_PHONE_ACCOUNTS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        )
    }

    fun addIncomingCall(
        context: Context,
        callId: String,
        callerId: String,
        callerName: String,
        callerPhoto: String,
        chatId: String,
        callType: String
    ) {
        val telecomManager = context.getSystemService(Context.TELECOM_SERVICE) as TelecomManager
        val extras = Bundle().apply {
            putString(EXTRA_CALL_ID, callId)
            putString(EXTRA_CALLER_ID, callerId)
            putString(EXTRA_CALLER_NAME, callerName)
            putString(EXTRA_CALLER_PHOTO, callerPhoto)
            putString(EXTRA_CHAT_ID, chatId)
            putString(EXTRA_CALL_TYPE, callType)
            putParcelable(TelecomManager.EXTRA_INCOMING_CALL_ADDRESS, Uri.fromParts("tel", callerId, null))
        }
        try {
            telecomManager.addNewIncomingCall(getPhoneAccountHandle(context), extras)
        } catch (e: SecurityException) {
            // Account not registered/enabled yet (e.g. user never completed the
            // one-time setup prompt). Don't drop the call — fall back to the
            // old direct path so it at least works while the app is foregrounded.
            android.util.Log.e("TelecomCallManager", "addNewIncomingCall failed: ${e.message}")
            fallbackStartCallService(context, callId, callerId, callerName, callerPhoto, chatId, callType)
        }
    }

    /**
     * Places an OUTGOING call through this app's self-managed Telecom account —
     * the counterpart to addIncomingCall(). Routes through
     * CallConnectionService.onCreateOutgoingConnection(), NOT the SIM/carrier
     * dialer (self-managed accounts never touch the SIM regardless).
     *
     * This must be called for every app-initiated call (audio or video) so
     * Telecom is aware of it: proper audio focus/routing, "other call in
     * progress" handling, Bluetooth/car integration, and system call log
     * entries under the TBTR account all depend on Telecom knowing the call
     * exists. Without this call, onCreateOutgoingConnection() never fires and
     * the call exists only as a Firebase record + push notification.
     *
     * @param calleeId used only to build the placeCall() address URI — your
     *   actual call routing stays on Firebase/WebRTC via callId, unchanged.
     */
    fun placeOutgoingCall(
        context: Context,
        callId: String,
        calleeId: String,
        callType: String
    ) {
        val telecomManager = context.getSystemService(Context.TELECOM_SERVICE) as TelecomManager

        val outgoingExtras = Bundle().apply {
            putString(EXTRA_CALL_ID, callId)
            putString(EXTRA_CALL_TYPE, callType)
        }
        val callExtras = Bundle().apply {
            putParcelable(TelecomManager.EXTRA_PHONE_ACCOUNT_HANDLE, getPhoneAccountHandle(context))
            putBundle(TelecomManager.EXTRA_OUTGOING_CALL_EXTRAS, outgoingExtras)
        }

        try {
            telecomManager.placeCall(Uri.fromParts("tel", calleeId, null), callExtras)
        } catch (e: SecurityException) {
            // Same guard as addIncomingCall: account not enabled yet. The call
            // still exists in Firebase/push, it just won't have Telecom UI/state.
            android.util.Log.e("TelecomCallManager", "placeCall failed: ${e.message}")
        }
    }

    private fun fallbackStartCallService(
        context: Context, callId: String, callerId: String, callerName: String,
        callerPhoto: String, chatId: String, callType: String
    ) {
        val intent = Intent(context, CallService::class.java).apply {
            action = CallService.ACTION_INCOMING_CALL
            putExtra(CallService.EXTRA_CALL_ID, callId)
            putExtra(CallService.EXTRA_CALLER_ID, callerId)
            putExtra(CallService.EXTRA_CALLER_NAME, callerName)
            putExtra(CallService.EXTRA_CALLER_PHOTO, callerPhoto)
            putExtra(CallService.EXTRA_CHAT_ID, chatId)
            putExtra(CallService.EXTRA_CALL_TYPE, callType)
        }
        ContextCompat.startForegroundService(context, intent)
    }
}