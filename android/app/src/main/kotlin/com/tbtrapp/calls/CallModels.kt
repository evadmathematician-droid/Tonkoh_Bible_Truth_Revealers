package com.tbtrapp.calls

/**
 * Firebase-serialisable ICE candidate.
 *
 * Written to `calls/{id}/callerCandidates` / `calls/{id}/calleeCandidates` by
 * [WebRtcClient] and read back on the other side via
 * `DataSnapshot.getValue(IceCandidateModel::class.java)`, which is why every
 * field needs a default (Firebase requires a no-arg constructor).
 */
data class IceCandidateModel(
    val sdpMid: String = "",
    val sdpMLineIndex: Int = 0,
    val candidate: String = ""
)
