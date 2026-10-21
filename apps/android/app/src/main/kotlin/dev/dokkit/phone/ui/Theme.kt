package dev.dokkit.phone.ui

import android.provider.Settings
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.remember
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.ExperimentalTextApi
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontVariation
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.LineHeightStyle
import androidx.compose.ui.unit.em
import androidx.compose.ui.unit.sp
import dev.dokkit.phone.R
import dev.dokkit.phone.core.Level
import dev.dokkit.phone.core.ThemeChoice
import dev.dokkit.phone.core.Tone

@Immutable
data class Tint(val surface: Color, val ink: Color, val solid: Color)

@Immutable
class Palette(
    val dark: Boolean,
    val bg: Color,
    val bg2: Color,
    val panel: Color,
    val line: Color,
    val ink: Color,
    val ink2: Color,
    val mute: Color,
    val brand: Color,
    val brandInk: Color,
    val brandSoft: Color,
    val focus: Color,
    val rose: Tint,
    val amber: Tint,
    val peach: Tint,
    val sage: Tint,
    val mist: Tint,
) {
    val chip: Color get() = bg2
    val ok: Color get() = sage.ink
    val warn: Color get() = amber.ink
    val bad: Color get() = rose.ink

    val brandTint: Tint get() = Tint(brandSoft, androidx.compose.ui.graphics.lerp(brand, ink, 0.3f), brand)

    fun tint(t: Tone): Tint = when (t) {
        Tone.Down -> rose
        Tone.Degraded -> amber
        Tone.Soon -> peach
        Tone.Ok -> sage
        Tone.Quiet -> mist
        Tone.Brand -> brandTint
    }

    fun of(level: Level): Color = when (level) {
        Level.Ok -> sage.ink
        Level.Degraded -> amber.ink
        Level.Down -> rose.ink
        else -> mute
    }
}

// docs/design.md, Colour.
private val lightPalette = Palette(
    dark = false,
    bg = Color(0xFFF8F3EE), bg2 = Color(0xFFEFE6DD), panel = Color(0xFFFFFCF9), line = Color(0xFFE2D4C9),
    ink = Color(0xFF241A15), ink2 = Color(0xFF4D3D33), mute = Color(0xFF6B5A4F),
    brand = Color(0xFFF28A3A),
    brandInk = Color(0xFF2A1203),
    brandSoft = Color(0xFFFBE4D2),
    focus = Color(0xFFA8460A),
    rose = Tint(Color(0xFFFBE7E4), Color(0xFFB42D25), Color(0xFFE0675E)),
    amber = Tint(Color(0xFFFBF0D6), Color(0xFF855B00), Color(0xFFE3A51C)),
    peach = Tint(Color(0xFFF6EAD9), Color(0xFF85561A), Color(0xFFD9A066)),
    sage = Tint(Color(0xFFE5F1E6), Color(0xFF1D7537), Color(0xFF8FCF9E)),
    mist = Tint(Color(0xFFF0E5DC), Color(0xFF6B5A4F), Color(0xFF6B5A4F)),
)

private val darkPalette = Palette(
    dark = true,
    bg = Color(0xFF1E1917), bg2 = Color(0xFF171311), panel = Color(0xFF27201D), line = Color(0xFF40342F),
    ink = Color(0xFFF7F1EC), ink2 = Color(0xFFDCCDC2), mute = Color(0xFFB9A99E),
    brand = Color(0xFFFF9A4D),
    brandInk = Color(0xFF2A1203),
    brandSoft = Color(0xFF3D2B1E),
    focus = Color(0xFFFFB074),
    rose = Tint(Color(0xFF3A2421), Color(0xFFFFA39C), Color(0xFFFF7B72)),
    amber = Tint(Color(0xFF382E1C), Color(0xFFF5C542), Color(0xFFF5C542)),
    peach = Tint(Color(0xFF362A20), Color(0xFFE7B77D), Color(0xFFE7B77D)),
    sage = Tint(Color(0xFF1F2D23), Color(0xFF7BD88F), Color(0xFF7BD88F)),
    mist = Tint(Color(0xFF332A26), Color(0xFFDCCDC2), Color(0xFFB9A99E)),
)

@OptIn(ExperimentalTextApi::class)
private fun figtree(w: Int) = Font(R.font.figtree, FontWeight(w), variationSettings = FontVariation.Settings(FontVariation.weight(w)))

val Figtree = FontFamily(figtree(400), figtree(500), figtree(600), figtree(700), figtree(800))

private val trim = LineHeightStyle(LineHeightStyle.Alignment.Center, LineHeightStyle.Trim.None)
private fun style(size: Int, weight: Int, line: Double, track: Double = 0.0) =
    TextStyle(fontFamily = Figtree, fontSize = size.sp, fontWeight = FontWeight(weight), lineHeight = (size * line).sp, letterSpacing = track.em, lineHeightStyle = trim)

private val type = Typography(
    displayLarge = style(40, 800, 1.06, -0.032),
    headlineMedium = style(30, 800, 1.1, -0.03),
    titleLarge = style(19, 700, 1.3, -0.01),
    titleMedium = style(17, 700, 1.3, -0.01),
    titleSmall = style(15, 700, 1.3),
    bodyLarge = style(16, 400, 1.45),
    bodyMedium = style(15, 400, 1.45),
    bodySmall = style(13, 400, 1.4),
    labelLarge = style(15, 600, 1.3),
    labelMedium = style(13, 600, 1.3),
    labelSmall = style(12, 600, 1.3),
)

val LocalPalette = staticCompositionLocalOf { lightPalette }

// True when the phone asks for no animation (Settings, Accessibility, Remove animations).
val LocalReducedMotion = staticCompositionLocalOf { false }

@Composable
fun DokkitTheme(theme: ThemeChoice = ThemeChoice.System, content: @Composable () -> Unit) {
    val dark = when (theme) {
        ThemeChoice.System -> isSystemInDarkTheme()
        ThemeChoice.Light -> false
        ThemeChoice.Dark -> true
    }
    val p = if (dark) darkPalette else lightPalette
    val ctx = LocalContext.current
    val reduced = remember { Settings.Global.getFloat(ctx.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f }
    val colors = if (dark) {
        darkColorScheme(
            primary = p.brand, onPrimary = p.brandInk, background = p.bg, onBackground = p.ink, surface = p.panel,
            onSurface = p.ink, surfaceVariant = p.bg2, onSurfaceVariant = p.mute, outline = p.line, error = p.bad,
            secondaryContainer = p.brandSoft, onSecondaryContainer = p.ink, surfaceContainerLow = p.panel, surfaceContainer = p.panel,
            surfaceContainerHigh = p.panel,
        )
    } else {
        lightColorScheme(
            primary = p.brand, onPrimary = p.brandInk, background = p.bg, onBackground = p.ink, surface = p.panel,
            onSurface = p.ink, surfaceVariant = p.bg2, onSurfaceVariant = p.mute, outline = p.line, error = p.bad,
            secondaryContainer = p.brandSoft, onSecondaryContainer = p.ink, surfaceContainerLow = p.panel, surfaceContainer = p.panel,
            surfaceContainerHigh = p.panel,
        )
    }
    CompositionLocalProvider(LocalPalette provides p, LocalContentColor provides p.ink, LocalReducedMotion provides reduced) {
        MaterialTheme(colorScheme = colors, typography = type, content = content)
    }
}
