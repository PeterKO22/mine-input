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
        versionCode = 2
        versionName = "0.2.0-w11"
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
