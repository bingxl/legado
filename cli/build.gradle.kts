plugins {
    // 版本由根工程 buildscript 的 kotlin 插件统一提供，这里不再声明版本
    id("org.jetbrains.kotlin.jvm")
    application
}

java {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
}

kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

dependencies {
    implementation(libs.jsoup)
    implementation(libs.jsoupxpath)
    implementation(libs.json.path)
    implementation(libs.gson)
    implementation(libs.kotlinx.coroutines.core)
    implementation(libs.okhttp)
    implementation(libs.mozilla.rhino)
    implementation(libs.hutool.crypto)
    implementation(libs.commons.text)
    // jsoupXpath 走 slf4j，没有 provider 会在启动时刷三行告警
    runtimeOnly(libs.slf4j.nop)
}

/**
 * 直接复用 app 模块中与 Android 无关的源码，不复制、不改写：
 * 只把文件同步到 build 目录后再参与编译，保证与上游同源。
 */
val syncEngineSource = tasks.register<Sync>("syncEngineSource") {
    from(layout.projectDirectory.dir("../app/src/main/java")) {
        // 规则实体
        include("io/legado/app/data/entities/rule/**")
        exclude("io/legado/app/data/entities/rule/RowUi.kt")
        exclude("io/legado/app/data/entities/rule/RowUi.kt")
        // 规则解析与执行
        include("io/legado/app/model/analyzeRule/**")
        // 书源流程编排
        include("io/legado/app/model/webBook/WebBook.kt")
        include("io/legado/app/model/webBook/BookList.kt")
        include("io/legado/app/model/webBook/BookInfo.kt")
        include("io/legado/app/model/webBook/BookChapterList.kt")
        include("io/legado/app/model/webBook/BookContent.kt")
        // 纯 JVM 工具
        include("io/legado/app/utils/GsonExtensions.kt")
        include("io/legado/app/utils/HtmlFormatter.kt")
        include("io/legado/app/utils/EncoderUtils.kt")
        // HTTP 响应封装（纯 OkHttp）
        include("io/legado/app/help/http/StrResponse.kt")
        // 并发限速
        include("io/legado/app/help/ConcurrentRateLimiter.kt")
    }
    into(layout.buildDirectory.dir("generated/legado-engine"))
}

/**
 * 同理复用 modules/rhino 的脚本引擎包装（legado 的 JS 运行环境）。
 */
val syncRhinoSource = tasks.register<Sync>("syncRhinoSource") {
    from(layout.projectDirectory.dir("../modules/rhino/src/main/java"))
    into(layout.buildDirectory.dir("generated/legado-rhino"))
}

kotlin.sourceSets["main"].kotlin.srcDir(layout.buildDirectory.dir("generated/legado-engine"))
kotlin.sourceSets["main"].kotlin.srcDir(layout.buildDirectory.dir("generated/legado-rhino"))
java.sourceSets["main"].java.srcDir(layout.buildDirectory.dir("generated/legado-engine"))

tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
    dependsOn(syncEngineSource, syncRhinoSource)
}

tasks.withType<JavaCompile>().configureEach {
    dependsOn(syncEngineSource, syncRhinoSource)
}

application {
    mainClass.set("io.legado.cli.MainKt")
    applicationName = "legado-cli"
    applicationDefaultJvmArgs = listOf("-Dfile.encoding=UTF-8")
}
