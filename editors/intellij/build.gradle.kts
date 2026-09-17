plugins {
    id("java")
    id("org.jetbrains.intellij.platform") version "2.9.0"
}

group = "com.github.pedrogitprojects"
version = "0.1.0"

repositories {
    mavenCentral()
    intellijPlatform {
        defaultRepositories()
    }
}

dependencies {
    intellijPlatform {
        // 2025.2 is the oldest platform this plugin is built and tested against.
        intellijIdeaCommunity("2025.2")
    }
}

java {
    toolchain {
        // 2025.2 runs on JBR 21; compiling to anything newer would not load.
        languageVersion = JavaLanguageVersion.of(21)
    }
}

intellijPlatform {
    pluginConfiguration {
        ideaVersion {
            sinceBuild = "252"
            // Nothing here touches internal API, so there is no reason to lock
            // the plugin out of future releases. `null` omits until-build.
            untilBuild = provider { null }
        }
    }
}
