package app.peanutbutter.tv.update

import android.app.AlertDialog
import android.graphics.Color
import android.graphics.drawable.ColorDrawable
import android.view.LayoutInflater
import android.widget.TextView
import android.widget.Toast
import androidx.core.view.isVisible
import androidx.fragment.app.FragmentActivity
import androidx.lifecycle.lifecycleScope
import app.peanutbutter.tv.R
import app.peanutbutter.tv.asTv
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
            update == null -> if (manual) toast(activity, activity.getString(R.string.update_none))
            !manual && update.build == deferredBuild -> Unit
            !activity.isFinishing && !activity.isDestroyed -> showUpdateDialog(activity, update)
        }
    }
}

private fun showUpdateDialog(activity: FragmentActivity, update: AppUpdate) {
    val session = activity.application.asTv().session
    val view = LayoutInflater.from(activity).inflate(R.layout.dialog_confirm, null)
    val title = view.findViewById<TextView>(R.id.dialog_title)
    val message = view.findViewById<TextView>(R.id.dialog_message)
    val later = view.findViewById<TextView>(R.id.dialog_negative)
    val install = view.findViewById<TextView>(R.id.dialog_positive)
    val mb = update.size / (1024 * 1024)
    title.text = activity.getString(R.string.update_title, update.version)
    message.text = activity.getString(R.string.update_message, mb)
    later.setText(R.string.update_later)
    install.setText(R.string.update_install)

    val dialog = AlertDialog.Builder(activity).setView(view).create()
    var job: Job? = null
    later.setOnClickListener {
        job?.cancel()
        deferredBuild = update.build
        dialog.dismiss()
    }
    install.setOnClickListener {
        install.isVisible = false
        later.setText(R.string.update_cancel)
        later.requestFocus()
        job = activity.lifecycleScope.launch {
            try {
                val apk = AppUpdater.download(activity, session, update) { p ->
                    activity.runOnUiThread {
                        message.text = activity.getString(R.string.update_downloading, (p * 100).toInt())
                    }
                }
                message.setText(R.string.update_installing)
                AppUpdater.install(activity, apk)
                dialog.dismiss()
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (e: Exception) {
                message.text = e.message ?: e.toString()
                install.setText(R.string.update_retry)
                install.isVisible = true
                later.setText(R.string.update_later)
                install.requestFocus()
            }
        }
    }
    dialog.setOnDismissListener { job?.cancel() }
    dialog.setOnShowListener {
        dialog.window?.setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT))
        install.requestFocus()
    }
    dialog.show()
    dialog.window?.setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT))
}

private fun toast(activity: FragmentActivity, text: String) {
    Toast.makeText(activity, text, Toast.LENGTH_LONG).show()
}
