package com.tbtrapp.calls

import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.net.Uri

/**
 * A ContentProvider is instantiated by the OS before Application.onCreate()
 * runs — even in a process that was started purely to handle a push while
 * the app was fully killed. Registering one just to grab applicationContext
 * this early means CallNotificationServiceExtension never has to guess
 * whether your Application class has already run.
 */
class CallAppContextProvider : ContentProvider() {
    override fun onCreate(): Boolean {
        context?.applicationContext?.let { CallAppContext.init(it) }
        return true
    }

    override fun query(uri: Uri, projection: Array<String>?, selection: String?, selectionArgs: Array<String>?, sortOrder: String?): Cursor? = null
    override fun getType(uri: Uri): String? = null
    override fun insert(uri: Uri, values: ContentValues?): Uri? = null
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<String>?): Int = 0
    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<String>?): Int = 0
}

object CallAppContext {
    lateinit var context: Context
        private set

    internal fun init(ctx: Context) {
        if (!::context.isInitialized) context = ctx
    }
}