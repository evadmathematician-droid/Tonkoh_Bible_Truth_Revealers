package com.tbtrapp.calls

import android.telecom.Connection
import android.telecom.DisconnectCause
import java.util.concurrent.ConcurrentHashMap

object CallConnectionRegistry {
    private val connections = ConcurrentHashMap<String, Connection>()

    fun put(callId: String, connection: Connection) { connections[callId] = connection }
    fun get(callId: String): Connection? = connections[callId]
    fun remove(callId: String) { connections.remove(callId) }

    fun markActive(callId: String) { get(callId)?.setActive() }

    fun disconnect(callId: String, cause: Int) {
        get(callId)?.apply {
            setDisconnected(DisconnectCause(cause))
            destroy()
        }
        remove(callId)
    }
}