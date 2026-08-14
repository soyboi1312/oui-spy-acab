package tech.acab.app.ui

import java.io.File
import java.nio.file.Files
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ExportCacheTest {
    @Test
    fun allocatesUniquePackagesAndPrunesOnlyOldUuidPackages() {
        val cache = Files.createTempDirectory("acab-export-cache").toFile()
        try {
            val now = 2_000_000_000L
            val root = cache.resolve("log-exports").apply { mkdirs() }
            val old = root.resolve("00000000-0000-0000-0000-000000000001").apply {
                mkdir(); resolve("acab-detections.csv").writeText("old")
                setLastModified(now - EXPORT_PACKAGE_MAX_AGE_MS - 1)
            }
            val recent = root.resolve("00000000-0000-0000-0000-000000000002").apply {
                mkdir(); resolve("acab-detections.csv").writeText("recent")
                setLastModified(now - EXPORT_PACKAGE_MAX_AGE_MS + 1)
            }
            val unrelated = root.resolve("do-not-touch").apply {
                mkdir(); setLastModified(0L)
            }

            val first = createExportPackage(cache, "log-exports", now)
            val second = createExportPackage(cache, "log-exports", now)

            assertFalse(old.exists())
            assertTrue(recent.exists())
            assertTrue(unrelated.exists())
            assertTrue(first.isDirectory)
            assertTrue(second.isDirectory)
            assertNotEquals(first, second)
        } finally {
            cache.deleteRecursively()
        }
    }

    @Test
    fun concurrentFirstAllocationsShareTheRootWithoutFailing() {
        val cache = Files.createTempDirectory("acab-export-cache-race").toFile()
        val workers = 12
        val ready = CountDownLatch(workers)
        val start = CountDownLatch(1)
        val pool = Executors.newFixedThreadPool(workers)
        try {
            val futures = (0 until workers).map {
                pool.submit<File> {
                    ready.countDown()
                    start.await()
                    createExportPackage(cache, "log-exports")
                }
            }
            assertTrue(ready.await(5, TimeUnit.SECONDS))
            start.countDown()
            val packages = futures.map { it.get(10, TimeUnit.SECONDS) }

            assertEquals(workers, packages.toSet().size)
            assertTrue(packages.all { it.isDirectory })
        } finally {
            start.countDown()
            pool.shutdownNow()
            cache.deleteRecursively()
        }
    }
}
