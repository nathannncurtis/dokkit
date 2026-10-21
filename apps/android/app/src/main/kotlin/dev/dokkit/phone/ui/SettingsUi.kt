package dev.dokkit.phone.ui

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.dokkit.phone.AppViewModel
import dev.dokkit.phone.R
import dev.dokkit.phone.core.AppSettings
import dev.dokkit.phone.core.LockAfter
import dev.dokkit.phone.core.ThemeChoice
import dev.dokkit.phone.core.Tone

private class Setting<T>(
    val title: String,
    val sub: String,
    val get: (AppSettings) -> T,
    val set: (AppSettings, T) -> AppSettings,
    val control: @Composable (T, (T) -> Unit) -> Unit,
    val defaultText: String,
)

private fun number(title: String, sub: String, before: String, after: String, range: IntRange, step: Int, get: (AppSettings) -> Int, set: (AppSettings, Int) -> AppSettings): Setting<Int> {
    val d = get(AppSettings())
    return Setting(title, sub, get, set, { v, on -> Stepper(v, range, step, before, after, title, on) }, "$before $d $after".replace(" %", "%").trim())
}

private fun <T> choice(title: String, sub: String, options: List<T>, word: (T) -> String, get: (AppSettings) -> T, set: (AppSettings, T) -> AppSettings): Setting<T> =
    Setting(title, sub, get, set, { v, on -> Choices(options, v, word, on) }, word(get(AppSettings())))

private class Group(val title: String, val sub: String, val icon: Int, val rows: List<Setting<*>>)

private val groups = listOf(
    Group("Look", "Light or dark.", R.drawable.ic_ph_palette, listOf(
        choice("Theme", "Light or dark. Follows the phone until you pick one.", ThemeChoice.entries, { it.word }, { it.theme }, { s, v -> s.copy(theme = v) }),
    )),
    Group("Snapshots", "How often the app looks, and when it warns.", R.drawable.ic_ph_arrows_clockwise, listOf(
        number("Look for a new snapshot", "While the app is in front. It also looks when opened and when you pull down.", "Every", "seconds",
            AppSettings.Limits.refresh, 5, { it.refreshSeconds }, { s, v -> s.copy(refreshSeconds = v) }),
        number("Snapshot is late", "Past this age the snapshot gets a warning.", "After", "minutes", AppSettings.Limits.late, 1, { it.lateMinutes }, { s, v -> s.copy(lateMinutes = v) }),
        number("Relay timeout", "How long to wait for the relay before saying it could not be reached.", "Wait", "seconds",
            AppSettings.Limits.relayWait, 5, { it.relayWaitSeconds }, { s, v -> s.copy(relayWaitSeconds = v) }),
    )),
    Group("What the screens show", "Meters and long lists.", R.drawable.ic_ph_squares_four, listOf(
        number("Busy meters", "A processor, memory or disk meter turns amber above this.", "Above", "%", AppSettings.Limits.hot, 5, { it.hotPercent }, { s, v -> s.copy(hotPercent = v) }),
        number("Fine services listed", "On a machine, the rest fold under \"and more that are fine\".", "Show", "then fold",
            AppSettings.Limits.fineShown, 1, { it.fineShown }, { s, v -> s.copy(fineShown = v) }),
    )),
    Group("Unlock", "When the app asks again.", R.drawable.ic_ph_lock_simple, listOf(
        choice("Ask to unlock", "Fingerprint, face or screen lock before anything shows.", LockAfter.entries, { it.word }, { it.lockAfter }, { s, v -> s.copy(lockAfter = v) }),
    )),
)

@Composable
fun SettingsPage(vm: AppViewModel) {
    val p = LocalPalette.current
    var draft by remember(vm.settings) { mutableStateOf(vm.settings) }
    val n = vm.settings.changed
    val hero = HeroModel(
        Tone.Brand, R.drawable.ic_ph_sliders_horizontal,
        { size -> if (n == 0) BigLine("All on defaults", size) else Tick(n, "set-n") { BigLine("$it changed", size) } },
        eyebrow = { Eyebrow("Settings", Tone.Brand) },
        lede = "Each starts at the value the app has always used, and shows it with a Reset next to it.",
    )
    StatementPage(Tone.Brand, { TopBar("Settings", null) }, hero) {
        groups.forEachIndexed { gi, g ->
            var open by rememberSaveable { mutableStateOf(gi == 0) }
            val turn by animateFloatAsState(if (open) 180f else 0f, tween(300, easing = Ease), label = "chev")
            BigCard {
                Row(
                    Modifier.fillMaxWidth().heightIn(min = 64.dp).clickable(role = Role.Button) { open = !open }.padding(horizontal = 20.dp, vertical = 16.dp)
                        .semantics { stateDescription = if (open) "Expanded" else "Collapsed" },
                    verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    Box(Modifier.size(34.dp).clip(CircleShape).background(p.brandSoft), contentAlignment = Alignment.Center) { Ph(g.icon, Modifier.size(18.dp)) }
                    Column(Modifier.weight(1f)) {
                        Text(g.title, style = MaterialTheme.typography.titleMedium, modifier = Modifier.semantics { heading() })
                        Text(g.sub, style = MaterialTheme.typography.bodySmall, fontSize = 14.sp, color = p.mute)
                    }
                    Ph(R.drawable.ic_ph_caret_down, Modifier.size(20.dp).rotate(turn), tint = p.mute)
                }
                AnimatedVisibility(open, enter = expandVertically(tween(350, easing = Ease)) + fadeIn(tween(300)), exit = shrinkVertically(tween(300, easing = Ease)) + fadeOut(tween(200))) {
                    Column(Modifier.padding(start = 20.dp, end = 20.dp, bottom = 18.dp)) {
                        g.rows.forEachIndexed { i, r ->
                            if (i > 0) Box(Modifier.fillMaxWidth().height(1.dp).background(p.line))
                            @Suppress("UNCHECKED_CAST")
                            SettingRow(r as Setting<Any?>, draft) { draft = it }
                        }
                        val dirty = g.rows.any { r -> r.get(draft) != r.get(vm.settings) }
                        Box(Modifier.fillMaxWidth().height(1.dp).background(p.line))
                        Row(Modifier.fillMaxWidth().padding(top = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                            Text(if (dirty) "Not saved yet." else "Applies on this phone only.", style = MaterialTheme.typography.bodySmall, color = if (dirty) p.amber.ink else p.mute, modifier = Modifier.weight(1f))
                            Box(Modifier.padding(start = 12.dp).width(120.dp)) {
                                PrimaryButton("Save", {
                                    @Suppress("UNCHECKED_CAST")
                                    vm.save(g.rows.fold(vm.settings) { acc, r -> (r as Setting<Any?>).set(acc, r.get(draft)) })
                                }, icon = R.drawable.ic_ph_check, enabled = dirty)
                            }
                        }
                    }
                }
            }
        }
        BigCard {
            Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text("About", style = MaterialTheme.typography.titleMedium)
                Text("Dokkit for Android. Read-only: it cannot change anything on a server and sends no notifications. It fetches when opened, when you pull down, and on the schedule above while in front.",
                    style = MaterialTheme.typography.bodySmall, fontSize = 14.sp, color = p.mute)
            }
        }
    }
}

@Composable
private fun SettingRow(r: Setting<Any?>, draft: AppSettings, onDraft: (AppSettings) -> Unit) {
    val p = LocalPalette.current
    val v = r.get(draft)
    val changed = v != r.get(AppSettings())
    Column(Modifier.padding(vertical = 14.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(r.title, style = MaterialTheme.typography.titleSmall, fontSize = 15.5.sp)
            if (changed) Text("changed", style = MaterialTheme.typography.labelSmall, fontSize = 11.sp, color = p.brand,
                modifier = Modifier.clip(RoundedCornerShape(99.dp)).background(p.brandSoft).padding(horizontal = 7.dp, vertical = 2.dp))
        }
        Text(r.sub, style = MaterialTheme.typography.bodySmall, fontSize = 13.5.sp, color = p.mute)
        r.control(v) { onDraft(r.set(draft, it)) }
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("Default: ${r.defaultText}", style = MaterialTheme.typography.bodySmall, fontSize = 12.5.sp, color = p.mute)
            if (changed) {
                Text("Reset", style = MaterialTheme.typography.labelMedium, color = p.brand,
                    modifier = Modifier.padding(start = 4.dp).heightIn(min = 44.dp).clip(RoundedCornerShape(10.dp))
                        .clickable(role = Role.Button, onClickLabel = "Reset ${r.title}") { onDraft(r.set(draft, r.get(AppSettings()))) }
                        .padding(horizontal = 8.dp, vertical = 12.dp))
            }
        }
    }
}

@Composable
private fun Stepper(value: Int, range: IntRange, step: Int, before: String, after: String, title: String, on: (Int) -> Unit) {
    val p = LocalPalette.current
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        Text(before, style = MaterialTheme.typography.bodyMedium, color = p.ink2)
        Row(Modifier.clip(RoundedCornerShape(14.dp)).background(p.bg).border(1.dp, p.line, RoundedCornerShape(14.dp)), verticalAlignment = Alignment.CenterVertically) {
            StepButton("−", "Less $title", value > range.first) { on((value - step).coerceIn(range)) }
            Text("$value", fontFamily = Figtree, fontWeight = FontWeight.Medium, fontSize = 16.sp, textAlign = TextAlign.Center, modifier = Modifier.widthIn(min = 44.dp))
            StepButton("+", "More $title", value < range.last) { on((value + step).coerceIn(range)) }
        }
        Text(after, style = MaterialTheme.typography.bodyMedium, color = p.ink2)
    }
}

@Composable
private fun StepButton(text: String, label: String, enabled: Boolean, onClick: () -> Unit) {
    val p = LocalPalette.current
    Box(
        Modifier.size(44.dp).clickable(enabled = enabled, role = Role.Button, onClick = onClick).semantics { contentDescription = label },
        contentAlignment = Alignment.Center,
    ) { Text(text, fontSize = 20.sp, fontWeight = FontWeight.SemiBold, color = if (enabled) p.ink else p.line) }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun <T> Choices(options: List<T>, value: T, word: (T) -> String, on: (T) -> Unit) {
    val p = LocalPalette.current
    FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        options.forEach { o ->
            val sel = o == value
            Text(
                word(o), style = MaterialTheme.typography.labelLarge, fontSize = 14.sp, color = if (sel) p.brandInk else p.ink2,
                modifier = Modifier.heightIn(min = 44.dp).clip(RoundedCornerShape(99.dp)).background(if (sel) p.brand else p.bg)
                    .border(1.dp, if (sel) p.brand else p.line, RoundedCornerShape(99.dp))
                    .clickable(role = Role.RadioButton) { on(o) }.semantics { selected = sel }
                    .padding(horizontal = 16.dp, vertical = 12.dp),
            )
        }
    }
}
