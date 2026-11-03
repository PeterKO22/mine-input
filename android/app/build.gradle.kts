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
        versionCode = 4
        versionName = "0.4.0-w16"
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

    // W16：RIME 数据（ping_wubi_mixed schema + wubi86/pinyin_simp 词库）随 app 部署。
    // 构建期从 ../schema 同步到 build/generated/rimeAssets（单一事实源，避免仓内双份 3.4MB）。
    // 注意（AGP 9）：SourceSet API 不收 Provider，须传静态路径；任务依赖由下方 preBuild 显式携带。
    sourceSets {
        getByName("main") {
            assets.srcDir("build/generated/rimeAssets")
        }
    }
}

// W16：assets/rime/{shared,user} ← schema/（default + schema + deps 词库 → shared；custom_phrase → user）
val syncRimeAssets = tasks.register<Copy>("syncRimeAssets") {
    from("${rootDir}/../schema") {
        include("default.yaml", "ping_wubi_mixed.schema.yaml")
        into("rime/shared")
    }
    from("${rootDir}/../schema/deps") { into("rime/shared") }
    from("${rootDir}/../schema/custom_phrase.txt") { into("rime/user") }
    into(layout.buildDirectory.dir("generated/rimeAssets"))
}
tasks.named("preBuild") { dependsOn(syncRimeAssets) }

dependencies {
    // W14：sherpa-onnx v2.0.1 Android 预编译（GitHub Releases AAR，本地 Maven 仓库；
    // 含 arm64-v8a/armeabi-v7a/x86/x86_64 全 ABI 的 libsherpa-onnx-jni + onnxruntime）
    implementation("com.k2fsa.sherpa:sherpa-onnx:2.0.1")
    // W14：SenseVoice tar.bz2 归档的纯 Java 解压（Android toybox 无 bunzip2）
    implementation(files("libs/commons-compress-1.26.2.jar", "libs/commons-io-2.16.1.jar"))
}
