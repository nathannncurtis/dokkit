package dev.dokkit.phone.core

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.util.zip.GZIPInputStream
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

@Serializable
data class SlotAnswer(
    val schema: Int? = null,
    val counter: Long,
    @SerialName("made_at") val madeAt: String? = null,
    @SerialName("slot_nonce") val slotNonce: String,
    val key: String,
    val nonce: String,
    val body: String,
)

object Sealing {
    fun open(a: SlotAnswer, p: Pairing, newest: Long? = null): ByteArray {
        if (newest != null && a.counter < newest) throw SealError.Older
        val phoneKey = p.keyBytes()?.takeIf { it.size == 32 } ?: throw SealError.NotOpened
        val slotNonce = B64.decode(a.slotNonce) ?: throw SealError.NotOpened
        val wrapped = B64.decode(a.key) ?: throw SealError.NotOpened
        val bodyNonce = B64.decode(a.nonce) ?: throw SealError.NotOpened
        val body = B64.decode(a.body) ?: throw SealError.NotOpened
        val contentKey = gcm(phoneKey, slotNonce, wrapped, "dokkit-phone-v1|${p.mailbox}|${p.slot}|${a.counter}")
        if (contentKey.size != 32) throw SealError.NotOpened
        val zipped = gcm(contentKey, bodyNonce, body, "dokkit-phone-v1|${p.mailbox}|body|${a.counter}")
        return Gzip.inflate(zipped) ?: throw SealError.NotOpened
    }

    private fun gcm(key: ByteArray, nonce: ByteArray, sealed: ByteArray, aad: String): ByteArray {
        if (sealed.size <= 16) throw SealError.NotOpened
        try {
            val c = Cipher.getInstance("AES/GCM/NoPadding")
            c.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce))
            c.updateAAD(aad.toByteArray(Charsets.UTF_8))
            return c.doFinal(sealed)
        } catch (e: Exception) {
            throw SealError.NotOpened
        }
    }
}

internal object Gzip {
    fun inflate(data: ByteArray, limit: Int = 64 shl 20): ByteArray? {
        try {
            GZIPInputStream(ByteArrayInputStream(data)).use { input ->
                val out = ByteArrayOutputStream()
                val buf = ByteArray(8192)
                while (true) {
                    val n = input.read(buf)
                    if (n < 0) break
                    if (out.size() + n > limit) return null
                    out.write(buf, 0, n)
                }
                return out.toByteArray()
            }
        } catch (e: IOException) {
            return null
        }
    }
}
