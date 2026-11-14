plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "app.portolan"
    compileSdk = 35
    defaultConfig {
        applicationId = "app.portolan.android"
        minSdk = 26
        targetSdk = 35
        versionCode = 1
        versionName = "0.1.0"
    }
    buildTypes { release { isMinifyEnabled = false } }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
    buildFeatures { compose = true }
    // The game's pictures and data come from core/assets. It is not in the repository:
    // extract it from your own copy of the original game with core/tools/build_assets.sh (see README).
    if (providers.gradleProperty("bundlePrivateAssets").orNull == "true") {
        // Personal builds only: never redistribute an APK containing these files.
        val localAssets = providers.gradleProperty("portolanAssets").orNull ?: "../../core/assets"
        sourceSets["main"].assets.srcDirs(localAssets)
    }
    androidResources { noCompress += listOf("tiles", "json", "png") }
    // The Swift rules run as a program shipped as a native library, so it must be unpacked on install.
    packaging { jniLibs { useLegacyPackaging = true } }
}

dependencies {
    implementation(platform("androidx.compose:compose-bom:2024.10.01"))
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.activity:activity-compose:1.9.3")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.1")
}
