package dev.dokkit.phone.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.List
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.unit.dp
import dev.dokkit.phone.AppViewModel
import java.time.Instant
import kotlinx.coroutines.delay

private const val REFRESH_MS = 30_000L
private const val TICK_MS = 5_000L

@Composable
fun AppRoot(vm: AppViewModel) {
    val p = LocalPalette.current
    var tab by rememberSaveable { mutableIntStateOf(0) }
    var service by rememberSaveable { mutableStateOf<String?>(null) }
    val now by produceState(Instant.now()) {
        while (true) {
            delay(TICK_MS)
            value = Instant.now()
        }
    }
    LaunchedEffect(Unit) {
        vm.load()
        while (true) {
            vm.refresh()
            delay(REFRESH_MS)
        }
    }
    BackHandler(enabled = service != null) { service = null }

    val tabs: List<Triple<String, ImageVector, Int>> = listOf(
        Triple("Needs you", Icons.Filled.Warning, 0),
        Triple("Everything", Icons.AutoMirrored.Filled.List, 1),
        Triple("Servers", Icons.Filled.Settings, 2),
    )
    Scaffold(
        containerColor = p.bg,
        contentColor = p.ink,
        bottomBar = {
            NavigationBar(containerColor = p.panel) {
                tabs.forEach { (label, icon, index) ->
                    NavigationBarItem(
                        selected = tab == index,
                        onClick = {
                            tab = index
                            service = null
                        },
                        icon = { Icon(icon, contentDescription = null) },
                        label = { Text(label) },
                        colors = NavigationBarItemDefaults.colors(indicatorColor = p.chip, selectedIconColor = p.brand, selectedTextColor = p.brand),
                    )
                }
            }
        },
    ) { pad ->
        Box(Modifier.padding(pad).fillMaxSize()) {
            val open = service
            when {
                open != null -> ServiceDetail(vm, open, now) { service = null }
                tab == 0 -> NeedsYouTab(vm, now) { service = it }
                tab == 1 -> EverythingTab(vm, now) { service = it }
                else -> ServersTab(vm, now)
            }
        }
    }
}

@Composable
fun LockCover(message: String?, onUnlock: () -> Unit) {
    val p = LocalPalette.current
    Column(
        Modifier.fillMaxSize().background(p.bg).padding(32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(16.dp, Alignment.CenterVertically),
    ) {
        Icon(Icons.Filled.Lock, contentDescription = null, modifier = Modifier.size(40.dp), tint = p.ink)
        Text("Dokkit is locked", style = MaterialTheme.typography.titleMedium, color = p.ink)
        message?.let { Text(it, style = MaterialTheme.typography.bodyMedium, color = p.ink) }
        Button(
            onClick = onUnlock,
            modifier = Modifier.heightIn(min = 48.dp),
            colors = ButtonDefaults.buttonColors(containerColor = p.brand, contentColor = p.brandInk),
        ) { Text("Unlock") }
    }
}
