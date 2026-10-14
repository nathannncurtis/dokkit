package dev.dokkit.phone

import android.app.Application
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import dev.dokkit.phone.core.PairedServer
import dev.dokkit.phone.core.Pairing
import dev.dokkit.phone.core.Refresher
import dev.dokkit.phone.core.ServerState
import dev.dokkit.phone.core.ServerStore
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withContext

class AppViewModel(app: Application) : AndroidViewModel(app) {
    private val refresher: Refresher

    init {
        val box = KeystoreBox()
        val dir = File(app.noBackupFilesDir, "dokkit")
        refresher = Refresher(ServerStore(KeystoreSecrets(EncryptedDir(File(dir, "secrets"), box)), EncryptedDir(File(dir, "files"), box)))
    }

    var servers by mutableStateOf(emptyList<PairedServer>())
        private set
    var states by mutableStateOf(emptyMap<String, ServerState>())
        private set
    var refreshing by mutableStateOf(false)
        private set
    var selectedId by mutableStateOf<String?>(null)
    var unlocked by mutableStateOf(false)
    var lockMessage by mutableStateOf<String?>(null)
    var adding by mutableStateOf(false)
    var loaded by mutableStateOf(false)
        private set
    var pasteOnly by mutableStateOf(false)
    val openMachines = mutableStateMapOf<String, Boolean>()
    val openMore = mutableStateMapOf<String, Boolean>()

    val selected: PairedServer? get() = servers.firstOrNull { it.id == selectedId } ?: servers.firstOrNull()
    val selectedState: ServerState get() = selected?.let { states[it.id] } ?: ServerState()

    suspend fun load() {
        val list = withContext(Dispatchers.IO) { runCatching { refresher.store.servers() }.getOrDefault(emptyList()) }
        servers = list
        loaded = true
        val fresh = withContext(Dispatchers.IO) {
            list.filter { it.id !in states }.associate { it.id to refresher.load(it.id) }
        }
        states = states + fresh
    }

    suspend fun refresh() {
        if (refreshing) return
        refreshing = true
        try {
            val ids = servers.map { it.id }
            val results = coroutineScope {
                ids.map { id -> async(Dispatchers.IO) { id to refresher.refresh(id) } }.awaitAll()
            }
            states = states + results.filter { (id, _) -> servers.any { it.id == id } }
        } finally {
            refreshing = false
        }
    }

    suspend fun add(code: String): String? = try {
        val p = Pairing.parse(code)
        val added = withContext(Dispatchers.IO) { refresher.store.add(p) }
        selectedId = added.id
        load()
        val state = withContext(Dispatchers.IO) { refresher.refresh(added.id) }
        states = states + (added.id to state)
        null
    } catch (e: Exception) {
        e.message ?: e.toString()
    }

    suspend fun remove(id: String) {
        withContext(Dispatchers.IO) { runCatching { refresher.store.remove(id) } }
        states = states - id
        if (selectedId == id) selectedId = null
        load()
    }
}
