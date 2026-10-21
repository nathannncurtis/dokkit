package dev.dokkit.phone.ui

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.ExperimentalSharedTransitionApi
import androidx.compose.animation.SharedTransitionLayout
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.togetherWith
import androidx.compose.animation.core.VisibilityThreshold
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.boundsInWindow
import androidx.compose.ui.layout.layout
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.geometry.Offset
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.wrapContentHeight
import kotlin.math.roundToInt
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.runtime.mutableIntStateOf
import dev.dokkit.phone.AppViewModel
import dev.dokkit.phone.R
import dev.dokkit.phone.Route
import dev.dokkit.phone.core.Freshness
import dev.dokkit.phone.core.Tone
import java.net.URI
import java.time.Instant
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

private const val TICK_MS = 5_000L

@OptIn(ExperimentalSharedTransitionApi::class)
@Composable
fun AppRoot(vm: AppViewModel) {
    val now by produceState(Instant.now()) {
        while (true) {
            delay(TICK_MS)
            value = Instant.now()
        }
    }
    LaunchedEffect(Unit) { vm.load() }
    LaunchedEffect(vm.settings.refreshSeconds) {
        while (true) {
            vm.refresh()
            delay(vm.settings.refreshSeconds * 1000L)
        }
    }
    BackHandler(enabled = vm.stack.size > 1) { vm.back() }
    val seen = remember { mutableMapOf<String, Int>() }
    val reduced = LocalReducedMotion.current
    val route = vm.route

    if (vm.loaded && vm.servers.isEmpty() && route !is Route.Add) {
        FirstRun(onScan = { vm.go(Route.Add(false)) }, onPaste = { vm.go(Route.Add(true)) })
        return
    }
    SharedTransitionLayout {
        CompositionLocalProvider(LocalShared provides this, LocalSeen provides seen) {
            Box(Modifier.fillMaxSize().background(LocalPalette.current.bg)) {
                AnimatedContent(
                    targetState = route,
                    contentKey = { it.key },
                    transitionSpec = {
                        val tabs = listOf(Route.Home, Route.Servers, Route.Settings)
                        val from = tabs.indexOf(initialState)
                        val to = tabs.indexOf(targetState)
                        if (from >= 0 && to >= 0 && from != to && !reduced) {
                            // Between tabs the pages slide like the issue cards, on the tab lens's spring.
                            val dir = if (to > from) 1 else -1
                            val move = androidx.compose.animation.core.spring(TRAVEL_DAMPING, TRAVEL_STIFFNESS, androidx.compose.ui.unit.IntOffset.VisibilityThreshold)
                            androidx.compose.animation.slideInHorizontally(move) { dir * it } togetherWith androidx.compose.animation.slideOutHorizontally(move) { -dir * it }
                        } else {
                            (fadeIn(tween(320, easing = Ease)) + slideInVertically(tween(420, easing = Ease)) { it / 60 }) togetherWith fadeOut(tween(200))
                        }
                    },
                    label = "page",
                ) { r ->
                    CompositionLocalProvider(LocalPageScope provides this) {
                        when (r) {
                            Route.Home -> HomePage(vm, now)
                            Route.Servers -> ServersPage(vm, now)
                            Route.Settings -> SettingsPage(vm)
                            is Route.Service -> ServicePage(vm, r, now)
                            is Route.Machine -> MachinePage(vm, r.id, now)
                            is Route.Add -> AddServer(vm, r.paste)
                        }
                    }
                }
                if (route !is Route.Add) {
                    val tab = when (route) { Route.Servers -> 1; Route.Settings -> 2; Route.Home -> 0; else -> -1 }
                    FloatingNav(tab, { vm.go(listOf(Route.Home, Route.Servers, Route.Settings)[it]) }, Modifier.align(Alignment.BottomCenter))
                }
            }
        }
    }
}

fun AppViewModel.freshness(now: Instant): Freshness =
    selectedState.let { Freshness.make(it.madeAt, it.snapshot != null, it.problem, now, settings.lateMinutes * 60) }

/** The top bar of the pages that show a server: its name, the server picker and refresh. */
@Composable
fun ServerTop(vm: AppViewModel, title: String, onBack: (() -> Unit)? = null) {
    val scope = rememberCoroutineScope()
    var picking by remember { mutableStateOf(false) }
    var from by remember { mutableStateOf(androidx.compose.ui.geometry.Rect.Zero) }
    TopBar(title, vm.selected?.name, onBack) {
        if (vm.servers.size > 1) {
            RoundIcon(R.drawable.ic_ph_swap, "Switch server", { picking = true },
                modifier = Modifier.onGloballyPositioned { from = it.boundsInWindow() })
        }
        RoundIcon(R.drawable.ic_ph_arrows_clockwise, "Refresh", { scope.launch { vm.refresh() } }, spinning = vm.refreshing)
    }
    if (picking) ServerPicker(vm, from) { picking = false }
}

/**
 * The server picker grows out of the button that opened it into a rounded window near the top of the screen, on
 * the same spring as the tab bar's lens; its contents fade in as it lands and a vignette gathers around it.
 * Tapping outside or Back shrinks it into the button again.
 */
@Composable
private fun ServerPicker(vm: AppViewModel, from: androidx.compose.ui.geometry.Rect, onGone: () -> Unit) {
    val p = LocalPalette.current
    val reduced = LocalReducedMotion.current
    val density = LocalDensity.current
    val scope = rememberCoroutineScope()
    val k = remember { androidx.compose.animation.core.Animatable(0f) }
    val spring = androidx.compose.animation.core.spring<Float>(dampingRatio = TRAVEL_DAMPING, stiffness = TRAVEL_STIFFNESS)
    LaunchedEffect(Unit) { if (reduced) k.snapTo(1f) else k.animateTo(1f, spring) }
    fun close(then: () -> Unit = {}) {
        scope.launch {
            if (reduced) k.snapTo(0f) else k.animateTo(0f, androidx.compose.animation.core.spring(dampingRatio = 1f, stiffness = TRAVEL_STIFFNESS))
            onGone()
            then()
        }
    }
    androidx.compose.ui.window.Popup(
        popupPositionProvider = object : androidx.compose.ui.window.PopupPositionProvider {
            override fun calculatePosition(anchorBounds: androidx.compose.ui.unit.IntRect, windowSize: androidx.compose.ui.unit.IntSize, layoutDirection: androidx.compose.ui.unit.LayoutDirection, popupContentSize: androidx.compose.ui.unit.IntSize) = androidx.compose.ui.unit.IntOffset.Zero
        },
        onDismissRequest = { close() },
        properties = androidx.compose.ui.window.PopupProperties(focusable = true, clippingEnabled = false),
    ) {
        val t = k.value
        var windowRect by remember { mutableStateOf(androidx.compose.ui.geometry.Rect.Zero) }
        var contentH by remember { mutableIntStateOf(0) }
        var windowRadius by remember { mutableStateOf(0f) }
        Box(
            Modifier.fillMaxSize()
                .drawBehind {
                    // A soft dark halo hugging the window at its current size, gathering as it lands.
                    val land = ((t - 0.35f) / 0.65f).coerceIn(0f, 1f)
                    if (land > 0f && windowRect != androidx.compose.ui.geometry.Rect.Zero) {
                        val reach = 56.dp.toPx()
                        val steps = 14
                        for (i in steps downTo 1) {
                            val f = i / steps.toFloat()
                            val grow = reach * f
                            val r = androidx.compose.ui.geometry.Rect(windowRect.left - grow, windowRect.top - grow, windowRect.right + grow, windowRect.bottom + grow)
                            drawRoundRect(
                                Color.Black.copy(alpha = (if (p.dark) 0.13f else 0.08f) * land * (1f - f) * (1f - f) + 0.005f * land),
                                topLeft = r.topLeft, size = r.size,
                                cornerRadius = androidx.compose.ui.geometry.CornerRadius(windowRadius + grow),
                            )
                        }
                    }
                }
                .clickable(remember { androidx.compose.foundation.interaction.MutableInteractionSource() }, null) { close() },
        ) {
            val margin = with(density) { 12.dp.toPx() }
            val top = from.bottom + with(density) { 10.dp.toPx() }
            val radiusFrom = from.width / 2f
            val radiusTo = with(density) { 28.dp.toPx() }
            Box(
                Modifier.layout { m, c ->
                    val targetW = (c.maxWidth - 2 * margin).roundToInt()
                    val tl = Offset(margin, top)
                    val l = androidx.compose.ui.util.lerp(from.left, tl.x, t)
                    val tp = androidx.compose.ui.util.lerp(from.top, tl.y, t)
                    val w = androidx.compose.ui.util.lerp(from.width, targetW.toFloat(), t).coerceAtLeast(1f)
                    val h = androidx.compose.ui.util.lerp(from.height, contentH.toFloat(), t).coerceAtLeast(1f)
                    windowRect = androidx.compose.ui.geometry.Rect(l, tp, l + w, tp + h)
                    windowRadius = androidx.compose.ui.util.lerp(radiusFrom, radiusTo, t.coerceIn(0f, 1f))
                    val box = m.measure(androidx.compose.ui.unit.Constraints.fixed(w.roundToInt(), h.roundToInt()))
                    layout(c.maxWidth, c.maxHeight) { box.place(l.roundToInt(), tp.roundToInt()) }
                }
                    .shadow((4 + 20 * t).dp, RoundedCornerShape(androidx.compose.ui.util.lerp(radiusFrom, radiusTo, t.coerceIn(0f, 1f)).let { with(density) { it.toDp() } }),
                        ambientColor = p.ink.copy(alpha = 0.2f), spotColor = p.ink.copy(alpha = 0.3f))
                    .clip(RoundedCornerShape(with(density) { androidx.compose.ui.util.lerp(radiusFrom, radiusTo, t.coerceIn(0f, 1f)).toDp() }))
                    .background(p.panel)
                    .border(1.dp, p.line.copy(alpha = 0.7f), RoundedCornerShape(with(density) { androidx.compose.ui.util.lerp(radiusFrom, radiusTo, t.coerceIn(0f, 1f)).toDp() }))
                    .clickable(remember { androidx.compose.foundation.interaction.MutableInteractionSource() }, null) {},
            ) {
                // The button's own icon, fading as the window takes its place.
                Box(Modifier.size(with(density) { from.width.toDp() }).graphicsLayer { alpha = (1f - t * 2.5f).coerceIn(0f, 1f) }, contentAlignment = Alignment.Center) {
                    Ph(R.drawable.ic_ph_swap, Modifier.size(22.dp))
                }
                Column(
                    Modifier.wrapContentHeight(unbounded = true, align = Alignment.Top).fillMaxWidth()
                        .onSizeChanged { contentH = it.height }
                        .graphicsLayer { alpha = ((t - 0.55f) / 0.45f).coerceIn(0f, 1f) }
                        .padding(start = 12.dp, end = 12.dp, top = 18.dp, bottom = 12.dp),
                    verticalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    Text("Show a server", style = MaterialTheme.typography.titleMedium, fontSize = 18.sp, modifier = Modifier.padding(start = 10.dp, bottom = 8.dp))
                    vm.servers.forEach { s ->
                        val on = s.id == vm.selected?.id
                        Row(
                            Modifier.fillMaxWidth().heightIn(min = 60.dp).clip(RoundedCornerShape(16.dp)).background(if (on) p.brandSoft else p.panel)
                                .clickable(role = Role.Button, onClickLabel = "Show ${s.name}") { vm.selectedId = s.id; close() }
                                .padding(horizontal = 16.dp, vertical = 12.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Column(Modifier.weight(1f)) {
                                Text(s.name, style = MaterialTheme.typography.titleSmall, fontSize = 16.sp)
                                Mono(runCatching { URI(s.relay).host }.getOrNull() ?: s.relay, 12f)
                            }
                            if (on) Ph(R.drawable.ic_ph_check, Modifier.size(20.dp), tint = p.brand, label = "Showing")
                        }
                    }
                }
            }
        }
    }
}

/** A page that is one card in the middle of the screen: first run and the lock. */
@Composable
fun CenterCard(tone: Tone, content: @Composable androidx.compose.foundation.layout.ColumnScope.() -> Unit) {
    val p = LocalPalette.current
    Box(Modifier.fillMaxSize().wash(p, tone).statusBarsPadding().navigationBarsPadding().verticalScroll(rememberScrollState()), contentAlignment = Alignment.Center) {
        Box(Modifier.padding(horizontal = 14.dp, vertical = 24.dp)) {
            StatementCard(tone, Modifier.padding(0.dp)) {
                Spacer(Modifier.height(6.dp))
                content()
            }
        }
    }
}

@Composable
fun LockCover(message: String?, onUnlock: () -> Unit) {
    val p = LocalPalette.current
    val tone = if (message != null) Tone.Degraded else Tone.Brand
    val t = p.tint(tone)
    CenterCard(tone) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Box(Modifier.size(44.dp).clip(RoundedCornerShape(50)).background(p.panel.copy(alpha = 0.8f)), contentAlignment = Alignment.Center) { Ph(R.drawable.ic_ph_lock_simple, tint = t.ink) }
            Eyebrow("Dokkit", tone)
        }
        Spacer(Modifier.height(16.dp))
        BigLine("Dokkit is locked", 38f)
        Text(message ?: "Unlock with your fingerprint, face or screen lock.", style = MaterialTheme.typography.bodyLarge, fontSize = 16.5.sp, color = p.ink2, modifier = Modifier.padding(top = 10.dp))
        Spacer(Modifier.height(20.dp))
        PrimaryButton("Unlock", onUnlock, icon = R.drawable.ic_ph_fingerprint)
    }
}

@Composable
fun FirstRun(onScan: () -> Unit, onPaste: () -> Unit) {
    val p = LocalPalette.current
    CenterCard(Tone.Brand) {
        Box(Modifier.size(64.dp).clip(RoundedCornerShape(18.dp)).background(p.brand)) {
            Image(painterResource(R.drawable.ic_launcher_foreground), contentDescription = null, modifier = Modifier.fillMaxSize())
        }
        Spacer(Modifier.height(18.dp))
        BigLine("Dokkit", 38f)
        Text("A read-only view of your Dokkit server. Alerts still reach you the usual way. Nothing here can change anything.",
            style = MaterialTheme.typography.bodyLarge, fontSize = 16.5.sp, color = p.ink2, modifier = Modifier.padding(top = 10.dp))
        Text("The code is in the Dokkit web interface: Settings, Phones, Add a phone.",
            style = MaterialTheme.typography.bodyMedium, fontSize = 14.5.sp, color = p.mute, modifier = Modifier.padding(top = 12.dp))
        Spacer(Modifier.height(18.dp))
        PrimaryButton("Scan the code", onScan, icon = R.drawable.ic_ph_qr_code)
        Spacer(Modifier.height(6.dp))
        QuietButton("Paste the code instead", onPaste)
    }
}

@Composable
fun BigWithTick(n: Int, key: String, one: String, many: String, sizeSp: Float) {
    Tick(n, key) { BigLine("$it ${if (it == "1") one else many}", sizeSp) }
}

@Composable
fun Mono(text: String, size: Float = 12.5f, color: androidx.compose.ui.graphics.Color = LocalPalette.current.mute, weight: FontWeight = FontWeight.Medium, modifier: Modifier = Modifier) {
    Text(text, fontFamily = Figtree, fontSize = size.sp, color = color, fontWeight = weight, modifier = modifier)
}
