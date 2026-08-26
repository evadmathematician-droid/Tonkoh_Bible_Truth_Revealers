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

// Several plugin dependencies (flutter_contacts, flutter_foreground_task,
// record_android, etc.) still compile their own Android library module
// against Java 8 internally — this app's own build.gradle.kts already
// targets 17, but each plugin is a separate Gradle module with its own
// compileOptions, which is what actually produces the repeated
// "source value 8 is obsolete" javac warnings. Force every subproject
// (including plugin modules, which this app doesn't control the source of)
// onto the same Java target as the app itself, rather than waiting on each
// plugin author to update.
subprojects {
    // plugins.withId reacts the moment the plugin is actually applied,
    // instead of racing project-evaluation order the way afterEvaluate
    // does — afterEvaluate here threw "Cannot run Project.afterEvaluate
    // when the project is already evaluated" because of the
    // evaluationDependsOn(":app") block above forcing :app to evaluate
    // early relative to other subprojects.
    //
    // Only com.android.library (the plugin modules actually causing the
    // Java-8 warnings) needs this — :app is com.android.application and
    // already sets compileOptions itself in app/build.gradle.kts; touching
    // it again here throws "sourceCompatibility has been finalized"
    // because AGP finalizes it once the app module's own android {} block
    // has already been evaluated.
    plugins.withId("com.android.library") {
        extensions.configure(com.android.build.gradle.LibraryExtension::class.java) {
            compileOptions {
                sourceCompatibility = JavaVersion.VERSION_17
                targetCompatibility = JavaVersion.VERSION_17
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
