package tech.acab.app.ui.theme

import android.app.UiModeManager
import android.content.Context
import android.os.Build
import android.view.accessibility.AccessibilityManager
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue

/** Which palette [Acab] shows: the in-app "always use higher contrast" switch OR the system
 *  asking for more contrast. Off on the switch means "follow the system", so switching it off
 *  while the system asks for more leaves higher contrast active; DisplayCard says so.
 *
 *  System inputs, both read fresh on every resume and via listeners while the activity lives:
 *  - Android 14+ (API 34) contrast slider, [UiModeManager.getContrast], -1..1 where 0 is default.
 *  - Android 16+ (API 36) "high contrast text", [AccessibilityManager.isHighContrastTextEnabled].
 *  Older phones have neither, which is why the in-app switch exists at all.
 *
 *  iOS twin: ContrastPreference in ContrastPreference.swift (same forced || system rule). */
object ContrastMode {
    private const val PREFS = "acab_ui"
    private const val KEY_ALWAYS_HIGHER = "always_higher_contrast"

    /** The contrast slider runs -1..1; the settings UI labels 0 "default", ~0.5 "medium" and 1
     *  "high". Medium already means the user asked for more, so the floor sits at the medium
     *  detent, with a hair of slack for float representation. */
    const val SYSTEM_CONTRAST_FLOOR = 0.49f

    var forced: Boolean by mutableStateOf(false)
        private set
    var systemContrast: Float by mutableStateOf(0f)
        private set
    var systemHighContrastText: Boolean by mutableStateOf(false)
        private set

    /** True when the SYSTEM (not the in-app switch) asks for more contrast. */
    val systemWantsHigher: Boolean
        get() = systemAsksForHigherContrast(systemContrast, systemHighContrastText)

    /** True when the phone exposes a system contrast control this app can follow. */
    val systemHasControl: Boolean get() = Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE

    private var contrastListener: UiModeManager.ContrastChangeListener? = null
    private var textListener: AccessibilityManager.HighContrastTextStateChangeListener? = null

    /** Cold start: read the persisted switch and the current system state, apply the palette. */
    fun load(context: Context) {
        forced = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getBoolean(KEY_ALWAYS_HIGHER, false)
        syncSystem(context)
    }

    fun setForced(context: Context, on: Boolean) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putBoolean(KEY_ALWAYS_HIGHER, on).apply()
        forced = on
        apply()
    }

    /** Re-read the system inputs (onResume: the user may have come back from Settings). */
    fun syncSystem(context: Context) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            val uim = context.getSystemService(Context.UI_MODE_SERVICE) as? UiModeManager
            systemContrast = uim?.contrast ?: 0f
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.BAKLAVA) {
            val am = context.getSystemService(Context.ACCESSIBILITY_SERVICE) as? AccessibilityManager
            systemHighContrastText = am?.isHighContrastTextEnabled ?: false
        }
        apply()
    }

    /** Live updates while the activity is alive. onResume's [syncSystem] covers the usual trip
     *  through Settings; this covers a change that lands while we stay resumed. Idempotent. */
    fun startListening(context: Context) {
        val app = context.applicationContext
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE && contrastListener == null) {
            val uim = app.getSystemService(Context.UI_MODE_SERVICE) as? UiModeManager
            val l = UiModeManager.ContrastChangeListener { c -> systemContrast = c; apply() }
            uim?.addContrastChangeListener(app.mainExecutor, l)
            contrastListener = l
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.BAKLAVA && textListener == null) {
            val am = app.getSystemService(Context.ACCESSIBILITY_SERVICE) as? AccessibilityManager
            val l = AccessibilityManager.HighContrastTextStateChangeListener { on ->
                systemHighContrastText = on; apply()
            }
            am?.addHighContrastTextStateChangeListener(app.mainExecutor, l)
            textListener = l
        }
    }

    fun stopListening(context: Context) {
        val app = context.applicationContext
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            contrastListener?.let {
                (app.getSystemService(Context.UI_MODE_SERVICE) as? UiModeManager)?.removeContrastChangeListener(it)
            }
            contrastListener = null
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.BAKLAVA) {
            textListener?.let {
                (app.getSystemService(Context.ACCESSIBILITY_SERVICE) as? AccessibilityManager)
                    ?.removeHighContrastTextStateChangeListener(it)
            }
            textListener = null
        }
    }

    private fun apply() {
        Acab.palette = if (effectiveHighContrast(forced, systemContrast, systemHighContrastText))
            AcabPalette.High else AcabPalette.Normal
    }
}

/** The one rule: the in-app switch OR the system. Pure so AcabPaletteTest can pin it. */
fun effectiveHighContrast(forced: Boolean, systemContrast: Float, systemHighContrastText: Boolean): Boolean =
    forced || systemAsksForHigherContrast(systemContrast, systemHighContrastText)

fun systemAsksForHigherContrast(systemContrast: Float, systemHighContrastText: Boolean): Boolean =
    systemContrast >= ContrastMode.SYSTEM_CONTRAST_FLOOR || systemHighContrastText
