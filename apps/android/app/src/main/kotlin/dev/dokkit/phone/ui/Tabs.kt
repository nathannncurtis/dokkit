package dev.dokkit.phone.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import dev.dokkit.phone.AppViewModel
import dev.dokkit.phone.core.IssueRow
import dev.dokkit.phone.core.Level
import dev.dokkit.phone.core.MachineRow
import dev.dokkit.phone.core.Screens
import dev.dokkit.phone.core.ServiceRow
import java.time.Instant

private fun String.upperFirst() = replaceFirstChar { it.uppercase() }

private fun meta(vararg parts: String?) = parts.filterNotNull().filter { it.isNotEmpty() }.joinToString(" · ")

@OptIn(ExperimentalLayoutApi::class)
@Composable
fun IssueRowView(row: IssueRow, onOpen: (() -> Unit)?) {
    val p = LocalPalette.current
    val open = if (onOpen != null && row.serviceId != null) Modifier.clickable(onClick = onOpen) else Modifier
    Column(
        Modifier.fillMaxWidth().then(open).heightIn(min = 48.dp).padding(horizontal = 16.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            StateMark(row.level)
            Spacer(Modifier.weight(1f))
            Text(row.shortId, style = MaterialTheme.typography.labelMedium, fontFamily = FontFamily.Monospace, color = p.mute)
        }
        Text(row.title, style = MaterialTheme.typography.bodyLarge, fontWeight = FontWeight.SemiBold)
        row.note?.let { Text(it, style = MaterialTheme.typography.bodyMedium, color = p.mute) }
        val line = meta(row.serviceName, row.machine, row.since, row.count)
        if (line.isNotEmpty()) Text(line, style = MaterialTheme.typography.bodySmall, color = p.mute)
        if (row.flags.isNotEmpty()) {
            FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                row.flags.forEach { Tag(it) }
            }
        }
    }
}

@Composable
fun NeedsYouTab(vm: AppViewModel, now: Instant, onOpen: (String) -> Unit) {
    val p = LocalPalette.current
    ServerScreen(vm, "Needs you", now) { snap, t ->
        val screen = Screens.needsYou(snap, t)
        if (screen.nothingNeedsYou) {
            Notice("Everything is fine", screen.fine?.let { it.upperFirst() + "." } ?: "Nothing needs you.", Icons.Filled.CheckCircle)
        }
        screen.sections.forEach { section ->
            Panel(section.title, "${section.rows.size}") {
                section.rows.forEachIndexed { i, row ->
                    if (i > 0) RowDivider()
                    IssueRowView(row) { row.serviceId?.let(onOpen) }
                }
            }
        }
        if (screen.notWatched.isNotEmpty()) {
            Panel("Not watched", "${screen.notWatched.size}") {
                screen.notWatched.forEachIndexed { i, row ->
                    if (i > 0) RowDivider()
                    Column(Modifier.fillMaxWidth().heightIn(min = 48.dp).padding(horizontal = 16.dp, vertical = 8.dp), verticalArrangement = Arrangement.Center) {
                        Text(row.name, style = MaterialTheme.typography.bodyLarge, fontWeight = FontWeight.Medium)
                        val line = meta(row.machine, row.kind, row.saw)
                        if (line.isNotEmpty()) Text(line, style = MaterialTheme.typography.bodySmall, color = p.mute)
                    }
                }
            }
        }
        if (!screen.nothingNeedsYou) {
            screen.fine?.let { Text(it.upperFirst() + ".", style = MaterialTheme.typography.bodySmall, color = p.mute) }
        }
    }
}

@Composable
fun EverythingTab(vm: AppViewModel, now: Instant, onOpen: (String) -> Unit) {
    val p = LocalPalette.current
    ServerScreen(vm, "Everything", now) { snap, _ ->
        val machines = Screens.everything(snap)
        if (machines.isEmpty()) Notice("No machines", "This snapshot lists no machines.", Icons.Filled.Info)
        machines.forEach { m ->
            val open = vm.openMachines[m.id] ?: (m.level.rank > 0)
            Panel {
                MachineHeader(m, open) { vm.openMachines[m.id] = !open }
                if (open) {
                    m.services.forEach { svc ->
                        RowDivider()
                        ServiceLine(svc) { onOpen(svc.id) }
                    }
                    if (m.services.isEmpty()) Text("No services", style = MaterialTheme.typography.bodySmall, color = p.mute, modifier = Modifier.padding(16.dp))
                }
            }
        }
    }
}

@Composable
private fun MachineHeader(row: MachineRow, open: Boolean, toggle: () -> Unit) {
    val p = LocalPalette.current
    Row(
        Modifier.fillMaxWidth().clickable(onClick = toggle).heightIn(min = 48.dp).padding(horizontal = 16.dp, vertical = 8.dp)
            .semantics { stateDescription = if (open) "Expanded" else "Collapsed" },
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(row.name, style = MaterialTheme.typography.bodyLarge, fontWeight = FontWeight.SemiBold)
                row.os?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = p.mute) }
            }
            StateMark(row.level)
            row.notice?.let { Tag(it, warn = row.level == Level.Down) }
            row.vitals.forEach {
                Text(
                    "${it.label} ${it.percent}%",
                    style = MaterialTheme.typography.labelMedium,
                    fontFamily = FontFamily.Monospace,
                    color = if (it.isHot) p.warn else p.mute,
                )
            }
            row.nextWindow?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = p.mute) }
        }
        Icon(if (open) Icons.Filled.KeyboardArrowUp else Icons.Filled.KeyboardArrowDown, contentDescription = null, tint = p.mute)
    }
}

@Composable
private fun ServiceLine(row: ServiceRow, onOpen: () -> Unit) {
    val p = LocalPalette.current
    Row(
        Modifier.fillMaxWidth().clickable(onClick = onOpen).heightIn(min = 48.dp).padding(horizontal = 16.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(row.name, style = MaterialTheme.typography.bodyLarge)
            StateMark(row.level)
            val line = meta(row.kind.takeIf { it != "service" }, row.version, row.environment)
            if (line.isNotEmpty()) Text(line, style = MaterialTheme.typography.bodySmall, color = p.mute)
            row.note?.takeIf { row.level.rank > 0 }?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = p.mute) }
        }
        if (row.chart.any { it != null }) Spark(row.chart, Modifier.width(64.dp))
        Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null, tint = p.mute)
    }
}
