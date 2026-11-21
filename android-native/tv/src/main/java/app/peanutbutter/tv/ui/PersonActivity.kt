package app.peanutbutter.tv.ui

import android.content.Intent
import android.os.Bundle
import android.widget.Toast
import androidx.activity.compose.setContent
import androidx.fragment.app.FragmentActivity
import androidx.lifecycle.lifecycleScope
import app.peanutbutter.core.PersonCredit
import app.peanutbutter.tv.R
import app.peanutbutter.tv.asTv
import kotlinx.coroutines.launch

/** A cast or crew member's page ([PersonScreen]), opened from a title's Cast & crew. */
class PersonActivity : FragmentActivity() {
    private val ui = PersonState()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val tmdbId = intent.getIntExtra(EXTRA_TMDB_ID, 0)
        ui.name = intent.getStringExtra(EXTRA_NAME).orEmpty()
        setContent { PersonScreen(ui, onBack = { finish() }, onOpen = ::open) }
        lifecycleScope.launch {
            try {
                ui.person = application.asTv().api.person(tmdbId)
            } catch (e: Exception) {
                ui.error = getString(R.string.person_load_failed)
            }
        }
    }

    private fun open(credit: PersonCredit) {
        if (ui.opening) return
        val known = credit.titleId
        if (known != null) {
            openDetails(known, credit.title)
            return
        }
        // Not in the catalog yet: the server stores it first.
        ui.opening = true
        lifecycleScope.launch {
            try {
                val id = application.asTv().api.openTmdbTitle(credit.tmdbId, credit.kind)
                if (id.isNotBlank()) openDetails(id, credit.title)
            } catch (e: Exception) {
                Toast.makeText(this@PersonActivity, e.message ?: getString(R.string.person_open_failed), Toast.LENGTH_LONG).show()
            } finally {
                ui.opening = false
            }
        }
    }

    private fun openDetails(id: String, title: String) {
        startActivity(
            Intent(this, DetailsActivity::class.java)
                .putExtra(DetailsActivity.EXTRA_ID, id)
                .putExtra(DetailsActivity.EXTRA_TITLE, title),
        )
    }

    companion object {
        const val EXTRA_TMDB_ID = "tmdb_person_id"
        const val EXTRA_NAME = "name"
    }
}
