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
    val rootPath = rootProject.projectDir.toPath().toAbsolutePath().normalize()
    val projectPath = project.projectDir.toPath().toAbsolutePath().normalize()
    if (projectPath.startsWith(rootPath)) {
        val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
        project.layout.buildDirectory.value(newSubprojectBuildDir)
    } else {
        tasks.withType<org.gradle.api.tasks.testing.Test>().configureEach {
            enabled = false
        }
    }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
