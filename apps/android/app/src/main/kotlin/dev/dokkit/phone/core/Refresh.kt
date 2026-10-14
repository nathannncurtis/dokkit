package dev.dokkit.phone.core

import java.time.Instant

data class ServerState(
    val snapshot: Snapshot? = null,
    val madeAt: Instant? = null,
    val counter: Long? = null,
    val problem: String? = null,
)

class Refresher(val store: ServerStore, private val client: RelayClient = RelayClient()) {
    fun load(id: String): ServerState = state(runCatching { store.saved(id) }.getOrNull(), null)

    fun refresh(id: String, now: Instant = Instant.now()): ServerState {
        val saved = runCatching { store.saved(id) }.getOrNull()
        var problem: String? = null
        try {
            val p = store.pairing(id) ?: return state(saved, "This server is no longer paired.")
            when (val r = client.fetch(p, saved?.etag)) {
                FetchResult.NotModified -> Unit
                is FetchResult.Fresh -> {
                    val json = Sealing.open(r.answer, p, saved?.counter)
                    val snap = Snapshot.decode(json)
                    val next = SavedSnapshot(
                        counter = r.answer.counter,
                        etag = r.etag,
                        madeAt = r.answer.madeAt ?: snap.server?.madeAt,
                        fetchedAt = now.toString(),
                        json = json.toString(Charsets.UTF_8),
                    )
                    store.save(id, next)
                    return state(next, null)
                }
            }
        } catch (e: kotlinx.serialization.SerializationException) {
            problem = "The snapshot was opened but could not be read. This app may be older than the server."
        } catch (e: Exception) {
            problem = e.message ?: e.toString()
        }
        return state(saved, problem)
    }

    private fun state(s: SavedSnapshot?, problem: String?): ServerState {
        if (s == null) return ServerState(problem = problem)
        val snap = runCatching { Snapshot.decode(s.json.toByteArray()) }.getOrNull() ?: return ServerState(problem = problem)
        return ServerState(snap, parseDate(s.madeAt), s.counter, problem)
    }
}
