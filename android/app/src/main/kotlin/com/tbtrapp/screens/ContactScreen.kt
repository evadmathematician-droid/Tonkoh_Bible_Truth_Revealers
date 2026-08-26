package com.tbtrapp.screens

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.provider.ContactsContract
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Call
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.Videocam
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import androidx.navigation.NavController
import com.tbtrapp.auth.AuthManager
import com.tbtrapp.calls.initiateCall
import com.tbtrapp.calls.OutgoingCallActivity
import com.tbtrapp.data.AppContact
import com.tbtrapp.data.ContactsCache
import com.tbtrapp.data.ContactsRepository
import com.tbtrapp.data.ProfilePhotoCache
import com.tbtrapp.components.ContactActionSheet
import com.tbtrapp.components.ContactRow
import com.tbtrapp.components.FullScreenProfilePhoto
import com.tbtrapp.util.PhoneActions
import kotlinx.coroutines.launch
import androidx.compose.foundation.shape.RoundedCornerShape


@Composable
fun ContactScreen(
    navController: NavController
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()

    val background = Brush.verticalGradient(
        listOf(Color(0xFFF6F9FF), Color(0xFFE7F0FF), Color(0xFFFFFFFF))
    )

    var hasPermission by remember {
        mutableStateOf(
            ContextCompat.checkSelfPermission(
                context, Manifest.permission.READ_CONTACTS
            ) == PackageManager.PERMISSION_GRANTED
        )
    }

    val appContacts by ContactsCache.contacts

    var isLoading by remember { mutableStateOf(false) }

    var menuExpanded by remember { mutableStateOf(false) }
    var showDeleteConfirm by remember { mutableStateOf(false) }
    var showDiscussionPicker by remember { mutableStateOf(false) }

    var selectedContact by remember { mutableStateOf<AppContact?>(null) }
    var photoViewerContact by remember { mutableStateOf<AppContact?>(null) }

    // ── current user info needed for calling ──
    var currentUid by remember { mutableStateOf<String?>(null) }
    var currentUserName by remember { mutableStateOf("") }

    val permissionLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.RequestPermission()
    ) { granted -> hasPermission = granted }

    suspend fun refreshContacts() {
        if (!hasPermission) return
        isLoading = true
        val fetched = ContactsRepository.fetchMatchedContacts(context)
        ContactsCache.contacts.value = fetched
        ContactsCache.hasLoadedOnce = true
        isLoading = false
    }

    suspend fun syncContactsQuietly() {
        if (!hasPermission) return
        val fetched = ContactsRepository.fetchMatchedContacts(context)
        ContactsCache.contacts.value = fetched
    }

    LaunchedEffect(Unit) {
        if (!hasPermission) permissionLauncher.launch(Manifest.permission.READ_CONTACTS)
    }

    LaunchedEffect(hasPermission) {
        if (!hasPermission) return@LaunchedEffect

        if (!ContactsCache.hasLoadedOnce) {
            refreshContacts()
        } else {
            syncContactsQuietly()
        }
    }

    // Fetch current user once so we can initiate calls
    LaunchedEffect(Unit) {
        val uid = AuthManager.currentUid(context)
        currentUid = uid
        if (uid != null) {
            AuthManager.fetchProfile(
                context = context,
                phoneKey = uid,
                onResult = { profile ->
                    currentUserName = profile?.name ?: ""
                }
            )
        }
    }

    Box(modifier = Modifier.fillMaxSize()) {

        Column(
            modifier = Modifier
                .fillMaxSize()
                .background(background)
                .padding(horizontal = 22.dp),
            horizontalAlignment = Alignment.CenterHorizontally
        ) {

            Spacer(modifier = Modifier.height(36.dp))

            Text("WELCOME TO", fontSize = 15.sp, color = Color.Gray, fontWeight = FontWeight.Medium)
            Spacer(modifier = Modifier.height(8.dp))
            Text(
                text = "TONKOH BIBLE\nTRUTH REVEALERS",
                textAlign = TextAlign.Center,
                fontSize = 28.sp,
                fontWeight = FontWeight.ExtraBold,
                color = Color(0xFF102A72)
            )
            Spacer(modifier = Modifier.height(10.dp))
            Text(
                text = "We Preach Christ and Him Crucified",
                textAlign = TextAlign.Center,
                fontSize = 14.sp,
                color = Color(0xFFB71C1C),
                fontWeight = FontWeight.SemiBold
            )
            Spacer(modifier = Modifier.height(24.dp))

            Text(
                text = "Contacts on the app",
                fontSize = 16.sp,
                fontWeight = FontWeight.Bold,
                color = Color(0xFF102A72),
                modifier = Modifier.fillMaxWidth().padding(bottom = 10.dp),
                textAlign = TextAlign.Start
            )

            when {
                !hasPermission -> {
                    Card(shape = RoundedCornerShape(18.dp), modifier = Modifier.fillMaxWidth()) {
                        Column(
                            modifier = Modifier.padding(20.dp),
                            horizontalAlignment = Alignment.CenterHorizontally
                        ) {
                            Text(
                                "Contact permission is needed to show which of your contacts are using the app.",
                                textAlign = TextAlign.Center,
                                fontSize = 13.sp
                            )
                            Spacer(modifier = Modifier.height(12.dp))
                            Button(onClick = {
                                permissionLauncher.launch(Manifest.permission.READ_CONTACTS)
                            }) { Text("Grant Access") }
                        }
                    }
                }

                isLoading -> {
                    Box(
                        modifier = Modifier.fillMaxWidth().padding(vertical = 40.dp),
                        contentAlignment = Alignment.Center
                    ) { CircularProgressIndicator() }
                }

                appContacts.isEmpty() -> {
                    Text(
                        "None of your contacts are using the app yet.",
                        fontSize = 13.sp,
                        color = Color.Gray,
                        modifier = Modifier.padding(vertical = 30.dp)
                    )
                }

                else -> {
                    LazyColumn(
                        modifier = Modifier.fillMaxWidth(),
                        verticalArrangement = Arrangement.spacedBy(10.dp)
                    ) {
                        items(appContacts) { contact ->
                            Box(modifier = Modifier.fillMaxWidth()) {
                                ContactRow(
                                    contact = contact,
                                    onClick = { selectedContact = contact },
                                    onAvatarClick = {
                                        contact.uid?.let { photoViewerContact = contact }
                                    }
                                )

                                // WhatsApp-style audio / video call buttons

                            }
                        }
                    }
                }
            }

            Spacer(modifier = Modifier.height(20.dp))
        }

        Box(
            modifier = Modifier
                .align(Alignment.TopEnd)
                .statusBarsPadding()
                .padding(top = 8.dp, end = 8.dp)
        ) {
            IconButton(onClick = { menuExpanded = true }) {
                Icon(Icons.Default.MoreVert, contentDescription = "More options", tint = Color(0xFF102A72))
            }

            DropdownMenu(expanded = menuExpanded, onDismissRequest = { menuExpanded = false }) {
                DropdownMenuItem(
                    text = { Text("Add contact") },
                    onClick = {
                        menuExpanded = false
                        try {
                            context.startActivity(
                                Intent(Intent.ACTION_INSERT).apply {
                                    type = ContactsContract.Contacts.CONTENT_TYPE
                                }
                            )
                        } catch (e: Exception) {
                            android.util.Log.e("ContactScreen", "No Contacts app found", e)
                        }
                    }
                )
                DropdownMenuItem(
                    text = { Text("Refresh") },
                    onClick = { menuExpanded = false; scope.launch { refreshContacts() } }
                )
                DropdownMenuItem(
                    text = { Text("Delete contacts") },
                    onClick = { menuExpanded = false; showDeleteConfirm = true }
                )
                DropdownMenuItem(
                    text = { Text("Create a two person discussion") },
                    onClick = { menuExpanded = false; showDiscussionPicker = true }
                )
            }
        }
    }

    selectedContact?.let { contact ->
        ContactActionSheet(
            contact = contact,
            onDismiss = { selectedContact = null },
            onMessage = { c ->
                if (c.uid != null) {
                    navController.navigate("privateChat/${c.uid}")
                } else {
                    PhoneActions.sendSms(context, c.phone)
                }
            },
            onVoiceCall = { c ->
                val uid = currentUid
                val calleeUid = c.uid
                if (uid != null && calleeUid != null) {
                    initiateCall(
                        callerUid = uid,
                        callerName = currentUserName,
                        calleeUid = calleeUid,
                        chatId = "",
                        callType = "audio",
                        onCallIdReady = { callId ->
                            context.startActivity(
                                OutgoingCallActivity.buildIntent(context, callId, c.name, "audio")
                            )
                        }
                    )
                }
            },
            onVideoCall = { c ->
                val uid = currentUid
                val calleeUid = c.uid
                if (uid != null && calleeUid != null) {
                    initiateCall(
                        callerUid = uid,
                        callerName = currentUserName,
                        calleeUid = calleeUid,
                        chatId = "",
                        callType = "video",
                        onCallIdReady = { callId ->
                            context.startActivity(
                                OutgoingCallActivity.buildIntent(context, callId, c.name, "video")
                            )
                        }
                    )
                }
            }
        )
    }

    photoViewerContact?.let { contact ->
        FullScreenProfilePhoto(
            name = contact.name,
            photoUrl = contact.uid?.let { ProfilePhotoCache.photoFor(context, it) } ?: "",
            isOwnProfile = contact.uid == AuthManager.currentUid(context),
            onDismiss = { photoViewerContact = null }
        )
    }

    if (showDeleteConfirm) {
        AlertDialog(
            onDismissRequest = { showDeleteConfirm = false },
            title = { Text("Clear contact list?") },
            text = {
                Text("This clears the list shown here. It won't delete anything from your phone's contacts. You can rebuild it anytime with Refresh.")
            },
            confirmButton = {
                TextButton(onClick = {
                    ContactsCache.contacts.value = emptyList()
                    showDeleteConfirm = false
                }) { Text("Clear") }
            },
            dismissButton = {
                TextButton(onClick = { showDeleteConfirm = false }) { Text("Cancel") }
            }
        )
    }

    if (showDiscussionPicker) {
        AlertDialog(
            onDismissRequest = { showDiscussionPicker = false },
            title = { Text("Start a discussion with…") },
            text = {
                val eligible = appContacts.filter { it.uid != null }
                if (eligible.isEmpty()) {
                    Text("No matched contacts yet. Try Refresh first.")
                } else {
                    LazyColumn(
                        modifier = Modifier.heightIn(max = 320.dp),
                        verticalArrangement = Arrangement.spacedBy(4.dp)
                    ) {
                        items(eligible) { contact ->
                            Text(
                                text = contact.name,
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clickable {
                                        showDiscussionPicker = false
                                        navController.navigate("privateChat/${contact.uid}")
                                    }
                                    .padding(vertical = 10.dp)
                            )
                        }
                    }
                }
            },
            confirmButton = {
                TextButton(onClick = { showDiscussionPicker = false }) { Text("Cancel") }
            }
        )
    }
}