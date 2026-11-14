import Foundation

/// What Joan's opening chapter (SNR1.DAT) hands the player before the first voyage.
/// The town scenes themselves are not implemented yet, so their outcome is applied here.
public enum Prologue {
    /// Ordered by the duke at script 0x25C (`F9 05 05`), a lateen caravel.
    public static let joanShipClass = 5
    /// Script 0x5CD `FA 05 0084`: the ship takes the name in scenario line 132.
    public static let joanShipName = "헤르메스Ⅱ세"
    /// Carlotta's 1000 coins from the duke (script 0x391, `0C 0003E8` then `E6`). The priest's
    /// 1000 (0x47F) is optional and the monthly allowance (0x96E) comes later, so neither is added.
    public static let joanRequiredGold = 1000
    // The ship is delivered without crew; Joan signs sailors at the Lisbon tavern.
}
