package dev.dokkit.phone.core

import java.time.Instant
import java.time.OffsetDateTime
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement

fun parseDate(s: String?): Instant? = s?.let { runCatching { OffsetDateTime.parse(it).toInstant() }.getOrNull() }

@Serializable
data class Snapshot(
    val schema: Int? = null,
    val server: ServerInfo? = null,
    val inbox: Inbox? = null,
    val machines: List<Machine>? = null,
    val services: List<Service>? = null,
    val issues: List<Issue>? = null,
    val jobs: List<Job>? = null,
    val logs: Map<String, List<LogLine>>? = null,
) {
    companion object {
        private val json = Json {
            ignoreUnknownKeys = true
            isLenient = true
            coerceInputValues = true
        }

        fun decode(data: ByteArray): Snapshot = json.decodeFromString(data.toString(Charsets.UTF_8))
    }
}

@Serializable
data class ServerInfo(
    val name: String? = null,
    val version: String? = null,
    @SerialName("made_at") val madeAt: String? = null,
    val counter: Long? = null,
    @SerialName("left_out") val leftOut: List<String>? = null,
)

@Serializable
data class Inbox(
    @SerialName("needs_you") val needsYou: List<Issue>? = null,
    val soon: List<Issue>? = null,
    val snoozed: List<Issue>? = null,
    @SerialName("not_watched") val notWatched: List<NotWatched>? = null,
    @SerialName("other_environments") val otherEnvironments: List<OtherEnvironment>? = null,
    val fine: Fine? = null,
)

@Serializable
data class Fine(val services: Int? = null, val machines: Int? = null)

@Serializable
data class OtherEnvironment(val environment: String? = null, val issues: List<Issue>? = null)

@Serializable
data class NotWatched(
    val id: String? = null,
    val machine: String? = null,
    val name: String? = null,
    val kind: String? = null,
    val detail: Detail? = null,
) {
    @Serializable
    data class Detail(val label: String? = null, val saw: String? = null)
}

@Serializable
data class AlertInfo(val status: String? = null, val channel: String? = null, val until: String? = null)

@Serializable
data class IssueEvent(
    val at: String? = null,
    val event: String? = null,
    val until: String? = null,
    val note: String? = null,
    val by: String? = null,
)

@Serializable
data class Issue(
    val id: String = "",
    @SerialName("short_id") val shortId: String? = null,
    val title: String? = null,
    val service: String? = null,
    val machine: String? = null,
    val state: String? = null,
    val kind: String? = null,
    val since: String? = null,
    val count: Int? = null,
    val note: String? = null,
    val soon: Boolean? = null,
    @SerialName("snoozed_until") val snoozedUntil: String? = null,
    @SerialName("acknowledged_at") val acknowledgedAt: String? = null,
    @SerialName("closed_at") val closedAt: String? = null,
    val alert: AlertInfo? = null,
    val history: List<IssueEvent>? = null,
)

@Serializable
data class Check(
    val name: String? = null,
    val type: String? = null,
    val state: String? = null,
    val note: String? = null,
    @SerialName("checked_at") val checkedAt: String? = null,
)

@Serializable
data class Chart(val metric: String? = null, val values: List<Double?>? = null)

@Serializable
data class Service(
    val id: String = "",
    val machine: String? = null,
    val name: String? = null,
    val kind: String? = null,
    val state: String? = null,
    val version: String? = null,
    val environment: String? = null,
    val note: String? = null,
    val checks: List<Check>? = null,
    @SerialName("open_issue") val openIssue: Issue? = null,
    val chart: Chart? = null,
)

@Serializable
data class Window(val until: String? = null, val reason: String? = null)

@Serializable
data class Schedule(
    val id: String? = null,
    val reason: String? = null,
    val time: String? = null,
    val next: String? = null,
    val at: String? = null,
    val days: List<Int>? = null,
    @SerialName("repeat") val repeats: String? = null,
    @SerialName("for_seconds") val forSeconds: Int? = null,
)

@Serializable
data class Machine(
    val id: String = "",
    val name: String? = null,
    val os: String? = null,
    val kind: String? = null,
    val down: Boolean? = null,
    @SerialName("last_seen_at") val lastSeenAt: String? = null,
    val vitals: Map<String, JsonElement>? = null,
    @SerialName("planned_downtime") val plannedDowntime: Window? = null,
    val schedules: List<Schedule>? = null,
    val services: List<Service>? = null,
    @SerialName("needs_a_look") val needsALook: Int? = null,
    @SerialName("last_day") val lastDay: List<String>? = null,
)

@Serializable
data class JobRun(
    val run: String? = null,
    val result: String? = null,
    @SerialName("started_at") val startedAt: String? = null,
    @SerialName("finished_at") val finishedAt: String? = null,
    @SerialName("duration_ms") val durationMs: Long? = null,
    @SerialName("exit_code") val exitCode: Int? = null,
    val done: Double? = null,
    val total: Double? = null,
)

@Serializable
data class Job(
    val id: String = "",
    val machine: String? = null,
    val name: String? = null,
    val state: String? = null,
    val schedule: String? = null,
    @SerialName("next_expected") val nextExpected: String? = null,
    @SerialName("last_good_run") val lastGoodRun: String? = null,
    @SerialName("last_run") val lastRun: JobRun? = null,
)

@Serializable
data class LogLine(val msg: String? = null, val level: String? = null, val t: String? = null)
