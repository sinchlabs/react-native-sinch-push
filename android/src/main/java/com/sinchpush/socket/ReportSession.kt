package com.sinchpush.socket

import android.content.Context
import android.content.SharedPreferences
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.util.Properties

/**
 * The minimal credential JS mirrors to native so a delivery report can be sent
 * without a JS runtime (`setSharedReportSession`): the device JWT and the push
 * API host. Never the HMAC secret. The same record the iOS extension reads.
 */
internal data class SharedReportSession(
    val accessToken: String,
    /** The push API base URL, e.g. `https://grpc.sinch-push.prod.sinch.com`. */
    val reportBaseURL: String,
    val userId: String = "",
    val appId: String = "",
)

internal interface SharedReportSessionStore {
    fun load(): SharedReportSession?

    /** `false` when the record did not reach storage. */
    fun save(session: SharedReportSession): Boolean

    /** `false` when the removal did not reach storage. */
    fun clear(): Boolean
}

/**
 * One small file in `Context.getNoBackupFilesDir()`: app-private like
 * `SharedPreferences`, but unlike them excluded from Auto Backup and device
 * transfer, so the mirrored JWT never leaves the device in a backup.
 *
 * Written to a temp file, synced, then renamed over the target: the FCM thread
 * reads this with no JS to ask, and JS may be killed right after storing, so a
 * session that is only half-written is worse than none.
 *
 * The first version kept the record in a `SharedPreferences` file, which Auto
 * Backup does include. [legacy] is that file: it is moved into the new file on
 * first use and always emptied, so no copy stays behind.
 */
internal class FileReportSessionStore(
    private val dir: File,
    private val legacy: SharedPreferences? = null,
    private val deleteLegacyFile: () -> Unit = {},
) : SharedReportSessionStore {

    private val target get() = File(dir, FILE_NAME)

    // One lock for the process, not per instance: `of()` builds a store per call, so
    // the JS module thread and the FCM thread each hold their own, and an instance
    // lock would never make them wait for each other (a migration could then write
    // the old token over a `clear()` or a newer `save()`).
    override fun load(): SharedReportSession? = synchronized(LOCK) {
        migrateLegacy()
        read()
    }

    override fun save(session: SharedReportSession): Boolean = synchronized(LOCK) {
        purgeLegacy()
        write(session)
    }

    override fun clear(): Boolean = synchronized(LOCK) {
        purgeLegacy()
        dir.listFiles { _, name -> name.startsWith("$FILE_NAME.") && name.endsWith(TEMP_SUFFIX) }
            ?.forEach { it.delete() }
        !target.exists() || target.delete()
    }

    private fun read(): SharedReportSession? {
        val file = target
        if (!file.isFile) return null
        val props = Properties()
        try {
            FileInputStream(file).use { props.load(it) }
        } catch (_: IOException) {
            return null
        } catch (_: IllegalArgumentException) {
            return null // a malformed \u escape: not ours
        }
        val token = props.getProperty(KEY_ACCESS_TOKEN)?.takeIf { it.isNotEmpty() } ?: return null
        val base = props.getProperty(KEY_BASE_URL)?.takeIf { it.isNotEmpty() } ?: return null
        return SharedReportSession(
            accessToken = token,
            reportBaseURL = base,
            userId = props.getProperty(KEY_USER_ID).orEmpty(),
            appId = props.getProperty(KEY_APP_ID).orEmpty(),
        )
    }

    private fun write(session: SharedReportSession): Boolean {
        val props = Properties().apply {
            setProperty(KEY_ACCESS_TOKEN, session.accessToken)
            setProperty(KEY_BASE_URL, session.reportBaseURL)
            setProperty(KEY_USER_ID, session.userId)
            setProperty(KEY_APP_ID, session.appId)
        }
        dir.mkdirs()
        var tmp: File? = null
        return try {
            // Its own name per write, so two writers never share a half-written file.
            val file = File.createTempFile("$FILE_NAME.", TEMP_SUFFIX, dir).also { tmp = it }
            FileOutputStream(file).use { out ->
                props.store(out, null)
                out.flush()
                out.fd.sync()
            }
            file.renameTo(target).also { if (!it) file.delete() }
        } catch (_: IOException) {
            tmp?.delete()
            false
        }
    }

    /** Moves a record the first version left in `SharedPreferences` into the file, then empties it. */
    private fun migrateLegacy() {
        val prefs = legacy ?: return
        val token = prefs.getString(KEY_ACCESS_TOKEN, null)?.takeIf { it.isNotEmpty() }
        val base = prefs.getString(KEY_BASE_URL, null)?.takeIf { it.isNotEmpty() }
        if (token != null && base != null && !target.isFile) {
            val moved = write(
                SharedReportSession(
                    accessToken = token,
                    reportBaseURL = base,
                    userId = prefs.getString(KEY_USER_ID, null).orEmpty(),
                    appId = prefs.getString(KEY_APP_ID, null).orEmpty(),
                ),
            )
            // Not moved: leave it, so the next attempt still has the token.
            if (!moved) return
        }
        purgeLegacy()
    }

    private fun purgeLegacy() {
        val prefs = legacy ?: return
        if (prefs.all.isNotEmpty()) prefs.edit().clear().commit()
        deleteLegacyFile()
    }

    companion object {
        const val FILE_NAME = "sinch_push_report_session.properties"

        /** The `SharedPreferences` file of the first version. */
        const val LEGACY_PREFS = "sinch_push_report_session"

        private const val TEMP_SUFFIX = ".tmp"
        private val LOCK = Any()

        private const val KEY_ACCESS_TOKEN = "access_token"
        private const val KEY_BASE_URL = "report_base_url"
        private const val KEY_USER_ID = "user_id"
        private const val KEY_APP_ID = "app_id"

        fun of(context: Context): FileReportSessionStore {
            val app = context.applicationContext
            return FileReportSessionStore(
                dir = app.noBackupFilesDir,
                legacy = app.getSharedPreferences(LEGACY_PREFS, Context.MODE_PRIVATE),
                deleteLegacyFile = {
                    // `clear()` leaves an empty XML behind; remove it too (best effort).
                    File(app.applicationInfo.dataDir, "shared_prefs/$LEGACY_PREFS.xml").delete()
                },
            )
        }
    }
}

/** An in-memory store for JVM tests. */
internal class InMemoryReportSessionStore(initial: SharedReportSession? = null) : SharedReportSessionStore {
    @Volatile private var session: SharedReportSession? = initial

    override fun load(): SharedReportSession? = session

    override fun save(session: SharedReportSession): Boolean {
        this.session = session
        return true
    }

    override fun clear(): Boolean {
        session = null
        return true
    }
}
