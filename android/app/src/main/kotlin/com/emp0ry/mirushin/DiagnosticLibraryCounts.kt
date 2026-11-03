package com.emp0ry.mirushin

import android.content.Context
import android.content.Intent
import android.database.sqlite.SQLiteDatabase
import android.util.Log
import java.io.File

/** Aggregate, read-only verification for the separate TV test app. */
internal object DiagnosticLibraryCounts {
    private const val TEST_PACKAGE = "com.emp0ry.mirushin.diagnostic"
    private const val ACTION = "$TEST_PACKAGE.LIBRARY_COUNTS"

    fun handle(context: Context, intent: Intent?) {
        if (context.packageName != TEST_PACKAGE || intent?.action != ACTION) return
        val directory = File(context.filesDir, "MiruShin/Library")
        Thread {
            try {
                val files = directory.listFiles()?.filter {
                    it.name.startsWith("mirushin_canonical_library_") &&
                        it.name.endsWith("_v1.sqlite")
                }.orEmpty()
                var metadata = 0L
                var operations = 0L
                var media = 0L
                for (file in files) {
                    SQLiteDatabase.openDatabase(
                        file.path, null,
                        SQLiteDatabase.OPEN_READONLY or SQLiteDatabase.NO_LOCALIZED_COLLATORS,
                    ).use { db ->
                        db.rawQuery(
                            "SELECT " +
                                "(SELECT COUNT(*) FROM library_operation_records WHERE fields_json = ?), " +
                                "(SELECT COUNT(*) FROM library_operation_records), " +
                                "(SELECT COUNT(*) FROM canonical_media_records)",
                            arrayOf("[\"metadata\"]"),
                        ).use { row ->
                            check(row.moveToFirst())
                            metadata += row.getLong(0)
                            operations += row.getLong(1)
                            media += row.getLong(2)
                        }
                    }
                }
                // No names, account identifiers, payloads, URLs, or tokens.
                Log.i("MiruLibraryCounts", "databases=${files.size} metadata=$metadata operations=$operations media=$media")
            } catch (error: Exception) {
                Log.e("MiruLibraryCounts", "queryFailed=${error.javaClass.simpleName}")
            }
        }.start()
    }
}
