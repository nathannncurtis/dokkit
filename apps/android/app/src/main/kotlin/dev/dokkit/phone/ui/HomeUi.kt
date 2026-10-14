package dev.dokkit.phone.ui

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.compositeOver
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import dev.dokkit.phone.AppViewModel
import dev.dokkit.phone.R
import dev.dokkit.phone.core.Home
import dev.dokkit.phone.core.IssueRow
import dev.dokkit.phone.core.KidRow
import dev.dokkit.phone.core.Level
import dev.dokkit.phone.core.MachineCard
import dev.dokkit.phone.core.MeterRow
import dev.dokkit.phone.core.TopBox
import java.time.Instant

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
fun HomeTab(vm: AppViewModel, now: Instant, onOpen: (String) -> Unit) {
    val p = LocalPalette.current
    ServerScreen(vm, "Home", now) { snap, t ->
        val home = Home.build(snap, t)
        TopBoxView(home.top, onOpen)
        home.snoozed?.let { Text(it, style = MaterialTheme.typography.bodyMedium, color = p.mute) }
        home.hardware.forEach { MachineCardView(vm, it, onOpen) }
        if (home.groups.isNotEmpty()) {
            Text("Not on a machine", style = MaterialTheme.typography.titleSmall, color = p.mute, modifier = Modifier.semantics { heading() })
            home.groups.forEach { MachineCardView(vm, it, onOpen) }
        }
    }
}

@Composable
private fun TopBoxView(top: TopBox, onOpen: (String) -> Unit) {
    val p = LocalPalette.current
    val shape = RoundedCornerShape(16.dp)
    when (top) {
        is TopBox.Trouble -> Column(
            Modifier.fillMaxWidth().clip(shape).background(p.bad.copy(alpha = 0.16f).compositeOver(p.panel))
                .border(1.dp, p.bad.copy(alpha = 0.45f), shape),
        ) {
            Text(
                top.title,
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.padding(start = 16.dp, end = 16.dp, top = 12.dp, bottom = 4.dp).semantics { heading() },
            )
            top.issues.forEach { i ->
                val open = i.serviceId?.let { id -> Modifier.clickable(onClickLabel = "Open the service") { onOpen(id) } } ?: Modifier
                Column(Modifier.fillMaxWidth().then(open).heightIn(min = 48.dp).padding(horizontal = 16.dp, vertical = 8.dp)) {
                    Text(i.title, style = MaterialTheme.typography.bodyLarge, fontWeight = FontWeight.SemiBold)
                    if (i.detail.isNotEmpty()) Text(i.detail, style = MaterialTheme.typography.bodySmall, color = p.mute)
                }
            }
        }
        is TopBox.Fine -> Row(
            Modifier.fillMaxWidth().clip(shape).background(p.ok.copy(alpha = 0.14f).compositeOver(p.panel))
                .border(1.dp, p.ok.copy(alpha = 0.4f), shape).padding(16.dp),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(Icons.Filled.CheckCircle, contentDescription = null, tint = p.ok, modifier = Modifier.size(28.dp))
            Column {
                Text("Everything is fine", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold, modifier = Modifier.semantics { heading() })
                Text(top.summary, style = MaterialTheme.typography.bodySmall, color = p.mute)
            }
        }
    }
}

@Composable
private fun MachineCardView(vm: AppViewModel, card: MachineCard, onOpen: (String) -> Unit) {
    val p = LocalPalette.current
    val shape = RoundedCornerShape(16.dp)
    val open = vm.openMachines[card.id] ?: false
    Column(Modifier.fillMaxWidth().clip(shape).background(p.panel).border(1.dp, p.line, shape)) {
        Column(
            Modifier.fillMaxWidth().clickable { vm.openMachines[card.id] = !open }.heightIn(min = 48.dp)
                .padding(start = 16.dp, end = 16.dp, top = 14.dp, bottom = 12.dp)
                .clearAndSetSemantics {
                    contentDescription = card.spoken
                    stateDescription = if (open) "Expanded" else "Collapsed"
                    role = Role.Button
                    onClick(label = if (open) "Close" else "Open") {
                        vm.openMachines[card.id] = !open
                        true
                    }
                },
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Text(card.name, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
                Icon(if (open) Icons.Filled.KeyboardArrowUp else Icons.Filled.KeyboardArrowDown, contentDescription = null, tint = p.mute)
            }
            card.status?.let { StateMark(if (card.down) Level.Down else if (card.inTrouble) Level.Degraded else Level.Ok, it) }
            if (card.meters.isNotEmpty()) Meters(card.meters)
            Text(card.counts, style = MaterialTheme.typography.bodySmall, color = p.mute)
        }
        if (open) {
            RowDivider()
            Kids(vm, card, onOpen)
        }
    }
}

@Composable
private fun Meters(meters: List<MeterRow>) {
    if (LocalConfiguration.current.fontScale > 1.3f) {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) { meters.forEach { Meter(it, Modifier.fillMaxWidth()) } }
    } else {
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) { meters.forEach { Meter(it, Modifier.weight(1f)) } }
    }
}

@Composable
private fun Meter(m: MeterRow, modifier: Modifier) {
    val p = LocalPalette.current
    val color = if (m.hot) p.warn else p.mute
    Column(modifier, verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            Text(m.label, style = MaterialTheme.typography.labelMedium, color = p.mute)
            Text(m.percent?.let { "$it%" } ?: "–", style = MaterialTheme.typography.labelMedium, color = color, fontWeight = if (m.hot) FontWeight.SemiBold else FontWeight.Normal)
        }
        Box(Modifier.fillMaxWidth().height(5.dp).clip(RoundedCornerShape(3.dp)).background(p.chip)) {
            Box(Modifier.fillMaxHeight().fillMaxWidth(((m.percent ?: 0) / 100f).coerceIn(0f, 1f)).clip(RoundedCornerShape(3.dp)).background(color))
        }
    }
}

@Composable
private fun Kids(vm: AppViewModel, card: MachineCard, onOpen: (String) -> Unit) {
    val p = LocalPalette.current
    val k = card.kids
    val more = vm.openMore[card.id] ?: false
    if (k.isEmpty) Line("Nothing is watched on it.")
    k.trouble.forEach { KidLine(it, onOpen) }
    k.fine.forEach { KidLine(it, onOpen) }
    if (more) {
        k.more.forEach { KidLine(it, onOpen) }
    } else {
        k.moreLine?.let {
            Text(
                it,
                style = MaterialTheme.typography.bodyMedium,
                color = p.mute,
                modifier = Modifier.fillMaxWidth().clickable(onClickLabel = "Show the rest") { vm.openMore[card.id] = true }
                    .heightIn(min = 48.dp).padding(horizontal = 16.dp, vertical = 12.dp),
            )
        }
    }
    k.quietLine?.let { Line(it) }
    k.plannedLine?.let { Line(it) }
}

@Composable
private fun Line(text: String) {
    Text(text, style = MaterialTheme.typography.bodySmall, color = LocalPalette.current.mute, modifier = Modifier.padding(horizontal = 16.dp, vertical = 10.dp))
}

@Composable
private fun KidLine(r: KidRow, onOpen: (String) -> Unit) {
    Row(
        Modifier.fillMaxWidth().clickable(onClickLabel = "Open the service") { onOpen(r.id) }.heightIn(min = 48.dp).padding(horizontal = 16.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text(r.name, style = MaterialTheme.typography.bodyLarge, modifier = Modifier.weight(1f))
        StateMark(r.level)
    }
}

@Composable
fun FirstRun(onScan: () -> Unit, onPaste: () -> Unit) {
    val p = LocalPalette.current
    Column(
        Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 24.dp, vertical = 32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(14.dp, Alignment.CenterVertically),
    ) {
        Box(Modifier.size(88.dp).clip(RoundedCornerShape(22.dp)).background(p.brand)) {
            Image(painterResource(R.drawable.ic_launcher_foreground), contentDescription = null, modifier = Modifier.fillMaxSize())
        }
        Text("Dokkit", style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.SemiBold, modifier = Modifier.semantics { heading() })
        Text("A read-only view of your Dokkit server.", style = MaterialTheme.typography.bodyLarge, textAlign = TextAlign.Center)
        Text("Alerts still reach you the usual way.", style = MaterialTheme.typography.bodyLarge, textAlign = TextAlign.Center)
        Text("Nothing here can change anything.", style = MaterialTheme.typography.bodyLarge, textAlign = TextAlign.Center)
        Text(
            "The code is in the Dokkit web interface: Settings, Phones, Add a phone.",
            style = MaterialTheme.typography.bodyMedium,
            color = p.mute,
            textAlign = TextAlign.Center,
        )
        Button(
            onClick = onScan,
            modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp),
            colors = ButtonDefaults.buttonColors(containerColor = p.brand, contentColor = p.brandInk),
        ) { Text("Scan the code") }
        TextButton(onClick = onPaste, modifier = Modifier.heightIn(min = 48.dp)) { Text("Paste the code instead", color = p.mute) }
    }
}
