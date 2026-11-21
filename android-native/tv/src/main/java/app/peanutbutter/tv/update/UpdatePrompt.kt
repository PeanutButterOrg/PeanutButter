package app.peanutbutter.tv.update

import android.widget.Toast
import androidx.fragment.app.FragmentActivity
import androidx.lifecycle.lifecycleScope
import app.peanutbutter.tv.R
import app.peanutbutter.tv.asTv
import app.peanutbutter.tv.ui.ConfirmCard
import app.peanutbutter.tv.ui.showPbDialog
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

private var checkedThisProcess = false
private var deferredBuild = 0L

/**
 * Ask the server for a newer TV build and offer it. [manual] (Settings) always
 * checks and reports "up to date"; the automatic home-screen check runs once
 * per process and stays quiet unless there is an update.
 */
fun checkForTvUpdate(activity: FragmentActivity, manual: Boolean = false) {
    if (!manual && checkedThisProcess) return
    checkedThisProcess = true
    val session = activity.application.asTv().session
    if (!session.isPaired) return
    activity.lifecycleScope.launch {
        val update = try {
            AppUpdater.check(activity, session)
        } catch (e: Exception) {
            if (manual) toast(activity, e.message ?: e.toString())
            return@launch
        }
        when {
            update == null -> {
                // Up to date: a kept APK from an earlier update isn't needed.
                AppUpdater.clearDownloads(activity)
                if (manual) toast(activity, activity.getString(R.string.update_none))
            }
            !manual && update.build == deferredBuild -> Unit
            !activity.isFinishing && !activity.isDestroyed -> showUpdateDialog(activity, update)
        }
    }
}

private fun showUpdateDialog(activity: FragmentActivity, update: AppUpdate) {
    val session = activity.application.asTv().session
    val mb = update.size / (1024 * 1024)
    // What the card shows; the download updates it.
    var message by mutableStateOf(activity.getString(R.string.update_message, mb))
    var positive by mutableStateOf<String?>(activity.getString(R.string.update_install))
    var negative by mutableStateOf(activity.getString(R.string.update_later))
    var job: Job? = null
    var dialog: androidx.activity.ComponentDialog? = null

    fun install() {
        positive = null
        negative = activity.getString(R.string.update_cancel)
        job = activity.lifecycleScope.launch {
            // Progress is posted from the download thread; once it's done, late
            // posts must not overwrite later messages (the dialog used to sit at
            // "Downloading… 75%" behind Android's installer).
            var downloading = true
            var lastPct = -1
            try {
                val apk = AppUpdater.download(activity, session, update) { p ->
                    val pct = (p * 100).toInt().coerceIn(0, 100)
                    if (pct == lastPct) return@download
                    lastPct = pct
                    activity.runOnUiThread {
                        if (downloading && dialog?.isShowing == true) {
                            message = activity.getString(R.string.update_downloading, pct)
                        }
                    }
                }
                downloading = false
                message = activity.getString(R.string.update_installing)
                // Hand the APK to Android's installer first, then close: the
                // dialog's dismiss listener cancels this job, and dismissing
                // before install() cancelled the install itself.
                AppUpdater.install(activity, apk)
                dialog?.dismiss()
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (e: Exception) {
                downloading = false
                if (dialog?.isShowing != true) {
                    toast(activity, e.message ?: e.toString())
                    return@launch
                }
                message = e.message ?: e.toString()
                positive = activity.getString(R.string.update_retry)
                negative = activity.getString(R.string.update_later)
            }
        }
    }

    dialog = showPbDialog(activity, onDismiss = { job?.cancel() }) { dismiss ->
        ConfirmCard(
            title = activity.getString(R.string.update_title, update.version),
            message = message,
            negative = negative,
            positive = positive,
            onNegative = {
                job?.cancel()
                deferredBuild = update.build
                dismiss()
            },
            onPositive = { install() },
            focusPositive = true,
        )
    }
}

private fun toast(activity: FragmentActivity, text: String) {
    Toast.makeText(activity, text, Toast.LENGTH_LONG).show()
}
