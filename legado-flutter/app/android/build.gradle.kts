allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

// NDK 版本在 app/build.gradle.kts 里显式声明（`ndkVersion`）。
// 不在这里用 subprojects + afterEvaluate 统一设置：下面的 evaluationDependsOn(":app")
// 会先把 :app 评测完，再注册 afterEvaluate 会直接抛
// "Cannot run Project.afterEvaluate(Action) when the project is already evaluated"。

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
