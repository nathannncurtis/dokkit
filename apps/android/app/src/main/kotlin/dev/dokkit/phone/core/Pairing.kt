package dev.dokkit.phone.core

import java.net.URI
import java.net.URISyntaxException
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

@Serializable
data class Pairing(
    val relay: String,
    val mailbox: String,
    val slot: String,
    val token: String,
    val key: String,
    val name: String,
) {
    fun keyBytes(): ByteArray? = B64.decode(key)

    companion object {
        private const val PREFIX = "dokkit-phone:"
        private val json = Json { ignoreUnknownKeys = true }

        fun parse(text: String): Pairing {
            val t = text.trim()
            if (!t.startsWith(PREFIX)) throw PairingError.NotACode
            if (!t.startsWith("${PREFIX}1:")) throw PairingError.NewerVersion
            val raw = B64.decodeUrl(t.removePrefix("${PREFIX}1:")) ?: throw PairingError.Damaged
            val p = try {
                json.decodeFromString<Pairing>(raw.toString(Charsets.UTF_8))
            } catch (e: IllegalArgumentException) {
                throw PairingError.Damaged
            }
            if (!isLowerHex32(p.mailbox) || !isLowerHex32(p.slot)) throw PairingError.Damaged
            val uri = try {
                URI(p.relay)
            } catch (e: URISyntaxException) {
                throw PairingError.Damaged
            }
            if (uri.host.isNullOrEmpty()) throw PairingError.Damaged
            if (uri.scheme?.lowercase() != "https") throw PairingError.RelayNotHttps
            if (!KeyCheck.isValid(p.token, "dkf_")) throw PairingError.BadToken
            if (p.keyBytes()?.size != 32) throw PairingError.BadKey
            return p
        }
    }
}
