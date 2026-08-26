package com.tbtrapp.util

import android.content.Context
import android.telephony.TelephonyManager
import com.google.i18n.phonenumbers.NumberParseException
import com.google.i18n.phonenumbers.PhoneNumberUtil
import java.util.Locale

// Same priority/fallback region list used by the country picker on
// ProfileSetupScreen (PRIORITY_CODES) and mirrored by _fallbackRegions in
// lib/util/phone_utils.dart, so a locally-formatted number (no "+") is
// interpreted the same way — try the picked/cached country first, then
// these five — on every platform this app runs on.
val FALLBACK_REGIONS = listOf("SL", "GN", "LR", "GH", "NG")

/**
 * Best-guess region for interpreting a phone number with no country code
 * typed in, when there's no signed-in profile's own country to use yet
 * (e.g. before registration). SIM country is the most reliable signal —
 * it doesn't depend on device settings the way locale can — falling back
 * to device locale, then hardcoded Sierra Leone. Works the same regardless
 * of which country the device itself is sold/used in.
 */
fun defaultRegion(context: Context): String {
    val tm = context.getSystemService(Context.TELEPHONY_SERVICE) as? TelephonyManager
    val simCountry = tm?.simCountryIso?.uppercase(Locale.US)
    if (!simCountry.isNullOrBlank()) return simCountry

    val localeCountry = Locale.getDefault().country.uppercase(Locale.US)
    if (localeCountry.isNotBlank()) return localeCountry

    return "SL"
}

/**
 * Turns whatever a user typed — with or without a country code, with or
 * without a leading trunk "0" — into one canonical E.164 string, e.g.
 * "088236249" with regionHint "SL" -> "+23288236249". Tries [regionHint]
 * first (the country the user picked at registration, or their cached
 * profile's country when matching contacts), then falls back through
 * FALLBACK_REGIONS so one wrong region guess doesn't outright reject a
 * validly-formatted number. Returns null only if no region can make sense
 * of the input at all.
 *
 * This is the ONE phone-normalization path for the whole Android app —
 * AuthManager.saveProfile (registration) and ContactsRepository (matching
 * the phone's address book against registered users) both call this same
 * function, so a given number is interpreted identically everywhere, for
 * every country, not just a hardcoded few.
 */
fun normalizePhone(raw: String, regionHint: String): String? {
    val util = PhoneNumberUtil.getInstance()

    fun tryRegion(region: String): String? {
        return try {
            val parsed = util.parse(raw, region)
            if (util.isValidNumber(parsed)) {
                util.format(parsed, PhoneNumberUtil.PhoneNumberFormat.E164)
            } else {
                null
            }
        } catch (_: NumberParseException) {
            null
        }
    }

    tryRegion(regionHint)?.let { return it }

    for (region in FALLBACK_REGIONS) {
        if (region == regionHint) continue
        tryRegion(region)?.let { return it }
    }
    return null
}
