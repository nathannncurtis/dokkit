package dev.dokkit.phone.ui

import android.Manifest
import android.content.pm.PackageManager
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.unit.dp
import dev.dokkit.phone.AppViewModel
import dev.dokkit.phone.core.Freshness
import dev.dokkit.phone.core.PairedServer
import dev.dokkit.phone.core.ServerState
import java.net.URI
import java.time.Instant
import kotlinx.coroutines.launch

@Composable
fun ServersTab(vm: AppViewModel, now: Instant) {
    val p = LocalPalette.current
    val scope = rememberCoroutineScope()
    var removing by remember { mutableStateOf<PairedServer?>(null) }
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        Text("Servers", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold, modifier = Modifier.semantics { heading() })
        if (vm.servers.isEmpty()) {
            Notice(
                "No server paired",
                "In the Dokkit web interface open Settings, Phones, Add a phone. It shows a QR code once. Choose Add a server below and scan it.",
            )
        } else {
            Panel("Paired servers", "${vm.servers.size}") {
                vm.servers.forEachIndexed { i, s ->
                    if (i > 0) RowDivider()
                    ServerRow(s, vm.states[s.id] ?: ServerState(), s.id == vm.selected?.id, now, onShow = { vm.selectedId = s.id }, onRemove = { removing = s })
                }
            }
        }
        Button(
            onClick = {
                vm.pasteOnly = false
                vm.adding = true
            },
            modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp),
            colors = ButtonDefaults.buttonColors(containerColor = p.brand, contentColor = p.brandInk),
        ) {
            Icon(Icons.Filled.Add, contentDescription = null, modifier = Modifier.size(18.dp))
            Text("  Add a server")
        }
    }
    removing?.let { s ->
        AlertDialog(
            onDismissRequest = { removing = null },
            title = { Text("Remove ${s.name} from this phone?") },
            text = { Text("Its key, its token and its saved snapshot are deleted from this phone. Nothing changes on the server.") },
            confirmButton = {
                TextButton(
                    onClick = {
                        removing = null
                        scope.launch { vm.remove(s.id) }
                    },
                    modifier = Modifier.heightIn(min = 48.dp),
                ) { Text("Remove", color = p.bad) }
            },
            dismissButton = { TextButton(onClick = { removing = null }, modifier = Modifier.heightIn(min = 48.dp)) { Text("Cancel") } },
        )
    }
}

@Composable
private fun ServerRow(s: PairedServer, state: ServerState, current: Boolean, now: Instant, onShow: () -> Unit, onRemove: () -> Unit) {
    val p = LocalPalette.current
    val fresh = Freshness.make(state.madeAt, state.snapshot != null, state.problem, now)
    val host = runCatching { URI(s.relay).host }.getOrNull() ?: s.relay
    Row(Modifier.fillMaxWidth().padding(start = 16.dp, top = 4.dp, bottom = 4.dp, end = 4.dp), verticalAlignment = Alignment.CenterVertically) {
        Column(
            Modifier.weight(1f).clickable(onClickLabel = "Show this server", onClick = onShow).heightIn(min = 48.dp).padding(vertical = 8.dp),
            verticalArrangement = Arrangement.spacedBy(3.dp),
        ) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(s.name, style = MaterialTheme.typography.bodyLarge, fontWeight = FontWeight.SemiBold)
                if (current) Tag("Showing")
            }
            Text(host, style = MaterialTheme.typography.bodySmall, color = p.mute)
            Text(fresh.text, style = MaterialTheme.typography.bodySmall, color = if (fresh.isWarning) p.warn else p.mute)
            fresh.detail?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = p.warn) }
        }
        IconButton(onClick = onRemove, modifier = Modifier.size(48.dp)) {
            Icon(Icons.Filled.Delete, contentDescription = "Remove ${s.name}", tint = p.bad)
        }
    }
}

@Composable
fun AddServer(vm: AppViewModel) {
    val p = LocalPalette.current
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()
    var pasted by rememberSaveable { mutableStateOf("") }
    var error by remember { mutableStateOf<String?>(null) }
    var working by remember { mutableStateOf(false) }
    var camera by remember { mutableStateOf(ctx.checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) }
    var asked by rememberSaveable { mutableStateOf(false) }
    val ask = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { camera = it }

    fun submit(code: String) {
        if (working) return
        working = true
        scope.launch {
            error = vm.add(code)
            working = false
            if (error == null) {
                pasted = ""
                vm.adding = false
            }
        }
    }

    val scan = !vm.pasteOnly
    BackHandler { vm.adding = false }
    LaunchedEffect(Unit) {
        if (scan && !camera && !asked) {
            asked = true
            ask.launch(Manifest.permission.CAMERA)
        }
    }

    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = { vm.adding = false }, modifier = Modifier.size(48.dp)) {
                Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Cancel")
            }
            Text("Add a server", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold, modifier = Modifier.semantics { heading() })
        }
        Text(
            if (scan) "Scan the QR code in the Dokkit web interface under Settings, Phones, Add a phone. It is shown once."
            else "Paste the code from the Dokkit web interface, under Settings, Phones, Add a phone.",
            style = MaterialTheme.typography.bodyMedium,
            color = p.mute,
        )
        if (!scan) {
            Unit
        } else if (camera) {
            QrScanner(onCode = { submit(it) }, modifier = Modifier.fillMaxWidth().heightIn(min = 300.dp, max = 300.dp))
        } else {
            Notice("The camera is off", "Allow the camera to scan, or paste the code below.", Icons.Filled.Info)
            OutlinedButton(onClick = { ask.launch(Manifest.permission.CAMERA) }, modifier = Modifier.heightIn(min = 48.dp)) { Text("Allow the camera") }
        }
        error?.let {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Icon(Icons.Filled.Warning, contentDescription = "Warning", tint = p.warn)
                Text(it, style = MaterialTheme.typography.bodyMedium, color = p.warn)
            }
        }
        Text("Or paste the code", style = MaterialTheme.typography.labelLarge, fontWeight = FontWeight.SemiBold)
        OutlinedTextField(
            value = pasted,
            onValueChange = { pasted = it },
            modifier = Modifier.fillMaxWidth().heightIn(min = 56.dp),
            placeholder = { Text("dokkit-phone:1:...") },
            textStyle = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace),
            keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.None),
        )
        OutlinedButton(onClick = { submit(pasted) }, enabled = pasted.isNotEmpty() && !working, modifier = Modifier.heightIn(min = 48.dp)) { Text("Add") }
    }
}
