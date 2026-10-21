package dev.dokkit.phone.ui

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.ImageFormat
import android.graphics.Matrix
import android.graphics.SurfaceTexture
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureRequest
import android.media.ImageReader
import android.os.Handler
import android.os.HandlerThread
import android.util.Size
import android.view.Surface
import android.view.TextureView
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import com.google.zxing.BarcodeFormat
import com.google.zxing.BinaryBitmap
import com.google.zxing.DecodeHintType
import com.google.zxing.MultiFormatReader
import com.google.zxing.PlanarYUVLuminanceSource
import com.google.zxing.ReaderException
import com.google.zxing.common.HybridBinarizer
import java.util.concurrent.atomic.AtomicBoolean

/** The back camera through the platform's Camera2 API, decoding QR codes from its frames. */
private class QrCamera(private val context: Context, private val onCode: (String) -> Unit, private val onFail: () -> Unit) {
    private val thread = HandlerThread("qr-camera").apply { start() }
    private val handler = Handler(thread.looper)
    private val main = ContextCompat.getMainExecutor(context)
    private val busy = AtomicBoolean(false)
    private val reader = MultiFormatReader().apply {
        setHints(mapOf(DecodeHintType.POSSIBLE_FORMATS to listOf(BarcodeFormat.QR_CODE), DecodeHintType.TRY_HARDER to true))
    }
    private var device: CameraDevice? = null
    private var session: CameraCaptureSession? = null
    private var frames: ImageReader? = null
    private var last: String? = null
    private var closed = false

    fun fail() = main.execute { if (!closed) onFail() }

    @SuppressLint("MissingPermission")
    fun open(texture: SurfaceTexture, view: TextureView) {
        try {
            val manager = context.getSystemService(CameraManager::class.java)
            val id = manager.cameraIdList.firstOrNull {
                manager.getCameraCharacteristics(it).get(CameraCharacteristics.LENS_FACING) == CameraCharacteristics.LENS_FACING_BACK
            } ?: return fail()
            val map = manager.getCameraCharacteristics(id).get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP) ?: return fail()
            val size = closest(map.getOutputSizes(ImageFormat.YUV_420_888), 1280, 720) ?: return fail()
            val preview = closest(map.getOutputSizes(SurfaceTexture::class.java), size.width, size.height) ?: size
            texture.setDefaultBufferSize(preview.width, preview.height)
            main.execute { cover(view, preview) }
            val images = ImageReader.newInstance(size.width, size.height, ImageFormat.YUV_420_888, 2).also { frames = it }
            images.setOnImageAvailableListener({ decode(it) }, handler)
            manager.openCamera(id, object : CameraDevice.StateCallback() {
                override fun onOpened(d: CameraDevice) {
                    if (closed) return d.close()
                    device = d
                    start(d, Surface(texture), images.surface)
                }

                override fun onDisconnected(d: CameraDevice) {
                    d.close()
                }

                override fun onError(d: CameraDevice, error: Int) {
                    d.close()
                    fail()
                }
            }, handler)
        } catch (e: Exception) {
            fail()
        }
    }

    private fun start(d: CameraDevice, screen: Surface, analysis: Surface) {
        try {
            @Suppress("DEPRECATION")
            d.createCaptureSession(listOf(screen, analysis), object : CameraCaptureSession.StateCallback() {
                override fun onConfigured(s: CameraCaptureSession) {
                    if (closed) return s.close()
                    session = s
                    val request = d.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW).apply {
                        addTarget(screen)
                        addTarget(analysis)
                        set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_PICTURE)
                    }.build()
                    runCatching { s.setRepeatingRequest(request, null, handler) }.onFailure { fail() }
                }

                override fun onConfigureFailed(s: CameraCaptureSession) = fail()
            }, handler)
        } catch (e: Exception) {
            fail()
        }
    }

    private fun decode(images: ImageReader) {
        val image = images.acquireLatestImage() ?: return
        if (!busy.compareAndSet(false, true)) return image.close()
        try {
            val plane = image.planes[0]
            val w = image.width
            val h = image.height
            val buf = plane.buffer
            val luma = ByteArray(w * h)
            for (row in 0 until h) {
                buf.position(row * plane.rowStride)
                buf.get(luma, row * w, w)
            }
            val text = reader.decodeWithState(BinaryBitmap(HybridBinarizer(PlanarYUVLuminanceSource(luma, w, h, 0, 0, w, h, false)))).text
            if (text != last) {
                last = text
                main.execute { if (!closed) onCode(text) }
            }
        } catch (e: ReaderException) {
            Unit
        } finally {
            reader.reset()
            image.close()
            busy.set(false)
        }
    }

    fun close() {
        closed = true
        handler.post {
            runCatching { session?.close() }
            runCatching { device?.close() }
            runCatching { frames?.close() }
            thread.quitSafely()
        }
    }

    // The camera's frames arrive upright but stretched to the view; scale them so they fill it without distortion.
    private fun cover(view: TextureView, preview: Size) {
        val vw = view.width.toFloat()
        val vh = view.height.toFloat()
        if (vw == 0f || vh == 0f) return
        val content = preview.height.toFloat() / preview.width
        val m = Matrix()
        if (vw / vh > content) m.setScale(1f, vw / content / vh, vw / 2, vh / 2) else m.setScale(vh * content / vw, 1f, vw / 2, vh / 2)
        view.setTransform(m)
    }

    private fun closest(sizes: Array<Size>?, w: Int, h: Int): Size? =
        sizes?.filter { it.width.toLong() * it.height <= 1920L * 1080 }?.minByOrNull { kotlin.math.abs(it.width * it.height - w * h) + kotlin.math.abs(it.width * h - it.height * w) / 100 }
}

@Composable
fun QrScanner(onCode: (String) -> Unit, modifier: Modifier = Modifier, onFail: () -> Unit = {}) {
    val ctx = LocalContext.current
    val camera = remember { QrCamera(ctx, onCode, onFail) }
    DisposableEffect(Unit) { onDispose { camera.close() } }
    AndroidView(
        modifier = modifier.semantics { contentDescription = "Camera view for scanning the QR code" },
        factory = { c ->
            TextureView(c).apply {
                surfaceTextureListener = object : TextureView.SurfaceTextureListener {
                    override fun onSurfaceTextureAvailable(s: SurfaceTexture, width: Int, height: Int) = camera.open(s, this@apply)
                    override fun onSurfaceTextureSizeChanged(s: SurfaceTexture, width: Int, height: Int) = Unit
                    override fun onSurfaceTextureDestroyed(s: SurfaceTexture): Boolean = true
                    override fun onSurfaceTextureUpdated(s: SurfaceTexture) = Unit
                }
            }
        },
    )
}
