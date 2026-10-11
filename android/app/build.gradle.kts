plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.debugly.markit"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.debugly.markit"
        minSdk = 26
        targetSdk = 36
        versionCode = 1
        versionName = "0.4.0"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")

            // Without this, assembleRelease produces app-release-unsigned.apk,
            // which Android refuses to install ("no certificates"). That is a
            // release that ships and cannot be used, so the release build is
            // signed with the debug key unless a real keystore is configured.
            //
            // The debug key is not a secret and does not provide identity, but
            // it makes the artifact installable, which is what a side-loaded
            // app needs. Set MARKIT_KEYSTORE to publish a properly signed one.
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }
    buildFeatures {
        viewBinding = true
        // The settings screen shows the running version, which is build data
        // rather than something to copy into a resource by hand and forget.
        buildConfig = true
    }
}

dependencies {
    implementation("androidx.core:core-ktx:1.13.0")
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("com.google.android.material:material:1.12.0")
    implementation("androidx.recyclerview:recyclerview:1.1.0")
    implementation("androidx.constraintlayout:constraintlayout:2.0.1")
    implementation("androidx.activity:activity-ktx:1.8.0")
    implementation("androidx.fragment:fragment-ktx:1.3.6")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.7.1")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    testImplementation("junit:junit:4.13.2")
    // The Android SDK ships org.json as stubs that throw on every call, which
    // makes the release parser untestable. The real implementation on the test
    // classpath is what lets those tests run on the JVM.
    testImplementation("org.json:json:20231013")
}