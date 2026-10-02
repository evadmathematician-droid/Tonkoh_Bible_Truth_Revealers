package com.tbtrapp.calls

import android.annotation.SuppressLint
import android.content.ComponentName
import android.content.Context
import android.net.Uri
import android.os.Bundle
import android.telecom.PhoneAccount
import android.telecom.PhoneAccountHandle
import android.telecom.TelecomManager
import android.util.Log
import java.util.concurrent.ConcurrentHashMap

/**
 * Owns the app's self-managed Telecom [PhoneAccount] and is the single entry
 * point for handing a call to the OS.
 *
 * Handing calls to Telecom (rather than only writing a Firebase record and
 * starting a foreground service directly) is what gives the app:
 *  - the background foreground-service-start exemption that lets the ringing
 *    UI appear from a cold / fully-killed process (see
 *    [CallConnectionService.onCreateIncomingConnection]);
 *  - correct audio focus / routing and "other call" handling;
 *  - an entry in the system call log and integration with Bluetooth / wearables.
 *
 * Self-managed accounts never touch the SIM or route through the carrier.
 *
 * The `EXTRA_*` keys below are the contract shared with
 * [CallConnectionService], which reads them back off the [android.telecom.ConnectionRequest].
 */
object TelecomCallManager {

    const val EXTRA_CALL_ID = "com.tbtrapp.calls.CALL_ID"
    const val EXTRA_CALLER_ID = "com.tbtrapp.calls.CALLER_ID"
    const val EXTRA_CALLER_NAME = "com.tbtrapp.calls.CALLER_NAME"
    const val EXTRA_CALLER_PHOTO = "com.tbtrapp.calls.CALLER_PHOTO"
    const val EXTRA_CHAT_ID = "com.tbtrapp.calls.CHAT_ID"
    const val EXTRA_CALL_TYPE = "com.tbtrapp.calls.CALL_TYPE"

    private const val TAG = "TelecomCallManager"
    private const val ACCOUNT_ID = "tbtr_self_managed"
    private const val ACCOUNT_LABEL = "TBTR"

    /**
     * Call ids already handed to Telecom as incoming, so a duplicate push /
     * RTDB event for the same call doesn't produce a second ring. Entries are
     * released by [clearIncomingCall] once the call's lifecycle ends
     * (see [CallService.clearCallState]).
     */
    private val activeIncoming: MutableSet<String> = ConcurrentHashMap.newKeySet()

    private fun accountHandle(context: Context) = PhoneAccountHandle(
        ComponentName(context.applicationContext, CallConnectionService::class.java),
        ACCOUNT_ID
    )

    /** Idempotent — registering an already-registered account is a no-op. */
    fun registerPhoneAccount(context: Context) {
        val tm = context.getSystemService(Context.TELECOM_SERVICE) as? TelecomManager ?: return
        try {
            val account = PhoneAccount.builder(accountHandle(context), ACCOUNT_LABEL)
                .setCapabilities(PhoneAccount.CAPABILITY_SELF_MANAGED)
                .build()
            tm.registerPhoneAccount(account)
        } catch (e: Exception) {
            Log.e(TAG, "registerPhoneAccount failed", e)
        }
    }

    /**
     * Outgoing call. Triggers [CallConnectionService.onCreateOutgoingConnection],
     * which reads [EXTRA_CALL_ID] / [EXTRA_CALL_TYPE] from the nested
     * [TelecomManager.EXTRA_OUTGOING_CALL_EXTRAS] bundle.
     */
    @SuppressLint("MissingPermission")
    fun placeOutgoingCall(context: Context, callId: String, calleeId: String, callType: String) {
        val tm = context.getSystemService(Context.TELECOM_SERVICE) as? TelecomManager ?: return
        registerPhoneAccount(context)

        val callExtras = Bundle().apply {
            putString(EXTRA_CALL_ID, callId)
            putString(EXTRA_CALL_TYPE, callType)
            putString(EXTRA_CALLER_ID, calleeId)
        }
        val extras = Bundle().apply {
            putParcelable(TelecomManager.EXTRA_PHONE_ACCOUNT_HANDLE, accountHandle(context))
            putBundle(TelecomManager.EXTRA_OUTGOING_CALL_EXTRAS, callExtras)
        }

        try {
            tm.placeCall(Uri.fromParts("tel", calleeId, null), extras)
        } catch (e: SecurityException) {
            Log.e(TAG, "placeCall denied — MANAGE_OWN_CALLS missing or account disabled in Settings", e)
        } catch (e: Exception) {
            Log.e(TAG, "placeCall failed", e)
        }
    }

    /**
     * Incoming call. De-dupes on [callId]; the first caller wins. Triggers
     * [CallConnectionService.onCreateIncomingConnection], which reads the flat
     * `EXTRA_*` keys back off the request.
     */
    @SuppressLint("MissingPermission")
    fun addIncomingCall(
        context: Context,
        callId: String,
        callerId: String,
        callerName: String,
        callerPhoto: String,
        chatId: String,
        callType: String
    ) {
        if (callId.isBlank()) return
        if (!activeIncoming.add(callId)) {
            Log.w(TAG, "addIncomingCall ignored — $callId already tracked")
            return
        }

        val tm = context.getSystemService(Context.TELECOM_SERVICE) as? TelecomManager
        if (tm == null) {
            activeIncoming.remove(callId)
            return
        }
        registerPhoneAccount(context)

        val extras = Bundle().apply {
            putString(EXTRA_CALL_ID, callId)
            putString(EXTRA_CALLER_ID, callerId)
            putString(EXTRA_CALLER_NAME, callerName)
            putString(EXTRA_CALLER_PHOTO, callerPhoto)
            putString(EXTRA_CHAT_ID, chatId)
            putString(EXTRA_CALL_TYPE, callType)
        }

        try {
            tm.addNewIncomingCall(accountHandle(context), extras)
        } catch (e: SecurityException) {
            activeIncoming.remove(callId)
            Log.e(TAG, "addNewIncomingCall denied — account not enabled in Settings", e)
        } catch (e: Exception) {
            activeIncoming.remove(callId)
            Log.e(TAG, "addNewIncomingCall failed", e)
        }
    }

    /** Release the de-dup guard once the call's lifecycle is over. */
    fun clearIncomingCall(callId: String) {
        activeIncoming.remove(callId)
    }
}
