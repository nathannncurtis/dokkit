package dev.dokkit.phone.core

import java.time.Instant
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

class SnapshotTest {
    private val s = Fixtures.snapshot
    private val raw = Fixtures.raw
    private val now = Fixtures.now

    private fun JsonObject.list(key: String): JsonArray = getValue(key).jsonArray
    private fun JsonObject.text(key: String): String? = this[key]?.takeIf { it !is kotlinx.serialization.json.JsonNull }?.jsonPrimitive?.content
    private fun JsonObject.count(key: String): Int? = (this[key] as? JsonArray)?.size
    private fun decode(json: String) = Snapshot.decode(json.toByteArray())

    @Test
    fun decodesWithoutLoss() {
        assertEquals("northwind.example.com", s.server?.name)
        assertEquals(1791937925L, s.server?.counter)
        assertEquals(Instant.parse("2026-10-14T00:32:05Z"), parseDate(s.server?.madeAt))

        val rawServices = raw.list("services")
        val services = assertNotNull(s.services)
        assertEquals(rawServices.size, services.size)
        for ((a, b) in services.zip(rawServices.map { it.jsonObject })) {
            assertEquals(b.text("id"), a.id)
            assertEquals(b.text("name"), a.name)
            assertEquals(b.text("state"), a.state)
            assertEquals(b.text("kind"), a.kind)
            assertEquals(b.text("version"), a.version)
            assertEquals(b.count("checks"), a.checks?.size)
        }

        val rawMachines = raw.list("machines")
        assertEquals(rawMachines.size, s.machines?.size)
        for ((a, b) in s.machines!!.zip(rawMachines.map { it.jsonObject })) {
            assertEquals(b.text("name"), a.name)
            assertEquals(b.count("services"), a.services?.size)
            assertEquals(b.count("schedules"), a.schedules?.size)
            assertNotNull(parseDate(a.lastSeenAt))
        }

        val rawIssues = raw.list("issues")
        assertEquals(rawIssues.size, s.issues?.size)
        for ((a, b) in s.issues!!.zip(rawIssues.map { it.jsonObject })) {
            assertEquals(b.text("short_id"), a.shortId)
            assertEquals(b.text("title"), a.title)
            assertNotNull(parseDate(a.since))
            assertEquals(b.count("history"), a.history?.size)
        }

        val box = raw.getValue("inbox").jsonObject
        assertEquals(box.list("needs_you").size, s.inbox?.needsYou?.size)
        assertEquals(box.list("soon").size, s.inbox?.soon?.size)
        assertEquals(box.list("snoozed").size, s.inbox?.snoozed?.size)
        assertEquals(box.list("not_watched").size, s.inbox?.notWatched?.size)
        assertNotNull(parseDate(s.inbox?.snoozed?.first()?.snoozedUntil))
        assertEquals(45, s.inbox?.fine?.services)
        assertEquals(3, s.jobs?.size)
        assertEquals("running", s.jobs?.first()?.lastRun?.result)

        for ((id, lines) in raw.getValue("logs").jsonObject) assertEquals(lines.jsonArray.size, s.logs?.get(id)?.size, id)
    }

    @Test
    fun toleratesUnknownFieldsAndValues() {
        val snap = decode("""{"schema":9,"extra":{"a":1},"services":[{"id":"a","name":"X","state":"sleepy","novel":[1],"chart":{"metric":null,"values":[1,null,2.5]}}]}""")
        assertEquals(Level.Other("sleepy"), Level.of(snap.services?.first()?.state))
        assertEquals("Sleepy", Level.Other("sleepy").word)
        assertEquals(listOf(1.0, null, 2.5), snap.services?.first()?.chart?.values)
        assertNull(snap.inbox)
        assertNull(leftOutText(snap))
        assertEquals("Log lines were left out of this snapshot to keep it small.", leftOutText(decode("""{"server":{"left_out":["logs"]}}""")))
        val empty = decode("{}")
        assertTrue(Screens.needsYou(empty, now).nothingNeedsYou)
        assertTrue(Screens.everything(empty).isEmpty())
    }

    @Test
    fun needsYouScreen() {
        val n = Screens.needsYou(s, now)
        assertEquals(listOf("Needs you", "Soon", "Snoozed"), n.sections.map { it.title })
        assertEquals(3, n.sections[0].rows.size)
        assertTrue(n.sections[0].rows.all { it.shortId.isNotEmpty() && it.serviceName != null })
        assertTrue(n.sections[2].rows[0].flags.first().startsWith("Snoozed until"))
        assertEquals(4, n.notWatched.size)
        assertEquals("defrag", n.notWatched.first().name)
        assertEquals("45 services and 6 machines fine", n.fine)
        assertFalse(n.nothingNeedsYou)
    }

    @Test
    fun everythingScreen() {
        val rows = Screens.everything(s)
        assertEquals(6, rows.size)
        assertEquals(rows.map { it.level.rank }.sortedDescending(), rows.map { it.level.rank })
        val db = rows.first { it.name == "db-01" }
        assertEquals(Level.Down, db.level)
        assertEquals(Level.Down, db.services.first().level)
    }

    @Test
    fun serviceScreen() {
        val v = assertNotNull(Screens.service(s, "4bfc9563-d352-4ef6-8486-f8ffc817aeb6", now))
        assertEquals("Upload portal", v.name)
        assertEquals("2.4.1", v.version)
        assertEquals(2, v.checks.size)
        assertNotNull(v.issue)
        assertEquals("Opened", v.history.first().text)
        assertEquals(20, v.logs.size)
        assertTrue(v.logs.any { it.isError })
        assertNull(Screens.service(s, "nope", now))
        assertEquals(Level.Down, Screens.service(s, "7012ff32-1231-4688-bcbf-309564fc2ee2", now)?.level)
        assertFalse(Screens.service(s, "0ae2b839-1e1a-4c8a-8170-524922bd9207", now)!!.job.isEmpty())
    }

    @Test
    fun chartDrawsFromValues() {
        val snap = decode("""{"machines":[{"id":"m","name":"m","services":[{"id":"s","name":"S","state":"ok"}]}],"services":[{"id":"s","name":"S","state":"ok","chart":{"metric":"latency","values":[1,null,3]}}]}""")
        assertEquals(listOf(1.0, null, 3.0), Screens.everything(snap)[0].services[0].chart)
        assertEquals(listOf(1.0, null, 3.0), Screens.service(snap, "s", now)?.chart)
        assertEquals("latency", snap.services?.first()?.chart?.metric)
    }

    @Test
    fun realChartsDecode() {
        for ((a, b) in (s.services ?: emptyList()).zip(raw.list("services").map { it.jsonObject })) {
            val n = (b["chart"] as? JsonObject)?.get("values")?.jsonArray?.size
            assertEquals(n, a.chart?.values?.size, a.name)
        }
    }

    @Test
    fun vitalsAreShown() {
        val snap = decode("""{"machines":[{"id":"m","name":"m","vitals":{"cpu.percent":12.4,"memory.used_percent":93,"disk.used_percent.C:":50}}]}""")
        assertEquals(
            listOf(Vital("Processor", 12, false), Vital("Memory", 93, true), Vital("Disk C:", 50, false)),
            Screens.everything(snap)[0].vitals,
        )
    }

    @Test
    fun logLinesAreFormattedLikeIos() {
        assertEquals("12:00:00 AM ERROR boom", LogRow("12:00:00 AM", "error", "boom", true).text)
        assertEquals("t WARNI x", LogRow("t", "warning", "x", false).text)
        assertEquals("t INFO  x", LogRow("t", "info", "x", false).text)
    }

    @Test
    fun ageTextAndWarning() {
        val t = now
        fun at(s: Long) = t.minusSeconds(s)
        assertEquals("just now", Age.ago(at(0), t))
        assertEquals("just now", Age.ago(at(-30), t))
        assertEquals("12 seconds ago", Age.ago(at(12), t))
        assertEquals("1 min ago", Age.ago(at(90), t))
        assertEquals("2 h ago", Age.ago(at(7300), t))
        assertEquals("3 d ago", Age.ago(at(3 * 86400), t))
        assertFalse(Freshness.make(at(300), true, null, t).isWarning)
        val late = Freshness.make(at(301), true, null, t)
        assertTrue(late.isWarning)
        assertTrue(late.detail!!.contains("not delivering"))
        val ok = Freshness.make(at(20), true, "The relay could not be reached.", t)
        assertTrue(!ok.isWarning && ok.detail == "The relay could not be reached.")
        assertEquals("No snapshot yet", Freshness.make(null, false, null, t).text)
        assertEquals("Snapshot age unknown", Freshness.make(null, true, null, t).text)
    }
}
