package dev.dokkit.phone.ui

import android.Manifest
import android.content.pm.PackageManager
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
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
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.dokkit.phone.AppViewModel
import dev.dokkit.phone.R
import dev.dokkit.phone.Route
import dev.dokkit.phone.core.Freshness
import dev.dokkit.phone.core.PairedServer
import dev.dokkit.phone.core.ServerState
import dev.dokkit.phone.core.Tone
import java.net.URI
import java.time.Instant
import kotlinx.coroutines.launch

@Composable
fun ServersPage(vm: AppViewModel, now: Instant) {
    val p = LocalPalette.current
    val scope = rememberCoroutineScope()
    var removing by remember { mutableStateOf<PairedServer?>(null) }
    val list = vm.servers
    val cur = vm.selected
    val hero = if (list.isEmpty()) {
        HeroModel(Tone.Quiet, R.drawable.ic_ph_device_mobile, { BigLine("No server paired", it) }, eyebrow = { Eyebrow("Servers", Tone.Quiet) },
            lede = "In the Dokkit web interface open Settings, Phones, Add a phone. It shows a QR code once. Choose Add a server below and scan it.")
    } else {
        HeroModel(
            Tone.Brand, R.drawable.ic_ph_hard_drives, { BigWithTick(list.size, "srv-n", "server paired", "servers paired", it) },
            eyebrow = { Eyebrow("Servers", Tone.Brand) },
            lede = "Showing ${cur?.name}. Remove one and its key, token and saved snapshot leave this phone.",
            age = vm.freshness(now).text,
        )
    }
    StatementPage(if (list.isEmpty()) Tone.Quiet else Tone.Brand, { TopBar("Servers", null) }, hero) {
        if (list.isNotEmpty()) {
            BigCard {
                CardHead("Paired servers", "${list.size}")
                list.forEachIndexed { i, s ->
                    if (i > 0) Box(Modifier.fillMaxWidth().height(1.dp).background(p.line.copy(alpha = 0.75f)))
                    ServerRow(s, vm.states[s.id] ?: ServerState(), s.id == cur?.id, now, vm.settings.lateMinutes * 60, onShow = { vm.selectedId = s.id }, onRemove = { removing = s })
                }
                Box(Modifier.height(8.dp))
            }
        }
        PrimaryButton("Add a server", { vm.go(Route.Add(false)) }, icon = R.drawable.ic_ph_plus)
    }
    removing?.let { s ->
        AlertDialog(
            onDismissRequest = { removing = null },
            containerColor = p.panel,
            shape = RoundedCornerShape(28.dp),
            title = { Text("Remove ${s.name} from this phone?", style = MaterialTheme.typography.titleLarge, fontSize = 20.sp) },
            text = { Text("Its key, its token and its saved snapshot are deleted from this phone. Nothing changes on the server.", style = MaterialTheme.typography.bodyMedium, color = p.ink2) },
            confirmButton = {
                TextButton(onClick = { removing = null; scope.launch { vm.remove(s.id) } }, modifier = Modifier.heightIn(min = 48.dp)) {
                    Text("Remove", style = MaterialTheme.typography.labelLarge, color = p.rose.ink)
                }
            },
            dismissButton = {
                TextButton(onClick = { removing = null }, modifier = Modifier.heightIn(min = 48.dp)) { Text("Cancel", style = MaterialTheme.typography.labelLarge, color = p.mute) }
            },
        )
    }
}

@Composable
private fun ServerRow(s: PairedServer, state: ServerState, current: Boolean, now: Instant, lateSeconds: Int, onShow: () -> Unit, onRemove: () -> Unit) {
    val p = LocalPalette.current
    val f = Freshness.make(state.madeAt, state.snapshot != null, state.problem, now, lateSeconds)
    val host = runCatching { URI(s.relay).host }.getOrNull() ?: s.relay
    Row(Modifier.fillMaxWidth().padding(end = 8.dp), verticalAlignment = Alignment.CenterVertically) {
        Column(
            Modifier.weight(1f).clickable(role = Role.Button, onClickLabel = "Show this server", onClick = onShow).heightIn(min = 56.dp).padding(horizontal = 20.dp, vertical = 14.dp),
            verticalArrangement = Arrangement.spacedBy(2.dp),
        ) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(s.name, style = MaterialTheme.typography.titleSmall, fontSize = 16.sp)
                if (current) Tag("Showing", Tone.Brand)
            }
            Mono(host, 12.5f)
            Text(f.text, style = MaterialTheme.typography.bodySmall, color = if (f.isWarning) p.amber.ink else p.mute)
            f.detail?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = p.amber.ink) }
        }
        Box(
            Modifier.size(44.dp).clip(CircleShape).clickable(role = Role.Button, onClick = onRemove).semantics { contentDescription = "Remove ${s.name}" },
            contentAlignment = Alignment.Center,
        ) { Ph(R.drawable.ic_ph_trash, tint = p.rose.ink) }
    }
}

@Composable
fun AddServer(vm: AppViewModel, pasteOnly: Boolean) {
    val p = LocalPalette.current
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()
    var pasted by rememberSaveable { mutableStateOf("") }
    var error by remember { mutableStateOf<String?>(null) }
    var working by remember { mutableStateOf(false) }
    var camera by remember { mutableStateOf(ctx.checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) }
    var asked by rememberSaveable { mutableStateOf(false) }
    var broken by remember { mutableStateOf(false) }
    val ask = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { camera = it }

    fun submit(code: String) {
        if (working) return
        working = true
        scope.launch {
            error = vm.add(code)
            working = false
            if (error == null) {
                pasted = ""
                if (!vm.back()) vm.go(Route.Home)
            }
        }
    }

    val scan = !pasteOnly
    LaunchedEffect(Unit) {
        if (scan && !camera && !asked) {
            asked = true
            ask.launch(Manifest.permission.CAMERA)
        }
    }
    val hero = HeroModel(
        Tone.Brand, if (scan) R.drawable.ic_ph_qr_code else R.drawable.ic_ph_clipboard_text,
        { BigLine(if (scan) "Scan the code" else "Paste the code", it) },
        eyebrow = { Eyebrow("Add a server", Tone.Brand) },
        lede = if (scan) "Scan the QR code in the Dokkit web interface under Settings, Phones, Add a phone. It is shown once."
        else "Paste the code from the Dokkit web interface, under Settings, Phones, Add a phone.",
    )
    StatementPage(Tone.Brand, { TopBar("Add a server", null, { vm.back() }, R.drawable.ic_ph_x, "Cancel") }, hero, bottomRoom = 32.dp) {
        if (scan) {
            if (camera && broken) {
                Notice(Tone.Quiet, R.drawable.ic_ph_camera_slash, "The camera could not start", "Paste the code below instead.")
            } else if (camera) {
                Box(Modifier.fillMaxWidth().aspectRatio(1f).clip(RoundedCornerShape(24.dp))) {
                    QrScanner(onCode = { submit(it) }, modifier = Modifier.fillMaxWidth().aspectRatio(1f), onFail = { broken = true })
                }
            } else {
                Notice(Tone.Quiet, R.drawable.ic_ph_camera_slash, "The camera is off", "Allow the camera to scan, or paste the code below.")
                QuietButton("Allow the camera", { ask.launch(Manifest.permission.CAMERA) }, color = p.brand)
            }
        }
        error?.let {
            Row(
                Modifier.fillMaxWidth().clip(RoundedCornerShape(18.dp)).background(p.amber.surface).padding(horizontal = 16.dp, vertical = 14.dp),
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Ph(R.drawable.ic_ph_warning, Modifier.size(20.dp), tint = p.amber.ink, label = "Warning")
                Text(it, style = MaterialTheme.typography.bodyMedium, fontSize = 14.sp, color = p.amber.ink)
            }
        }
        Text("Or paste the code", style = MaterialTheme.typography.titleSmall, modifier = Modifier.padding(start = 6.dp))
        OutlinedTextField(
            value = pasted,
            onValueChange = { pasted = it },
            modifier = Modifier.fillMaxWidth().heightIn(min = 84.dp),
            placeholder = { Mono("dokkit-phone:1:...", 13.5f) },
            textStyle = MaterialTheme.typography.bodySmall.copy(fontFamily = Figtree, fontSize = 13.5.sp),
            keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.None, autoCorrectEnabled = false),
            shape = RoundedCornerShape(16.dp),
            colors = OutlinedTextFieldDefaults.colors(focusedBorderColor = p.brand, unfocusedBorderColor = p.line, focusedContainerColor = p.panel, unfocusedContainerColor = p.panel.copy(alpha = 0.8f), cursorColor = p.brand),
        )
        PrimaryButton("Add", { submit(pasted) }, enabled = pasted.isNotEmpty() && !working)
    }
}
