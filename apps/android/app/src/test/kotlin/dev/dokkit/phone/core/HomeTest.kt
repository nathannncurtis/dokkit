package dev.dokkit.phone.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class HomeTest {
    private val now = Fixtures.now

    private fun svc(id: String, name: String, state: String, env: String = "production") =
        """{"id":"$id","name":"$name","state":"$state","environment":"$env"}"""

    private fun machine(id: String, name: String, kind: String, services: List<String>, extra: String = "") =
        """{"id":"$id","name":"$name","kind":"$kind","services":[${services.joinToString(",")}]$extra}"""

    private fun build(machines: List<String>, inbox: String = "{}") =
        Home.build(Snapshot.decode("""{"inbox":$inbox,"machines":[${machines.joinToString(",")}]}""".toByteArray()), now)

    @Test
    fun fixtureHasIssuesInTheTopBoxAndSnoozedLine() {
        val h = Home.build(Fixtures.snapshot, now)
        val top = h.top as TopBox.Attention
        val box = Fixtures.snapshot.inbox
        assertEquals("3 need you", top.title)
        assertTrue(top.urgent)
        assertEquals((box?.needsYou?.size ?: 0) + (box?.soon?.size ?: 0), top.issues.size)
        assertTrue(top.issues.all { it.title.isNotEmpty() && it.detail.isNotEmpty() && it.serviceId != null })
        assertEquals(Fixtures.snapshot.inbox?.snoozed?.size?.let { "$it snoozed" }, h.snoozed)
        assertEquals(6, h.hardware.size + h.groups.size)
    }

    @Test
    fun fineSaysHowManyMachinesAreUpAndThingsRunning() {
        val h = build(
            listOf(
                machine("a", "a", "enrolled", listOf(svc("1", "x", "ok"), svc("2", "y", "ok"))),
                machine("b", "b", "enrolled", listOf(svc("3", "z", "ok")), ""","down":true"""),
                machine("g", "apps", "group", listOf(svc("4", "w", "unknown"))),
            ),
        )
        assertEquals(TopBox.Fine("Everything is fine", "1 of 2 machines up · 3 things running"), h.top)
        assertNull(h.snoozed)
    }

    @Test
    fun metersUseTheFullestDiskAndWarnAbove85() {
        val vitals = ""","vitals":{"cpu.percent":90,"memory.used_percent":85,"disk.used_percent.C:":40,"disk.used_percent.D:":86.4},"last_seen_at":"2026-10-13T23:58:00Z""""
        val card = build(listOf(machine("a", "a", "enrolled", emptyList(), vitals))).hardware.single()
        assertEquals(
            listOf(Triple("CPU", 90, true), Triple("Memory", 85, false), Triple("Disk D:", 86, true)),
            card.meters.map { Triple(it.label + (it.subject?.let { s -> " $s" } ?: ""), it.percent, it.isHot) },
        )
        assertEquals("Up · 2 min ago", card.status)
        assertTrue(card.spoken.contains("CPU 90 percent, high"))
        assertTrue(card.spoken.contains("Disk D: 86 percent, high"))
        assertTrue(card.spoken.endsWith("nothing watched."))
    }

    @Test
    fun noVitalsMeansNoMeters() {
        val card = build(listOf(machine("a", "a", "enrolled", emptyList()))).hardware.single()
        assertTrue(card.meters.isEmpty())
        assertEquals("nothing watched", card.counts)
    }

    @Test
    fun downFirstThenTroubleThenName() {
        val h = build(
            listOf(
                machine("1", "zeta", "enrolled", listOf(svc("a", "s", "ok"))),
                machine("2", "alpha", "enrolled", listOf(svc("b", "s", "ok"))),
                machine("3", "mid", "enrolled", listOf(svc("c", "s", "degraded"))),
                machine("4", "omega", "enrolled", emptyList(), ""","down":true"""),
                machine("5", "bgroup", "group", listOf(svc("d", "s", "ok"))),
                machine("6", "agroup", "group", listOf(svc("e", "s", "down"))),
            ),
        )
        assertEquals(listOf("omega", "mid", "alpha", "zeta"), h.hardware.map { it.name })
        assertEquals(listOf("agroup", "bgroup"), h.groups.map { it.name })
        assertEquals("Down", h.hardware.first().status)
        assertNull(h.groups.first().status)
        assertTrue(h.groups.all { it.meters.isEmpty() })
    }

    @Test
    fun eightFineThenTheRestAndTroubleFirst() {
        val services = (1..11).map { svc("o$it", "ok%02d".format(it), "ok") } + svc("t", "broken", "down") + svc("d", "slow", "degraded")
        val card = build(listOf(machine("a", "a", "enrolled", services))).hardware.single()
        assertEquals(listOf("Down", "Degraded"), card.trouble.map { it.level.word })
        assertEquals(8, card.fine.size)
        assertEquals(3, card.moreFine.size)
        assertEquals("11 fine · 2 in trouble", card.counts)
        assertTrue(card.inTrouble)
    }

    @Test
    fun hidesUnwatchedAndOtherEnvironmentsAndNamesNoSignal() {
        val services = listOf(
            svc("1", "fine", "ok"),
            svc("2", "hidden", "unwatched"),
            svc("3", "staging thing", "ok", "staging"),
            svc("4", "d", "unknown"),
            svc("5", "c", "unknown"),
            svc("6", "b", "unknown"),
            svc("7", "a", "unknown"),
        )
        val card = build(listOf(machine("a", "a", "enrolled", services))).hardware.single()
        assertEquals("1 fine · 4 no signal", card.counts)
        assertEquals("4 with no signal yet: a, b, c…", card.quietLine)
        assertFalse(card.fine.any { it.name == "hidden" || it.name == "staging thing" })
    }

    @Test
    fun plannedDowntimeIsOneLine() {
        val card = build(listOf(machine("a", "a", "enrolled", emptyList(), ""","planned_downtime":{"until":"2026-10-14T05:00:00Z"}"""))).hardware.single()
        assertTrue(card.notice!!.startsWith("Planned downtime until "))
        assertTrue(card.spoken.contains("Planned downtime until "))
    }

    @Test
    fun soonOnlyIsWarningAndLinesFollowIos() {
        val inbox = """{"soon":[{"id":"i","title":"Disk filling","service":"s1","machine":"m1","since":"2026-10-13T20:00:00Z","alert":{"status":"held"}}]}"""
        val machines = """[{"id":"m","name":"m1","kind":"enrolled","services":[{"id":"s1","name":"Portal","state":"ok"}]}]"""
        val h = Home.build(Snapshot.decode("""{"inbox":$inbox,"machines":$machines}""".toByteArray()), now)
        val top = h.top as TopBox.Attention
        assertEquals("1 coming up soon", top.title)
        assertFalse(top.urgent)
        assertEquals("Portal · m1 · open 4 h · alert held for the night", top.issues.single().detail)
    }

    @Test
    fun downSaysLastReportedAndScheduledWindowShowsOnTheClosedCard() {
        val extra = ""","down":true,"last_seen_at":"2026-10-13T21:00:00Z","schedules":[{"next":"2026-10-20T05:00:00Z"}]"""
        val card = build(listOf(machine("a", "a", "enrolled", emptyList(), extra))).hardware.single()
        assertEquals("Down · last reported 3 h ago", card.status)
        assertTrue(card.notice!!.startsWith("Planned downtime scheduled, next "))
    }

    @Test
    fun noHardwareSaysOnlyThingsRunning() {
        val h = build(listOf(machine("g", "apps", "group", listOf(svc("1", "x", "ok")))))
        assertEquals(TopBox.Fine("Everything is fine", "1 thing running"), h.top)
    }
}
