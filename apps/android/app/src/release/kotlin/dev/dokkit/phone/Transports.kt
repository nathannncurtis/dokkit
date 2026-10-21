package dev.dokkit.phone

import android.content.Context
import dev.dokkit.phone.core.HttpsTransport
import dev.dokkit.phone.core.Transport

fun appTransport(context: Context, timeoutMs: () -> Int): Transport = HttpsTransport(timeoutMs)
