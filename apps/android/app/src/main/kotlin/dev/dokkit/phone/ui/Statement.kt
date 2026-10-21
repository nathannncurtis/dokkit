package dev.dokkit.phone.ui

import androidx.annotation.DrawableRes
import androidx.compose.animation.AnimatedVisibilityScope
import androidx.compose.animation.ExperimentalSharedTransitionApi
import androidx.compose.animation.SharedTransitionScope
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.material3.pulltorefresh.PullToRefreshDefaults
import androidx.compose.material3.pulltorefresh.rememberPullToRefreshState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.layout.layout
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.layout.positionInWindow
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.dokkit.phone.R
import dev.dokkit.phone.core.Flag
import dev.dokkit.phone.core.Freshness
import dev.dokkit.phone.core.IssueCard
import dev.dokkit.phone.core.MeterRow
import dev.dokkit.phone.core.Tone
import androidx.compose.animation.core.spring
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.mutableStateOf
import kotlinx.coroutines.coroutineScope
import androidx.compose.ui.graphics.drawscope.clipPath
import androidx.compose.ui.graphics.drawscope.clipRect
import kotlin.math.roundToInt
import kotlinx.coroutines.launch

val Ease = CubicBezierEasing(0.2f, 0.8f, 0.2f, 1f)

// Numbers and fills that animate only the first time they are seen.
val LocalSeen = staticCompositionLocalOf { mutableMapOf<String, Int>() }

@OptIn(ExperimentalSharedTransitionApi::class)
val LocalShared = staticCompositionLocalOf<SharedTransitionScope?> { null }
val LocalPageScope = staticCompositionLocalOf<AnimatedVisibilityScope?> { null }

@OptIn(ExperimentalSharedTransitionApi::class)
@Composable
fun Modifier.morph(key: String?): Modifier {
    val shared = LocalShared.current
    val scope = LocalPageScope.current
    if (key == null || shared == null || scope == null || LocalReducedMotion.current) return this
    return with(shared) {
        this@morph.sharedBounds(rememberSharedContentState(key), scope, resizeMode = SharedTransitionScope.ResizeMode.RemeasureToBounds)
    }
}

@Composable
fun Ph(@DrawableRes id: Int, modifier: Modifier = Modifier.size(22.dp), tint: Color = LocalPalette.current.ink, label: String? = null) {
    Icon(painterResource(id), contentDescription = label, modifier = modifier, tint = tint)
}

fun toneIcon(t: Tone): Int = when (t) {
    Tone.Down -> R.drawable.ic_ph_warning_octagon
    Tone.Degraded -> R.drawable.ic_ph_hourglass_medium
    Tone.Soon -> R.drawable.ic_ph_calendar
    Tone.Ok -> R.drawable.ic_ph_check_circle
    Tone.Quiet -> R.drawable.ic_ph_circle_dashed
    Tone.Brand -> R.drawable.ic_ph_info
}

// ---------- the page: a wash in the page's tone, a top bar, a hero card that settles as you scroll ----------

fun Modifier.wash(p: Palette, tone: Tone): Modifier = drawBehind {
    val t = p.tint(tone)
    drawRect(Brush.verticalGradient(0f to lerp(p.bg, t.surface, 0.55f), 0.62f to p.bg, startY = 0f, endY = size.height))
    drawRect(Brush.radialGradient(listOf(t.surface.copy(alpha = 0.85f), Color.Transparent), center = Offset(size.width * 0.85f, -size.height * 0.1f), radius = size.width * 1.2f))
}

@Composable
fun TopBar(title: String, server: String?, onBack: (() -> Unit)? = null, backIcon: Int = R.drawable.ic_ph_arrow_left, backLabel: String = "Back", tools: @Composable RowScope.() -> Unit = {}) {
    val p = LocalPalette.current
    Row(Modifier.fillMaxWidth().heightIn(min = 56.dp).padding(start = 8.dp, end = 8.dp), verticalAlignment = Alignment.CenterVertically) {
        if (onBack != null) {
            RoundIcon(backIcon, backLabel, onBack)
            Spacer(Modifier.width(10.dp))
        } else {
            Spacer(Modifier.width(12.dp))
        }
        Column(Modifier.weight(1f)) {
            Text(title, style = MaterialTheme.typography.labelLarge, fontWeight = FontWeight.Bold, color = p.ink2, modifier = Modifier.semantics { heading() })
            server?.let { Text(it, fontFamily = Figtree, fontSize = 12.sp, color = p.mute, maxLines = 1, overflow = TextOverflow.Ellipsis) }
        }
        tools()
    }
}

@Composable
fun RoundIcon(icon: Int, label: String, onClick: () -> Unit, spinning: Boolean = false, modifier: Modifier = Modifier) {
    val p = LocalPalette.current
    val press = remember { MutableInteractionSource() }
    val down by press.collectIsPressedAsState()
    val scale by animateFloatAsState(if (down) 0.92f else 1f, tween(200, easing = Ease), label = "press")
    val turn = if (spinning && !LocalReducedMotion.current) {
        rememberInfiniteTransition(label = "spin").animateFloat(0f, 360f, infiniteRepeatable(tween(1000, easing = LinearEasing)), label = "turn").value
    } else 0f
    Box(
        modifier.padding(start = 6.dp).size(44.dp).graphicsLayer { scaleX = scale; scaleY = scale }.clip(CircleShape)
            .background(p.panel.copy(alpha = 0.55f)).border(1.dp, p.line.copy(alpha = 0.7f), CircleShape)
            .clickable(interactionSource = press, indication = null, role = Role.Button, onClickLabel = label, onClick = onClick)
            .semantics { contentDescription = label },
        contentAlignment = Alignment.Center,
    ) { Ph(icon, Modifier.size(22.dp).rotate(turn)) }
}

class HeroModel(
    val tone: Tone,
    val icon: Int,
    val big: @Composable (sizeSp: Float) -> Unit,
    val eyebrow: (@Composable () -> Unit)? = null,
    val lede: String? = null,
    val extra: (@Composable () -> Unit)? = null,
    val age: String? = null,
    val morphKey: String? = null,
)

private fun Modifier.fold(p: Float): Modifier = this
    .graphicsLayer { alpha = (1f - p * 1.7f).coerceIn(0f, 1f); clip = true }
    .layout { m, c ->
        val pl = m.measure(c)
        val h = (pl.height * (1f - p)).roundToInt().coerceAtLeast(0)
        layout(pl.width, h) { pl.place(0, 0) }
    }

@Composable
fun StatementCard(tone: Tone, modifier: Modifier = Modifier, p: Float = 0f, content: @Composable ColumnScope.() -> Unit) {
    val pal = LocalPalette.current
    val t = pal.tint(tone)
    val reduced = LocalReducedMotion.current
    val sheen = if (reduced) 0f else rememberInfiniteTransition(label = "sheen")
        .animateFloat(-0.28f, 0.28f, infiniteRepeatable(tween(14_000, easing = CubicBezierEasing(0.42f, 0f, 0.58f, 1f)), RepeatMode.Reverse), label = "x").value
    val shape = RoundedCornerShape((30 - 8 * p).dp)
    val sheenColor = if (pal.dark) Color.White.copy(alpha = 0.07f) else Color.White.copy(alpha = 0.5f)
    Column(
        modifier.fillMaxWidth()
            .shadow((10 + 8 * p).dp, shape, ambientColor = t.solid.copy(alpha = 0.3f), spotColor = t.solid.copy(alpha = 0.35f))
            .clip(shape)
            .drawBehind {
                drawRect(Brush.linearGradient(listOf(t.surface, lerp(pal.panel, t.surface, 0.62f)), start = Offset.Zero, end = Offset(size.width, size.height)))
                drawCircle(Brush.radialGradient(listOf(t.solid.copy(alpha = 0.22f), Color.Transparent), center = Offset(size.width - 50.dp.toPx(), 40.dp.toPx()), radius = 110.dp.toPx()), radius = 110.dp.toPx(), center = Offset(size.width - 50.dp.toPx(), 40.dp.toPx()))
                val w = size.width * 1.8f
                val x = size.width * sheen
                drawRect(Brush.linearGradient(0.38f to Color.Transparent, 0.5f to sheenColor, 0.62f to Color.Transparent, start = Offset(x - w * 0.2f, -size.height * 0.4f), end = Offset(x + w * 0.8f, size.height * 1.4f)))
            }
            .border(1.dp, pal.panel.copy(alpha = 0.6f), shape)
            .padding(horizontal = 22.dp, vertical = (24 - 10 * p).dp),
        content = content,
    )
}

@Composable
fun Hero(m: HeroModel, p: Float = 0f) {
    val pal = LocalPalette.current
    val t = pal.tint(m.tone)
    StatementCard(m.tone, Modifier.morph(m.morphKey), p) {
        Column(Modifier.fold(p)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Box(Modifier.size(44.dp).clip(CircleShape).background(pal.panel.copy(alpha = 0.8f)), contentAlignment = Alignment.Center) { Ph(m.icon, tint = t.ink) }
                m.eyebrow?.invoke()
            }
            Spacer(Modifier.height(14.dp))
        }
        m.big(38f - 14f * p)
        Column(Modifier.fold(p)) {
            m.lede?.let { Text(it, style = MaterialTheme.typography.bodyLarge, fontSize = 16.5.sp, color = pal.ink2, modifier = Modifier.padding(top = 10.dp)) }
            m.extra?.invoke()
            m.age?.let {
                Row(Modifier.padding(top = 14.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    Ph(R.drawable.ic_ph_clock, Modifier.size(14.dp), tint = t.ink)
                    Text(it, fontFamily = Figtree, fontSize = 12.sp, color = t.ink)
                }
            }
        }
    }
}

@Composable
fun BigLine(text: String, sizeSp: Float, mono: Boolean = false) {
    Text(
        text,
        fontFamily = Figtree,
        fontWeight = FontWeight.ExtraBold,
        fontSize = sizeSp.sp,
        lineHeight = (sizeSp * 1.08f).sp,
        letterSpacing = (-0.032 * sizeSp).sp,
        color = LocalPalette.current.ink,
        modifier = Modifier.semantics { heading() },
    )
}

@Composable
fun Eyebrow(text: String, tone: Tone, icon: Int? = null) {
    val t = LocalPalette.current.tint(tone)
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        icon?.let { Ph(it, Modifier.size(16.dp), tint = t.ink) }
        Text(text, style = MaterialTheme.typography.labelLarge, fontSize = 14.sp, color = t.ink)
    }
}

/** A page: the wash, the top bar, a hero that pins and settles as the page scrolls, and big cards under it. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun StatementPage(
    tone: Tone,
    top: @Composable () -> Unit,
    hero: HeroModel?,
    refreshing: Boolean = false,
    onRefresh: (() -> Unit)? = null,
    bottomRoom: Dp = 112.dp,
    content: @Composable ColumnScope.() -> Unit,
) {
    val pal = LocalPalette.current
    val reduced = LocalReducedMotion.current
    val density = LocalDensity.current
    val scroll = rememberScrollState()
    val range = with(density) { 240.dp.toPx() }
    val pinned = hero != null && !reduced
    val p = if (pinned) (scroll.value / range).coerceIn(0f, 1f) else 0f
    var heroH by remember { mutableIntStateOf(0) }
    var viewport by remember { mutableFloatStateOf(0f) }
    Column(Modifier.fillMaxSize().wash(pal, tone)) {
        Spacer(Modifier.statusBarsPadding())
        top()
        val body = @Composable {
            Box(Modifier.fillMaxSize().onGloballyPositioned { viewport = it.positionInWindow().y + it.size.height }) {
                CompositionLocalProvider(LocalViewportBottom provides viewport) {
                    Column(Modifier.fillMaxSize().verticalScroll(scroll)) {
                        if (pinned) {
                            Spacer(Modifier.height(with(density) { heroH.toDp() }))
                        } else if (hero != null) {
                            Box(Modifier.padding(start = 12.dp, end = 12.dp, top = 4.dp, bottom = 10.dp)) { Hero(hero) }
                        }
                        Column(
                            Modifier.fillMaxWidth().padding(start = 14.dp, end = 14.dp, top = 8.dp, bottom = bottomRoom).navigationBarsPadding(),
                            verticalArrangement = Arrangement.spacedBy(16.dp),
                            content = content,
                        )
                    }
                }
                if (pinned) {
                    Box(Modifier.fillMaxWidth().onSizeChanged { if (scroll.value == 0) heroH = it.height }) {
                        Box(
                            Modifier.matchParentSize().graphicsLayer { alpha = p }.background(
                                Brush.verticalGradient(0f to lerp(pal.bg, pal.tint(tone).surface, 0.4f), 0.7f to lerp(pal.bg, pal.tint(tone).surface, 0.4f).copy(alpha = 0.92f), 1f to Color.Transparent),
                            ),
                        )
                        Box(Modifier.padding(start = 12.dp, end = 12.dp, top = 4.dp, bottom = 10.dp)) { Hero(hero!!, p) }
                    }
                }
            }
        }
        if (onRefresh != null) {
            val state = rememberPullToRefreshState()
            PullToRefreshBox(
                isRefreshing = refreshing,
                onRefresh = onRefresh,
                state = state,
                modifier = Modifier.weight(1f),
                indicator = {
                    PullToRefreshDefaults.Indicator(state = state, isRefreshing = refreshing, modifier = Modifier.align(Alignment.TopCenter), containerColor = pal.panel, color = pal.brand)
                },
            ) { body() }
        } else {
            Box(Modifier.weight(1f)) { body() }
        }
    }
}

val LocalViewportBottom = staticCompositionLocalOf { 0f }

/** Cards rise a little as they come into view, tied to the scroll. */
@Composable
fun Modifier.rise(): Modifier {
    if (LocalReducedMotion.current) return this
    val bottom = LocalViewportBottom.current
    var k by remember { mutableFloatStateOf(1f) }
    return this
        .onGloballyPositioned {
            val top = it.positionInWindow().y
            val reach = it.size.height * 0.55f
            k = if (bottom <= 0f || reach <= 0f) 1f else ((bottom - top) / reach).coerceIn(0f, 1f)
        }
        .graphicsLayer {
            val e = Ease.transform(k)
            translationY = (1f - e) * 22.dp.toPx()
            val s = 0.985f + 0.015f * e
            scaleX = s; scaleY = s
            alpha = 0.55f + 0.45f * e
        }
}

// ---------- cards and small parts ----------

@Composable
fun BigCard(modifier: Modifier = Modifier, content: @Composable ColumnScope.() -> Unit) {
    val p = LocalPalette.current
    val shape = RoundedCornerShape(24.dp)
    Column(
        modifier.rise().fillMaxWidth()
            .shadow(14.dp, shape, ambientColor = p.ink.copy(alpha = 0.08f), spotColor = p.ink.copy(alpha = 0.10f))
            .clip(shape).background(p.panel.copy(alpha = 0.96f)).border(1.dp, p.line.copy(alpha = 0.75f), shape),
        content = content,
    )
}

@Composable
fun CardHead(title: String, detail: String? = null) {
    val p = LocalPalette.current
    Row(Modifier.fillMaxWidth().padding(start = 20.dp, end = 20.dp, top = 20.dp, bottom = 4.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(title, style = MaterialTheme.typography.titleMedium, fontSize = 18.sp, modifier = Modifier.weight(1f).semantics { heading() })
        detail?.let { Text(it, fontFamily = Figtree, fontSize = 12.5.sp, color = p.mute) }
    }
}

@Composable
fun Label(text: String) {
    Text(text.uppercase(), style = MaterialTheme.typography.labelMedium, letterSpacing = 0.6.sp, color = LocalPalette.current.mute,
        modifier = Modifier.padding(start = 6.dp, top = 6.dp).semantics { heading() })
}

@Composable
fun Tick(value: Int, key: String, style: @Composable (String) -> Unit) {
    val seen = LocalSeen.current
    val reduced = LocalReducedMotion.current
    val from = seen[key]
    val a = remember(key) { Animatable(if (reduced || value == 0) value.toFloat() else (from ?: 0).toFloat()) }
    LaunchedEffect(key, value) {
        seen[key] = value
        if (reduced) a.snapTo(value.toFloat()) else a.animateTo(value.toFloat(), tween(700, easing = CubicBezierEasing(0.33f, 1f, 0.68f, 1f)))
    }
    style(a.value.roundToInt().toString())
}

class Figure(val value: Int, val word: String, val tone: Tone, val key: String)

@Composable
fun Figures(items: List<Figure>) {
    val p = LocalPalette.current
    BigCard {
        Row(Modifier.fillMaxWidth().height(IntrinsicSize.Min)) {
            items.forEachIndexed { n, f ->
                if (n > 0) Box(Modifier.width(1.dp).fillMaxHeight().background(p.line.copy(alpha = 0.75f)))
                Column(
                    Modifier.weight(1f).padding(start = 18.dp, end = 10.dp, top = 18.dp, bottom = 18.dp)
                        .clearAndSetSemantics { contentDescription = "${f.value} ${f.word}" },
                ) {
                    Tick(f.value, f.key) {
                        Text(it, fontSize = 34.sp, fontWeight = FontWeight.ExtraBold, letterSpacing = (-1).sp, lineHeight = 36.sp,
                            color = if (f.value > 0 && f.tone != Tone.Quiet) p.tint(f.tone).ink else p.ink)
                    }
                    Text(f.word, style = MaterialTheme.typography.labelMedium, fontSize = 13.5.sp, color = p.mute)
                }
            }
        }
    }
}

@Composable
fun Tag(text: String, tone: Tone, onPanel: Boolean = false) {
    val p = LocalPalette.current
    val t = p.tint(tone)
    Text(
        text, style = MaterialTheme.typography.labelMedium, color = t.ink,
        modifier = Modifier.clip(RoundedCornerShape(99.dp)).background(if (onPanel) p.panel.copy(alpha = 0.8f) else t.surface).padding(horizontal = 10.dp, vertical = 3.dp),
    )
}

@Composable
fun Pip(tone: Tone) {
    val p = LocalPalette.current
    val t = p.tint(tone)
    Canvas(Modifier.size(16.dp)) {
        val r = 5.dp.toPx()
        if (tone == Tone.Quiet) {
            drawCircle(p.mute, r, style = androidx.compose.ui.graphics.drawscope.Stroke(2.dp.toPx(), pathEffect = androidx.compose.ui.graphics.PathEffect.dashPathEffect(floatArrayOf(3f, 3f))))
        } else {
            drawCircle(t.surface, r + 3.dp.toPx())
            drawCircle(t.solid, r)
        }
    }
}

@Composable
fun ToneCircle(tone: Tone, icon: Int = toneIcon(tone), size: Dp = 44.dp, onPanel: Boolean = false) {
    val p = LocalPalette.current
    val t = p.tint(tone)
    Box(
        Modifier.size(size).clip(CircleShape).background(if (onPanel) p.panel else t.surface).then(if (onPanel) Modifier.border(1.dp, p.line, CircleShape) else Modifier),
        contentAlignment = Alignment.Center,
    ) { Ph(icon, Modifier.size(size * 0.5f), tint = t.ink) }
}

@Composable
fun Pressable(onClick: () -> Unit, label: String, modifier: Modifier = Modifier, content: @Composable BoxScope.() -> Unit) {
    val press = remember { MutableInteractionSource() }
    val down by press.collectIsPressedAsState()
    val s by animateFloatAsState(if (down) 0.985f else 1f, tween(250, easing = Ease), label = "press")
    Box(modifier.graphicsLayer { scaleX = s; scaleY = s }.clickable(press, null, role = Role.Button, onClickLabel = label, onClick = onClick), content = content)
}

@Composable
fun SoftButton(text: String, onClick: () -> Unit, icon: Int? = R.drawable.ic_ph_arrow_right, modifier: Modifier = Modifier) {
    val p = LocalPalette.current
    Pressable(onClick, text, modifier.heightIn(min = 46.dp).clip(RoundedCornerShape(14.dp)).background(p.brandSoft)) {
        Row(Modifier.padding(horizontal = 18.dp, vertical = 11.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(text, style = MaterialTheme.typography.labelLarge, color = p.ink)
            icon?.let { Ph(it, Modifier.size(18.dp)) }
        }
    }
}

@Composable
fun PrimaryButton(text: String, onClick: () -> Unit, icon: Int? = null, modifier: Modifier = Modifier, enabled: Boolean = true) {
    val p = LocalPalette.current
    val shape = RoundedCornerShape(16.dp)
    Pressable(
        { if (enabled) onClick() }, text,
        modifier.fillMaxWidth().heightIn(min = 52.dp).graphicsLayer { alpha = if (enabled) 1f else 0.5f }
            .shadow(10.dp, shape, ambientColor = p.brand.copy(alpha = 0.4f), spotColor = p.brand.copy(alpha = 0.45f)).clip(shape).background(p.brand),
    ) {
        Row(Modifier.align(Alignment.Center).padding(horizontal = 18.dp, vertical = 14.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            icon?.let { Ph(it, Modifier.size(20.dp), tint = p.brandInk) }
            Text(text, style = MaterialTheme.typography.labelLarge, fontSize = 16.sp, color = p.brandInk)
        }
    }
}

@Composable
fun QuietButton(text: String, onClick: () -> Unit, modifier: Modifier = Modifier, color: Color = LocalPalette.current.mute) {
    Pressable(onClick, text, modifier.fillMaxWidth().heightIn(min = 48.dp).clip(RoundedCornerShape(14.dp))) {
        Text(text, style = MaterialTheme.typography.labelLarge, color = color, modifier = Modifier.align(Alignment.Center))
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
fun IssueCardView(c: IssueCard, onOpen: (() -> Unit)?) {
    val p = LocalPalette.current
    val t = p.tint(c.tone)
    val shape = RoundedCornerShape(24.dp)
    val open = if (onOpen != null && c.serviceId != null) onOpen else null
    val inner = @Composable {
        Row(Modifier.padding(20.dp), horizontalArrangement = Arrangement.spacedBy(16.dp)) {
            ToneCircle(c.tone, onPanel = true)
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(c.title, style = MaterialTheme.typography.titleLarge)
                Text(c.sentence, style = MaterialTheme.typography.bodyMedium, fontSize = 15.5.sp, color = p.ink2)
                Text(listOfNotNull(c.machine.ifEmpty { null }, c.shortId.ifEmpty { null }, if (c.count > 1) "${c.count} times" else null).joinToString("   "),
                    fontFamily = Figtree, fontSize = 12.sp, color = p.mute, modifier = Modifier.padding(top = 4.dp))
                if (c.flags.isNotEmpty()) {
                    FlowRow(Modifier.padding(top = 6.dp), horizontalArrangement = Arrangement.spacedBy(6.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        c.flags.forEach { Tag(it.text, it.tone) }
                    }
                }
                if (open != null) SoftButton(c.nextStep, open, modifier = Modifier.padding(top = 10.dp))
            }
        }
    }
    val m = Modifier.rise().morph("issue-${c.id}").fillMaxWidth()
        .shadow(14.dp, shape, ambientColor = p.ink.copy(alpha = 0.08f), spotColor = p.ink.copy(alpha = 0.10f))
        .clip(shape)
        .background(Brush.linearGradient(0f to t.surface, 0.62f to p.panel, start = Offset.Zero, end = Offset(900f, 300f)))
        .border(1.dp, p.line.copy(alpha = 0.75f), shape)
    if (open != null) Pressable(open, c.nextStep, m) { inner() } else Box(m) { inner() }
}

@Composable
fun Banner(f: Freshness) {
    val p = LocalPalette.current
    val tone = if (f.isWarning || f.detail != null) Tone.Degraded else Tone.Quiet
    val t = p.tint(tone)
    val spoken = (if (f.isWarning) "Warning. " else "") + f.text + ". " + (f.detail ?: "")
    Row(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(18.dp)).background(t.surface).padding(horizontal = 16.dp, vertical = 14.dp)
            .clearAndSetSemantics { contentDescription = spoken },
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Ph(if (f.isWarning) R.drawable.ic_ph_warning else R.drawable.ic_ph_info, Modifier.size(20.dp), tint = t.ink)
        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(f.text, style = MaterialTheme.typography.labelLarge, fontSize = 14.sp, color = t.ink)
            f.detail?.let { Text(it, style = MaterialTheme.typography.bodySmall, fontSize = 14.sp, color = t.ink) }
        }
    }
}

@Composable
fun Notice(tone: Tone, icon: Int, title: String, text: String) {
    val p = LocalPalette.current
    BigCard {
        Row(Modifier.padding(20.dp), horizontalArrangement = Arrangement.spacedBy(16.dp)) {
            ToneCircle(tone, icon)
            Column {
                Text(title, style = MaterialTheme.typography.titleMedium, fontSize = 18.sp)
                Text(text, style = MaterialTheme.typography.bodyMedium, fontSize = 14.sp, color = p.mute)
            }
        }
    }
}

@Composable
fun QuietLine(text: String, icon: Int? = null) {
    val p = LocalPalette.current
    Row(Modifier.padding(horizontal = 6.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        icon?.let { Ph(it, Modifier.size(16.dp), tint = p.mute) }
        Text(text, style = MaterialTheme.typography.bodySmall, fontSize = 14.sp, color = p.mute)
    }
}

// ---------- the last day: one capsule per machine, half hours in the same state merged into one stretch ----------

private fun stateColor(p: Palette, c: String): Color = when (c) {
    "warn" -> p.amber.solid
    "bad" -> p.rose.solid
    "off" -> p.line.copy(alpha = 0.55f)
    "none" -> p.bg2
    else -> p.sage.solid
}

@Composable
fun Strip(cells: List<String>, key: String, row: Int = 0, label: String) {
    val p = LocalPalette.current
    val seen = LocalSeen.current
    val reduced = LocalReducedMotion.current
    val done = reduced || seen.containsKey("strip$key")
    val k = remember(key) { Animatable(if (done) 1f else 0f) }
    LaunchedEffect(key) {
        seen["strip$key"] = 1
        if (!done) {
            kotlinx.coroutines.delay(row * 50L)
            k.animateTo(1f, tween(700, easing = Ease))
        }
    }
    val runs = remember(cells) {
        buildList {
            var start = 0
            for (i in 1..cells.size) if (i == cells.size || cells[i] != cells[start]) { add(Triple(start, i, cells[start])); start = i }
        }
    }
    val spoken = remember(runs) {
        runs.joinToString(", ") { (a, b, c) ->
            val word = when (c) { "warn" -> "slow"; "bad" -> "down"; "off" -> "not expected"; "none" -> "no data"; else -> "fine" }
            "$word for ${(b - a) / 2.0} h".replace(".0 h", " h")
        }
    }
    Canvas(Modifier.fillMaxWidth().height(10.dp).clearAndSetSemantics { contentDescription = "$label, the last day: $spoken" }) {
        val h = size.height
        val unit = size.width / cells.size
        val gap = 2.dp.toPx()
        val shown = size.width * k.value
        val bar = androidx.compose.ui.graphics.Path().apply { addRoundRect(androidx.compose.ui.geometry.RoundRect(0f, 0f, size.width, h, CornerRadius(h / 2))) }
        clipPath(bar) {
            clipRect(right = shown) {
                runs.forEachIndexed { n, (a, b, c) ->
                    val l = a * unit + if (n > 0) gap / 2 else 0f
                    val r = b * unit - if (n < runs.lastIndex) gap / 2 else 0f
                    drawRect(stateColor(p, c), Offset(l, 0f), Size(r - l, h))
                }
            }
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
fun Legend() {
    val p = LocalPalette.current
    FlowRow(horizontalArrangement = Arrangement.spacedBy(14.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        listOf("Fine" to "ok", "Slow" to "warn", "Down" to "bad", "Not expected" to "off").forEach { (w, c) ->
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Box(Modifier.size(16.dp, 8.dp).clip(RoundedCornerShape(99.dp)).background(stateColor(p, c)))
                Text(w, style = MaterialTheme.typography.bodySmall, color = p.mute)
            }
        }
    }
}

@Composable
fun Axis(vararg words: String) {
    Row(Modifier.fillMaxWidth().padding(top = 6.dp), horizontalArrangement = Arrangement.SpaceBetween) {
        words.forEach { Text(it, fontFamily = Figtree, fontSize = 12.sp, color = LocalPalette.current.mute) }
    }
}

// ---------- meters and the chart ----------

@Composable
fun MeterBar(fraction: Float, color: Color, key: String) {
    val p = LocalPalette.current
    val seen = LocalSeen.current
    val reduced = LocalReducedMotion.current
    val k = remember(key) { Animatable(if (reduced || seen.containsKey("m$key")) 1f else 0f) }
    LaunchedEffect(key) { seen["m$key"] = 1; k.animateTo(1f, tween(800, easing = Ease)) }
    Canvas(Modifier.fillMaxWidth().height(8.dp)) {
        val r = CornerRadius(size.height / 2)
        drawRoundRect(p.bg2, cornerRadius = r)
        drawRoundRect(color, size = Size(size.width * fraction.coerceIn(0f, 1f) * k.value, size.height), cornerRadius = r)
    }
}

@Composable
fun MeterView(m: MeterRow, key: String) {
    val p = LocalPalette.current
    Column(Modifier.clearAndSetSemantics { contentDescription = m.spoken }, verticalArrangement = Arrangement.spacedBy(5.dp)) {
        Row(Modifier.fillMaxWidth()) {
            Text(m.label + (m.subject?.let { " $it" } ?: ""), style = MaterialTheme.typography.bodySmall, color = p.mute, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
            Text("${m.percent}%", fontFamily = Figtree, fontSize = 12.5.sp, fontWeight = FontWeight.Medium, color = if (m.isHot) p.amber.ink else p.ink2)
        }
        MeterBar(m.fraction, if (m.isHot) p.amber.solid else p.sage.solid, key)
    }
}

@Composable
fun Bars(values: List<Double?>, key: String, label: String) {
    val p = LocalPalette.current
    val seen = LocalSeen.current
    val reduced = LocalReducedMotion.current
    val present = values.filterNotNull()
    val hi = present.maxOrNull() ?: 0.0
    val total = values.size * 18 + 600
    val k = remember(key) { Animatable(if (reduced || seen.containsKey("c$key")) 1f else 0f) }
    LaunchedEffect(key) { seen["c$key"] = 1; k.animateTo(1f, tween(total, easing = LinearEasing)) }
    Canvas(
        Modifier.fillMaxWidth().height(88.dp)
            .clearAndSetSemantics { contentDescription = "$label over the last ${values.size} hours" + (present.lastOrNull()?.let { ", latest ${Math.round(it)}" } ?: "") },
    ) {
        if (hi <= 0.0 || values.isEmpty()) return@Canvas
        val g = 2.dp.toPx()
        val w = (size.width - g * (values.size - 1)) / values.size
        values.forEachIndexed { i, v ->
            if (v == null) return@forEachIndexed
            val local = if (k.value >= 1f) 1f else ((k.value - i * 18f / total) * total / 600f).coerceIn(0f, 1f)
            val h = maxOf(6.dp.toPx(), size.height * (v / hi).toFloat()) * Ease.transform(local)
            val last = i == values.lastIndex
            drawRoundRect(if (last) p.brand else p.mute.copy(alpha = 0.55f), Offset(i * (w + g), size.height - h), Size(w, h), CornerRadius(3.dp.toPx()))
        }
    }
}

// ---------- the floating tab bar ----------

// iOS 27 tab bar lens motion, built to the measured native behaviour: a 0.4 s spring with a little bounce
// carries the lens; on the tap it lifts (16 dp larger, clear glass, magnifying what it passes over), leans into
// the move, drops back once nearly there, squashes on landing in proportion to the distance and wobbles once;
// the whole bar swells briefly. Pressing and dragging lifts it under the finger; letting go picks that tab.
const val TRAVEL_DAMPING = 0.85f
const val TRAVEL_STIFFNESS = 247f
private val travelSpring = spring<Float>(dampingRatio = TRAVEL_DAMPING, stiffness = TRAVEL_STIFFNESS)
private val liftSpring = spring<Float>(dampingRatio = 1f, stiffness = 632f)
private val settleSpring = spring<Float>(dampingRatio = 0.42f, stiffness = 320f)

/** A row of choices with the glass lens over the chosen one. The tab bar and the segmented switches share it. */
@Composable
fun GlassSelector(
    count: Int,
    selected: Int,
    onSelect: (Int) -> Unit,
    modifier: Modifier = Modifier,
    shape: androidx.compose.ui.graphics.Shape,
    lensShape: androidx.compose.ui.graphics.Shape,
    inset: Dp,
    surface: Modifier.() -> Modifier,
    lensRestColor: Color,
    item: @Composable RowScope.(i: Int, near: Float, grow: Float) -> Unit,
) {
    val p = LocalPalette.current
    val reduced = LocalReducedMotion.current
    val density = LocalDensity.current
    val scope = rememberCoroutineScope()
    val pos = remember { Animatable(selected.coerceAtLeast(0).toFloat()) }
    val lift = remember { Animatable(0f) }
    val lean = remember { Animatable(0f) }
    val squash = remember { Animatable(0f) }
    val swell = remember { Animatable(0f) }
    var unitPx by remember { mutableFloatStateOf(1f) }
    var dragging by remember { mutableStateOf(false) }

    fun land(distancePx: Float) {
        scope.launch { lift.animateTo(0f, liftSpring) }
        if (reduced) return
        val dp = distancePx / density.density
        scope.launch {
            squash.snapTo(if (dp < 8f) 0f else 0.04f + 0.11f * ((dp - 64f) / 194f).coerceIn(0f, 1f))
            squash.animateTo(0f, settleSpring)
        }
    }

    LaunchedEffect(selected) {
        if (selected < 0 || dragging) return@LaunchedEffect
        val to = selected.toFloat()
        val distance = kotlin.math.abs(to - pos.value) * unitPx
        if (reduced) {
            pos.snapTo(to); lift.snapTo(0f)
            return@LaunchedEffect
        }
        coroutineScope {
            if (distance > 1f) {
                launch { lift.animateTo(1f, liftSpring) }
                launch { lean.animateTo(1f, tween(130, easing = Ease)); lean.animateTo(0f, travelSpring) }
                launch { swell.animateTo(1f, tween(130, easing = Ease)); swell.animateTo(0f, spring(dampingRatio = 0.6f, stiffness = 420f)) }
            }
            var landed = false
            pos.animateTo(to, travelSpring) {
                if (!landed && kotlin.math.abs(value - to) * unitPx < 3.5f * density.density) {
                    landed = true
                    land(distance)
                }
            }
            if (!landed) land(distance)
        }
    }

    val swellScale = 1f + swell.value * with(density) { 9.dp.toPx() } / (unitPx * count).coerceAtLeast(1f)
    val liftPx = with(density) { 16.dp.toPx() }
    // One shape and one motion, drawn in two layers: the resting fill and shadow under the labels so they stay
    // readable, and the clear glass (rim and a faint sheen) over them.
    val lens: Modifier = Modifier.layout { m, c ->
        val pad = inset.toPx()
        val w = (unitPx + liftPx * lift.value).roundToInt()
        val h = (c.maxHeight - 2 * pad + liftPx * lift.value).roundToInt()
        val pl = m.measure(androidx.compose.ui.unit.Constraints.fixed(w, h))
        val cx = pad + (pos.value + 0.5f) * unitPx
        layout(c.maxWidth, c.maxHeight) { pl.place((cx - w / 2f).roundToInt(), ((c.maxHeight - h) / 2f).roundToInt()) }
    }.graphicsLayer {
        scaleX = 1f + 0.12f * lean.value - squash.value
        scaleY = 1f - 0.16f * lean.value + squash.value * 0.6f
    }
    val rim = if (p.dark) Color.White.copy(alpha = 0.30f) else Color.White
    Box(modifier.graphicsLayer { scaleX = swellScale; scaleY = swellScale }) {
        Box(Modifier.matchParentSize().surface().clip(shape))
        Box(
            Modifier.matchParentSize().then(lens)
                .shadow((1 + 10 * lift.value).dp, lensShape, ambientColor = p.ink.copy(alpha = 0.16f), spotColor = p.ink.copy(alpha = 0.20f))
                .clip(lensShape)
                .background(lensRestColor.copy(alpha = lensRestColor.alpha * (1f - lift.value))),
        )
        Row(
            Modifier.fillMaxWidth().padding(inset)
                .onSizeChanged { unitPx = it.width / count.toFloat() }
                .pointerInput(count) {
                    detectHorizontalDragGestures(
                        onDragStart = { o ->
                            dragging = true
                            scope.launch { lift.animateTo(1f, liftSpring) }
                            scope.launch { pos.animateTo((o.x / unitPx - 0.5f).coerceIn(0f, count - 1f), spring(dampingRatio = 0.9f, stiffness = 900f)) }
                        },
                        onHorizontalDrag = { c, dx ->
                            c.consume()
                            scope.launch { pos.snapTo((pos.value + dx / unitPx).coerceIn(0f, count - 1f)) }
                        },
                        onDragEnd = {
                            val i = Math.round(pos.value).coerceIn(0, count - 1)
                            dragging = false
                            scope.launch { pos.animateTo(i.toFloat(), travelSpring) }
                            land(unitPx * 0.5f)
                            if (i != selected) onSelect(i)
                        },
                        onDragCancel = { dragging = false; land(0f) },
                    )
                },
        ) {
            for (i in 0 until count) {
                val near = (1f - kotlin.math.abs(pos.value - i)).coerceIn(0f, 1f)
                item(i, near, 1f + 0.16f * lift.value * near)
            }
        }
        Box(
            Modifier.matchParentSize().then(lens)
                .clip(lensShape)
                .background(Brush.verticalGradient(listOf(Color.White.copy(alpha = if (p.dark) 0.08f else 0.18f), Color.Transparent)))
                .border(1.dp, Brush.verticalGradient(listOf(rim, rim.copy(alpha = 0.12f), p.ink.copy(alpha = 0.10f))), lensShape),
        )
    }
}

@Composable
fun FloatingNav(tab: Int, onTab: (Int) -> Unit, modifier: Modifier = Modifier) {
    val p = LocalPalette.current
    val tabs = listOf("Home" to R.drawable.ic_ph_house, "Servers" to R.drawable.ic_ph_hard_drives, "Settings" to R.drawable.ic_ph_gear)
    val shape = RoundedCornerShape(26.dp)
    GlassSelector(
        tabs.size, tab, onTab,
        modifier.navigationBarsPadding().padding(start = 12.dp, end = 12.dp, bottom = 8.dp).fillMaxWidth().widthIn(max = 520.dp),
        shape = shape, lensShape = RoundedCornerShape(50), inset = 4.dp,
        surface = {
            shadow(18.dp, shape, ambientColor = p.ink.copy(alpha = 0.12f), spotColor = p.ink.copy(alpha = 0.14f))
                .clip(shape).background(p.panel).border(1.dp, p.line.copy(alpha = 0.7f), shape)
        },
        lensRestColor = p.brandSoft,
    ) { i, near, grow ->
        val (label, icon) = tabs[i]
        Column(
            Modifier.weight(1f).heightIn(min = 60.dp)
                .clickable(remember { MutableInteractionSource() }, null, role = Role.Tab, onClickLabel = label) { onTab(i) }
                .semantics { selected = tab == i },
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center,
        ) {
            Ph(icon, Modifier.size(22.dp).graphicsLayer { scaleX = grow; scaleY = grow }, tint = lerp(p.mute, p.brand, near))
            Text(label, style = MaterialTheme.typography.labelMedium, fontSize = 12.5.sp, color = lerp(p.mute, p.ink, near),
                modifier = Modifier.padding(top = 2.dp).graphicsLayer { scaleX = grow; scaleY = grow })
        }
    }
}

@Composable
fun FlagsRow(flags: List<Flag>) {
    @OptIn(ExperimentalLayoutApi::class)
    FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) { flags.forEach { Tag(it.text, it.tone, onPanel = true) } }
}

@Composable
fun ScreenWidthCompact(): Boolean = LocalConfiguration.current.screenWidthDp < 380 || LocalConfiguration.current.fontScale > 1.3f
