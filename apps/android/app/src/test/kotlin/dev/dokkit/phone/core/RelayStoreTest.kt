package dev.dokkit.phone.core

import java.io.IOException
import java.time.Instant
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.serialization.json.Json

class FakeTransport(private val reply: (String, Map<String, String>) -> HttpResponse) : Transport {
    val seen = mutableListOf<Pair<String, Map<String, String>>>()

    override fun get(url: String, headers: Map<String, String>): HttpResponse {
        seen += url to headers
        return reply(url, headers)
    }
}

private fun reply(status: Int, headers: Map<String, String> = emptyMap(), body: String = "") =
    HttpResponse(status, headers, body.toByteArray())

class RelayTest {
    private val phone = Fixtures.sealing.phones[0]
    private val answerJson = Json.encodeToString(SlotAnswer.serializer(), phone.slotAnswer)

    private fun client(t: Transport) = RelayClient(t)

    @Test
    fun fetchesAndSendsBearerAndEtag() {
        val t = FakeTransport { _, _ -> reply(200, mapOf("etag" to "\"184223\""), answerJson) }
        val r = client(t).fetch(phone.pairing, "\"1\"")
        assertEquals(FetchResult.Fresh(phone.slotAnswer, "\"184223\""), r)
        val (url, headers) = t.seen.single()
        assertEquals("https://relay.example.com/m/${phone.pairing.mailbox}/${phone.slot}", url)
        assertEquals("Bearer ${phone.token}", headers["Authorization"])
        assertEquals("\"1\"", headers["If-None-Match"])
    }

    @Test
    fun noEtagMeansNoHeader() {
        val t = FakeTransport { _, _ -> reply(304) }
        client(t).fetch(phone.pairing, null)
        assertNull(t.seen.single().second["If-None-Match"])
    }

    @Test
    fun notModified() {
        assertEquals(FetchResult.NotModified, client(FakeTransport { _, _ -> reply(304) }).fetch(phone.pairing, "x"))
    }

    @Test
    fun notFound() {
        assertFailsWith<RelayError.NotFound> { client(FakeTransport { _, _ -> reply(404) }).fetch(phone.pairing, null) }
    }

    @Test
    fun rateLimited() {
        val e = assertFailsWith<RelayError.RateLimited> {
            client(FakeTransport { _, _ -> reply(429, mapOf("Retry-After" to "17")) }).fetch(phone.pairing, null)
        }
        assertEquals(17, e.retryAfter)
        assertEquals("The relay says this phone is asking too often; try again in 17 seconds.", e.message)
    }

    @Test
    fun otherStatusBadBodyAndNetwork() {
        val e = assertFailsWith<RelayError.Status> { client(FakeTransport { _, _ -> reply(503) }).fetch(phone.pairing, null) }
        assertEquals(503, e.code)
        assertFailsWith<RelayError.BadAnswer> { client(FakeTransport { _, _ -> reply(200, body = "nope") }).fetch(phone.pairing, null) }
        val n = assertFailsWith<RelayError.Network> { client(FakeTransport { _, _ -> throw IOException("timed out") }).fetch(phone.pairing, null) }
        assertEquals("The relay could not be reached (timed out).", n.message)
    }

    @Test
    fun refusesPlainHttp() {
        val t = FakeTransport { _, _ -> reply(200) }
        assertFailsWith<RelayError.NotHttps> { client(t).fetch(phone.pairing.copy(relay = "http://relay.example.com"), null) }
        assertTrue(t.seen.isEmpty())
    }

    @Test
    fun refresherOpensKeepsAndRefusesReplay() {
        val store = ServerStore(MemorySecrets(), MemoryFiles())
        val id = store.add(phone.pairing).id
        val ok = FakeTransport { _, _ -> reply(200, mapOf("ETag" to "\"184223\""), answerJson) }

        val first = Refresher(store, client(ok)).refresh(id, Fixtures.now)
        assertEquals("Northwind", first.snapshot?.server?.name)
        assertNull(first.problem)
        assertEquals(184223L, first.counter)

        val unchanged = FakeTransport { _, _ -> reply(304) }
        val second = Refresher(store, client(unchanged)).refresh(id)
        assertEquals(first.snapshot, second.snapshot)
        assertEquals("\"184223\"", unchanged.seen.first().second["If-None-Match"])

        val down = FakeTransport { _, _ -> reply(503) }
        val third = Refresher(store, client(down)).refresh(id)
        assertEquals(first.snapshot, third.snapshot)
        assertTrue(third.problem!!.contains("503"))

        store.save(id, assertNotNull(store.saved(id)).copy(counter = 999_999, etag = null))
        val replay = Refresher(store, client(ok)).refresh(id)
        assertEquals(SealError.Older.message, replay.problem)
        assertEquals(first.snapshot, replay.snapshot)
    }

    @Test
    fun refresherTreatsBrokenBodyAsNoSnapshot() {
        val bad = phone.slotAnswer.copy(body = java.util.Base64.getEncoder().encodeToString(ByteArray(40) { 1 }))
        val store = ServerStore(MemorySecrets(), MemoryFiles())
        val id = store.add(phone.pairing).id
        val t = FakeTransport { _, _ -> reply(200, body = Json.encodeToString(SlotAnswer.serializer(), bad)) }
        val s = Refresher(store, client(t)).refresh(id)
        assertNull(s.snapshot)
        assertEquals(SealError.NotOpened.message, s.problem)
        assertNull(store.saved(id))
    }

    @Test
    fun refresherSaysWhenNoLongerPaired() {
        val store = ServerStore(MemorySecrets(), MemoryFiles())
        assertEquals("This server is no longer paired.", Refresher(store, client(FakeTransport { _, _ -> reply(200) })).refresh("gone").problem)
    }
}

class StoreTest {
    private val phones = Fixtures.sealing.phones

    @Test
    fun addReplaceRemove() {
        val secrets = MemorySecrets()
        val files = MemoryFiles()
        val store = ServerStore(secrets, files)
        val s = store.add(phones[0].pairing)
        assertEquals(Fixtures.sealing.mailbox, s.id)
        assertEquals(1, store.servers().size)
        assertEquals(phones[0].pairing, store.pairing(s.id))
        assertEquals(listOf("${s.id}.key", "${s.id}.token"), secrets.accounts)
        assertTrue(!files.read("servers.json")!!.toString(Charsets.UTF_8).contains(phones[0].token))

        val saved = SavedSnapshot(counter = 5, fetchedAt = Instant.EPOCH.toString(), json = "{}")
        store.save(s.id, saved)
        store.add(phones[1].pairing)
        assertEquals(1, store.servers().size)
        assertEquals(phones[1].pairing, store.pairing(s.id))
        assertEquals(saved, store.saved(s.id))

        store.remove(s.id)
        assertTrue(store.servers().isEmpty())
        assertNull(store.saved(s.id))
        assertNull(store.pairing(s.id))
        assertTrue(secrets.accounts.isEmpty())
        assertEquals(listOf("servers.json"), files.names)
    }
}
