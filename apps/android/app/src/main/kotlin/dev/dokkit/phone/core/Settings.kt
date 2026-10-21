package dev.dokkit.phone.core

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

enum class ThemeChoice(val word: String) { System("System"), Light("Light"), Dark("Dark") }

enum class LockAfter(val word: String, val seconds: Long) {
    EveryReturn("Every launch and every return", 0),
    AfterMinute("Every launch, and after 1 min away", 60),
    AfterFiveMinutes("Every launch, and after 5 min away", 300),
}

@Serializable
data class AppSettings(
    val theme: ThemeChoice = ThemeChoice.System,
    val refreshSeconds: Int = 30,
    val lateMinutes: Int = Age.WARN_AFTER_SECONDS / 60,
    val hotPercent: Int = Home.HOT_ABOVE.toInt(),
    val fineShown: Int = Home.FINE_SHOWN,
    val relayWaitSeconds: Int = 15,
    val lockAfter: LockAfter = LockAfter.EveryReturn,
) {
    fun encode(): String = json.encodeToString(serializer(), this)

    // Out-of-range numbers from an older or hand-edited file fall back to their limits.
    fun clamped(): AppSettings = copy(
        refreshSeconds = refreshSeconds.coerceIn(Limits.refresh),
        lateMinutes = lateMinutes.coerceIn(Limits.late),
        hotPercent = hotPercent.coerceIn(Limits.hot),
        fineShown = fineShown.coerceIn(Limits.fineShown),
        relayWaitSeconds = relayWaitSeconds.coerceIn(Limits.relayWait),
    )

    val changed: Int get() {
        val d = AppSettings()
        return listOf(theme != d.theme, refreshSeconds != d.refreshSeconds, lateMinutes != d.lateMinutes, hotPercent != d.hotPercent,
            fineShown != d.fineShown, relayWaitSeconds != d.relayWaitSeconds, lockAfter != d.lockAfter).count { it }
    }

    object Limits {
        val refresh = 10..600
        val late = 1..120
        val hot = 1..100
        val fineShown = 1..100
        val relayWait = 5..120
    }

    companion object {
        private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true; coerceInputValues = true }

        fun decode(text: String?): AppSettings =
            text?.let { runCatching { json.decodeFromString(serializer(), it) }.getOrNull() }?.clamped() ?: AppSettings()
    }
}
