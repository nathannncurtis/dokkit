package dev.dokkit.phone.core

import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle

enum class Tone { Down, Degraded, Soon, Ok, Quiet, Brand }

data class Flag(val text: String, val tone: Tone)

data class IssueCard(
    val id: String,
    val shortId: String,
    val title: String,
    val sentence: String,
    val tone: Tone,
    val word: String,
    val machine: String,
    val count: Int,
    val flags: List<Flag>,
    val nextStep: String,
    val serviceId: String?,
)

object Words {
    private val clock = DateTimeFormatter.ofLocalizedTime(FormatStyle.SHORT)

    fun tone(level: Level): Tone = when (level) {
        Level.Ok -> Tone.Ok
        Level.Degraded -> Tone.Degraded
        Level.Down -> Tone.Down
        else -> Tone.Quiet
    }

    private fun snoozed(i: Issue, now: Instant) = parseDate(i.snoozedUntil)?.isAfter(now) == true

    fun tone(i: Issue, now: Instant): Tone = when {
        snoozed(i, now) -> Tone.Quiet
        i.soon == true -> Tone.Soon
        else -> tone(Level.of(i.state))
    }

    fun word(i: Issue, now: Instant): String = when {
        snoozed(i, now) -> "Snoozed"
        i.soon == true -> "Coming up"
        else -> Level.of(i.state).word
    }

    fun sentence(i: Issue, names: Map<String, String?>, now: Instant): String {
        val where = (i.service?.let { names[it] } ?: "it") + (i.machine?.takeIf { it.isNotEmpty() }?.let { " on $it" } ?: "")
        val since = parseDate(i.since)?.let { Age.ago(it, now) }
        parseDate(i.snoozedUntil)?.takeIf { it.isAfter(now) }?.let {
            return "Snoozed until ${clock.withZone(ZoneId.systemDefault()).format(it)}. It comes back then if it is still wrong."
        }
        if (i.soon == true) return "Nothing is broken. Plan for it when it suits you."
        return when (Level.of(i.state)) {
            Level.Down -> "Something is wrong with $where" + (since?.let { " since $it." } ?: ".")
            else -> "Working, but not as it should: $where" + (since?.let { ", since $it." } ?: ".")
        }
    }

    // The phone cannot change anything, so the one next step always opens something on the phone.
    fun nextStep(i: Issue): String = when (i.kind) {
        "job" -> "See the last run"
        "threshold", "forecast" -> "Look at the disk"
        "expiry" -> "See the certificate"
        else -> "Look into it"
    }

    fun flags(i: Issue, now: Instant): List<Flag> = buildList {
        parseDate(i.snoozedUntil)?.takeIf { it.isAfter(now) }?.let { add(Flag("Snoozed until ${shortTime(it)}", Tone.Quiet)) }
        if (i.acknowledgedAt != null) add(Flag("Seen", Tone.Ok))
        if (i.alert?.status == "held") add(Flag("Alert held for the night" + (parseDate(i.alert?.until)?.let { " until " + shortTime(it) } ?: ""), Tone.Soon))
    }

    fun card(i: Issue, names: Map<String, String?>, now: Instant) = IssueCard(
        id = i.id,
        shortId = i.shortId ?: "",
        title = i.title ?: "Untitled",
        sentence = sentence(i, names, now),
        tone = tone(i, now),
        word = word(i, now),
        machine = i.machine ?: "",
        count = i.count ?: 1,
        flags = flags(i, now),
        nextStep = nextStep(i),
        serviceId = i.service,
    )

    fun greeting(now: Instant, zone: ZoneId = ZoneId.systemDefault()): String {
        val h = now.atZone(zone).hour
        return if (h < 12) "Good morning" else if (h < 18) "Good afternoon" else "Good evening"
    }

    fun plural(n: Int, one: String, many: String) = "$n ${if (n == 1) one else many}"
}
