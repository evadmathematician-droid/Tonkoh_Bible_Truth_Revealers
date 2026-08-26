package com.tbtrapp.components

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Call
import androidx.compose.material.icons.filled.Message
import androidx.compose.material.icons.filled.Videocam
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.tbtrapp.data.AppContact

// Bottom sheet shown when a contact row is tapped: Message / Voice Call /
// Video Call. This component is intentionally dumb — it just renders the
// three actions and calls back to whatever the screen passed in. The
// caller decides what "Message"/"Voice Call"/"Video Call" actually do
// (in-app chat + WebRTC call for matched app users vs. SMS/dialer/WhatsApp
// fallback for non-app contacts) — that branching lives in the screen
// that shows this sheet, not here.
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ContactActionSheet(
    contact: AppContact,
    onDismiss: () -> Unit,
    onMessage: (AppContact) -> Unit,
    onVoiceCall: (AppContact) -> Unit,
    onVideoCall: (AppContact) -> Unit
) {
    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(modifier = Modifier.padding(horizontal = 8.dp, vertical = 4.dp)) {

            Text(
                text = contact.name,
                fontWeight = FontWeight.Bold,
                modifier = Modifier.padding(start = 16.dp, bottom = 2.dp)
            )
            Text(
                text = contact.phone,
                color = Color.Gray,
                modifier = Modifier.padding(start = 16.dp, bottom = 12.dp)
            )

            ActionItem(icon = Icons.Default.Message, label = "Message") {
                onMessage(contact)
                onDismiss()
            }
            // 🔑 FIX: Voice Call and Video Call rows never existed — only
            // "Message" was rendered, even though the sheet's whole point
            // (per its own header comment) was Message/Voice/Video.
            ActionItem(icon = Icons.Default.Call, label = "Voice Call") {
                onVoiceCall(contact)
                onDismiss()
            }
            ActionItem(icon = Icons.Default.Videocam, label = "Video Call") {
                onVideoCall(contact)
                onDismiss()
            }

            Spacer(modifier = Modifier.height(12.dp))
        }
    }
}

@Composable
private fun ActionItem(
    icon: ImageVector,
    label: String,
    onClick: () -> Unit
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable { onClick() }
            .padding(horizontal = 16.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Icon(imageVector = icon, contentDescription = label, tint = Color(0xFF365DDB))
        Spacer(modifier = Modifier.width(20.dp))
        Text(text = label, fontWeight = FontWeight.Medium)
    }
}