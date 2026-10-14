package dev.dokkit.phone.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material.icons.filled.Info
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import dev.dokkit.phone.core.Freshness
import dev.dokkit.phone.core.Level

@Composable
fun StateMark(level: Level, word: String = level.word) {
    val color = LocalPalette.current.of(level)
    Row(
        Modifier.clearAndSetSemantics { contentDescription = "State $word" },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Canvas(Modifier.size(11.dp)) {
            val line = Stroke(width = 1.5.dp.toPx())
            when (level) {
                Level.Ok -> drawRoundRect(color, cornerRadius = CornerRadius(3.dp.toPx()))
                Level.Degraded -> rotate(45f) { drawRect(color, topLeft = Offset(size.width * 0.07f, size.height * 0.07f), size = size * 0.86f) }
                Level.Down -> drawRect(color)
                Level.Unknown, Level.Unwatched ->
                    drawRect(color, style = Stroke(width = line.width, pathEffect = PathEffect.dashPathEffect(floatArrayOf(2.5.dp.toPx(), 2.dp.toPx()))))
                is Level.Other -> drawCircle(color, radius = size.minDimension / 2 - line.width / 2, style = line)
            }
        }
        Text(word, style = MaterialTheme.typography.labelMedium, fontWeight = FontWeight.Medium, color = color)
    }
}

@Composable
fun Panel(title: String? = null, detail: String? = null, content: @Composable ColumnScope.() -> Unit) {
    val p = LocalPalette.current
    val shape = RoundedCornerShape(10.dp)
    Column(Modifier.fillMaxWidth().clip(shape).background(p.panel).border(1.dp, p.line, shape)) {
        if (title != null) {
            Row(
                Modifier.fillMaxWidth().heightIn(min = 48.dp).padding(horizontal = 16.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(title, style = MaterialTheme.typography.labelLarge, fontWeight = FontWeight.SemiBold, modifier = Modifier.semantics { heading() })
                Spacer(Modifier.weight(1f))
                if (detail != null) Text(detail, style = MaterialTheme.typography.labelMedium, color = p.mute)
            }
            HorizontalDivider(color = p.line)
        }
        content()
    }
}

@Composable
fun RowDivider() {
    HorizontalDivider(Modifier.padding(start = 16.dp), color = LocalPalette.current.line)
}

@Composable
fun Spark(values: List<Double?>, modifier: Modifier = Modifier, height: Int = 28) {
    val p = LocalPalette.current
    val present = values.filterNotNull()
    val latest = present.lastOrNull()?.let { ", latest ${Math.round(it)}" } ?: ""
    Canvas(
        modifier.height(height.dp).clearAndSetSemantics { contentDescription = "Chart of the last ${values.size} hours$latest" },
    ) {
        val hi = present.maxOrNull() ?: 0.0
        if (hi <= 0.0 || values.isEmpty()) return@Canvas
        val w = size.width / values.size
        values.forEachIndexed { i, v ->
            if (v == null) return@forEachIndexed
            val h = maxOf(2.dp.toPx(), size.height * (v / hi).toFloat())
            drawRect(
                p.mute.copy(alpha = 0.6f),
                topLeft = Offset(i * w + 0.5f, size.height - h),
                size = Size(maxOf(1f, w - 1f), h),
            )
        }
    }
}

@Composable
fun Tag(text: String, warn: Boolean = false) {
    val p = LocalPalette.current
    Text(
        text,
        style = MaterialTheme.typography.labelMedium,
        color = if (warn) p.warn else p.mute,
        modifier = Modifier.clip(RoundedCornerShape(5.dp))
            .background(if (warn) p.warn.copy(alpha = 0.15f) else p.chip)
            .padding(horizontal = 7.dp, vertical = 2.dp),
    )
}

@Composable
fun Notice(title: String, text: String, icon: ImageVector = Icons.Filled.Info) {
    val p = LocalPalette.current
    Column(
        Modifier.fillMaxWidth().padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Icon(icon, contentDescription = null, tint = p.mute, modifier = Modifier.size(36.dp))
        Text(title, style = MaterialTheme.typography.titleMedium, textAlign = TextAlign.Center)
        Text(text, style = MaterialTheme.typography.bodyMedium, color = p.mute, textAlign = TextAlign.Center)
    }
}

@Composable
fun AgeBanner(f: Freshness) {
    val p = LocalPalette.current
    val color = if (f.isWarning) p.warn else p.mute
    val spoken = (if (f.isWarning) "Warning. " else "") + f.text + ". " + (f.detail ?: "")
    Column(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(10.dp))
            .background(if (f.isWarning) p.warn.copy(alpha = 0.15f) else p.chip)
            .padding(12.dp)
            .clearAndSetSemantics { contentDescription = spoken },
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            if (f.isWarning) Icon(Icons.Filled.Warning, contentDescription = null, tint = color, modifier = Modifier.size(16.dp))
            Text(
                f.text,
                style = MaterialTheme.typography.bodySmall,
                fontWeight = if (f.isWarning) FontWeight.SemiBold else FontWeight.Normal,
                color = color,
            )
        }
        f.detail?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = color) }
    }
}
