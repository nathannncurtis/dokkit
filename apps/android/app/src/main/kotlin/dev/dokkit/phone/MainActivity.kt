package dev.dokkit.phone

import android.content.pm.ApplicationInfo
import android.graphics.Color
import android.os.Bundle
import android.os.SystemClock
import android.view.WindowManager
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricManager.Authenticators.BIOMETRIC_WEAK
import androidx.biometric.BiometricManager.Authenticators.DEVICE_CREDENTIAL
import androidx.biometric.BiometricPrompt
import androidx.compose.runtime.LaunchedEffect
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import dev.dokkit.phone.ui.AppRoot
import dev.dokkit.phone.ui.DokkitTheme
import dev.dokkit.phone.ui.LocalPalette
import dev.dokkit.phone.ui.LockCover

class MainActivity : FragmentActivity() {
    private val vm: AppViewModel by viewModels()
    private var prompting = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Debug builds allow screenshots so the design can be checked on an emulator.
        if (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE == 0) {
            window.setFlags(WindowManager.LayoutParams.FLAG_SECURE, WindowManager.LayoutParams.FLAG_SECURE)
        }
        enableEdgeToEdge()
        setContent {
            DokkitTheme(vm.settings.theme) {
                val dark = LocalPalette.current.dark
                LaunchedEffect(dark) {
                    val bars = if (dark) SystemBarStyle.dark(Color.TRANSPARENT) else SystemBarStyle.light(Color.TRANSPARENT, Color.TRANSPARENT)
                    enableEdgeToEdge(bars, bars)
                }
                if (vm.unlocked) AppRoot(vm) else LockCover(vm.lockMessage) { unlock() }
            }
        }
    }

    override fun onStart() {
        super.onStart()
        val away = SystemClock.elapsedRealtime() - vm.stoppedAt
        if (vm.stoppedAt > 0 && away >= vm.settings.lockAfter.seconds * 1000) vm.unlocked = false
        unlock()
    }

    override fun onStop() {
        super.onStop()
        if (isChangingConfigurations) return
        vm.stoppedAt = SystemClock.elapsedRealtime()
        if (vm.settings.lockAfter.seconds == 0L) vm.unlocked = false
    }

    private fun unlock() {
        if (prompting || vm.unlocked) return
        val allowed = BIOMETRIC_WEAK or DEVICE_CREDENTIAL
        if (BiometricManager.from(this).canAuthenticate(allowed) != BiometricManager.BIOMETRIC_SUCCESS) {
            vm.lockMessage = "Set a screen lock on this phone to use Dokkit."
            return
        }
        prompting = true
        val callback = object : BiometricPrompt.AuthenticationCallback() {
            override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                prompting = false
                vm.lockMessage = null
                vm.unlocked = true
            }

            override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                prompting = false
                vm.lockMessage = "Dokkit stayed locked."
            }
        }
        val info = BiometricPrompt.PromptInfo.Builder().setTitle("Open Dokkit").setAllowedAuthenticators(allowed).build()
        BiometricPrompt(this, ContextCompat.getMainExecutor(this), callback).authenticate(info)
    }
}
