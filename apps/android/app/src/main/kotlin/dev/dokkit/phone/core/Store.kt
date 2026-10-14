package dev.dokkit.phone.core

import java.time.Instant
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json

interface SecretStore {
    fun get(account: String): ByteArray?
    fun set(account: String, data: ByteArray)
    fun remove(account: String)
}

interface FileStore {
    fun read(name: String): ByteArray?
    fun write(name: String, data: ByteArray)
    fun remove(name: String)
}

class MemorySecrets : SecretStore {
    private val items = mutableMapOf<String, ByteArray>()
    val accounts: List<String>
        @Synchronized get() = items.keys.sorted()
    @Synchronized override fun get(account: String) = items[account]
    @Synchronized override fun set(account: String, data: ByteArray) { items[account] = data }
    @Synchronized override fun remove(account: String) { items.remove(account) }
}

class MemoryFiles : FileStore {
    private val items = mutableMapOf<String, ByteArray>()
    val names: List<String>
        @Synchronized get() = items.keys.sorted()
    @Synchronized override fun read(name: String) = items[name]
    @Synchronized override fun write(name: String, data: ByteArray) { items[name] = data }
    @Synchronized override fun remove(name: String) { items.remove(name) }
}

@Serializable
data class PairedServer(
    val name: String,
    val relay: String,
    val mailbox: String,
    val slot: String,
    val addedAt: String,
) {
    val id: String get() = mailbox
}

@Serializable
data class SavedSnapshot(
    val counter: Long,
    val etag: String? = null,
    val madeAt: String? = null,
    val fetchedAt: String,
    val json: String,
)

class ServerStore(private val secrets: SecretStore, private val files: FileStore) {
    private val json = Json { ignoreUnknownKeys = true }
    private val listSerializer = ListSerializer(PairedServer.serializer())

    @Synchronized
    fun servers(): List<PairedServer> {
        val d = files.read(LIST) ?: return emptyList()
        return json.decodeFromString(listSerializer, d.toString(Charsets.UTF_8))
    }

    @Synchronized
    fun add(p: Pairing, now: Instant = Instant.now()): PairedServer {
        val server = PairedServer(p.name, p.relay, p.mailbox, p.slot, now.toString())
        secrets.set("${p.mailbox}.key", p.key.toByteArray())
        secrets.set("${p.mailbox}.token", p.token.toByteArray())
        writeList(servers().filter { it.id != server.id } + server)
        return server
    }

    @Synchronized
    fun pairing(id: String): Pairing? {
        val s = servers().firstOrNull { it.id == id } ?: return null
        val key = secrets.get("$id.key") ?: return null
        val token = secrets.get("$id.token") ?: return null
        return Pairing(s.relay, s.mailbox, s.slot, token.toString(Charsets.UTF_8), key.toString(Charsets.UTF_8), s.name)
    }

    @Synchronized
    fun remove(id: String) {
        secrets.remove("$id.key")
        secrets.remove("$id.token")
        files.remove(snapshotFile(id))
        writeList(servers().filter { it.id != id })
    }

    @Synchronized
    fun saved(id: String): SavedSnapshot? {
        val d = files.read(snapshotFile(id)) ?: return null
        return try {
            json.decodeFromString<SavedSnapshot>(d.toString(Charsets.UTF_8))
        } catch (e: IllegalArgumentException) {
            null
        }
    }

    @Synchronized
    fun save(id: String, s: SavedSnapshot) {
        files.write(snapshotFile(id), json.encodeToString(SavedSnapshot.serializer(), s).toByteArray())
    }

    private fun writeList(list: List<PairedServer>) {
        files.write(LIST, json.encodeToString(listSerializer, list).toByteArray())
    }

    private fun snapshotFile(id: String) = "snapshot-$id.json"

    private companion object {
        const val LIST = "servers.json"
    }
}
