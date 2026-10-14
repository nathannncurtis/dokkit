package dev.dokkit.phone.core

import java.time.Instant
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject

@Serializable
data class Phone(
    val name: String,
    val slot: String,
    val token: String,
    @SerialName("phone_key") val phoneKey: String,
    val pairing: Pairing,
    @SerialName("pairing_code") val pairingCode: String,
    @SerialName("slot_answer") val slotAnswer: SlotAnswer,
)

@Serializable
data class SealingFixture(
    @SerialName("upload_key") val uploadKey: String,
    val mailbox: String,
    val counter: Long,
    @SerialName("snapshot_json") val snapshotJson: String,
    val phones: List<Phone>,
)

object Fixtures {
    private fun text(name: String): String =
        Fixtures::class.java.getResourceAsStream("/fixtures/$name.json")!!.use { it.readBytes().toString(Charsets.UTF_8) }

    private val json = Json { ignoreUnknownKeys = true }

    val sealing: SealingFixture = json.decodeFromString(text("sealing"))
    val snapshotText: String = text("snapshot")
    val snapshot: Snapshot = Snapshot.decode(snapshotText.toByteArray())
    val raw: JsonObject = json.parseToJsonElement(snapshotText).jsonObject
    val now: Instant = Instant.parse("2026-10-14T00:00:00Z")
}
