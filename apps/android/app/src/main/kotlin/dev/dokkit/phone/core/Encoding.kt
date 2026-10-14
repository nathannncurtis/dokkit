package dev.dokkit.phone.core

import java.util.Base64
import java.util.zip.CRC32

object B64 {
    fun decode(s: String): ByteArray? = try {
        Base64.getDecoder().decode(s)
    } catch (e: IllegalArgumentException) {
        null
    }

    fun decodeUrl(s: String): ByteArray? = try {
        Base64.getUrlDecoder().decode(s)
    } catch (e: IllegalArgumentException) {
        null
    }
}

object KeyCheck {
    private const val ALPHABET = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"

    fun isValid(key: String, prefix: String): Boolean {
        if (!key.startsWith(prefix)) return false
        val rest = key.substring(prefix.length)
        if (rest.length != 36 || rest.any { it !in ALPHABET }) return false
        var n = CRC32().apply { update(rest.substring(0, 30).toByteArray(Charsets.US_ASCII)) }.value
        val tail = CharArray(6)
        for (i in 5 downTo 0) {
            tail[i] = ALPHABET[(n % 62).toInt()]
            n /= 62
        }
        return rest.substring(30) == String(tail)
    }
}

fun isLowerHex32(s: String): Boolean = s.length == 32 && s.all { it in '0'..'9' || it in 'a'..'f' }
