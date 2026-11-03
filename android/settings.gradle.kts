// W5 android: mine-input Android 基座（Kotlin IMS 骨架）
pluginManagement {
    repositories {
        // dl.google.com 在本机网络不可达，统一走阿里云镜像（google/central/gradle-plugin）
        maven("https://maven.aliyun.com/repository/google")
        maven("https://maven.aliyun.com/repository/central")
        maven("https://maven.aliyun.com/repository/gradle-plugin")
        gradlePluginPortal()
        google()
        mavenCentral()
    }
}
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        // W14：sherpa-onnx 预编译 AAR 的本地 Maven 仓库（AGP 8+ 不支持直接 .aar 文件依赖；
        // fetch-deps.sh 下载 AAR + SHA256 校验，POM 在 git 内）
        maven(url = uri("${rootDir}/local-repo"))
        maven("https://maven.aliyun.com/repository/google")
        maven("https://maven.aliyun.com/repository/central")
        google()
        mavenCentral()
    }
}

rootProject.name = "mine-input"
include(":app")
