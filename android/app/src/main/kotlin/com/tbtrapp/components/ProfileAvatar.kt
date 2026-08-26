// ui/components/ProfileAvatar.kt
package com.tbtrapp.components

import android.util.Base64
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil.compose.AsyncImage
import androidx.compose.ui.platform.LocalContext
import com.tbtrapp.data.ProfilePhotoCache


/**
 * Single source of truth for "who is this" — contact rows, chat headers,
 * the discussion picker, wherever. Anywhere a photoUrl (Base64) is
 * available, use this instead of a hand-rolled initials circle, so a
 * saved photo shows up on every screen instead of just one.
 */
@Composable
fun ProfileAvatar(
    name: String,
    photoUrl: String?,
    size: Dp = 44.dp,
    onClick: (() -> Unit)? = null
) {
    val photoBytes = remember(photoUrl) {
        if (!photoUrl.isNullOrBlank()) {
            try { Base64.decode(photoUrl, Base64.NO_WRAP) } catch (_: Exception) { null }
        } else null
    }

    val base = Modifier
        .size(size)
        .clip(CircleShape)
        .let { if (onClick != null) it.clickable(onClick = onClick) else it }

    if (photoBytes != null) {
        AsyncImage(
            model = photoBytes,
            contentDescription = "$name's profile picture",
            contentScale = ContentScale.Crop,
            modifier = base
        )
    } else {
        Box(modifier = base.background(colorForName(name)), contentAlignment = Alignment.Center) {
            Text(
                text = initialsFor(name),
                color = Color.White,
                fontWeight = FontWeight.Bold,
                fontSize = (size.value / 2.6).sp
            )
        }
    }
}

/**
 * Cache-backed avatar — pass a uid instead of a raw photoUrl and this
 * pulls from ProfilePhotoCache automatically (instant, offline-safe,
 * self-updating). This is now the DEFAULT way to show anyone's photo
 * except the owner's own in-progress unsaved pick, which still needs
 * ProfileAvatar directly (see UserProfileIdentityScreen).
 */
@Composable
fun CachedProfileAvatar(
    uid: String?,
    name: String,
    size: Dp = 44.dp,
    onClick: (() -> Unit)? = null
) {
    val context = LocalContext.current
    val photoUrl = if (!uid.isNullOrBlank()) ProfilePhotoCache.photoFor(context, uid) else ""
    ProfileAvatar(name = name, photoUrl = photoUrl, size = size, onClick = onClick)
}

private fun initialsFor(name: String): String =
    name.trim().split(" ").filter { it.isNotBlank() }.take(2)
        .joinToString("") { it.first().uppercaseChar().toString() }
        .ifBlank { "?" }

// Keeps a letter-circle fallback for people with no photo yet, but colors
// it by name so it's not every single contact in the same flat blue.
private fun colorForName(name: String): Color {
    val palette = listOf(
        Color(0xFF102A72), Color(0xFF1E88E5), Color(0xFF00897B),
        Color(0xFF6D4C41), Color(0xFF8E24AA), Color(0xFFD81B60),
        Color(0xFF43A047), Color(0xFFF4511E)
    )
    val idx = name.trim().sumOf { it.code }.let { if (it < 0) -it else it } % palette.size
    return palette[idx]
}