# Plan: Android phone

Goal: run the Android app on phones with layouts for small portrait/landscape screens.

1. Start from `android/`, reusing the shared `core/` package. The Swift engine is the
   same child process; only the Compose UI needs phone layouts.
2. The tablet UI assumes a large landscape screen: the sea screen (HUD, helm pad, minimap), the walking town and the big
   window panels (trade, tavern, shipyard, harbour, fleet sheet, coast sheet) need compact versions.
3. Reuse the shared UI pieces in `Ui.kt` (touch-target size, one slider, cards) and add `WindowSizeClass`-based layouts.
4. Test on small and large phones, both orientations, with the system font scaled up.
5. Keep the game data out of the repository; the default APK excludes it. APKs built with the explicit private-assets option must never be published.

Phone layouts remain planned; this source repository already shares one engine and tablet client.
