plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

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

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
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

    buildTypes {
        release {
            // TODO: 换成正式签名后再发版。
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}
