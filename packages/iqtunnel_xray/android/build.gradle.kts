plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
}

group = "com.iqtunnel.xray"
version = "1.0"

android {
    namespace = "com.iqtunnel.xray"
    compileSdk = 36

    defaultConfig {
        minSdk = 21
        consumerProguardFiles("consumer-rules.pro")
    }

    // Match Flutter's generated Android app module to avoid Java/Kotlin
    // bytecode target mismatches on newer JDK and Kotlin Gradle Plugin releases.
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

}

// Keep Kotlin's modern compilerOptions API rather than the deprecated
// kotlinOptions bridge, which is rejected by the current AGP/KGP toolchain.
tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_11)
    }
}

dependencies {
    implementation(files("libs/libXray.jar"))
}
