package dev.dokkit.phone.core

import java.time.Instant
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.doubleOrNull

data class TopIssue(val id: String, val title: String, val detail: String, val serviceId: String?)

sealed interface TopBox {
    data class Trouble(val title: String, val issues: List<TopIssue>) : TopBox
    data class Fine(val summary: String) : TopBox
}

data class MeterRow(val label: String, val percent: Int?, val hot: Boolean)

data class KidRow(val id: String, val name: String, val level: Level, val word: String)

data class Kids(
    val trouble: List<KidRow>,
    val fine: List<KidRow>,
    val more: List<KidRow>,
    val quietLine: String?,
    val plannedLine: String?,
) {
    val moreLine: String? get() = if (more.isEmpty()) null else "and ${more.size} more that are fine"
    val isEmpty: Boolean get() = trouble.isEmpty() && fine.isEmpty() && more.isEmpty() && quietLine == null && plannedLine == null
}

data class MachineCard(
    val id: String,
    val name: String,
    val hardware: Boolean,
    val down: Boolean,
    val inTrouble: Boolean,
    val status: String?,
    val meters: List<MeterRow>,
    val counts: String,
    val kids: Kids,
    val spoken: String,
)

data class HomeScreen(val top: TopBox, val snoozed: String?, val hardware: List<MachineCard>, val groups: List<MachineCard>)

object Home {
    const val HOT_ABOVE = 85.0
    const val FINE_SHOWN = 8

    fun build(s: Snapshot, now: Instant): HomeScreen {
        val cards = (s.machines ?: emptyList()).map { card(it, s, now) }
        val order = compareBy<MachineCard>({ !it.down }, { !it.inTrouble }).thenBy(String.CASE_INSENSITIVE_ORDER) { it.name }
        val hardware = cards.filter { it.hardware }.sortedWith(order)
        val groups = cards.filter { !it.hardware }.sortedWith(order)
        val snoozed = s.inbox?.snoozed?.size?.takeIf { it > 0 }?.let { "$it snoozed" }
        return HomeScreen(topBox(s, cards, hardware, now), snoozed, hardware, groups)
    }

    private fun topBox(s: Snapshot, cards: List<MachineCard>, hardware: List<MachineCard>, now: Instant): TopBox {
        val names = serviceNames(s)
        val rows = (s.inbox?.needsYou ?: emptyList()).map { issueRow(it, names, now) }
        if (rows.isNotEmpty()) {
            val issues = rows.map {
                TopIssue(it.id, it.title, listOfNotNull(it.serviceName, it.machine.ifEmpty { null }, it.since).joinToString(" · "), it.serviceId)
            }
            return TopBox.Trouble("${issues.size} need you", issues)
        }
        val running = cards.sumOf { c -> c.kids.fine.size + c.kids.more.size }
        return TopBox.Fine("${hardware.count { !it.down }} of ${hardware.size} machines up · $running things running")
    }

    private fun card(m: Machine, s: Snapshot, now: Instant): MachineCard {
        val top = (s.services ?: emptyList()).associateBy { it.id }
        val watched = (m.services ?: emptyList()).mapNotNull { svc ->
            val full = top[svc.id] ?: svc
            val level = Level.of(svc.state ?: full.state)
            val env = svc.environment ?: full.environment
            if (level == Level.Unwatched || (env != null && env != "production")) null
            else KidRow(svc.id, svc.name ?: full.name ?: "Unnamed", level, "")
        }
        val byName = compareBy<KidRow, String>(String.CASE_INSENSITIVE_ORDER) { it.name }
        val trouble = watched.filter { it.level == Level.Down || it.level == Level.Degraded }
            .sortedWith(compareBy<KidRow> { it.level != Level.Down }.then(byName)).map { it.copy(word = it.level.word) }
        val fine = watched.filter { it.level == Level.Ok }.sortedWith(byName)
        val quiet = watched.filter { it.level != Level.Ok && it.level != Level.Down && it.level != Level.Degraded }.sortedWith(byName)

        val counts = listOfNotNull(
            fine.size.takeIf { it > 0 }?.let { "$it fine" },
            trouble.size.takeIf { it > 0 }?.let { "$it in trouble" },
            quiet.size.takeIf { it > 0 }?.let { "$it no signal" },
        ).joinToString(" · ").ifEmpty { "nothing watched" }

        val quietLine = quiet.takeIf { it.isNotEmpty() }?.let {
            "${it.size} with no signal yet: " + it.take(3).joinToString(", ") { r -> r.name } + if (it.size > 3) "…" else ""
        }
        val kids = Kids(trouble, fine.take(FINE_SHOWN).map { it.copy(word = "OK") }, fine.drop(FINE_SHOWN).map { it.copy(word = "OK") }, quietLine, planned(m))

        val hardware = m.kind == "enrolled"
        val down = hardware && m.down == true
        val seen = parseDate(m.lastSeenAt)?.let { Age.ago(it, now) }
        val status = if (!hardware) null else (if (down) "Down" else "Up") + (seen?.let { " · $it" } ?: "")
        val meters = if (hardware) meters(m.vitals ?: emptyMap()) else emptyList()
        val spoken = buildString {
            append(m.name ?: "Unnamed").append(". ")
            status?.let { append(it).append(". ") }
            if (meters.isNotEmpty()) {
                append(meters.joinToString(", ") { r ->
                    r.label + " " + (r.percent?.let { p -> "$p percent" + if (r.hot) ", high" else "" } ?: "no reading")
                }).append(". ")
            }
            append(counts).append('.')
        }
        return MachineCard(m.id, m.name ?: "Unnamed", hardware, down, trouble.isNotEmpty(), status, meters, counts, kids, spoken)
    }

    private fun planned(m: Machine): String? {
        if (m.plannedDowntime != null) return "Planned downtime" + (parseDate(m.plannedDowntime.until)?.let { " until ${shortTime(it)}" } ?: "")
        val next = (m.schedules ?: emptyList())
            .mapNotNull { sc -> (parseDate(sc.next) ?: parseDate(sc.at))?.let { it to sc } }
            .minByOrNull { it.first } ?: return null
        return "Next planned downtime " + shortTime(next.first) + (next.second.reason?.let { ", $it" } ?: "")
    }

    private fun meters(v: Map<String, JsonElement>): List<MeterRow> {
        val num = v.mapNotNull { (k, e) -> (e as? JsonPrimitive)?.doubleOrNull?.let { k to it } }.toMap()
        val cpu = num["cpu.percent"]
        val mem = num["memory.used_percent"]
        val disk = num.filterKeys { it.startsWith("disk.used_percent.") }.values.maxOrNull()
        if (cpu == null && mem == null && disk == null) return emptyList()
        fun row(label: String, x: Double?) = MeterRow(label, x?.let { Math.round(it).toInt() }, x != null && x > HOT_ABOVE)
        return listOf(row("CPU", cpu), row("Memory", mem), row("Disk", disk))
    }
}
