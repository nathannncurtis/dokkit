package dev.dokkit.phone

import android.app.Application
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import dev.dokkit.phone.core.AppSettings
import dev.dokkit.phone.core.PairedServer
import dev.dokkit.phone.core.Pairing
import dev.dokkit.phone.core.Refresher
import dev.dokkit.phone.core.RelayClient
import dev.dokkit.phone.core.ServerState
import dev.dokkit.phone.core.ServerStore
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class AppViewModel(app: Application) : AndroidViewModel(app) {
    private val refresher: Refresher

    init {
        val box = KeystoreBox()
        val dir = File(app.noBackupFilesDir, "dokkit")
        val transport = appTransport(app) { settings.relayWaitSeconds * 1000 }
        refresher = Refresher(ServerStore(KeystoreSecrets(EncryptedDir(File(dir, "secrets"), box)), EncryptedDir(File(dir, "files"), box)), RelayClient(transport))
    }

    private val prefs = app.getSharedPreferences("settings", android.content.Context.MODE_PRIVATE)

    var settings by mutableStateOf(AppSettings.decode(prefs.getString("settings", null)))
        private set

    fun save(next: AppSettings) {
        settings = next.clamped()
        prefs.edit().putString("settings", settings.encode()).apply()
    }

    // When the app last went to the background, for the unlock setting.
    var stoppedAt: Long = 0L

    var servers by mutableStateOf(emptyList<PairedServer>())
        private set
    var states by mutableStateOf(emptyMap<String, ServerState>())
        private set
    var refreshing by mutableStateOf(false)
        private set
    var selectedId by mutableStateOf<String?>(null)
    var unlocked by mutableStateOf(false)
    var lockMessage by mutableStateOf<String?>(null)
    var loaded by mutableStateOf(false)
        private set
    var stack by mutableStateOf(listOf<Route>(Route.Home))
        private set
    val route: Route get() = stack.last()

    fun go(r: Route) {
        stack = if (r.isTab) listOf(r) else stack + r
    }

    fun back(): Boolean {
        if (stack.size <= 1) return false
        stack = stack.dropLast(1)
        return true
    }
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

    fun refreshAsync() {
        viewModelScope.launch { refresh() }
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

sealed interface Route {
    val isTab: Boolean get() = false
    val key: String

    data object Home : Route { override val isTab = true; override val key = "home" }
    data object Servers : Route { override val isTab = true; override val key = "servers" }
    data object Settings : Route { override val isTab = true; override val key = "settings" }
    data class Service(val id: String, val fromIssue: String? = null) : Route { override val key = "service/$id" }
    data class Machine(val id: String) : Route { override val key = "machine/$id" }
    data class Add(val paste: Boolean) : Route { override val key = "add/$paste" }
}
