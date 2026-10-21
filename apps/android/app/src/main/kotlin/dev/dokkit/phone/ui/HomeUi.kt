package dev.dokkit.phone.ui

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.togetherWith
import androidx.compose.animation.core.VisibilityThreshold
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.dokkit.phone.AppViewModel
import dev.dokkit.phone.R
import dev.dokkit.phone.Route
import dev.dokkit.phone.core.Home
import dev.dokkit.phone.core.KidRow
import dev.dokkit.phone.core.MachineCard
import dev.dokkit.phone.core.Screens
import dev.dokkit.phone.core.Snapshot
import dev.dokkit.phone.core.Tone
import dev.dokkit.phone.core.TopBox
import dev.dokkit.phone.core.Words
import dev.dokkit.phone.core.leftOutText
import java.time.Instant

private fun cardTone(c: MachineCard) = if (c.planned) Tone.Quiet else if (c.down) Tone.Down else if (c.inTrouble) Tone.Degraded else Tone.Ok

/** The hero and body every server page shows when there is no snapshot to show. */
@Composable
fun NoSnapshot(vm: AppViewModel, title: String, now: Instant, onBack: (() -> Unit)?) {
    val f = vm.freshness(now)
    val paired = vm.servers.isNotEmpty()
    StatementPage(
        Tone.Quiet, { ServerTop(vm, title, onBack) },
        HeroModel(
            Tone.Quiet, if (paired) R.drawable.ic_ph_hourglass_medium else R.drawable.ic_ph_device_mobile,
            big = { BigLine(if (paired) "No snapshot yet" else "No server paired", it) },
            eyebrow = { Eyebrow(Words.greeting(now), Tone.Quiet) },
            lede = if (paired) "This phone is paired. The server uploads a snapshot about once a minute while a phone is paired; pull down to look again."
            else "In the Dokkit web interface open Settings, Phones, Add a phone. It shows a QR code once. Then choose Servers here and scan it.",
        ),
        vm.refreshing, { vm.refreshAsync() },
    ) {
        if (f.detail != null) Banner(f)
    }
}

@Composable
fun HomePage(vm: AppViewModel, now: Instant) {
    val snap = vm.selectedState.snapshot
    if (snap == null) {
        NoSnapshot(vm, "Home", now, null)
        return
    }
    val p = LocalPalette.current
    val f = vm.freshness(now)
    val h = Home.build(snap, now, vm.settings.hotPercent.toDouble(), vm.settings.fineShown)
    val top = h.top
    val tone = when {
        top is TopBox.Fine -> Tone.Ok
        h.needs.isNotEmpty() -> if (h.needs.any { it.tone == Tone.Down }) Tone.Down else Tone.Degraded
        else -> Tone.Soon
    }
    val hero = HeroModel(
        tone, toneIcon(tone),
        big = { size ->
            when {
                top is TopBox.Fine -> BigLine(top.headline, size)
                h.needs.isNotEmpty() -> BigWithTick(h.needs.size, "hero-needs", "thing needs you", "things need you", size)
                else -> BigWithTick(h.soon.size, "hero-soon", "thing is coming up", "things are coming up", size)
            }
        },
        eyebrow = { Eyebrow(Words.greeting(now), tone, R.drawable.ic_ph_hand_waving) },
        lede = if (top is TopBox.Fine) top.detail else h.lede,
        age = f.text.takeIf { !f.isWarning && f.detail == null },
    )
    StatementPage(tone, { ServerTop(vm, "Home") }, hero, vm.refreshing, { vm.refreshAsync() }) {
        if (f.isWarning || f.detail != null) Banner(f)
        leftOutText(snap)?.let { QuietLine(it, R.drawable.ic_ph_info) }
        Figures(
            listOf(
                Figure(h.needs.size, "need you", if (tone == Tone.Down) Tone.Down else Tone.Degraded, "fig-needs"),
                Figure(h.soon.size, "coming up", Tone.Soon, "fig-soon"),
                Figure(h.fineServices, "fine", Tone.Ok, "fig-fine"),
            ),
        )
        if (top is TopBox.Attention) {
            var tab by rememberSaveable { mutableStateOf("needs") }
            if (tab == "needs" && h.needs.isEmpty()) tab = "soon"
            if (tab == "soon" && h.soon.isEmpty()) tab = "needs"
            if (h.needs.isNotEmpty() && h.soon.isNotEmpty()) {
                Segmented(listOf("needs" to "Needs you" to h.needs.size, "soon" to "Coming up" to h.soon.size), tab) { tab = it }
            } else {
                Label(if (tab == "needs") "Needs you" else "Coming up")
            }
            // The cards slide with the switch, on the same spring as its lens: forward pushes them left.
            val reduced = LocalReducedMotion.current
            androidx.compose.animation.AnimatedContent(
                targetState = tab,
                transitionSpec = {
                    val dir = if (targetState == "soon") 1 else -1
                    val move = androidx.compose.animation.core.spring(TRAVEL_DAMPING, TRAVEL_STIFFNESS, androidx.compose.ui.unit.IntOffset.VisibilityThreshold)
                    if (reduced) androidx.compose.animation.EnterTransition.None togetherWith androidx.compose.animation.ExitTransition.None
                    else (androidx.compose.animation.slideInHorizontally(move) { dir * it } togetherWith androidx.compose.animation.slideOutHorizontally(move) { -dir * it })
                        .using(androidx.compose.animation.SizeTransform(clip = false) { _, _ -> androidx.compose.animation.core.spring(TRAVEL_DAMPING, TRAVEL_STIFFNESS, androidx.compose.ui.unit.IntSize.VisibilityThreshold) })
                },
                label = "issues",
            ) { t ->
                Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
                    (if (t == "needs") h.needs else h.soon).forEach { c ->
                        IssueCardView(c) { c.serviceId?.let { vm.go(Route.Service(it, c.id)) } }
                    }
                }
            }
            h.snoozed?.let { QuietLine(it, R.drawable.ic_ph_moon) }
            h.fineLine?.let { AllFine(it) }
        } else {
            h.snoozed?.let { QuietLine(it, R.drawable.ic_ph_moon) }
        }
        val days = h.hardware.filter { it.lastDay != null }
        if (days.isNotEmpty()) {
            BigCard {
                Column(Modifier.padding(20.dp)) {
                    Text("The last day", style = MaterialTheme.typography.titleMedium, fontSize = 18.sp)
                    Text("The last 24 hours. Now is on the right.", style = MaterialTheme.typography.bodySmall, fontSize = 14.sp, color = p.mute)
                    Spacer(Modifier.height(16.dp))
                    days.forEachIndexed { n, c ->
                        Row(
                            Modifier.fillMaxWidth().clickable(role = Role.Button, onClickLabel = "Open ${c.name}") { vm.go(Route.Machine(c.id)) }.padding(top = if (n == 0) 0.dp else 8.dp, bottom = 4.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Mono(c.name, 12.5f, p.ink2, modifier = Modifier.weight(1f))
                            Ph(R.drawable.ic_ph_caret_right, Modifier.size(14.dp), tint = p.mute)
                        }
                        Strip(c.lastDay!!, "home-${c.id}", n, c.name)
                    }
                    Spacer(Modifier.height(16.dp))
                    Legend()
                }
            }
        }
        if (h.hardware.isNotEmpty()) {
            Label("Machines")
            MachineList(vm, h.hardware)
        }
        if (h.groups.isNotEmpty()) {
            Label("Not on a machine")
            MachineList(vm, h.groups)
        }
    }
}

@Composable
fun Segmented(items: List<Pair<Pair<String, String>, Int>>, selected: String, onPick: (String) -> Unit) {
    val p = LocalPalette.current
    val shape = RoundedCornerShape(16.dp)
    GlassSelector(
        items.size, items.indexOfFirst { it.first.first == selected }, { onPick(items[it].first.first) },
        Modifier.fillMaxWidth(),
        shape = shape, lensShape = RoundedCornerShape(12.dp), inset = 4.dp,
        surface = { clip(shape).background(p.bg2.copy(alpha = 0.8f)) },
        lensRestColor = p.panel,
    ) { i, near, grow ->
        val (kv, n) = items[i]
        Row(
            Modifier.weight(1f).heightIn(min = 44.dp)
                .clickable(remember { androidx.compose.foundation.interaction.MutableInteractionSource() }, null, role = Role.Tab) { onPick(kv.first) }
                .semantics { this.selected = kv.first == selected }
                .graphicsLayer { scaleX = grow; scaleY = grow },
            horizontalArrangement = Arrangement.Center,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(kv.second, style = MaterialTheme.typography.labelLarge, fontSize = 14.5.sp, color = androidx.compose.ui.graphics.lerp(p.ink2, p.ink, near))
            Mono(" $n", 12f)
        }
    }
}

@Composable
fun AllFine(text: String) {
    val p = LocalPalette.current
    Row(
        Modifier.rise().fillMaxWidth().clip(RoundedCornerShape(24.dp)).background(p.sage.surface).padding(20.dp),
        horizontalArrangement = Arrangement.spacedBy(16.dp), verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(Modifier.size(44.dp).clip(RoundedCornerShape(50)).background(p.panel), contentAlignment = Alignment.Center) { Ph(R.drawable.ic_ph_check_circle, tint = p.sage.ink) }
        Column {
            Text(text, style = MaterialTheme.typography.labelLarge, fontSize = 15.5.sp, color = p.sage.ink)
            Text("Nothing to do there. Dokkit keeps watching.", style = MaterialTheme.typography.bodySmall, fontSize = 14.sp, color = p.sage.ink.copy(alpha = 0.85f))
        }
    }
}

@Composable
private fun MachineList(vm: AppViewModel, cards: List<MachineCard>) {
    val p = LocalPalette.current
    BigCard {
        cards.forEachIndexed { i, c ->
            if (i > 0) Box(Modifier.fillMaxWidth().height(1.dp).background(p.line.copy(alpha = 0.75f)))
            MachineRow(vm, c)
        }
    }
}

@Composable
private fun MachineRow(vm: AppViewModel, c: MachineCard) {
    val p = LocalPalette.current
    val open = vm.openMachines[c.id] ?: false
    val turn by animateFloatAsState(if (open) 180f else 0f, tween(350, easing = Ease), label = "chev")
    Column(Modifier.fillMaxWidth().background(if (open) p.bg.copy(alpha = 0.5f) else p.panel.copy(alpha = 0f))) {
        Row(
            Modifier.fillMaxWidth().heightIn(min = 68.dp).clickable { vm.openMachines[c.id] = !open }.padding(horizontal = 20.dp, vertical = 14.dp)
                .clearAndSetSemantics {
                    contentDescription = c.spoken
                    stateDescription = if (open) "Expanded" else "Collapsed"
                    role = Role.Button
                    onClick(label = if (open) "Close" else "Open") { vm.openMachines[c.id] = !open; true }
                },
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            if (c.hardware) Pip(cardTone(c).let { if (it == Tone.Ok) Tone.Ok else it }) else Ph(R.drawable.ic_ph_cloud, Modifier.size(17.dp), tint = p.mute)
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Mono(c.name, 16f, p.ink, FontWeight.Medium)
                c.status?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = if (c.down) p.rose.ink else p.mute) }
                Text(c.counts, style = MaterialTheme.typography.bodySmall, color = p.mute)
            }
            Ph(R.drawable.ic_ph_caret_down, Modifier.size(20.dp).rotate(turn), tint = p.mute)
        }
        AnimatedVisibility(open, enter = expandVertically(tween(380, easing = Ease)) + fadeIn(tween(300)), exit = shrinkVertically(tween(300, easing = Ease)) + fadeOut(tween(200))) {
            Column(Modifier.padding(start = 20.dp, end = 20.dp, bottom = 20.dp, top = 2.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                if (c.meters.isNotEmpty()) {
                    Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) { c.meters.forEachIndexed { n, m -> Box(Modifier.weight(1f)) { MeterView(m, "${c.id}-$n") } } }
                }
                c.notice?.let { NoticeLine(it) }
                Services(vm, c)
                if (c.hardware) SoftButton("Open ${c.name}", { vm.go(Route.Machine(c.id)) }, modifier = Modifier.fillMaxWidth())
            }
        }
    }
}

@Composable
private fun NoticeLine(text: String) {
    val p = LocalPalette.current
    Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp)).background(p.mist.surface).padding(horizontal = 14.dp, vertical = 10.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
        Ph(R.drawable.ic_ph_moon, Modifier.size(16.dp), tint = p.mist.ink)
        Text(text, style = MaterialTheme.typography.bodySmall, fontSize = 13.5.sp, color = p.mist.ink)
    }
}

@Composable
fun Services(vm: AppViewModel, c: MachineCard) {
    val p = LocalPalette.current
    val more = vm.openMore[c.id] ?: false
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        if (c.isEmpty) QuietLine("Nothing is watched on it.")
        c.trouble.forEach { SvcRow(vm, it) }
        c.fine.forEach { SvcRow(vm, it) }
        AnimatedVisibility(more, enter = expandVertically(tween(350, easing = Ease)) + fadeIn(), exit = shrinkVertically(tween(250)) + fadeOut()) {
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) { c.moreFine.forEach { SvcRow(vm, it) } }
        }
        if (c.moreFine.isNotEmpty()) {
            Text(
                if (more) "Show fewer" else "and ${c.moreFine.size} more that are fine",
                style = MaterialTheme.typography.labelLarge, fontSize = 14.sp, color = p.brand,
                modifier = Modifier.fillMaxWidth().heightIn(min = 44.dp).clip(RoundedCornerShape(10.dp)).clickable { vm.openMore[c.id] = !more }.padding(horizontal = 12.dp, vertical = 12.dp),
            )
        }
        c.quietLine?.let { QuietLine(it, R.drawable.ic_ph_circle_dashed) }
    }
}

@Composable
private fun SvcRow(vm: AppViewModel, r: KidRow) {
    val p = LocalPalette.current
    val tone = Words.tone(r.level)
    Pressable(
        { vm.go(Route.Service(r.id)) }, "Open the service",
        Modifier.fillMaxWidth().heightIn(min = 46.dp).clip(RoundedCornerShape(14.dp)).background(androidx.compose.ui.graphics.lerp(p.panel, p.bg, 0.7f)),
    ) {
        Row(Modifier.padding(horizontal = 12.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Pip(tone)
            Mono(r.name, 13.5f, p.ink, modifier = Modifier.weight(1f))
            if (tone == Tone.Ok) Text(r.level.word, style = MaterialTheme.typography.bodySmall, fontSize = 12.sp, color = p.mute) else Tag(r.level.word, tone)
        }
    }
}

// ---------- a machine ----------

@Composable
fun MachinePage(vm: AppViewModel, id: String, now: Instant) {
    val snap = vm.selectedState.snapshot
    if (snap == null) {
        NoSnapshot(vm, "Machine", now) { vm.back() }
        return
    }
    val p = LocalPalette.current
    val f = vm.freshness(now)
    val c = Home.machine(snap, id, now, vm.settings.hotPercent.toDouble(), vm.settings.fineShown)
    if (c == null) {
        StatementPage(Tone.Quiet, { ServerTop(vm, "Machine") { vm.back() } }, HeroModel(Tone.Quiet, R.drawable.ic_ph_info, { BigLine("Not in this snapshot", it) },
            eyebrow = { Eyebrow("Machine", Tone.Quiet) }, lede = "The newest snapshot no longer lists this machine.")) {}
        return
    }
    val tone = cardTone(c)
    val mine = machineIssues(snap, c.name, now)
    val lede = when {
        c.planned -> "${c.notice}. That is expected, so Dokkit does not worry about it."
        c.down -> "It has stopped reporting."
        mine.isNotEmpty() -> Words.plural(mine.size, "thing needs", "things need") + " a look here."
        else -> "All good. ${c.counts}."
    }
    val hero = HeroModel(
        tone, if (c.planned) R.drawable.ic_ph_moon else toneIcon(tone),
        big = { BigLine(c.name, it, mono = true) },
        eyebrow = { Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) { c.word?.let { Tag(it, tone, onPanel = true) }; c.os?.let { Eyebrow(it, tone) } } },
        lede = lede,
        extra = c.status?.let { s -> { Mono(s, 12.5f, modifier = Modifier.padding(top = 8.dp)) } },
        age = f.text.takeIf { !f.isWarning && f.detail == null },
    )
    StatementPage(tone, { ServerTop(vm, "Machine") { vm.back() } }, hero, vm.refreshing, { vm.refreshAsync() }) {
        if (f.isWarning || f.detail != null) Banner(f)
        if (c.meters.isNotEmpty()) {
            BigCard {
                Row(Modifier.fillMaxWidth().height(IntrinsicSize.Min)) {
                    c.meters.forEachIndexed { n, m ->
                        if (n > 0) Box(Modifier.width(1.dp).fillMaxHeight().background(p.line.copy(alpha = 0.75f)))
                        Column(Modifier.weight(1f).padding(start = 18.dp, end = 12.dp, top = 18.dp, bottom = 18.dp).clearAndSetSemantics { contentDescription = m.spoken },
                            verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            Text(m.label + (m.subject?.let { " $it" } ?: ""), style = MaterialTheme.typography.labelMedium, color = p.mute, maxLines = 1, overflow = TextOverflow.Ellipsis)
                            Row(verticalAlignment = Alignment.Bottom) {
                                Tick(m.percent, "v-$id-$n") { Text(it, fontSize = 30.sp, fontWeight = FontWeight.ExtraBold, letterSpacing = (-0.9).sp, lineHeight = 30.sp, color = if (m.isHot) p.amber.ink else p.ink) }
                                Text("%", style = MaterialTheme.typography.labelLarge, color = p.mute, modifier = Modifier.padding(start = 1.dp, bottom = 2.dp))
                            }
                            MeterBar(m.fraction, if (m.isHot) p.amber.solid else p.sage.solid, "mp-$id-$n")
                        }
                    }
                }
            }
        } else if (c.hardware) {
            QuietLine(if (c.down) "Not reporting, so no readings." else "No readings in this snapshot.")
        }
        c.lastDay?.let { day ->
            BigCard {
                Column(Modifier.padding(20.dp)) {
                    Text("The last day", style = MaterialTheme.typography.titleMedium, fontSize = 18.sp)
                    Text("The last 24 hours.", style = MaterialTheme.typography.bodySmall, fontSize = 14.sp, color = p.mute, modifier = Modifier.padding(bottom = 16.dp))
                    Strip(day, "machine-$id", 0, c.name)
                    Axis("24 h ago", "12 h ago", "Now")
                    Spacer(Modifier.height(12.dp))
                    Legend()
                }
            }
        }
        if (mine.isNotEmpty()) {
            Label("Needs a look")
            mine.forEach { i -> IssueCardView(i) { i.serviceId?.let { vm.go(Route.Service(it, i.id)) } } }
        }
        Label("Services")
        BigCard { Box(Modifier.padding(10.dp)) { Services(vm, c) } }
    }
}

private fun machineIssues(s: Snapshot, machine: String, now: Instant) = s.inbox.let { box ->
    val names = Screens.serviceNames(s)
    listOfNotNull(box?.needsYou, box?.soon, box?.snoozed).flatten().filter { it.machine == machine }.map { Words.card(it, names, now) }
}
