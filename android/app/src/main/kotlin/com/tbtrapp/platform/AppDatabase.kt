package com.tbtrapp.platform

import com.google.firebase.database.DatabaseException
import com.google.firebase.database.FirebaseDatabase

/**
 * The Realtime Database instance native code uses — the same one the Flutter
 * plugin uses (same app, same URL), so they share a single connection.
 *
 * Native code can be the first to touch the database (a call push or the
 * presence service starting before Flutter). Persistence has to be switched
 * on before any other use, so do it here; Dart's own
 * `setPersistenceEnabled(true)` then fails harmlessly (it's caught) and the
 * disk cache stays on either way.
 */
object AppDatabase {
    @Volatile
    private var configured = false

    fun get(): FirebaseDatabase {
        val db = FirebaseDatabase.getInstance()
        if (!configured) {
            synchronized(this) {
                if (!configured) {
                    configured = true
                    try {
                        db.setPersistenceEnabled(true)
                    } catch (_: DatabaseException) {
                        // Flutter already started using it — already set.
                    }
                }
            }
        }
        return db
    }
}
