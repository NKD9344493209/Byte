plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.naveen.byteapp"
    compileSdk = flutter.compileSdkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // java.time on old Androids (plugins use it)
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.naveen.byteapp"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        multiDexEnabled = true
        // 64-bit ARM only (every Android phone since ~2017): a smaller APK.
        // Build with: flutter build apk --release --target-platform android-arm64
        ndk { abiFilters += listOf("arm64-v8a") }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
            // R8 shrinks the Java/Kotlin side (ML Kit, Play services, ExoPlayer…).
            // Everything reached by name — plugin channels, Gson models, JNI — is
            // kept by proguard-rules.pro. If the app ever dies at boot after a new
            // plugin is added, add that plugin's package to proguard-rules.pro;
            // switching both flags to false is the emergency rollback.
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

// ML Kit text recognition ships five script packs; BYTE reads Latin only
// (Tamil is not supported by ML Kit at all). Dropping the other four saves
// tens of MB — the plugin's README documents exactly this exclusion.
configurations.all {
    exclude(group = "com.google.mlkit", module = "text-recognition-chinese")
    exclude(group = "com.google.mlkit", module = "text-recognition-devanagari")
    exclude(group = "com.google.mlkit", module = "text-recognition-japanese")
    exclude(group = "com.google.mlkit", module = "text-recognition-korean")
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    // AppCompat theme parents (local_auth biometric prompt)
    implementation("androidx.appcompat:appcompat:1.7.0")
    // ContextCompat / core helpers used by the native side
    implementation("androidx.core:core:1.13.1")
    // Avoids a crash on Android 12L+ with desugaring (flutter/flutter#110658)
    implementation("androidx.window:window:1.0.0")
    implementation("androidx.window:window-java:1.0.0")
}
