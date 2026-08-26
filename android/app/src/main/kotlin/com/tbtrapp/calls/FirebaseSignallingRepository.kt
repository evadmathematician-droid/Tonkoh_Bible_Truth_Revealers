package com.tbtrapp.call

import android.util.Log
import com.google.firebase.database.ChildEventListener
import com.google.firebase.database.DataSnapshot
import com.google.firebase.database.DatabaseError
import com.google.firebase.database.FirebaseDatabase
import com.google.firebase.database.ValueEventListener

class FirebaseSignalingRepository {

    private val db = FirebaseDatabase.getInstance()
    private fun callRef(callId: String) = db.getReference("calls").child(callId)

    fun createCall(session: CallSession, onComplete: (String) -> Unit) {
        val ref = db.getReference("calls").push()
        val callId = ref.key ?: return
        ref.setValue(session.copy(callId = callId, createdAt = System.currentTimeMillis()))
            .addOnSuccessListener { onComplete(callId) }
    }

    fun setState(callId: String, state: CallState) {
        callRef(callId).child("state").setValue(state.name)
    }

    fun observeState(callId: String, onChange: (CallState) -> Unit): ValueEventListener {
        val listener = object : ValueEventListener {
            override fun onDataChange(snapshot: DataSnapshot) {
                val raw = snapshot.getValue(String::class.java) ?: return
                runCatching { CallState.valueOf(raw) }.getOrNull()?.let(onChange)
            }
            override fun onCancelled(error: DatabaseError) {}
        }
        callRef(callId).child("state").addValueEventListener(listener)
        return listener
    }

    fun stopObservingState(callId: String, listener: ValueEventListener) {
        callRef(callId).child("state").removeEventListener(listener)
    }

    fun sendOffer(callId: String, sdp: String) {
        callRef(callId).child("offer").setValue(SdpPayload("offer", sdp))
    }

    fun sendAnswer(callId: String, sdp: String) {
        callRef(callId).child("answer").setValue(SdpPayload("answer", sdp))
    }

    fun observeOffer(callId: String, onOffer: (String) -> Unit): ValueEventListener {
        val listener = object : ValueEventListener {
            override fun onDataChange(snapshot: DataSnapshot) {
                snapshot.getValue(SdpPayload::class.java)?.let { onOffer(it.sdp) }
            }
            override fun onCancelled(error: DatabaseError) {}
        }
        callRef(callId).child("offer").addValueEventListener(listener)
        return listener
    }

    fun observeAnswer(callId: String, onAnswer: (String) -> Unit): ValueEventListener {
        val listener = object : ValueEventListener {
            override fun onDataChange(snapshot: DataSnapshot) {
                snapshot.getValue(SdpPayload::class.java)?.let { onAnswer(it.sdp) }
            }
            override fun onCancelled(error: DatabaseError) {}
        }
        callRef(callId).child("answer").addValueEventListener(listener)
        return listener
    }

    // 🔑 FIX: write to callerCandidates / calleeCandidates to match OngoingCallActivity
    fun sendIceCandidate(callId: String, isCaller: Boolean, candidate: IceCandidateModel) {
        val childName = if (isCaller) "callerCandidates" else "calleeCandidates"
        callRef(callId).child(childName).push().setValue(candidate)
    }

    // 🔑 FIX: listen to the opposite side's candidate list
    fun observeRemoteIceCandidates(
        callId: String,
        isCaller: Boolean,
        onCandidate: (IceCandidateModel) -> Unit
    ): ChildEventListener {
        val childName = if (isCaller) "calleeCandidates" else "callerCandidates"
        val listener = object : ChildEventListener {
            override fun onChildAdded(snapshot: DataSnapshot, previousChildName: String?) {
                snapshot.getValue(IceCandidateModel::class.java)?.let(onCandidate)
            }
            override fun onChildChanged(snapshot: DataSnapshot, previousChildName: String?) {}
            override fun onChildRemoved(snapshot: DataSnapshot) {}
            override fun onChildMoved(snapshot: DataSnapshot, previousChildName: String?) {}
            override fun onCancelled(error: DatabaseError) {}
        }
        callRef(callId).child(childName).addChildEventListener(listener)
        return listener
    }

    fun removeAllListeners(callId: String) {
        callRef(callId).removeEventListener(object : ValueEventListener {
            override fun onDataChange(snapshot: DataSnapshot) {}
            override fun onCancelled(error: DatabaseError) {}
        })
    }

    fun deleteCall(callId: String) {
        callRef(callId).removeValue()
    }

    // -----------------------------------------------------------------
    // INCOMING CALL LISTENER
    // -----------------------------------------------------------------

    fun startListeningForIncomingCalls(
        myUid: String,
        onIncomingCall: (callId: String, callerUid: String, callerName: String, type: String) -> Unit
    ): ChildEventListener {
        val listener = object : ChildEventListener {
            override fun onChildAdded(snapshot: DataSnapshot, previousChildName: String?) {
                val callId = snapshot.child("callId").getValue(String::class.java) ?: snapshot.key ?: return

                val calleeUid = snapshot.child("calleeId").getValue(String::class.java) ?: return
                if (calleeUid != myUid) return

                val stateRaw = snapshot.child("state").getValue(String::class.java)
                    ?: snapshot.child("status").getValue(String::class.java)
                    ?: return
                if (!stateRaw.equals("RINGING", ignoreCase = true)) return

                val createdAt = snapshot.child("createdAt").getValue(Long::class.java)
                    ?: snapshot.child("timestamp").getValue(Long::class.java)
                    ?: 0L
                val ageMs = System.currentTimeMillis() - createdAt
                if (ageMs > 30_000) {
                    Log.d("FirebaseSignaling", "Ignoring stale call $callId (age=${ageMs / 1000}s)")
                    if (ageMs > 300_000) snapshot.ref.removeValue()
                    return
                }

                val type = snapshot.child("type").getValue(String::class.java)
                    ?: snapshot.child("callType").getValue(String::class.java)
                    ?: "audio"

                val callerUid = snapshot.child("callerId").getValue(String::class.java) ?: return
                val callerName = snapshot.child("callerName").getValue(String::class.java) ?: "Unknown"

                Log.d("FirebaseSignaling", "📞 Incoming call: $callId type=$type from=$callerName")
                onIncomingCall(callId, callerUid, callerName, type)
            }

            override fun onChildChanged(snapshot: DataSnapshot, previousChildName: String?) {}
            override fun onChildRemoved(snapshot: DataSnapshot) {}
            override fun onChildMoved(snapshot: DataSnapshot, previousChildName: String?) {}
            override fun onCancelled(error: DatabaseError) {
                Log.e("FirebaseSignaling", "Listener cancelled", error.toException())
            }
        }

        db.getReference("calls")
            .orderByChild("calleeId")
            .equalTo(myUid)
            .addChildEventListener(listener)

        return listener
    }

    fun stopListeningForIncomingCalls(listener: ChildEventListener) {
        db.getReference("calls").removeEventListener(listener)
    }
}