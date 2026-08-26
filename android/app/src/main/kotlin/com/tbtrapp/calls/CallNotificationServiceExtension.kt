package com.tbtrapp.calls

import com.onesignal.notifications.INotificationReceivedEvent
import com.onesignal.notifications.INotificationServiceExtension

class CallNotificationServiceExtension : INotificationServiceExtension {

    override fun onNotificationReceived(event: INotificationReceivedEvent) {
        val data = event.notification.additionalData ?: return
        if (data.optString("type") != "incoming_call") return

        val context = CallAppContext.context ?: return // set by CallAppContextProvider.onCreate()

        val callId = data.optString("callId")
        val callerId = data.optString("callerId")
        val callerName = data.optString("callerName")
        val callType = data.optString("callType")
        val chatId = data.optString("chatId")
        if (callId.isNullOrEmpty() || callerId.isNullOrEmpty()) return

        // Don't let OneSignal show its own generic notification — Telecom's
        // full-screen ringing UI (IncomingCallActivity) takes over instead.
        event.preventDefault()

        TelecomCallManager.addIncomingCall(
            context = context,
            callId = callId,
            callerId = callerId,
            callerName = callerName,
            callerPhoto = data.optString("callerPhoto", ""),
            callType = callType,
            chatId = chatId
        )
    }
}