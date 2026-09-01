plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

// Release signing material, read from ~/.gradle/gradle.properties or env vars so
// no keystore path or password is ever committed. Create the key once with:
//   keytool -genkey -v -keystore acab-release.jks -keyalg RSA -keysize 2048 \
//     -validity 10000 -alias acab
// then set ACAB_STORE_FILE / ACAB_STORE_PASSWORD / ACAB_KEY_ALIAS /
// ACAB_KEY_PASSWORD. Absent them, the release build is left unsigned; debug is
// unaffected either way.
val acabStoreFile = (findProperty("ACAB_STORE_FILE") as String?) ?: System.getenv("ACAB_STORE_FILE")
val acabStorePassword = (findProperty("ACAB_STORE_PASSWORD") as String?) ?: System.getenv("ACAB_STORE_PASSWORD")
val acabKeyAlias = (findProperty("ACAB_KEY_ALIAS") as String?) ?: System.getenv("ACAB_KEY_ALIAS")
val acabKeyPassword = (findProperty("ACAB_KEY_PASSWORD") as String?) ?: System.getenv("ACAB_KEY_PASSWORD")

android {
    namespace = "tech.acab.app"
    compileSdk = 36   // Android 16: compile against the Live Update promote APIs

    defaultConfig {
        // The PERMANENT public identity on Play: it becomes the store URL and can never be
        // changed after publishing. Deliberately NOT the namespace below, which stays tech.acab.app
        // so no Kotlin package has to move; applicationId exists precisely for this split.
        applicationId = "tech.soyboi.beacons"
        minSdk = 26
        // 36 from 2026-08-06. Play requires API 36 for UPDATES from 2026-08-31, so this is a
        // deadline, not a preference. Raising it opts the app into Android 16's enforced
        // behaviours (edge-to-edge is no longer opt-out-able being the big one), which is why the
        // PR carries a manual QA checklist rather than a claim that it works: insets on Map,
        // Device and Detail, orientation changes, the Drive foreground service, and large-screen
        // layout all need eyes on a real 16 device.
        targetSdk = 36
        versionCode = 26
        versionName = "2.0.6"
    }

    signingConfigs {
        if (acabStoreFile != null) {
            create("release") {
                storeFile = file(acabStoreFile)
                storePassword = acabStorePassword
                keyAlias = acabKeyAlias
                keyPassword = acabKeyPassword
            }
        }
    }

    buildTypes {
        release {
            // R8 + resource shrink: Compose relies on R8 to finish its lambda/singleton
            // optimizations (unminified release Compose is measurably jankier), and
            // material-icons-extended is only shippable shrunk.
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            // Signed only when the ACAB_* signing material is present.
            if (acabStoreFile != null) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }
    // Lint policy, made explicit. NOTE these mostly RESTATE AGP defaults, they are documentation,
    // NOT the gate. The actual gate is the `:app:lintRelease` step in .github/workflows/
    // android-release.yml, because assembleRelease only triggers lintVitalRelease (the "fatal"
    // subset) and that PROVABLY misses real errors: with the bare <View> reintroduced in the
    // RemoteViews widget layout, lintVitalRelease still reported BUILD SUCCESSFUL (tested
    // 2026-07-30). Do not delete the CI step and assume this block covers you.
    // Warnings stay non-fatal, there are ~90 and triaging them should not block a release.
    lint {
        abortOnError = true
        warningsAsErrors = false
        checkReleaseBuilds = true
    }

    buildFeatures {
        compose = true
        // BuildConfig.VERSION_NAME feeds the osmdroid tile User-Agent (see configureOsmdroid).
        // OSM's tile usage policy wants a UA that identifies the app AND its version, and reading
        // it from BuildConfig means the version can never drift from build.gradle.kts.
        buildConfig = true
    }
}

dependencies {
    val composeBom = platform("androidx.compose:compose-bom:2025.01.00")
    implementation(composeBom)

    implementation("androidx.core:core-ktx:1.17.0")   // 1.17+ carries the Live Update promote APIs

    // Nordic legacy-DFU client, for updating the nRF52840 co-processor over BLE. The nRF runs the
    // Adafruit/Seeed bootloader, which speaks LEGACY Nordic DFU (service 0x1530), not secure DFU.
    // BSD-3, so it stays F-Droid-clean.
    implementation("no.nordicsemi.android:dfu:2.5.0")
    // The DFU library's abort is driven over a local broadcast (DfuBaseService.BROADCAST_ACTION).
    implementation("androidx.localbroadcastmanager:localbroadcastmanager:1.1.0")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.8.7")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.7")
    implementation("androidx.activity:activity-compose:1.9.3")
    // Photo contributions are re-encoded without metadata. AndroidX ExifInterface supplies
    // consistent orientation parsing across supported image containers and API levels before
    // orientation is baked into the bounded bitmap.
    implementation("androidx.exifinterface:exifinterface:1.4.1")

    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-graphics")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    // Home-screen launcher widget surface. widgetCategory is deliberately home_screen ONLY -
    // keyguard hosting was reverted as a privacy regression; see res/xml/widget_beacons_info.xml.
    implementation("androidx.glance:glance-appwidget:1.1.1")

    // OpenStreetMap, no Google dependency. Wired in when the map screen lands.
    implementation("org.osmdroid:osmdroid-android:6.1.20")

    debugImplementation("androidx.compose.ui:ui-tooling")

    // Local JVM unit tests: the policy, parser and parity fixtures under
    // src/test/java/tech/acab/app/{ble,model,net,ui}, written against logic that is kept free of
    // Android framework calls so it runs on a plain JVM. They cover, among others, the OTA
    // URL-trust and bounded-read gates, the status-JSON contract rules, the ALPR dataset wire
    // format, the contribution CSV and log-export lenses, and the map-pin rules. SEVERAL of those
    // are cross-platform parity contracts, run against the same vectors the Swift side asserts, so
    // a change to any of them is a change on both phones: follow-evidence, map-pin, the ALPR peek
    // radius and the ALPR dataset wire format. Follow-evidence is the clearest worked example - it
    // is the ACTUAL guarantee that the Android and iOS scorers band the same journey the same way -
    // but calling it THE cross-platform one is how the other three drift.
    // `./gradlew :app:testDebugUnitTest` runs the whole source set, which is what
    // the release workflow gates on before anything is signed.
    testImplementation("junit:junit:4.13.2")
    // Real org.json on the unit-test classpath. Android's bundled org.json is a STUB in local unit
    // tests: every method throws "not mocked", so any test that parses a status or detection JSON
    // fails for a reason that has nothing to do with the code under test. TEST-ONLY, so it does not
    // ship and does not affect F-Droid cleanliness. The alternative (returnDefaultValues = true)
    // would silently hand back nulls and make the fixtures pass while proving nothing.
    testImplementation("org.json:json:20240303")
}
