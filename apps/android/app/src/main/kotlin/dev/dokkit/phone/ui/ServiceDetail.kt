package dev.dokkit.phone.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Info
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import dev.dokkit.phone.AppViewModel
import dev.dokkit.phone.core.ServiceScreen
import dev.dokkit.phone.core.Screens
import java.time.Instant

@Composable
fun ServiceDetail(vm: AppViewModel, id: String, now: Instant, onBack: () -> Unit) {
    ServerScreen(vm, "Service", now, showPicker = false, onBack = onBack) { snap, t ->
        val v = Screens.service(snap, id, t)
        if (v != null) {
            ServiceBody(v)
        } else {
            Notice("Not in this snapshot", "The newest snapshot no longer lists this service.", Icons.Filled.Info)
        }
    }
}

@Composable
private fun ServiceBody(v: ServiceScreen) {
    val p = LocalPalette.current
    Panel(v.name, v.machine) {
        Column(Modifier.fillMaxWidth().padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            StateMark(v.level)
            v.note?.let { Text(it, style = MaterialTheme.typography.bodyMedium, color = p.mute) }
            val line = listOfNotNull(v.kind, v.version?.let { "version $it" }, v.environment).joinToString(" · ")
            if (line.isNotEmpty()) Text(line, style = MaterialTheme.typography.bodySmall, color = p.mute)
        }
    }
    v.issue?.let { issue ->
        Panel("Open issue", issue.shortId) {
            IssueRowView(issue, null)
            v.history.forEach { h ->
                RowDivider()
                Column(Modifier.fillMaxWidth().heightIn(min = 48.dp).padding(horizontal = 16.dp, vertical = 8.dp)) {
                    Text(h.text, style = MaterialTheme.typography.bodyMedium)
                    h.whenText?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = p.mute) }
                }
            }
        }
    }
    if (v.checks.isNotEmpty()) {
        Panel("Checks", "${v.checks.size}") {
            v.checks.forEachIndexed { i, c ->
                if (i > 0) RowDivider()
                Column(Modifier.fillMaxWidth().heightIn(min = 48.dp).padding(horizontal = 16.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                    Text(c.name, style = MaterialTheme.typography.bodyLarge, fontWeight = FontWeight.Medium)
                    StateMark(c.level)
                    c.note?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = p.mute) }
                    c.checked?.let { Text("Checked $it", style = MaterialTheme.typography.bodySmall, color = p.mute) }
                }
            }
        }
    }
    if (v.job.isNotEmpty()) {
        Panel("Job") {
            v.job.forEachIndexed { i, (label, value) ->
                if (i > 0) RowDivider()
                Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(label, style = MaterialTheme.typography.bodySmall, color = p.mute)
                    Text(value, style = MaterialTheme.typography.bodyMedium)
                }
            }
        }
    }
    if (v.chart.any { it != null }) {
        Panel("Last 24 hours") { Spark(v.chart, Modifier.fillMaxWidth().padding(16.dp), height = 56) }
    }
    if (v.logs.isNotEmpty()) {
        Panel("Last log lines", "${v.logs.size}") {
            SelectionContainer {
                Column(Modifier.fillMaxWidth().padding(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    v.logs.forEach {
                        Text(
                            it.text,
                            style = MaterialTheme.typography.bodySmall,
                            fontFamily = FontFamily.Monospace,
                            color = if (it.isError) p.bad else p.ink,
                        )
                    }
                }
            }
        }
    }
}
