package dev.dokkit.phone.ui

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import dev.dokkit.phone.core.Level

class Palette(
    val bg: Color,
    val panel: Color,
    val line: Color,
    val ink: Color,
    val mute: Color,
    val chip: Color,
    val brand: Color,
    val brandInk: Color,
    val ok: Color,
    val warn: Color,
    val bad: Color,
) {
    fun of(level: Level): Color = when (level) {
        Level.Ok -> ok
        Level.Degraded -> warn
        Level.Down -> bad
        else -> mute
    }
}

private val light = Palette(
    bg = Color(0xFFFAFAFA), panel = Color(0xFFFFFFFF), line = Color(0xFFE6E6EA), ink = Color(0xFF18181B),
    mute = Color(0xFF6B6B76), chip = Color(0xFFF0F0F3), brand = Color(0xFF0F766E), brandInk = Color(0xFFFFFFFF),
    ok = Color(0xFF147A3A), warn = Color(0xFFA14A08), bad = Color(0xFFC81E1E),
)

private val dark = Palette(
    bg = Color(0xFF1E1917), panel = Color(0xFF27201D), line = Color(0xFF40342F), ink = Color(0xFFF7F1EC),
    mute = Color(0xFFB9A99E), chip = Color(0xFF3A2F2A), brand = Color(0xFFFF9A4D), brandInk = Color(0xFF2A1203),
    ok = Color(0xFF4ADE80), warn = Color(0xFFFBBF24), bad = Color(0xFFF87171),
)

val LocalPalette = staticCompositionLocalOf { light }

@Composable
fun DokkitTheme(content: @Composable () -> Unit) {
    val p = if (isSystemInDarkTheme()) dark else light
    val colors = if (isSystemInDarkTheme()) {
        darkColorScheme(
            primary = p.brand, onPrimary = p.brandInk, background = p.bg, onBackground = p.ink, surface = p.panel,
            onSurface = p.ink, surfaceVariant = p.chip, onSurfaceVariant = p.mute, outline = p.line, error = p.bad,
            secondaryContainer = p.chip, onSecondaryContainer = p.ink,
        )
    } else {
        lightColorScheme(
            primary = p.brand, onPrimary = p.brandInk, background = p.bg, onBackground = p.ink, surface = p.panel,
            onSurface = p.ink, surfaceVariant = p.chip, onSurfaceVariant = p.mute, outline = p.line, error = p.bad,
            secondaryContainer = p.chip, onSecondaryContainer = p.ink,
        )
    }
    CompositionLocalProvider(LocalPalette provides p, LocalContentColor provides p.ink) {
        MaterialTheme(colorScheme = colors, content = content)
    }
}
