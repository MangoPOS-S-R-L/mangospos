rootProject.extra.set("kotlin_version", "2.1.0")

allprojects {
    buildscript {
        configurations.all {
            resolutionStrategy {
                force("org.jetbrains.kotlin:kotlin-gradle-plugin:2.1.0")
            }
        }
    }
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory = rootProject.layout.buildDirectory.dir("../../build").get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
    
    val setupSubproject = {
        val android = project.extensions.findByName("android") as? com.android.build.gradle.BaseExtension
        if (android != null) {
            if (android.namespace == null) {
                if (project.name == "flutter_usb_printer") {
                    android.namespace = "app.mylekha.client.flutter_usb_printer"
                } else {
                    android.namespace = project.group.toString()
                }
            }
        }
        tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
            kotlinOptions {
                val target = android?.compileOptions?.targetCompatibility?.toString()
                if (target != null) {
                    jvmTarget = target
                }
            }
        }
    }

    if (project.state.executed) {
        setupSubproject()
    } else {
        project.afterEvaluate { setupSubproject() }
    }

    configurations.all {
        resolutionStrategy {
            force("org.jetbrains.kotlin:kotlin-gradle-plugin:2.1.0")
            force("org.jetbrains.kotlin:kotlin-stdlib-jdk8:2.1.0")
            force("org.jetbrains.kotlin:kotlin-stdlib:2.1.0")
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
