package dev.dokkit.phone.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class WordsTest {
    private val now = Fixtures.now

    private fun issue(extra: String) = Snapshot.decode(
        """{"issues":[{"id":"i","short_id":"DOK-1","title":"T","service":"s","machine":"db-01","since":"${now.minusSeconds(7200)}"$extra}]}""".toByteArray(),
    ).issues!!.first()

    private val names = mapOf("s" to "nightly-purge")

    @Test
    fun saysWhatIsWrongInOneSentence() {
        assertEquals("Something is wrong with nightly-purge on db-01 since 2 h ago.", Words.sentence(issue(""","state":"down""""), names, now))
        assertEquals("Working, but not as it should: nightly-purge on db-01, since 2 h ago.", Words.sentence(issue(""","state":"degraded""""), names, now))
        assertEquals("Nothing is broken. Plan for it when it suits you.", Words.sentence(issue(""","state":"degraded","soon":true"""), names, now))
        assertTrue(Words.sentence(issue(""","state":"degraded","snoozed_until":"${now.plusSeconds(3600)}""""), names, now).startsWith("Snoozed until "))
    }

    @Test
    fun theNextStepOpensSomethingOnThePhone() {
        assertEquals("See the last run", Words.nextStep(issue(""","kind":"job"""")))
        assertEquals("Look at the disk", Words.nextStep(issue(""","kind":"threshold"""")))
        assertEquals("See the certificate", Words.nextStep(issue(""","kind":"expiry"""")))
        assertEquals("Look into it", Words.nextStep(issue(""","kind":"http"""")))
    }

    @Test
    fun toneAndFlagsFollowTheIssue() {
        assertEquals(Tone.Down, Words.tone(issue(""","state":"down""""), now))
        assertEquals(Tone.Soon, Words.tone(issue(""","state":"degraded","soon":true"""), now))
        val flags = Words.flags(issue(""","state":"degraded","acknowledged_at":"$now","alert":{"status":"held"}"""), now).map { it.text }
        assertEquals(listOf("Seen", "Alert held for the night"), flags)
    }

    @Test
    fun homeLedeIsTrueToTheCounts() {
        val h = Home.build(Fixtures.snapshot, now)
        val needs = Fixtures.snapshot.inbox?.needsYou?.size ?: 0
        assertEquals(needs, h.needs.size)
        assertTrue(h.lede.isNotEmpty())
        assertTrue(h.needs.all { it.sentence.isNotEmpty() && it.nextStep.isNotEmpty() })
    }
}
