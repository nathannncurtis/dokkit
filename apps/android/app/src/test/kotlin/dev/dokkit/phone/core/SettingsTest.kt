package dev.dokkit.phone.core

import kotlin.test.Test
import kotlin.test.assertEquals

class SettingsTest {
    @Test
    fun defaultsAreTheValuesTheAppAlwaysUsed() {
        val d = AppSettings()
        assertEquals(ThemeChoice.System, d.theme)
        assertEquals(30, d.refreshSeconds)
        assertEquals(5, d.lateMinutes)
        assertEquals(85, d.hotPercent)
        assertEquals(8, d.fineShown)
        assertEquals(15, d.relayWaitSeconds)
        assertEquals(LockAfter.EveryReturn, d.lockAfter)
        assertEquals(0, d.changed)
    }

    @Test
    fun roundTripsAndCountsWhatDiffers() {
        val s = AppSettings(theme = ThemeChoice.Dark, refreshSeconds = 60)
        assertEquals(s, AppSettings.decode(s.encode()))
        assertEquals(2, s.changed)
    }

    @Test
    fun badOrMissingTextFallsBackToDefaultsAndLimits() {
        assertEquals(AppSettings(), AppSettings.decode(null))
        assertEquals(AppSettings(), AppSettings.decode("not json"))
        val wild = AppSettings.decode("""{"refreshSeconds":1,"hotPercent":400,"theme":"Purple","future":true}""")
        assertEquals(10, wild.refreshSeconds)
        assertEquals(100, wild.hotPercent)
        assertEquals(ThemeChoice.System, wild.theme)
    }

    @Test
    fun theLateSettingMovesTheWarning() {
        val made = Fixtures.now.minusSeconds(400)
        assertEquals(true, Freshness.make(made, true, null, Fixtures.now).isWarning)
        assertEquals(false, Freshness.make(made, true, null, Fixtures.now, lateSeconds = 600).isWarning)
    }
}
