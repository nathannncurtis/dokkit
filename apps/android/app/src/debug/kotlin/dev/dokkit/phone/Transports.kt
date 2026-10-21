package dev.dokkit.phone

import android.content.Context
import dev.dokkit.phone.core.HttpResponse
import dev.dokkit.phone.core.HttpsTransport
import dev.dokkit.phone.core.Transport
import java.io.ByteArrayOutputStream
import java.security.SecureRandom
import java.time.Instant
import java.time.OffsetDateTime
import java.util.Base64
import java.util.zip.GZIPOutputStream
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

// Debug builds only: a made-up relay at demo.dokkit.invalid that seals the demo snapshot the way a server does,
// so the app can be looked at on an emulator without a Dokkit server. "northwind" has trouble; "harbor-lab" is the same
// estate with everything fine.
fun appTransport(context: Context, timeoutMs: () -> Int): Transport {
    val real = HttpsTransport(timeoutMs)
    return Transport { url, headers -> if (url.startsWith(DemoRelay.RELAY)) DemoRelay.answer(context, url) else real.get(url, headers) }
}

object DemoRelay {
    const val RELAY = "https://demo.dokkit.invalid"
    // Paste one of these into Add a server to pair a demo server.
    @Suppress("unused")
    const val NORTHWIND_CODE = "dokkit-phone:1:eyJyZWxheSI6Imh0dHBzOi8vZGVtby5kb2traXQuaW52YWxpZCIsIm1haWxib3giOiJjOWZkOWJkMGFlN2UyZjBlMWQzOTZmMWUxMzNkNGVkOCIsInNsb3QiOiIwMWVjNmFiNDAxZGU4OWFjOWQ5ZWUzZWQzNmQ3YzdlNiIsInRva2VuIjoiZGtmX3NKZ2pmVFVER3ZsNUREZGpLRjBXM09xMGV1b3I1STF1YlNPNiIsImtleSI6IjVpREZ3U1VGUDNrQTBHS2pXQ3JBZnRvOVZ3Z3draU43NkJQS08vejMyZVE9IiwibmFtZSI6Im5vcnRod2luZCJ9"
    @Suppress("unused")
    const val HARBOR_LAB_CODE = "dokkit-phone:1:eyJyZWxheSI6Imh0dHBzOi8vZGVtby5kb2traXQuaW52YWxpZCIsIm1haWxib3giOiIzOWU2ZjUwY2M3MjE4Yjc0ZmM3ZTY1ODkxZDM2OGM3MSIsInNsb3QiOiI3NDIzODE2YzZjNzA1ZWRhYmIwMWY2NDMzMGVhODIzZCIsInRva2VuIjoiZGtmX0VTWUx5cVlYYXNFU1F4Mk54aWJOZG9tMUlGVm9odDNSNDNrQSIsImtleSI6Inc5ZnQ2Q3RZaG01Tnp1Z0xlNXFEeDNwNDdPNk5ZcW0rVXRHM2FJL1l6MTQ9IiwibmFtZSI6ImhhcmJvci1sYWIifQ=="

    private class Demo(val mailbox: String, val slot: String, val key: String, val asset: String)

    private val demos = listOf(
        Demo("c9fd9bd0ae7e2f0e1d396f1e133d4ed8", "01ec6ab401de89ac9d9ee3ed36d7c7e6", "5iDFwSUFP3kA0GKjWCrAfto9VwgwkiN76BPKO/z32eQ=", "demo-snapshot.json"),
        Demo("39e6f50cc7218b74fc7e65891d368c71", "7423816c6c705edabb01f64330ea823d", "w9ft6CtYhm5NzugLe5qDx3p47O6NYqm+UtG3aI/Yz14=", "demo-fine.json"),
    )

    private val random = SecureRandom()

    fun answer(context: Context, url: String): HttpResponse {
        val demo = demos.firstOrNull { url.contains("/m/${it.mailbox}/") } ?: return HttpResponse(404, emptyMap(), ByteArray(0))
        val now = Instant.now()
        val raw = context.assets.open(demo.asset).use { it.readBytes() }.toString(Charsets.UTF_8)
        val doc = Json.parseToJsonElement(raw).jsonObjectOrEmpty()
        val shift = (doc["generated_at"] as? JsonPrimitive)?.content?.let { java.time.Duration.between(OffsetDateTime.parse(it).toInstant(), now) } ?: java.time.Duration.ZERO
        val moved = shiftDates(doc, shift) as JsonObject
        val counter = now.epochSecond
        val server = (moved["server"] as? JsonObject ?: JsonObject(emptyMap())).let {
            JsonObject(it + mapOf("made_at" to JsonPrimitive(now.minusSeconds(40).toString()), "counter" to JsonPrimitive(counter)))
        }
        val body = JsonObject(moved + ("server" to server)).toString().toByteArray()

        val contentKey = ByteArray(32).also(random::nextBytes)
        val slotNonce = ByteArray(12).also(random::nextBytes)
        val bodyNonce = ByteArray(12).also(random::nextBytes)
        val wrapped = seal(Base64.getDecoder().decode(demo.key), slotNonce, contentKey, "dokkit-phone-v1|${demo.mailbox}|${demo.slot}|$counter")
        val sealed = seal(contentKey, bodyNonce, gzip(body), "dokkit-phone-v1|${demo.mailbox}|body|$counter")
        val b64 = Base64.getEncoder()
        val answer = buildJsonObject {
            put("schema", 1)
            put("counter", counter)
            put("made_at", now.minusSeconds(40).toString())
            put("slot_nonce", b64.encodeToString(slotNonce))
            put("key", b64.encodeToString(wrapped))
            put("nonce", b64.encodeToString(bodyNonce))
            put("body", b64.encodeToString(sealed))
        }
        return HttpResponse(200, emptyMap(), answer.toString().toByteArray())
    }

    private fun JsonElement.jsonObjectOrEmpty() = this as? JsonObject ?: JsonObject(emptyMap())

    private val iso = Regex("""^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$""")

    private fun shiftDates(e: JsonElement, by: java.time.Duration): JsonElement = when (e) {
        is JsonObject -> JsonObject(e.mapValues { shiftDates(it.value, by) })
        is JsonArray -> JsonArray(e.map { shiftDates(it, by) })
        is JsonPrimitive -> if (e.isString && iso.matches(e.content)) JsonPrimitive(OffsetDateTime.parse(e.content).toInstant().plus(by).toString()) else e
    }

    private fun seal(key: ByteArray, nonce: ByteArray, plain: ByteArray, aad: String): ByteArray {
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce))
        c.updateAAD(aad.toByteArray())
        return c.doFinal(plain)
    }

    private fun gzip(b: ByteArray): ByteArray = ByteArrayOutputStream().also { out -> GZIPOutputStream(out).use { it.write(b) } }.toByteArray()
}
