# BYTE — keep everything that is reached by name (reflection, JNI, method
# channels, Gson) so R8 can shrink the rest without breaking boot.

# Flutter engine + plugins
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }
-dontwarn io.flutter.embedding.**

# BYTE's own native code (the activity and its channels)
-keep class com.naveen.byteapp.** { *; }

# Gson models reached by reflection (plugins)
-keepclassmembers class * implements java.io.Serializable { *; }
-keep class com.google.gson.** { *; }
# R8 full mode (AGP 8+) strips TypeToken's generic signature unless its
# subclasses are kept.
-keep class com.google.gson.reflect.TypeToken
-keep class * extends com.google.gson.reflect.TypeToken
-keep public class * implements java.lang.reflect.Type
-keepattributes Signature, *Annotation*, EnclosingMethod, InnerClasses

# Plugins that live outside io.flutter.plugins and are reached by name
# (WorkManager instantiates its Worker by class name; the rest are cheap insurance).
-keep class dev.fluttercommunity.workmanager.** { *; }
-keep class be.tramckrijte.workmanager.** { *; }
-keep class dev.fluttercommunity.plus.share.** { *; }
-keep class com.it_nomads.fluttersecurestorage.** { *; }
-keep class com.tekartik.sqflite.** { *; }
-keep class com.mr.flutter.plugin.filepicker.** { *; }
-keep class com.crazecoder.openfile.** { *; }
-keep class com.google_mlkit_** { *; }

# ML Kit (text, image labeling) and Play services
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.** { *; }
-dontwarn com.google.mlkit.**
-dontwarn com.google.android.gms.**

# WorkManager, record, audioplayers, video_player (ExoPlayer/media3)
-keep class androidx.work.** { *; }
-keep class com.llfbandit.record.** { *; }
-keep class xyz.luan.audioplayers.** { *; }
-keep class androidx.media3.** { *; }
-dontwarn androidx.media3.**

# Google Sign-In
-keep class com.google.android.libraries.identity.** { *; }
-dontwarn com.google.android.libraries.identity.**

# Kotlin. Several first-party plugins (shared_preferences, path_provider,
# url_launcher…) call their Kotlin side from native code by EXACT method
# signature, and those signatures contain Kotlin types (kotlin.coroutines.
# Continuation, kotlin.Unit, kotlin.jvm.functions.*). If R8 renames any of
# them the lookup fails at boot with NoSuchMethodError. So: Kotlin classes
# may be removed when unused, but never renamed, and coroutines are kept whole.
-keepnames class kotlin.** { *; }
-keep class kotlin.coroutines.** { *; }
-keep class kotlinx.coroutines.** { *; }
-keep class kotlin.Metadata { *; }
-keep class kotlin.Unit { *; }
-keep class kotlin.jvm.functions.** { *; }
-dontwarn kotlin.**
-dontwarn kotlinx.**
-dontwarn org.jetbrains.annotations.**

# JNI: anything with a native method keeps its exact name and signature.
-keepclasseswithmembernames,includedescriptorclasses class * {
    native <methods>;
}
# Method signatures that native code looks up must keep their descriptor types.
-keepclassmembers,includedescriptorclasses class io.flutter.plugins.** { *; }
-keepclassmembers,includedescriptorclasses class dev.flutter.** { *; }
-keep class dev.flutter.** { *; }

# Play Core split-install classes referenced by Flutter's deferred components (not used)
-dontwarn com.google.android.play.core.**
