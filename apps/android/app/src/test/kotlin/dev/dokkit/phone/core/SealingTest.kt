package dev.dokkit.phone.core

import java.util.Base64
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.serialization.json.Json

class SealingTest {
    private val f = Fixtures.sealing

    @Test
    fun opensEveryPhonesAnswer() {
        for (p in f.phones) {
            assertEquals(f.snapshotJson, Sealing.open(p.slotAnswer, p.pairing).toString(Charsets.UTF_8), p.name)
        }
    }

    @Test
    fun parsesEveryPairingCode() {
        for (p in f.phones) assertEquals(p.pairing, Pairing.parse(p.pairingCode))
        assertEquals(f.phones[0].pairing, Pairing.parse("  ${f.phones[0].pairingCode}\n"))
    }

    private fun code(edit: (Pairing) -> Pairing): String {
        val json = Json.encodeToString(edit(f.phones[0].pairing))
        return "dokkit-phone:1:" + Base64.getUrlEncoder().withoutPadding().encodeToString(json.toByteArray())
    }

    @Test
    fun refusesBadPairingCodes() {
        val good = f.phones[0].pairingCode
        assertFailsWith<PairingError.NotACode> { Pairing.parse("https://example.com") }
        assertFailsWith<PairingError.NewerVersion> { Pairing.parse(good.replace(":1:", ":2:")) }
        assertFailsWith<PairingError.Damaged> { Pairing.parse(good + "!!") }
        assertFailsWith<PairingError.RelayNotHttps> { Pairing.parse(code { it.copy(relay = "http://relay.example.com") }) }
        assertFailsWith<PairingError.BadToken> { Pairing.parse(code { it.copy(token = it.token.dropLast(1) + "0") }) }
        assertFailsWith<PairingError.BadKey> { Pairing.parse(code { it.copy(key = "AAAA") }) }
        assertFailsWith<PairingError.Damaged> { Pairing.parse(code { it.copy(slot = "xyz") }) }
    }

    @Test
    fun checksum() {
        assertTrue(KeyCheck.isValid(f.uploadKey, "dkr_"))
        for (p in f.phones) assertTrue(KeyCheck.isValid(p.token, "dkf_"))
        assertFalse(KeyCheck.isValid(f.uploadKey, "dkf_"))
        for (key in listOf(f.uploadKey, f.phones[0].token)) {
            val prefix = key.take(4)
            val lastChanged = key.dropLast(1) + if (key.last() == '0') '1' else '0'
            assertFalse(KeyCheck.isValid(lastChanged, prefix))
            val bodyChanged = key.substring(0, 6) + (if (key[6] == 'a') 'b' else 'a') + key.substring(7)
            assertFalse(KeyCheck.isValid(bodyChanged, prefix))
        }
        assertFalse(KeyCheck.isValid("dkf_short", "dkf_"))
    }

    @Test
    fun wrongCounterInAdditionalDataFails() {
        val p = f.phones[0]
        assertFailsWith<SealError.NotOpened> { Sealing.open(p.slotAnswer.copy(counter = p.slotAnswer.counter + 1), p.pairing) }
    }

    @Test
    fun wrongSlotFails() {
        val p = f.phones[0]
        assertFailsWith<SealError.NotOpened> { Sealing.open(p.slotAnswer, p.pairing.copy(slot = f.phones[1].slot)) }
    }

    @Test
    fun anotherPhonesKeyFails() {
        val p = f.phones[0]
        assertFailsWith<SealError.NotOpened> { Sealing.open(p.slotAnswer, p.pairing.copy(key = f.phones[1].pairing.key)) }
    }

    private fun flipped(s: String, at: Int): String {
        val d = Base64.getDecoder().decode(s)
        d[at] = (d[at].toInt() xor 1).toByte()
        return Base64.getEncoder().encodeToString(d)
    }

    @Test
    fun anyChangedByteFails() {
        val p = f.phones[0]
        val a = p.slotAnswer
        val fields = listOf(a.slotNonce, a.key, a.nonce, a.body)
        for ((field, value) in fields.withIndex()) {
            val size = Base64.getDecoder().decode(value).size
            for (i in setOf(0, size / 2, size - 1)) {
                val bad = flipped(value, i)
                val b = when (field) {
                    0 -> a.copy(slotNonce = bad)
                    1 -> a.copy(key = bad)
                    2 -> a.copy(nonce = bad)
                    else -> a.copy(body = bad)
                }
                assertFailsWith<SealError.NotOpened>("field $field byte $i") { Sealing.open(b, p.pairing) }
            }
        }
    }

    @Test
    fun counterRule() {
        val p = f.phones[0]
        assertFailsWith<SealError.Older> { Sealing.open(p.slotAnswer, p.pairing, f.counter + 1) }
        assertTrue(Sealing.open(p.slotAnswer, p.pairing, f.counter).isNotEmpty())
        assertTrue(Sealing.open(p.slotAnswer, p.pairing, f.counter - 1).isNotEmpty())
        assertTrue(Sealing.open(p.slotAnswer, p.pairing, null).isNotEmpty())
    }

    @Test
    fun gzipRejectsGarbage() {
        assertNull(Gzip.inflate(ByteArray(40) { 7 }))
        assertNull(Gzip.inflate(ByteArray(0)))
    }
}
