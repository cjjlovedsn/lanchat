import java.io.FileInputStream
import java.util.Properties
import java.security.KeyStore
import java.security.MessageDigest

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Committed release keystore (personal project): CI and local builds must
// produce the same signature or Android refuses updates with a
// "signature mismatch" error. Never silently sign a release with a debug key.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "local.lanchat"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        applicationId = "local.lanchat"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            if (keystorePropertiesFile.exists()) {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        debug {
            applicationIdSuffix = ".debug"
            versionNameSuffix = "-debug"
        }
        release {
            signingConfig = signingConfigs.getByName("release")
        }
    }
}

flutter {
    source = "../.."
}

// Fail before packaging rather than distributing an APK signed by a temporary
// per-machine key. Debug builds remain available without release credentials.
tasks.matching { it.name == "validateSigningRelease" }.configureEach {
    doFirst {
        require(keystorePropertiesFile.isFile) {
            "Missing android/key.properties. Release APKs must use the fixed LanChat release key."
        }
        listOf("keyAlias", "keyPassword", "storeFile", "storePassword").forEach { name ->
            require(!keystoreProperties.getProperty(name).isNullOrBlank()) {
                "Missing release signing property: $name"
            }
        }
        val keyFile = file(keystoreProperties.getProperty("storeFile"))
        require(keyFile.isFile) {
            "Release keystore is missing. Do not generate a replacement key for an existing app."
        }
        val keys = KeyStore.getInstance(keyFile, keystoreProperties.getProperty("storePassword").toCharArray())
        val certificate = keys.getCertificate(keystoreProperties.getProperty("keyAlias"))
            ?: error("Release certificate is missing")
        val fingerprint = MessageDigest.getInstance("SHA-256").digest(certificate.encoded)
            .joinToString("") { "%02x".format(it) }
        val expected = rootProject.file("release-certificate.sha256").readText().trim()
        require(fingerprint == expected) {
            "Release certificate changed. Do not distribute an APK that cannot update existing installations."
        }
    }
}
