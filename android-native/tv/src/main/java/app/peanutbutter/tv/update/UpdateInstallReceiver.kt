package app.peanutbutter.tv.update

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.os.Build
import android.widget.Toast
import app.peanutbutter.tv.R

/** PackageInstaller callback: shows Android's confirm screen, reports failures. */
class UpdateInstallReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)) {
            PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                val confirm = if (Build.VERSION.SDK_INT >= 33) {
                    intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
                } else {
                    @Suppress("DEPRECATION") intent.getParcelableExtra(Intent.EXTRA_INTENT)
                }
                confirm?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)?.let(context::startActivity)
            }
            PackageInstaller.STATUS_SUCCESS -> Unit
            PackageInstaller.STATUS_FAILURE_ABORTED -> Unit
            else -> {
                val message = when (status) {
                    // Old installs signed with the debug key can't take the release key.
                    PackageInstaller.STATUS_FAILURE_CONFLICT,
                    PackageInstaller.STATUS_FAILURE_INCOMPATIBLE,
                    -> context.getString(R.string.update_signature_conflict)
                    else -> context.getString(
                        R.string.update_install_failed,
                        intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE) ?: "status $status",
                    )
                }
                Toast.makeText(context, message, Toast.LENGTH_LONG).show()
            }
        }
    }
}
