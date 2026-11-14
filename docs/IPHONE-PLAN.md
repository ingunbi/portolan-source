# Plan: iPhone

Goal: run the iPad app on iPhone with layouts that work on a small portrait/landscape screen and with touch controls.

1. Start from `ipad/`, reusing the shared `core/` package. The SwiftUI code is shared with the Mac and iPad
   versions; keep it identical where you can, and put phone-only views behind size classes.
2. Allow iPhone in the generated Xcode project (`ipad/ios/make_project.py`: `TARGETED_DEVICE_FAMILY`), then fix what breaks:
   - the sea screen (HUD, helm, minimap) and the walking town need compact layouts and larger touch targets;
   - building windows (trade, tavern, shipyard, harbour, fleet sheet) are designed for a large window: use sheets that fit
     a phone and scroll;
   - the Android tablet app's recent work on control sizes (48 pt minimum targets, one slider style) is a good model.
3. Test on a real phone and in the simulator (small and large iPhones, both orientations, Dynamic Type).
4. Keep the game data out of the repository, as in the current tablet clients (`.gitignore` already lists it).

Phone layouts remain planned; a universal UI can be developed here without copying the shared core.
