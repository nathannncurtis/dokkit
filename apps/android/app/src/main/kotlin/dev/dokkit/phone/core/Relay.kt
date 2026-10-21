package dev.dokkit.phone.core

import java.io.IOException
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL
import kotlinx.serialization.json.Json

class HttpResponse(val status: Int, val headers: Map<String, String>, val body: ByteArray) {
    fun header(name: String): String? = headers.entries.firstOrNull { it.key.equals(name, ignoreCase = true) }?.value
}

fun interface Transport {
    @Throws(IOException::class)
    fun get(url: String, headers: Map<String, String>): HttpResponse
}

class HttpsTransport(private val timeoutMs: () -> Int = { 15_000 }) : Transport {
    override fun get(url: String, headers: Map<String, String>): HttpResponse {
        val c = URL(url).openConnection() as HttpURLConnection
        try {
            c.connectTimeout = timeoutMs()
            c.readTimeout = timeoutMs()
            c.instanceFollowRedirects = false
            c.useCaches = false
            headers.forEach { (k, v) -> c.setRequestProperty(k, v) }
            val status = c.responseCode
            val stream = if (status >= 400) c.errorStream else c.inputStream
            val body = stream?.use { readLimited(it, MAX_BODY) } ?: ByteArray(0)
            val seen = c.headerFields.entries.filter { it.key != null && it.value.isNotEmpty() }
                .associate { it.key to it.value.first() }
            return HttpResponse(status, seen, body)
        } finally {
            c.disconnect()
        }
    }

    private fun readLimited(input: java.io.InputStream, limit: Int): ByteArray {
        val out = java.io.ByteArrayOutputStream()
        val buf = ByteArray(8192)
        while (true) {
            val n = input.read(buf)
            if (n < 0) break
            if (out.size() + n > limit) throw IOException("the answer is larger than $limit bytes")
            out.write(buf, 0, n)
        }
        return out.toByteArray()
    }

    private companion object {
        const val MAX_BODY = 8 shl 20
    }
}

sealed interface FetchResult {
    data class Fresh(val answer: SlotAnswer, val etag: String?) : FetchResult
    data object NotModified : FetchResult
}

class RelayClient(private val transport: Transport = HttpsTransport()) {
    private val json = Json { ignoreUnknownKeys = true }

    fun fetch(p: Pairing, etag: String?): FetchResult {
        val url = "${p.relay.trimEnd('/')}/m/${p.mailbox}/${p.slot}"
        val scheme = try {
            URI(url).scheme?.lowercase()
        } catch (e: java.net.URISyntaxException) {
            null
        }
        if (scheme != "https") throw RelayError.NotHttps
        val headers = buildMap {
            put("Authorization", "Bearer ${p.token}")
            put("Accept", "application/json")
            if (etag != null) put("If-None-Match", etag)
        }
        val r = try {
            transport.get(url, headers)
        } catch (e: IOException) {
            throw RelayError.Network(e.message ?: e.javaClass.simpleName)
        }
        return when (r.status) {
            200 -> {
                val answer = try {
                    json.decodeFromString<SlotAnswer>(r.body.toString(Charsets.UTF_8))
                } catch (e: IllegalArgumentException) {
                    throw RelayError.BadAnswer
                }
                FetchResult.Fresh(answer, r.header("ETag"))
            }
            304 -> FetchResult.NotModified
            404 -> throw RelayError.NotFound
            429 -> throw RelayError.RateLimited(r.header("Retry-After")?.trim()?.toIntOrNull())
            else -> throw RelayError.Status(r.status)
        }
    }
}
