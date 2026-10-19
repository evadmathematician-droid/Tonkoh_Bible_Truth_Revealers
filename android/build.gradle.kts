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

// Some plugins (file_picker) still compile against android-34, but
// flutter_plugin_android_lifecycle now requires 36 from everything that uses
// it, which fails release builds at checkReleaseAarMetadata. compileSdk only
// affects which APIs a plugin may call at build time — not targetSdk/minSdk —
// so raising it for the plugin modules is safe.
subprojects {
    if (name != "app") {
        val raiseCompileSdk: Project.() -> Unit = {
            extensions.findByType(com.android.build.gradle.LibraryExtension::class.java)?.let {
                if ((it.compileSdk ?: 0) < 36) it.compileSdk = 36
            }
        }
        // After the plugin's own build script has set its compileSdk.
        if (state.executed) raiseCompileSdk() else afterEvaluate { raiseCompileSdk() }
    }
}

// Several plugins still compile their Java code for source/target 8, and
// javac on JDK 21 warns that 8 is obsolete on every build. Silence only that
// [options] lint; the plugins' own Java versions are left unchanged.
subprojects {
    tasks.withType<JavaCompile>().configureEach {
        options.compilerArgs.add("-Xlint:-options")
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
