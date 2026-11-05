package com.emp0ry.mirushin

import android.app.SearchManager
import android.content.ContentProvider
import android.content.ContentValues
import android.content.Intent
import android.database.MatrixCursor
import android.net.Uri
import android.provider.BaseColumns
import android.util.Log
import org.json.JSONException
import org.json.JSONObject
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL

/** Answers Android TV search using public catalog metadata only. */
class TvSearchProvider : ContentProvider() {
    override fun onCreate() = true

    override fun query(
        uri: Uri,
        projection: Array<out String>?,
        selection: String?,
        selectionArgs: Array<out String>?,
        sortOrder: String?,
    ): MatrixCursor {
        val results = MatrixCursor(columns)
        val path = uri.pathSegments
        if (path.firstOrNull() != SearchManager.SUGGEST_URI_PATH_QUERY || path.size > 2) {
            return results
        }
        val query = (selectionArgs?.firstOrNull() ?: path.getOrNull(1))?.trim()
        if (query.isNullOrEmpty() || query.length > 160) return results
        val episodeMatch = episodePattern.find(query)
        val episode = episodeMatch?.groupValues?.drop(1)?.firstOrNull { it.isNotEmpty() }?.toInt()
        val titleQuery = if (episodeMatch == null) query else {
            query.removeRange(episodeMatch.range)
                .replace(commandPrefix, "")
                .trim(' ', '"', '\'', '«', '»', '“', '”', ',', '.')
        }
        if (titleQuery.length < 2) return results

        val media = try {
            searchAnime(titleQuery)
        } catch (_: IOException) {
            null
        } catch (_: JSONException) {
            null
        } ?: return results

        for (index in 0 until media.length()) {
            val item = media.optJSONObject(index) ?: continue
            val id = item.optInt("id")
            val title = item.optJSONObject("title") ?: continue
            val name = title.optString("english").takeUnless { title.isNull("english") }
                ?: title.optString("romaji")
            if (id <= 0 || name.isBlank()) continue
            val year = item.optJSONObject("startDate")?.optInt("year") ?: 0
            val image = item.optJSONObject("coverImage")?.optString("large")
            val episodePath = if (episode != null && episode in 1..item.optInt("episodes")) {
                "/episode/$episode"
            } else {
                ""
            }
            val description = listOfNotNull(
                year.takeIf { it > 0 }?.toString(),
                episode.takeIf { episodePath.isNotEmpty() }?.let { "Серия $it" },
            ).joinToString(" · ")
            results.addRow(
                arrayOf(
                    id, name, description, image, image, year,
                    item.optLong("duration") * 60_000, Intent.ACTION_VIEW,
                    "mirushin://anilist/anime/$id$episodePath",
                ),
            )
        }
        Log.d("MiruShinTvSearch", "results=${results.count} episodeRequested=${episode != null}")
        return results
    }

    private fun searchAnime(title: String): org.json.JSONArray? {
        val connection = URL("https://graphql.anilist.co").openConnection() as HttpURLConnection
        try {
            connection.requestMethod = "POST"
            connection.instanceFollowRedirects = false
            connection.connectTimeout = 1800
            connection.readTimeout = 1800
            connection.doOutput = true
            connection.setRequestProperty("User-Agent", "MiruShin Android TV Search")
            connection.setRequestProperty("Accept", "application/json")
            connection.setRequestProperty("Content-Type", "application/json")
            val body = JSONObject()
                .put("query", catalogQuery)
                .put("variables", JSONObject().put("search", title))
            connection.outputStream.use { it.write(body.toString().toByteArray(Charsets.UTF_8)) }
            if (connection.responseCode != HttpURLConnection.HTTP_OK) return null
            val response = connection.inputStream.bufferedReader().use { it.readText() }
            return JSONObject(response).optJSONObject("data")?.optJSONObject("Page")
                ?.optJSONArray("media")
        } finally {
            connection.disconnect()
        }
    }

    override fun getType(uri: Uri) = SearchManager.SUGGEST_MIME_TYPE
    override fun insert(uri: Uri, values: ContentValues?): Uri? = null
    override fun update(uri: Uri, values: ContentValues?, selection: String?, args: Array<out String>?) = 0
    override fun delete(uri: Uri, selection: String?, args: Array<out String>?) = 0

    private companion object {
        val columns = arrayOf(
            BaseColumns._ID,
            SearchManager.SUGGEST_COLUMN_TEXT_1,
            SearchManager.SUGGEST_COLUMN_TEXT_2,
            SearchManager.SUGGEST_COLUMN_ICON_1,
            SearchManager.SUGGEST_COLUMN_RESULT_CARD_IMAGE,
            SearchManager.SUGGEST_COLUMN_PRODUCTION_YEAR,
            SearchManager.SUGGEST_COLUMN_DURATION,
            SearchManager.SUGGEST_COLUMN_INTENT_ACTION,
            SearchManager.SUGGEST_COLUMN_INTENT_DATA,
        )
        val episodePattern = Regex(
            """(?<![\p{L}\d])(?:episode|серія|серію|серия|серию)\s+(\d{1,4})(?!\d)|(?<!\d)(\d{1,4})(?:[-‑]?(?:ту|у|а|я|ю|th|st|nd|rd))?\s+(?:episode|серія|серію|серия|серию)(?!\p{L})""",
            RegexOption.IGNORE_CASE,
        )
        val commandPrefix = Regex(
            """^(?:(?:стефанія|стефания|stefania)[, ]+)?(?:(?:відкрий|увімкни|запусти|відтвори|открой|включи|open|play)(?:\s+(?:мені|мне))?[, ]*)?(?:(?:з|із|of)\s+)?""",
            RegexOption.IGNORE_CASE,
        )
        val catalogQuery = """
            query SearchAnime(${'$'}search: String!) {
                Page(perPage: 8) {
                    media(type: ANIME, search: ${'$'}search, isAdult: false) {
                        id title { english romaji } startDate { year }
                        coverImage { large } duration episodes
                    }
                }
            }
        """.trimIndent()
    }
}
