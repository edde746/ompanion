import java.util.Properties
import org.gradle.api.artifacts.component.ModuleComponentIdentifier
import org.gradle.api.artifacts.result.ResolvedArtifactResult
import org.gradle.maven.MavenModule
import org.gradle.maven.MavenPomArtifact

plugins {
    id("com.android.application")
}

// VERSION (`<semver>+<build>`) is the app's only version: versionName is the semver, versionCode the build number.
val version = rootDir.resolve("../../VERSION").readText().trim().split("+")
if (version.size != 2) throw GradleException("VERSION is not <semver>+<build>: ${version.joinToString("+")}")

// The upload key: shells/android/key.properties (gitignored) with storePassword, keyPassword, keyAlias and storeFile
// (relative to shells/android/app), as the Flutter app's android/key.properties. CI writes it from the four Android
// secrets. Without it release builds are signed with the debug key, so a fork's build still installs for testing.
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties().apply {
    if (keystorePropertiesFile.exists()) keystorePropertiesFile.inputStream().use { load(it) }
}

fun keystoreProperty(name: String): String =
    keystoreProperties.getProperty(name) ?: throw GradleException("shells/android/key.properties has no $name.")

// Firebase's public client config for push (docs/contracts/push.md): shells/android/firebase.properties with the
// projectId, applicationId, apiKey and senderId of the Firebase console's Android app. Push.kt sets Firebase up from
// these in code, not the google-services plugin. Without the file the app builds and reports push as not configured.
val firebasePropertiesFile = rootProject.file("firebase.properties")
val firebaseProperties = Properties().apply {
    if (firebasePropertiesFile.exists()) firebasePropertiesFile.inputStream().use { load(it) }
}

fun firebaseField(name: String): String {
    if (!firebasePropertiesFile.exists()) return "\"\""
    val value =
        firebaseProperties.getProperty(name)
            ?: throw GradleException("shells/android/firebase.properties has no $name (docs/contracts/push.md).")
    return "\"$value\""
}

android {
    namespace = "com.edde746.ompanion"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.edde746.ompanion"
        minSdk = 24
        targetSdk = 36
        versionCode = version[1].toInt()
        versionName = version[0]

        buildConfigField("String", "FIREBASE_PROJECT_ID", firebaseField("projectId"))
        buildConfigField("String", "FIREBASE_APPLICATION_ID", firebaseField("applicationId"))
        buildConfigField("String", "FIREBASE_API_KEY", firebaseField("apiKey"))
        buildConfigField("String", "FIREBASE_SENDER_ID", firebaseField("senderId"))
    }

    buildFeatures {
        buildConfig = true
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
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"))
            signingConfig = signingConfigs.getByName(if (keystorePropertiesFile.exists()) "release" else "debug")
        }
    }

    // One APK with every ABI the core is built for and one with arm64 only. A bundle has its own per-ABI splits, and
    // AGP builds none while APK splits are on (https://issuetracker.google.com/402800800).
    splits {
        abi {
            isEnable = gradle.startParameter.taskNames.none { it.contains("bundle", ignoreCase = true) }
            reset()
            include("arm64-v8a")
            isUniversalApk = true
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

// Copies the built page into the APK's assets/ui/, where MainActivity's WebViewAssetLoader serves it: ui/dist, or the
// directory `-Pui=<path>` names (build.sh builds one per channel).
abstract class SyncUi : DefaultTask() {
    @get:InputDirectory
    abstract val dist: DirectoryProperty

    @get:OutputDirectory
    abstract val assets: DirectoryProperty

    @get:Inject
    abstract val files: FileSystemOperations

    @TaskAction
    fun sync() {
        files.sync {
            from(dist)
            into(assets.dir("ui"))
        }
    }
}

val syncUi = tasks.register<SyncUi>("syncUi") {
    dist = file(providers.gradleProperty("ui").getOrElse(rootDir.resolve("../../ui/dist").path))
}

androidComponents {
    onVariants { variant ->
        variant.sources.assets!!.addGeneratedSourceDirectory(syncUi, SyncUi::assets)
    }
}

// The Maven libraries the licences page lists (core/cmd/licenses, which build.sh runs on the page): every library on
// the release runtime classpath, one per line as `<group>:<artifact>:<version>\t<POM>\t<AAR or JAR>`.
tasks.register("licenseInputs") {
    val artifacts = configurations.named("releaseRuntimeClasspath").flatMap { it.incoming.artifacts.resolvedArtifacts }
    val handler = dependencies
    val list = rootDir.resolve("../../build/android/maven-libraries.tsv")
    doLast {
        val libraries = artifacts.get().filter { it.id.componentIdentifier is ModuleComponentIdentifier }
        val poms = handler.createArtifactResolutionQuery()
            .forComponents(libraries.map { it.id.componentIdentifier })
            .withArtifacts(MavenModule::class.java, MavenPomArtifact::class.java)
            .execute().resolvedComponents.associate { component ->
                val pom = component.getArtifacts(MavenPomArtifact::class.java).filterIsInstance<ResolvedArtifactResult>()
                component.id to pom.single().file
            }
        list.parentFile.mkdirs()
        list.writeText(libraries.joinToString("") {
            "${it.id.componentIdentifier.displayName}\t${poms.getValue(it.id.componentIdentifier)}\t${it.file}\n"
        })
    }
}

dependencies {
    implementation(files(rootDir.resolve("../../build/core/android/ompcore.aar")))
    implementation("androidx.activity:activity:1.13.0")
    implementation("androidx.webkit:webkit:1.18.0")
    implementation(platform("com.google.firebase:firebase-bom:34.19.0"))
    implementation("com.google.firebase:firebase-messaging")
    implementation("com.google.firebase:firebase-installations")
    // Play services' basement brings Fragment 1.1.0, and with it on the classpath lint fails the release build because
    // MainActivity uses the ActivityResult APIs (InvalidFragmentVersionForActivityResult). Nothing uses Fragment.
    implementation("androidx.fragment:fragment:1.7.1")
    testImplementation("junit:junit:4.13.2")
}
