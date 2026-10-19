package com.tbtrapp.share

/**
 * Hand-off between [ShareReceiverActivity] (which runs in the sending app's
 * task) and MainActivity (the app's own task, same process). Holds the
 * latest incoming share until Flutter takes it.
 */
object ShareInbox {
    const val EXTRA_HAS_SHARE = "com.tbtrapp.HAS_SHARE"

    data class SharedFile(val path: String, val mimeType: String, val name: String)

    data class Payload(
        val text: String?,
        val subject: String?,
        val files: List<SharedFile>,
        /** "audio" when shared via the Audio Screen Direct Share shortcut. */
        val target: String? = null,
    ) {
        fun isEmpty() = text.isNullOrBlank() && files.isEmpty()

        /** Shape read by lib/share/incoming_share.dart (IncomingShare.fromMap). */
        fun toMap(): Map<String, Any?> = mapOf(
            "text" to text,
            "subject" to subject,
            "target" to target,
            "files" to files.map {
                mapOf("path" to it.path, "mimeType" to it.mimeType, "name" to it.name)
            },
        )
    }

    private var pending: Payload? = null
    private var listener: ((Payload) -> Unit)? = null

    @Synchronized
    fun put(payload: Payload) {
        val l = listener
        if (l != null) l(payload) else pending = payload
    }

    @Synchronized
    fun take(): Payload? = pending.also { pending = null }

    /** While set, new shares go straight to [l] instead of waiting. */
    @Synchronized
    fun setListener(l: ((Payload) -> Unit)?) {
        listener = l
    }
}
