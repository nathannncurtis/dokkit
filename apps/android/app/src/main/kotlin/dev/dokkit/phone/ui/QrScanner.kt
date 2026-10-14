package dev.dokkit.phone.ui

import android.util.Size
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleOwner
import com.google.zxing.BarcodeFormat
import com.google.zxing.BinaryBitmap
import com.google.zxing.DecodeHintType
import com.google.zxing.MultiFormatReader
import com.google.zxing.PlanarYUVLuminanceSource
import com.google.zxing.ReaderException
import com.google.zxing.common.HybridBinarizer
import java.util.concurrent.Executors

private class QrAnalyzer(private val onText: (String) -> Unit) : ImageAnalysis.Analyzer {
    private val reader = MultiFormatReader().apply {
        setHints(mapOf(DecodeHintType.POSSIBLE_FORMATS to listOf(BarcodeFormat.QR_CODE), DecodeHintType.TRY_HARDER to true))
    }

    override fun analyze(image: ImageProxy) {
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
            val bitmap = BinaryBitmap(HybridBinarizer(PlanarYUVLuminanceSource(luma, w, h, 0, 0, w, h, false)))
            onText(reader.decodeWithState(bitmap).text)
        } catch (e: ReaderException) {
            return
        } finally {
            reader.reset()
            image.close()
        }
    }
}

@Composable
fun QrScanner(onCode: (String) -> Unit, modifier: Modifier = Modifier) {
    val ctx = LocalContext.current
    val executor = remember { Executors.newSingleThreadExecutor() }
    val provider = remember { arrayOfNulls<ProcessCameraProvider>(1) }
    val last = remember { arrayOfNulls<String>(1) }
    DisposableEffect(Unit) {
        onDispose {
            provider[0]?.unbindAll()
            executor.shutdown()
        }
    }
    AndroidView(
        modifier = modifier.clip(RoundedCornerShape(10.dp))
            .semantics { contentDescription = "Camera view for scanning the QR code" },
        factory = { c ->
            PreviewView(c).also { view ->
                val future = ProcessCameraProvider.getInstance(c)
                future.addListener({
                    val cameraProvider = future.get()
                    provider[0] = cameraProvider
                    val preview = Preview.Builder().build().also { it.surfaceProvider = view.surfaceProvider }
                    val analysis = ImageAnalysis.Builder()
                        .setResolutionSelector(
                            ResolutionSelector.Builder()
                                .setResolutionStrategy(ResolutionStrategy(Size(1280, 720), ResolutionStrategy.FALLBACK_RULE_CLOSEST_HIGHER_THEN_LOWER))
                                .build(),
                        )
                        .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                        .build()
                    analysis.setAnalyzer(executor, QrAnalyzer { text ->
                        if (text != last[0]) {
                            last[0] = text
                            view.post { onCode(text) }
                        }
                    })
                    cameraProvider.unbindAll()
                    cameraProvider.bindToLifecycle(ctx as LifecycleOwner, CameraSelector.DEFAULT_BACK_CAMERA, preview, analysis)
                }, ContextCompat.getMainExecutor(c))
            }
        },
    )
}
