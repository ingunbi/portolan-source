package app.portolan

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue

/** A mirror of what the engine reports of the purse and the hold (the engine owns the numbers). */
class Wallet {
    var gold by mutableIntStateOf(300)
    var lumber by mutableIntStateOf(0)
    var shot by mutableIntStateOf(0)
    /** Guns on the flagship (the shipyard fits them). */
    var guns by mutableIntStateOf(0)
    var cargoSpace = 80
    var message by mutableStateOf<String?>(null)
}
