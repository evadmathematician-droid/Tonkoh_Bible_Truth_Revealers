package com.tbtrapp.platform

import android.app.Activity
import android.app.NotificationManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.util.Log

/**
 * The phone settings that decide whether calls and messages arrive while the
 * app is closed, for the "Allow TBTR to ring when closed" screen.
 */
object BackgroundSettings {
    private const val TAG = "BackgroundSettings"

    /**
     * Manufacturer "Auto-start" / background-launch screens, most specific
     * first. Infinix, Tecno and itel (Transsion) kill closed apps unless the
     * app is allowed here — no app can switch it on by itself.
     */
    private val autoStartScreens = listOf(
        // Transsion: Infinix / Tecno / itel (Phone Master)
        ComponentName("com.transsion.phonemaster", "com.cyin.himgr.autostart.AutoStartActivity"),
        ComponentName("com.transsion.phonemanager", "com.itel.autobootmanager.activity.AutoBootMgrActivity"),
        ComponentName("com.transsion.phonemaster", "com.transsion.phonemaster.MainActivity"),
        // Xiaomi / Redmi / POCO
        ComponentName("com.miui.securitycenter", "com.miui.permcenter.autostart.AutoStartManagementActivity"),
        // Oppo / Realme / OnePlus
        ComponentName("com.coloros.safecenter", "com.coloros.safecenter.permission.startup.StartupAppListActivity"),
        ComponentName("com.coloros.safecenter", "com.coloros.safecenter.startupapp.StartupAppListActivity"),
        ComponentName("com.oppo.safe", "com.oppo.safe.permission.startup.StartupAppListActivity"),
        // Vivo
        ComponentName("com.vivo.permissionmanager", "com.vivo.permissionmanager.activity.BgStartUpManagerActivity"),
        ComponentName("com.iqoo.secure", "com.iqoo.secure.ui.phoneoptimize.BgStartUpManager"),
        // Huawei / Honor
        ComponentName("com.huawei.systemmanager", "com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity"),
        ComponentName("com.huawei.systemmanager", "com.huawei.systemmanager.optimize.process.ProtectActivity"),
        // Samsung
        ComponentName("com.samsung.android.lool", "com.samsung.android.sm.battery.ui.BatteryActivity"),
    )

    /** Android 14+ lets users turn off full-screen ringing for an app. */
    fun canUseFullScreenIntent(ctx: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) return true
        val mgr = ctx.getSystemService(NotificationManager::class.java)
        return mgr?.canUseFullScreenIntent() ?: true
    }

    fun openFullScreenIntentSettings(activity: Activity) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE &&
            tryStart(
                activity,
                Intent(Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT)
                    .setData(Uri.parse("package:${activity.packageName}")),
            )
        ) return
        openAppDetails(activity)
    }

    /**
     * Opens this phone's auto-start screen. Returns false when the phone has
     * none we know of — the app's own settings page is opened instead.
     */
    fun openAutoStartSettings(activity: Activity): Boolean {
        for (component in autoStartScreens) {
            val intent = Intent().setComponent(component)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            if (tryStart(activity, intent)) return true
        }
        openAppDetails(activity)
        return false
    }

    fun openAppDetails(activity: Activity) {
        tryStart(
            activity,
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                .setData(Uri.parse("package:${activity.packageName}")),
        )
    }

    private fun tryStart(activity: Activity, intent: Intent): Boolean = try {
        activity.startActivity(intent)
        true
    } catch (e: Exception) {
        // Not on this phone, or not exported to other apps.
        Log.d(TAG, "can't open ${intent.component ?: intent.action}: ${e.message}")
        false
    }
}
