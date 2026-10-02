package com.tbtrapp.calls

import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.net.Uri

/**
 * No-op [ContentProvider] whose only job is to capture the application
 * [Context] very early in process startup — providers are created before
 * `Application.onCreate()`, and this one is given a high `initOrder` in the
 * manifest.
 *
 * `android.telecom.Connection` (see [AppConnection]) has no Context of its
 * own, and Telecom callbacks can fire from a cold process before anything
 * else has run, so those code paths read the context from here.
 */
class CallAppContextProvider : ContentProvider() {

    companion object {
        @Volatile
        private var _appContext: Context? = null

        /** The application context. Safe to touch from any Telecom callback. */
        val appContext: Context
            get() = _appContext
                ?: error("CallAppContextProvider not yet created")

        val isReady: Boolean get() = _appContext != null
    }

    override fun onCreate(): Boolean {
        _appContext = context?.applicationContext
        return true
    }

    override fun query(
        uri: Uri,
        projection: Array<out String>?,
        selection: String?,
        selectionArgs: Array<out String>?,
        sortOrder: String?
    ): Cursor? = null

    override fun getType(uri: Uri): String? = null

    override fun insert(uri: Uri, values: ContentValues?): Uri? = null

    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = 0

    override fun update(
        uri: Uri,
        values: ContentValues?,
        selection: String?,
        selectionArgs: Array<out String>?
    ): Int = 0
}
