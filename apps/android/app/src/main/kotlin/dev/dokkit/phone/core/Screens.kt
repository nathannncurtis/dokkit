package dev.dokkit.phone.core

import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.time.temporal.ChronoUnit
import java.util.UUID
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.doubleOrNull

sealed class Level(val word: String, val rank: Int) {
    data object Ok : Level("OK", 0)
    data object Degraded : Level("Degraded", 2)
    data object Down : Level("Down", 3)
    data object Unknown : Level("Unknown", 1)
    data object Unwatched : Level("Not watched", 0)
    data class Other(val raw: String) : Level(raw.cap(), 1)

    companion object {
        fun of(s: String?): Level = when (s) {
            "ok" -> Ok
            "degraded" -> Degraded
            "down" -> Down
            "unknown", null -> Unknown
            "unwatched", "not_watched" -> Unwatched
            else -> Other(s.orEmpty())
        }
    }
}

private fun String.cap() = replaceFirstChar { it.uppercase() }

object Age {
    const val WARN_AFTER_SECONDS = 300

    fun seconds(from: Instant, now: Instant): Long = maxOf(0L, ChronoUnit.MILLIS.between(from, now) / 1000)

    fun ago(from: Instant, now: Instant): String {
        val s = seconds(from, now)
        return when {
            s < 5 -> "just now"
            s < 60 -> "$s seconds ago"
            s < 3600 -> "${s / 60} min ago"
            s < 86400 -> "${s / 3600} h ago"
            else -> "${s / 86400} d ago"
        }
    }

    fun isStale(from: Instant, now: Instant): Boolean = ChronoUnit.MILLIS.between(from, now) > WARN_AFTER_SECONDS * 1000L
}

data class Freshness(val text: String, val isWarning: Boolean, val detail: String?) {
    companion object {
        fun make(madeAt: Instant?, hasSnapshot: Boolean, problem: String?, now: Instant): Freshness {
            if (!hasSnapshot) return Freshness("No snapshot yet", problem != null, problem)
            if (madeAt == null) return Freshness("Snapshot age unknown", true, problem)
            val stale = Age.isStale(madeAt, now)
            val late = if (stale) "The server, its network or the relay is not delivering." else null
            return Freshness(
                "Snapshot made ${Age.ago(madeAt, now)}",
                stale,
                listOfNotNull(problem, late).joinToString(" ").ifEmpty { null },
            )
        }
    }
}

fun leftOutText(s: Snapshot): String? {
    val parts = s.server?.leftOut?.takeIf { it.isNotEmpty() } ?: return null
    val names = parts.map {
        when (it) {
            "logs" -> "Log lines"
            "issues" -> "Issue histories"
            "jobs" -> "Jobs"
            "services" -> "Service details"
            "chart" -> "Charts"
            else -> it.cap()
        }
    }
    return names.joinToString(", ") + " were left out of this snapshot to keep it small."
}

private val shortFormat = DateTimeFormatter.ofLocalizedDateTime(FormatStyle.MEDIUM, FormatStyle.SHORT)
private val clockFormat = DateTimeFormatter.ofLocalizedTime(FormatStyle.MEDIUM)

fun shortTime(d: Instant): String = shortFormat.withZone(ZoneId.systemDefault()).format(d)

data class IssueRow(
    val id: String,
    val shortId: String,
    val title: String,
    val level: Level,
    val machine: String,
    val serviceName: String?,
    val serviceId: String?,
    val since: String?,
    val count: String?,
    val note: String?,
    val flags: List<String>,
)

data class NotWatchedRow(val id: String, val name: String, val machine: String, val kind: String, val saw: String?)

data class Section(val title: String, val rows: List<IssueRow>)

data class NeedsYouScreen(
    val sections: List<Section>,
    val notWatched: List<NotWatchedRow>,
    val fine: String?,
    val nothingNeedsYou: Boolean,
)

data class Vital(val label: String, val percent: Int, val isHot: Boolean)

data class ServiceRow(
    val id: String,
    val name: String,
    val level: Level,
    val kind: String,
    val version: String?,
    val environment: String?,
    val note: String?,
    val chart: List<Double?>,
)

data class MachineRow(
    val id: String,
    val name: String,
    val os: String?,
    val level: Level,
    val notice: String?,
    val vitals: List<Vital>,
    val nextWindow: String?,
    val services: List<ServiceRow>,
)

data class CheckRow(val name: String, val kind: String?, val level: Level, val note: String?, val checked: String?)

data class HistoryRow(val whenText: String?, val text: String)

data class LogRow(val time: String, val level: String, val message: String, val isError: Boolean) {
    val text: String get() = "$time ${level.uppercase().take(5).padEnd(5)} $message"
}

data class ServiceScreen(
    val id: String,
    val name: String,
    val machine: String?,
    val kind: String?,
    val level: Level,
    val version: String?,
    val environment: String?,
    val note: String?,
    val checks: List<CheckRow>,
    val issue: IssueRow?,
    val history: List<HistoryRow>,
    val chart: List<Double?>,
    val job: List<Pair<String, String>>,
    val logs: List<LogRow>,
)

object Screens {
    fun needsYou(s: Snapshot, now: Instant): NeedsYouScreen {
        val names = serviceNames(s)
        val box = s.inbox
        fun rows(l: List<Issue>?) = (l ?: emptyList()).map { issueRow(it, names, now) }
        val sections = listOf("Needs you" to rows(box?.needsYou), "Soon" to rows(box?.soon), "Snoozed" to rows(box?.snoozed))
            .filter { it.second.isNotEmpty() }
            .map { Section(it.first, it.second) }
        val notWatched = (box?.notWatched ?: emptyList()).map {
            NotWatchedRow(it.id ?: UUID.randomUUID().toString(), it.detail?.label ?: it.name ?: "Unnamed", it.machine ?: "", it.kind ?: "", it.detail?.saw)
        }
        var fine: String? = null
        val f = box?.fine
        if (f != null && (f.services != null || f.machines != null)) {
            val parts = mutableListOf<String>()
            f.services?.let { parts += "$it service${if (it == 1) "" else "s"}" }
            f.machines?.let { parts += "$it machine${if (it == 1) "" else "s"}" }
            fine = parts.joinToString(" and ") + " fine"
        }
        return NeedsYouScreen(sections, notWatched, fine, box?.needsYou.isNullOrEmpty())
    }

    fun everything(s: Snapshot): List<MachineRow> {
        val top = (s.services ?: emptyList()).associateBy { it.id }
        return (s.machines ?: emptyList()).map { m ->
            val services = (m.services ?: emptyList()).map { svc ->
                val full = top[svc.id] ?: svc
                ServiceRow(
                    id = svc.id,
                    name = svc.name ?: "Unnamed",
                    level = Level.of(svc.state ?: full.state),
                    kind = svc.kind ?: full.kind ?: "service",
                    version = svc.version ?: full.version,
                    environment = envTag(svc.environment ?: full.environment),
                    note = svc.note ?: full.note,
                    chart = full.chart?.values ?: emptyList(),
                )
            }.sortedWith(compareByDescending<ServiceRow> { it.level.rank }.thenBy(String.CASE_INSENSITIVE_ORDER) { it.name })
            val worst = services.map { it.level }.maxByOrNull { it.rank } ?: Level.Ok
            val seen = parseDate(m.lastSeenAt)
            val until = parseDate(m.plannedDowntime?.until)
            val notice = when {
                m.down == true -> "Stopped reporting" + (seen?.let { ", last seen ${shortTime(it)}" } ?: "")
                m.plannedDowntime != null -> "Planned downtime" + (until?.let { " until ${shortTime(it)}" } ?: "")
                else -> null
            }
            val next = (m.schedules ?: emptyList())
                .mapNotNull { sc -> (parseDate(sc.next) ?: parseDate(sc.at))?.let { it to sc } }
                .minByOrNull { it.first }
            val nextText = next?.let { (at, sc) -> "Next planned downtime " + shortTime(at) + (sc.reason?.let { ", $it" } ?: "") }
            MachineRow(m.id, m.name ?: "Unnamed", m.os, if (m.down == true) Level.Down else worst, notice, vitals(m.vitals ?: emptyMap()), nextText, services)
        }.sortedWith(compareByDescending<MachineRow> { it.level.rank }.thenBy(String.CASE_INSENSITIVE_ORDER) { it.name })
    }

    fun service(s: Snapshot, id: String, now: Instant): ServiceScreen? {
        val full = (s.services ?: emptyList()).firstOrNull { it.id == id }
            ?: (s.machines ?: emptyList()).flatMap { it.services ?: emptyList() }.firstOrNull { it.id == id }
            ?: return null
        val names = serviceNames(s)
        val open = full.openIssue ?: (s.issues ?: emptyList()).firstOrNull { it.service == id && it.closedAt == null }
        val detail = (s.issues ?: emptyList()).firstOrNull { it.id == open?.id } ?: open
        val job = (s.jobs ?: emptyList()).firstOrNull { it.id == id }
        return ServiceScreen(
            id = id,
            name = full.name ?: "Unnamed",
            machine = full.machine,
            kind = full.kind,
            level = Level.of(full.state),
            version = full.version,
            environment = full.environment,
            note = full.note,
            checks = (full.checks ?: emptyList()).map {
                CheckRow(it.name ?: "check", it.type, Level.of(it.state), it.note, parseDate(it.checkedAt)?.let { t -> Age.ago(t, now) })
            },
            issue = open?.let { issueRow(it, names, now) },
            history = (detail?.history ?: emptyList()).map { historyRow(it) },
            chart = full.chart?.values ?: emptyList(),
            job = job?.let { jobLines(it) } ?: emptyList(),
            logs = ((s.logs ?: emptyMap())[id] ?: emptyList()).map {
                LogRow(
                    time = parseDate(it.t)?.let { t -> clockFormat.withZone(ZoneId.systemDefault()).format(t) } ?: "--:--:--",
                    level = it.level ?: "info",
                    message = it.msg ?: "",
                    isError = it.level == "error",
                )
            },
        )
    }

    private fun serviceNames(s: Snapshot): Map<String, String?> {
        val out = mutableMapOf<String, String?>()
        s.machines?.forEach { m -> m.services?.forEach { out[it.id] = it.name } }
        s.services?.forEach { out[it.id] = it.name }
        return out
    }

    private fun issueRow(i: Issue, names: Map<String, String?>, now: Instant): IssueRow {
        val flags = mutableListOf<String>()
        parseDate(i.snoozedUntil)?.takeIf { it.isAfter(now) }?.let { flags += "Snoozed until ${shortTime(it)}" }
        if (i.acknowledgedAt != null) flags += "Seen"
        if (i.alert?.status == "held") {
            flags += "Alert held for the night" + (parseDate(i.alert?.until)?.let { " until " + shortTime(it) } ?: "")
        }
        val n = i.count ?: 1
        return IssueRow(
            id = i.id,
            shortId = i.shortId ?: "",
            title = i.title ?: "Untitled",
            level = Level.of(i.state),
            machine = i.machine ?: "",
            serviceName = i.service?.let { names[it] },
            serviceId = i.service,
            since = parseDate(i.since)?.let { "Open since " + Age.ago(it, now).replace(" ago", "") },
            count = if (n > 1) "$n times" else null,
            note = i.note,
            flags = flags,
        )
    }

    private fun historyRow(e: IssueEvent): HistoryRow {
        val name = e.event ?: "event"
        var text = name.cap()
        if (name == "snoozed") parseDate(e.until)?.let { text += " until ${shortTime(it)}" }
        if (!e.note.isNullOrEmpty()) text += ": ${e.note}"
        e.by?.let { text += " ($it)" }
        return HistoryRow(parseDate(e.at)?.let(::shortTime), text)
    }

    private fun jobLines(j: Job): List<Pair<String, String>> {
        val out = mutableListOf<Pair<String, String>>()
        j.schedule?.let { out += "Schedule" to it }
        j.lastRun?.let { r ->
            var v = r.result ?: "unknown"
            r.exitCode?.let { v += ", exit code $it" }
            r.durationMs?.let { v += ", took ${it / 1000} s" }
            val done = r.done
            val total = r.total
            if (r.result == "running" && done != null && total != null && total > 0) v += ", ${(done / total * 100).toInt()} percent"
            out += "Last run" to v
            parseDate(r.startedAt)?.let { out += "Started" to shortTime(it) }
        }
        parseDate(j.lastGoodRun)?.let { out += "Last good run" to shortTime(it) }
        parseDate(j.nextExpected)?.let { out += "Next expected" to shortTime(it) }
        return out
    }

    private fun vitals(v: Map<String, kotlinx.serialization.json.JsonElement>): List<Vital> {
        val num = v.mapNotNull { (k, e) -> (e as? JsonPrimitive)?.doubleOrNull?.let { k to it } }.toMap()
        fun make(label: String, x: Double) = Vital(label, Math.round(x).toInt(), x >= 90)
        val out = mutableListOf<Vital>()
        num["cpu.percent"]?.let { out += make("Processor", it) }
        num["memory.used_percent"]?.let { out += make("Memory", it) }
        num.entries.sortedBy { it.key }.filter { it.key.startsWith("disk.used_percent.") }
            .forEach { out += make("Disk " + it.key.removePrefix("disk.used_percent."), it.value) }
        return out
    }

    private fun envTag(e: String?): String? = if (e == null || e == "production") null else e
}
