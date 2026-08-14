package tech.acab.app.ui

import java.io.File
import java.io.IOException
import java.util.UUID

internal const val EXPORT_PACKAGE_MAX_AGE_MS = 7L * 24L * 60L * 60L * 1000L

/**
 * Allocate an immutable, per-export cache package and opportunistically remove only packages
 * old enough that no chooser or receiving app should still be reading them. Recent packages are
 * deliberately retained: a share target may keep using a granted URI after our chooser closes.
 */
internal fun createExportPackage(
    cacheDir: File,
    family: String,
    nowMs: Long = System.currentTimeMillis(),
    maxAgeMs: Long = EXPORT_PACKAGE_MAX_AGE_MS,
): File {
    require(family.matches(Regex("[a-z0-9-]+"))) { "invalid export family" }
    val root = File(cacheDir, family)
    // Two exports can start together. If the other one creates [root] between our isDirectory
    // check and mkdirs(), mkdirs() returns false even though the postcondition is satisfied.
    if (!root.isDirectory && !root.mkdirs() && !root.isDirectory) {
        throw IOException("could not create the export cache")
    }

    val cutoff = nowMs - maxAgeMs
    root.listFiles()?.forEach { candidate ->
        // Only our UUID child directories are packages. Never let an unexpected file or a fresh
        // in-flight package become collateral damage during best-effort housekeeping.
        val isPackage = candidate.isDirectory &&
            runCatching { UUID.fromString(candidate.name) }.isSuccess
        if (isPackage && candidate.lastModified() < cutoff) {
            runCatching { candidate.deleteRecursively() }
        }
    }

    repeat(4) {
        val packageDir = File(root, UUID.randomUUID().toString())
        if (packageDir.mkdir()) return packageDir
    }
    throw IOException("could not create the export package")
}
