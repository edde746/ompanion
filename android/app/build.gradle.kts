import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// The upload key lives in android/key.properties, which is gitignored (README, Releasing). CI writes it from the
// four Android secrets; on the maintainer's Mac it is kept by hand. Without it release builds are signed with the
// debug key, so an artifact built from a fork still installs for testing.
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties().apply {
    if (keystorePropertiesFile.exists()) keystorePropertiesFile.inputStream().use { load(it) }
}

fun keystoreProperty(name: String): String =
    keystoreProperties.getProperty(name)
        ?: throw GradleException("android/key.properties has no $name (README, Releasing).")

// Firebase's public client config for push (docs/contracts/push.md): android/firebase.properties with the
// projectId, applicationId, apiKey and senderId of the Firebase console's Android app. Firebase is set up in code
// from these (MainApplication), not by the google-services plugin. Without the file the app builds and reports push
// as not configured.
val firebasePropertiesFile = rootProject.file("firebase.properties")
val firebaseProperties = Properties().apply {
    if (firebasePropertiesFile.exists()) firebasePropertiesFile.inputStream().use { load(it) }
}

fun firebaseField(name: String): String {
    if (!firebasePropertiesFile.exists()) return "\"\""
    val value =
        firebaseProperties.getProperty(name)
            ?: throw GradleException("android/firebase.properties has no $name (docs/contracts/push.md).")
    return "\"$value\""
}

android {
    namespace = "com.edde746.ompanion"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // flutter_local_notifications requires desugaring (its README), even on Android, where the app never
        // initializes it.
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        buildConfig = true
    }

    defaultConfig {
        applicationId = "com.edde746.ompanion"
        // Flutter 3.47.1's defaults: compileSdk 36, targetSdk 36, minSdk 24. Google Play requires new apps and
        // updates to target API 36 from 31 August 2026, so the defaults are already what the stores want
        // (https://developer.android.com/google/play/requirements/target-sdk).
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        buildConfigField("String", "FIREBASE_PROJECT_ID", firebaseField("projectId"))
        buildConfigField("String", "FIREBASE_APPLICATION_ID", firebaseField("applicationId"))
        buildConfigField("String", "FIREBASE_API_KEY", firebaseField("apiKey"))
        buildConfigField("String", "FIREBASE_SENDER_ID", firebaseField("senderId"))
    }

    signingConfigs {
        create("release") {
            if (keystorePropertiesFile.exists()) {
                keyAlias = keystoreProperty("keyAlias")
                keyPassword = keystoreProperty("keyPassword")
                storePassword = keystoreProperty("storePassword")
                storeFile = file(keystoreProperty("storeFile"))
            }
        }
    }

    buildTypes {
        release {
            // key.properties present: the upload key, which is what the stores accept. Absent: the debug key, so
            // `flutter run --release` and a fork's CI still produce something installable.
            signingConfig =
                if (keystorePropertiesFile.exists()) {
                    signingConfigs.getByName("release")
                } else {
                    signingConfigs.getByName("debug")
                }
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

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    implementation(platform("com.google.firebase:firebase-bom:34.19.0"))
    implementation("com.google.firebase:firebase-messaging")
    implementation("com.google.firebase:firebase-installations")
    testImplementation("junit:junit:4.13.2")
}
