package dev.dokkit.phone.core

import java.time.Instant
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.doubleOrNull

data class TopIssue(val id: String, val title: String, val detail: String, val serviceId: String?)

sealed interface TopBox {
    data class Attention(val title: String, val issues: List<TopIssue>, val urgent: Boolean) : TopBox
    data class Fine(val headline: String, val detail: String) : TopBox
}

data class MeterRow(val label: String, val subject: String?, val percent: Int, val isHot: Boolean, val fraction: Float) {
    val spoken: String get() = (subject?.let { "$label $it" } ?: label) + " $percent percent" + if (isHot) ", high" else ""
}

data class KidRow(val id: String, val name: String, val level: Level)

data class MachineCard(
    val id: String,
    val name: String,
    val hardware: Boolean,
    val down: Boolean,
    val inTrouble: Boolean,
    val mark: Level,
    val word: String?,
    val status: String?,
    val meters: List<MeterRow>,
    val counts: String,
    val notice: String?,
    val trouble: List<KidRow>,
    val fine: List<KidRow>,
    val moreFine: List<KidRow>,
    val quietLine: String?,
    val spoken: String,
) {
    val isEmpty: Boolean get() = trouble.isEmpty() && fine.isEmpty() && moreFine.isEmpty() && quietLine == null
}

data class HomeScreen(val top: TopBox, val snoozed: String?, val hardware: List<MachineCard>, val groups: List<MachineCard>)

object Home {
    const val HOT_ABOVE = 85.0
    const val FINE_SHOWN = 8

    fun build(s: Snapshot, now: Instant): HomeScreen {
        val cards = (s.machines ?: emptyList()).map { card(it, now) }
        val order = compareBy<MachineCard>({ !it.down }, { !it.inTrouble }).thenBy(String.CASE_INSENSITIVE_ORDER) { it.name }
        val snoozed = s.inbox?.snoozed?.size ?: 0
        return HomeScreen(
            topBox(s, now),
            if (snoozed > 0) "$snoozed snoozed" else null,
            cards.filter { it.hardware }.sortedWith(order),
            cards.filter { !it.hardware }.sortedWith(order),
        )
    }

    private fun isProduction(environment: String?) = environment == null || environment == "production"

    private fun topBox(s: Snapshot, now: Instant): TopBox {
        val names = Screens.serviceNames(s)
        val needs = s.inbox?.needsYou ?: emptyList()
        val soon = s.inbox?.soon ?: emptyList()
        if (needs.isNotEmpty() || soon.isNotEmpty()) {
            val shown = needs.ifEmpty { soon }
            val title = if (needs.isEmpty()) "${soon.size} coming up soon" else "${needs.size} need you"
            return TopBox.Attention(title, shown.map { line(it, names, now) }, needs.isNotEmpty())
        }
        val machines = s.machines ?: emptyList()
        val hardware = machines.filter { it.kind == "enrolled" }
        val running = machines.sumOf { m -> (m.services ?: emptyList()).count { isProduction(it.environment) && Level.of(it.state) == Level.Ok } }
        val things = "$running thing${if (running == 1) "" else "s"} running"
        val detail = if (hardware.isEmpty()) things else "${hardware.count { it.down != true }} of ${hardware.size} machines up · $things"
        return TopBox.Fine("Everything is fine", detail)
    }

    private fun line(i: Issue, names: Map<String, String?>, now: Instant): TopIssue {
        val parts = mutableListOf<String>()
        i.service?.let { names[it] }?.let { parts += it }
        i.machine?.takeIf { it.isNotEmpty() }?.let { parts += it }
        parseDate(i.since)?.let { parts += "open " + Age.ago(it, now).replace(" ago", "") }
        if (i.snoozedUntil == null && i.alert?.status == "held") parts += "alert held for the night"
        return TopIssue(i.id, i.title ?: "Untitled", parts.joinToString(" · "), i.service)
    }

    private fun meters(v: Map<String, JsonElement>): List<MeterRow> {
        val num = v.mapNotNull { (k, e) -> (e as? JsonPrimitive)?.doubleOrNull?.let { k to it } }.toMap()
        val out = mutableListOf<MeterRow>()
        num["cpu.percent"]?.let { out += meter("CPU", it, null) }
        num["memory.used_percent"]?.let { out += meter("Memory", it, null) }
        val prefix = "disk.used_percent."
        num.filterKeys { it.startsWith(prefix) }.entries
            .minWithOrNull(compareByDescending<Map.Entry<String, Double>> { it.value }.thenBy { it.key })
            ?.let { out += meter("Disk", it.value, it.key.removePrefix(prefix)) }
        return out
    }

    private fun meter(label: String, value: Double, subject: String?) =
        MeterRow(label, subject, Math.round(value).toInt(), value > HOT_ABOVE, (value.coerceIn(0.0, 100.0) / 100).toFloat())

    private fun countLine(fine: Int, trouble: Int, quiet: Int): String = listOfNotNull(
        if (fine > 0) "$fine fine" else null,
        if (trouble > 0) "$trouble in trouble" else null,
        if (quiet > 0) "$quiet no signal" else null,
    ).joinToString(" · ").ifEmpty { "nothing watched" }

    private fun card(m: Machine, now: Instant): MachineCard {
        val trouble = mutableListOf<KidRow>()
        val fine = mutableListOf<KidRow>()
        val quiet = mutableListOf<KidRow>()
        for (svc in m.services ?: emptyList()) {
            if (!isProduction(svc.environment)) continue
            val level = Level.of(svc.state)
            val item = KidRow(svc.id, svc.name ?: "Unnamed", level)
            when (level) {
                Level.Ok -> fine += item
                Level.Unknown -> quiet += item
                Level.Unwatched -> Unit
                else -> trouble += item
            }
        }
        val byName = compareBy<KidRow, String>(String.CASE_INSENSITIVE_ORDER) { it.name }
        trouble.sortWith(compareByDescending<KidRow> { it.level.rank }.then(byName))
        fine.sortWith(byName)
        quiet.sortWith(byName)

        val hardware = m.kind == "enrolled"
        val down = hardware && m.down == true
        val hasTrouble = trouble.isNotEmpty()
        val word = if (!hardware) null else if (down) "Down" else "Up"
        val status = word?.let { w ->
            val seen = parseDate(m.lastSeenAt)?.let { Age.ago(it, now) }
            w + (seen?.let { if (down) " · last reported $it" else " · $it" } ?: "")
        }
        val meterList = meters(m.vitals ?: emptyMap())
        val counts = countLine(fine.size, trouble.size, quiet.size)
        val quietLine = quiet.takeIf { it.isNotEmpty() }?.let {
            "${it.size} with no signal yet: " + it.take(3).joinToString(", ") { r -> r.name } + if (it.size > 3) "…" else ""
        }
        val notice = notice(m)
        val spoken = (listOfNotNull(m.name ?: "Unnamed", status) + meterList.map { it.spoken } + counts + listOfNotNull(notice))
            .joinToString(". ")
        return MachineCard(
            m.id, m.name ?: "Unnamed", hardware, down, hasTrouble,
            if (down) Level.Down else if (hasTrouble) Level.Degraded else Level.Ok,
            word, status, meterList, counts, notice, trouble, fine.take(FINE_SHOWN), fine.drop(FINE_SHOWN), quietLine, spoken,
        )
    }

    private fun notice(m: Machine): String? {
        m.plannedDowntime?.let { w -> return "Planned downtime" + (parseDate(w.until)?.let { " until ${shortTime(it)}" } ?: "") }
        val next = (m.schedules ?: emptyList()).mapNotNull { parseDate(it.next) ?: parseDate(it.at) }.minOrNull() ?: return null
        return "Planned downtime scheduled, next ${shortTime(next)}"
    }
}
