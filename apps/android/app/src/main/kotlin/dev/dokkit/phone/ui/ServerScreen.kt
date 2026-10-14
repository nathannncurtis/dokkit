package dev.dokkit.phone.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.automirrored.filled.List
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import dev.dokkit.phone.AppViewModel
import dev.dokkit.phone.core.Freshness
import dev.dokkit.phone.core.Snapshot
import dev.dokkit.phone.core.leftOutText
import java.time.Instant
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ServerScreen(
    vm: AppViewModel,
    title: String,
    now: Instant,
    showPicker: Boolean = true,
    onBack: (() -> Unit)? = null,
    content: @Composable ColumnScope.(Snapshot, Instant) -> Unit,
) {
    val p = LocalPalette.current
    val scope = rememberCoroutineScope()
    val state = vm.selectedState
    Column(Modifier.fillMaxSize()) {
        Row(Modifier.fillMaxWidth().heightIn(min = 56.dp).padding(horizontal = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            if (onBack != null) {
                IconButton(onClick = onBack, modifier = Modifier.size(48.dp)) {
                    Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                }
            } else {
                Spacer(Modifier.size(8.dp))
            }
            Column(Modifier.weight(1f)) {
                Text(title, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold, modifier = Modifier.semantics { heading() })
                vm.selected?.let { Text(it.name, style = MaterialTheme.typography.bodySmall, color = p.mute) }
            }
            if (showPicker && vm.servers.size > 1) {
                var menu by remember { mutableStateOf(false) }
                IconButton(onClick = { menu = true }, modifier = Modifier.size(48.dp)) {
                    Icon(Icons.AutoMirrored.Filled.List, contentDescription = "Switch server")
                }
                DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                    vm.servers.forEach { s ->
                        DropdownMenuItem(
                            text = { Text(s.name) },
                            leadingIcon = if (s.id == vm.selected?.id) ({ Icon(Icons.Filled.Check, contentDescription = "Showing") }) else null,
                            onClick = {
                                vm.selectedId = s.id
                                menu = false
                            },
                        )
                    }
                }
            }
            IconButton(onClick = { scope.launch { vm.refresh() } }, modifier = Modifier.size(48.dp)) {
                Icon(Icons.Filled.Refresh, contentDescription = "Refresh")
            }
        }
        PullToRefreshBox(isRefreshing = vm.refreshing, onRefresh = { scope.launch { vm.refresh() } }, modifier = Modifier.weight(1f)) {
            Column(
                Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                if (vm.servers.isEmpty()) {
                    Notice(
                        "No server paired",
                        "In the Dokkit web interface open Settings, Phones, Add a phone. It shows a QR code once. Then choose Servers here and scan it.",
                    )
                } else {
                    AgeBanner(Freshness.make(state.madeAt, state.snapshot != null, state.problem, now))
                    val snap = state.snapshot
                    if (snap != null) {
                        leftOutText(snap)?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = p.mute) }
                        content(snap, now)
                    } else {
                        Notice(
                            "No snapshot yet",
                            "This phone is paired. The server uploads a snapshot about once a minute while a phone is paired; pull down to look again.",
                        )
                    }
                }
            }
        }
    }
}
