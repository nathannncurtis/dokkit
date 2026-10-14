package dev.dokkit.phone.core

sealed class PairingError(message: String) : Exception(message) {
    data object NotACode : PairingError("This is not a Dokkit pairing code.")
    data object NewerVersion : PairingError("This code is from a newer Dokkit than this app understands.")
    data object Damaged : PairingError("The pairing code is damaged. Show a new one in Settings, Phones.")
    data object RelayNotHttps : PairingError("The relay address in this code is not https, so the app refuses it.")
    data object BadToken : PairingError("The fetch token in this code does not pass its checksum.")
    data object BadKey : PairingError("The phone key in this code is not valid.")
}

sealed class SealError(message: String) : Exception(message) {
    data object NotOpened :
        SealError("The snapshot could not be opened. The key on this phone may no longer match the server; pair the phone again.")

    data object Older :
        SealError("The relay sent an older snapshot than the newest one already opened, so it was ignored.")
}

sealed class RelayError(message: String) : Exception(message) {
    data object NotHttps : RelayError("The relay address is not https, so the app did not contact it.")
    data object NotFound : RelayError("The relay does not know this phone. It may have been removed in Dokkit; pair it again.")
    data class RateLimited(val retryAfter: Int?) :
        RelayError("The relay says this phone is asking too often" + (retryAfter?.let { "; try again in $it seconds." } ?: "."))

    data class Status(val code: Int) : RelayError("The relay answered with an error ($code).")
    data object BadAnswer : RelayError("The relay sent an answer the app could not read.")
    data class Network(val detail: String) : RelayError("The relay could not be reached ($detail).")
}
