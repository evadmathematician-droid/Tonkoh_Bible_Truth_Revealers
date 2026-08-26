package com.tbtrapp.ui.screens

import android.content.Context
import android.telephony.TelephonyManager
import android.widget.Toast
import androidx.compose.foundation.background
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Popup
import androidx.compose.ui.window.PopupProperties
import com.tbtrapp.auth.AuthManager
import java.util.Locale
import androidx.compose.foundation.rememberScrollState


// Priority/local countries pinned to the top of the dropdown; every other
// ISO 3166-1 country is generated dynamically below, so the picker covers
// every country libphonenumber supports, not just a hand-typed subset.
private val PRIORITY_CODES = listOf("SL", "GN", "LR", "GH", "NG")

// `by lazy` instead of a plain `val`: guarantees this ~195-entry list is
// built exactly once per process (first access), off the hot path of
// screen recomposition, rather than risking rebuild on every class load
// in some tooling/preview scenarios.
private val COUNTRY_OPTIONS: List<Pair<String, String>> by lazy {
    val all = Locale.getISOCountries()
        .map { code -> code to Locale("", code).displayCountry }
        .filter { it.second.isNotBlank() }

    val priority = PRIORITY_CODES.mapNotNull { code -> all.find { it.first == code } }
    val rest = all.filterNot { it.first in PRIORITY_CODES }.sortedBy { it.second }

    priority + rest
}

// Best-guess default so most people never have to touch the picker —
// falls back through SIM country, then device locale, then Sierra Leone.
private fun detectDefaultCountry(context: Context): String {
    val tm = context.getSystemService(Context.TELEPHONY_SERVICE) as? TelephonyManager
    val simCountry = tm?.simCountryIso?.uppercase(Locale.US)
    if (!simCountry.isNullOrBlank()) return simCountry

    val localeCountry = Locale.getDefault().country.uppercase(Locale.US)
    if (localeCountry.isNotBlank()) return localeCountry

    return "SL"
}

// Shown exactly once per install, right after anonymous sign-in, if this
// device has no saved profile yet (AuthManager.getCachedProfile(context)
// == null). Name + phone + country — self-entered, not SMS-verified — so
// people show up with a real name/number next to their messages and
// audio, the same way a WhatsApp contact name works. The country picker
// is what lets the phone number be stored correctly (E.164) whether the
// person is in Sierra Leone, Guinea, the US, or anywhere else — see
// AuthManager.saveProfile.
//
// Identity is the E.164 phone number itself, which doesn't exist yet when
// this screen runs — AuthManager.saveProfile computes it from the
// name/phone/country entered below and uses that as the Firebase key.
// Saving here simply reuses (and inherits the history of) whatever
// account already exists under that number.
@Composable
fun ProfileSetupScreen(
    onDone: () -> Unit
) {
    val context = LocalContext.current

    var name by remember { mutableStateOf("") }
    var phone by remember { mutableStateOf("") }
    var countryIso by remember { mutableStateOf(detectDefaultCountry(context)) }
    var isSaving by remember { mutableStateOf(false) }

    val selectedCountryName = remember(countryIso) {
        COUNTRY_OPTIONS.firstOrNull { it.first == countryIso }?.second ?: countryIso
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .imePadding()
            .verticalScroll(rememberScrollState())
            .background(
                Brush.verticalGradient(
                    listOf(Color(0xFFF3F7FF), Color.White)
                )
            ),
        contentAlignment = Alignment.Center
    ) {

        Card(
            modifier = Modifier
                .fillMaxWidth(.9f)
                .padding(20.dp),
            shape = RoundedCornerShape(24.dp),
            elevation = CardDefaults.cardElevation(defaultElevation = 8.dp)
        ) {

            Column(
                modifier = Modifier.padding(24.dp),
                verticalArrangement = Arrangement.spacedBy(16.dp)
            ) {

                Text(
                    text = "Welcome 👋",
                    fontSize = 22.sp,
                    fontWeight = FontWeight.ExtraBold,
                    color = Color(0xFF2346A0)
                )

                Text(
                    text = "Tell us your name and phone number so others know who's sharing.",
                    color = Color.Gray
                )

                OutlinedTextField(
                    value = name,
                    onValueChange = { name = it },
                    label = { Text("Your name") },
                    modifier = Modifier.fillMaxWidth(),
                    shape = RoundedCornerShape(14.dp)
                )

                // Country picker — determines how the phone number below
                // is interpreted (e.g. same digits mean different things
                // in different countries). Defaults automatically; only
                // needs changing if the auto-detection guessed wrong.
                //
                // Deliberately NOT Material3's ExposedDropdownMenu: that
                // composable renders every item eagerly (no virtualization),
                // and with ~195 countries that made the menu take minutes
                // to open on-device. This is a lightweight Popup + LazyColumn
                // instead, so only visible rows are composed, plus a search
                // field so users can jump straight to "Sierra Leone" etc.
                CountryPickerField(
                    selectedCountryName = selectedCountryName,
                    onCountrySelected = { countryIso = it }
                )

                OutlinedTextField(
                    value = phone,
                    onValueChange = { phone = it },
                    label = { Text("Phone number") },
                    placeholder = { Text("With or without country code") },
                    modifier = Modifier.fillMaxWidth(),
                    shape = RoundedCornerShape(14.dp)
                )

                Button(
                    onClick = {

                        if (name.isBlank() || phone.isBlank()) {
                            Toast.makeText(context, "Please fill in both fields", Toast.LENGTH_SHORT).show()
                            return@Button
                        }

                        isSaving = true

                        AuthManager.saveProfile(
                            context = context,
                            name = name,
                            phone = phone,
                            countryIso = countryIso,
                            onSuccess = {
                                isSaving = false
                                onDone()
                            },
                            onError = { message ->
                                isSaving = false
                                Toast.makeText(context, "Error: $message", Toast.LENGTH_LONG).show()
                            }
                        )
                    },
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(52.dp),
                    enabled = !isSaving,
                    shape = RoundedCornerShape(16.dp),
                    colors = ButtonDefaults.buttonColors(containerColor = Color(0xFF365DDB))
                ) {
                    Text(if (isSaving) "Saving..." else "Continue", fontWeight = FontWeight.Bold)
                }
            }
        }
    }
}

/**
 * Fast, searchable country picker.
 *
 * Uses a Popup anchored under the field (not DropdownMenu) so we control
 * exactly what's inside: a search TextField + a LazyColumn. LazyColumn only
 * composes rows currently on screen, so opening the picker is instant
 * regardless of list size (195 countries or 2,000 would behave the same).
 */
@Composable
private fun CountryPickerField(
    selectedCountryName: String,
    onCountrySelected: (iso: String) -> Unit
) {
    var expanded by remember { mutableStateOf(false) }
    var query by remember { mutableStateOf("") }

    val filteredOptions by remember {
        derivedStateOf {
            if (query.isBlank()) {
                COUNTRY_OPTIONS
            } else {
                COUNTRY_OPTIONS.filter { it.second.contains(query, ignoreCase = true) }
            }
        }
    }

    Box {
        OutlinedTextField(
            value = selectedCountryName,
            onValueChange = {},
            readOnly = true,
            label = { Text("Country") },
            trailingIcon = {
                Icon(Icons.Default.ArrowDropDown, contentDescription = null)
            },
            modifier = Modifier
                .fillMaxWidth()
                .clickable {
                    query = ""
                    expanded = true
                },
            shape = RoundedCornerShape(14.dp),
            enabled = false,
            colors = OutlinedTextFieldDefaults.colors(
                disabledTextColor = MaterialTheme.colorScheme.onSurface,
                disabledBorderColor = MaterialTheme.colorScheme.outline,
                disabledLabelColor = MaterialTheme.colorScheme.onSurfaceVariant,
                disabledTrailingIconColor = MaterialTheme.colorScheme.onSurfaceVariant
            )
        )

        // Invisible clickable overlay so taps register even though the
        // field above is disabled (disabled = no focus/keyboard, which is
        // what we want since it's read-only and driven by the popup below).
        Box(
            modifier = Modifier
                .matchParentSize()
                .clickable {
                    query = ""
                    expanded = true
                }
        )
    }

    if (expanded) {
        Popup(
            onDismissRequest = { expanded = false },
            properties = PopupProperties(focusable = true)
        ) {
            Card(
                modifier = Modifier
                    .fillMaxWidth(.9f)
                    .heightIn(max = 420.dp),
                shape = RoundedCornerShape(16.dp),
                elevation = CardDefaults.cardElevation(defaultElevation = 12.dp)
            ) {
                Column {
                    OutlinedTextField(
                        value = query,
                        onValueChange = { query = it },
                        placeholder = { Text("Search country") },
                        singleLine = true,
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(12.dp),
                        shape = RoundedCornerShape(12.dp)
                    )

                    if (filteredOptions.isEmpty()) {
                        Box(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(24.dp),
                            contentAlignment = Alignment.Center
                        ) {
                            Text("No matches", color = Color.Gray)
                        }
                    } else {
                        LazyColumn(
                            modifier = Modifier.fillMaxWidth()
                        ) {
                            items(
                                items = filteredOptions,
                                key = { it.first }
                            ) { (iso, displayName) ->
                                Text(
                                    text = displayName,
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .clickable {
                                            onCountrySelected(iso)
                                            expanded = false
                                        }
                                        .padding(horizontal = 16.dp, vertical = 12.dp)
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}
