plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Kotlin 2.3 起 android.kotlinOptions 已移除，改用 project 作用域的 kotlin{compilerOptions}。
// 编译用 daemon 的 JDK 25（见 ../gradle/gradle-daemon-jvm.properties），
// 字节码目标保持 17：Android/D8 不支持更高的 class file 版本。
kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

// CI 可选注入正式签名：4 个属性齐全时才创建 release signingConfig，
// 本地开发 / 未配置 secrets 时沿用原来的 debug 签名，行为不变。
val releaseStoreFile = providers.gradleProperty("RELEASE_STORE_FILE").orNull
val releaseKeyAlias = providers.gradleProperty("RELEASE_KEY_ALIAS").orNull
val releaseStorePassword = providers.gradleProperty("RELEASE_STORE_PASSWORD").orNull
val releaseKeyPassword = providers.gradleProperty("RELEASE_KEY_PASSWORD").orNull
val hasReleaseSigning = !releaseStoreFile.isNullOrBlank() &&
    !releaseKeyAlias.isNullOrBlank() &&
    !releaseStorePassword.isNullOrBlank() &&
    !releaseKeyPassword.isNullOrBlank()

android {
    namespace = "flutter.legado.bingxl.cn"
    compileSdk = flutter.compileSdkVersion
    // 必须显式写死。不写的话 AGP 8.x 会回落到它自己的默认 NDK 27.0.12077973，
    // 而本机那个目录是下载中断留下的空壳（没有 source.properties），
    // 直接报 "NDK at ... did not have a source.properties file"。
    // 本工程没有任何 native 代码，钉到本机唯一完整的 29.x 即可。
    ndkVersion = "29.0.14206865"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "flutter.legado.bingxl.cn"
        // 内核是纯 Dart，不再受 gomobile 的 -androidapi 24 约束，
        // 直接跟随 Flutter 的默认 minSdk（当前为 24），少一个要手工对齐的常量。
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                storeFile = file(releaseStoreFile!!)
                keyAlias = releaseKeyAlias!!
                storePassword = releaseStorePassword!!
                keyPassword = releaseKeyPassword!!
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (hasReleaseSigning) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

flutter {
    source = "../.."
}
