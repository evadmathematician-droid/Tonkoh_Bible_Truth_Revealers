package com.tbtrapp.data

import androidx.compose.runtime.mutableStateOf

/**
 * App-wide contacts cache — same pattern as GlobalAudioPlayer.
 *
 * Because this is a plain Kotlin object (not screen-scoped remember state),
 * it survives navigating away from and back to ContactScreen. The list is
 * fetched once per app process (first time the screen is ever opened), and
 * every re-entry after that reads instantly from here — no spinner, no
 * re-query. A quiet background sync (see ContactScreen) then checks for
 * newly-registered matches without blocking the UI.
 */
object ContactsCache {
    val contacts = mutableStateOf<List<AppContact>>(emptyList())
    var hasLoadedOnce = false
}
