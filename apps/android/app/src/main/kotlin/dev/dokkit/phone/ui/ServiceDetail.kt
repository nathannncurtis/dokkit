package dev.dokkit.phone.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.dokkit.phone.AppViewModel
import dev.dokkit.phone.R
import dev.dokkit.phone.Route
import dev.dokkit.phone.core.Screens
import dev.dokkit.phone.core.ServiceScreen
import dev.dokkit.phone.core.Snapshot
import dev.dokkit.phone.core.Tone
import dev.dokkit.phone.core.Words
import dev.dokkit.phone.core.leftOutText
import java.time.Instant

@Composable
fun ServicePage(vm: AppViewModel, r: Route.Service, now: Instant) {
    val snap = vm.selectedState.snapshot
    if (snap == null) {
        NoSnapshot(vm, "Service", now) { vm.back() }
        return
    }
    val v = Screens.service(snap, r.id, now)
    if (v == null) {
        StatementPage(Tone.Quiet, { ServerTop(vm, "Service") { vm.back() } }, HeroModel(Tone.Quiet, R.drawable.ic_ph_info, { BigLine("Not in this snapshot", it) },
            eyebrow = { Eyebrow("Service", Tone.Quiet) }, lede = "The newest snapshot no longer lists this service.", morphKey = r.fromIssue?.let { "issue-$it" })) {}
        return
    }
    val p = LocalPalette.current
    val f = vm.freshness(now)
    val tone = Words.tone(v.level)
    val machineId = snap.machines?.firstOrNull { it.name == v.machine }?.id
    val line = listOfNotNull(v.kind, v.version?.let { "version $it" }, v.environment).joinToString(" · ")
    val hero = HeroModel(
        tone, toneIcon(tone),
        big = { BigLine(v.name, it, mono = true) },
        eyebrow = {
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
                Tag(v.level.word, tone, onPanel = true)
                v.machine?.let { m ->
                    Mono(m, 13f, p.tint(tone).ink, FontWeight.Medium,
                        Modifier.then(if (machineId != null) Modifier.clickable(role = Role.Button, onClickLabel = "Open $m") { vm.go(Route.Machine(machineId)) } else Modifier).padding(vertical = 8.dp))
                }
            }
        },
        lede = v.note,
        extra = if (line.isNotEmpty()) ({ Mono(line, 12.5f, modifier = Modifier.padding(top = 8.dp)) }) else null,
        age = f.text.takeIf { !f.isWarning && f.detail == null },
        morphKey = r.fromIssue?.let { "issue-$it" },
    )
    StatementPage(tone, { ServerTop(vm, "Service") { vm.back() } }, hero, vm.refreshing, { vm.refreshAsync() }) {
        if (f.isWarning || f.detail != null) Banner(f)
        leftOutText(snap)?.let { QuietLine(it, R.drawable.ic_ph_info) }
        v.issue?.let { OpenIssue(snap, v, now) }
        if (v.checks.isNotEmpty()) Checks(v)
        if (v.job.isNotEmpty()) Job(snap, v)
        if (v.chart.any { it != null }) Chart(v)
        if (v.logs.isNotEmpty()) Logs(v)
    }
}

@Composable
private fun OpenIssue(snap: Snapshot, v: ServiceScreen, now: Instant) {
    val p = LocalPalette.current
    val row = v.issue ?: return
    val raw = (snap.issues ?: emptyList()).firstOrNull { it.id == row.id } ?: snap.inbox?.let { b -> listOfNotNull(b.needsYou, b.soon, b.snoozed).flatten().firstOrNull { it.id == row.id } }
    val tone = raw?.let { Words.tone(it, now) } ?: Words.tone(row.level)
    val word = raw?.let { Words.word(it, now) } ?: row.level.word
    val t = p.tint(tone)
    BigCard {
        CardHead("Open issue", row.shortId)
        Column(Modifier.padding(12.dp).fillMaxWidth().clip(RoundedCornerShape(18.dp)).background(t.surface).padding(18.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Tag(word, tone, onPanel = true)
            Text(row.title, style = MaterialTheme.typography.titleLarge, modifier = Modifier.padding(top = 6.dp))
            row.note?.let { Text(it, style = MaterialTheme.typography.bodyMedium, color = p.ink2) }
            Mono(listOfNotNull(row.serviceName, row.machine.ifEmpty { null }, row.since, row.count).joinToString(" · "), 12f, modifier = Modifier.padding(top = 6.dp))
            val flags = raw?.let { Words.flags(it, now) } ?: emptyList()
            if (flags.isNotEmpty()) Box(Modifier.padding(top = 8.dp)) { FlagsRow(flags) }
        }
        if (v.history.isNotEmpty()) {
            Column(Modifier.padding(start = 22.dp, end = 22.dp, top = 6.dp, bottom = 22.dp)) {
                val events = v.history.reversed()
                events.forEachIndexed { n, e ->
                    Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                        Box(Modifier.width(14.dp)) {
                            if (n < events.lastIndex) {
                                Canvas(Modifier.padding(top = 18.dp).width(14.dp).height(44.dp)) {
                                    drawLine(p.line, Offset(size.width / 2, 0f), Offset(size.width / 2, size.height), 2.dp.toPx())
                                }
                            }
                            Box(Modifier.padding(top = 4.dp).size(14.dp).border(2.dp, if (n == 0) t.ink else p.mist.ink, CircleShape))
                        }
                        Column(Modifier.padding(bottom = if (n < events.lastIndex) 16.dp else 0.dp)) {
                            Text(e.text, style = MaterialTheme.typography.bodyMedium)
                            e.whenText?.let { Mono(it, 12f) }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun Checks(v: ServiceScreen) {
    val p = LocalPalette.current
    BigCard {
        CardHead("Checks", "${v.checks.size}")
        Column(Modifier.padding(bottom = 8.dp)) {
            v.checks.forEachIndexed { n, c ->
                if (n > 0) Box(Modifier.fillMaxWidth().height(1.dp).background(p.line.copy(alpha = 0.75f)))
                val tone = Words.tone(c.level)
                Row(Modifier.padding(horizontal = 20.dp, vertical = 14.dp), horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                    ToneCircle(tone, size = 34.dp)
                    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        Mono(c.name, 14f, p.ink, FontWeight.Medium)
                        Text(c.level.word, style = MaterialTheme.typography.labelMedium, color = if (tone == Tone.Quiet) p.mute else p.tint(tone).ink)
                        c.note?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = p.mute) }
                        c.checked?.let { Mono("Checked $it", 12f) }
                    }
                }
            }
        }
    }
}

@Composable
private fun Job(snap: Snapshot, v: ServiceScreen) {
    val p = LocalPalette.current
    val run = snap.jobs?.firstOrNull { it.id == v.id }?.lastRun
    BigCard {
        CardHead("Job")
        Column(Modifier.padding(start = 20.dp, end = 20.dp, top = 12.dp, bottom = 20.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            v.job.forEach { (k, value) ->
                Row(horizontalArrangement = Arrangement.spacedBy(18.dp)) {
                    Text(k, style = MaterialTheme.typography.bodyMedium, fontSize = 14.sp, color = p.mute, modifier = Modifier.width(110.dp))
                    Mono(value, 13f, p.ink, modifier = Modifier.weight(1f))
                }
            }
            val done = run?.done
            val total = run?.total
            if (run?.result == "running" && done != null && total != null && total > 0) {
                MeterBar((done / total).toFloat(), p.peach.solid, "job-${v.id}")
            }
        }
    }
}

@Composable
private fun Chart(v: ServiceScreen) {
    val p = LocalPalette.current
    val latest = v.chart.lastOrNull { it != null }
    BigCard {
        Column(Modifier.padding(20.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("Last 24 hours", style = MaterialTheme.typography.titleMedium, fontSize = 18.sp, modifier = Modifier.weight(1f))
                Text(v.metric ?: "", style = MaterialTheme.typography.bodySmall, color = p.mute)
            }
            latest?.let {
                Row(Modifier.padding(top = 10.dp), verticalAlignment = Alignment.Bottom) {
                    Tick(Math.round(it).toInt(), "chart-${v.id}") { n -> Text(n, fontSize = 34.sp, fontWeight = FontWeight.ExtraBold, letterSpacing = (-1).sp, lineHeight = 36.sp) }
                    Text("now", style = MaterialTheme.typography.labelLarge, fontSize = 14.sp, color = p.mute, modifier = Modifier.padding(start = 6.dp, bottom = 4.dp))
                }
            }
            Spacer(Modifier.height(16.dp))
            Bars(v.chart, "svc-${v.id}", v.metric ?: "Chart")
            Axis("24 h ago", "Now")
        }
    }
}
@Composable
private fun Logs(v: ServiceScreen) {
    val p = LocalPalette.current
    BigCard {
        CardHead("Last log lines", "${v.logs.size}")
        SelectionContainer {
            Column(Modifier.padding(10.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                v.logs.forEach { l ->
                    val bg = when (l.level) { "error" -> p.rose.surface; "warn", "warning" -> p.amber.surface; else -> p.panel.copy(alpha = 0f) }
                    val ink = when (l.level) { "error" -> p.rose.ink; "warn", "warning" -> p.amber.ink; else -> p.ink }
                    Text(
                        l.text, fontFamily = Figtree, fontSize = 12.5.sp, lineHeight = 18.sp, color = ink,
                        modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(8.dp)).background(bg).padding(horizontal = 10.dp, vertical = 6.dp),
                    )
                }
            }
        }
    }
}
