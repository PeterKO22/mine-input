// W5 android: app 模块
// AGP 9.0+ 内置 Kotlin 支持，不再单独应用 org.jetbrains.kotlin.android
plugins {
    id("com.android.application")
}

android {
    namespace = "com.mineinput.ime"
    compileSdk = 37

    defaultConfig {
        applicationId = "com.mineinput.ime"
        minSdk = 29
        targetSdk = 37
        versionCode = 3
        versionName = "0.3.0-w14"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

dependencies {
    // W14：sherpa-onnx v2.0.1 Android 预编译（GitHub Releases AAR，本地 Maven 仓库；
    // 含 arm64-v8a/armeabi-v7a/x86/x86_64 全 ABI 的 libsherpa-onnx-jni + onnxruntime）
    implementation("com.k2fsa.sherpa:sherpa-onnx:2.0.1")
    // W14：SenseVoice tar.bz2 归档的纯 Java 解压（Android toybox 无 bunzip2）
    implementation(files("libs/commons-compress-1.26.2.jar", "libs/commons-io-2.16.1.jar"))
}
