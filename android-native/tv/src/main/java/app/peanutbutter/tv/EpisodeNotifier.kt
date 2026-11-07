package app.peanutbutter.tv

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import app.peanutbutter.core.AppLog
import app.peanutbutter.tv.ui.DetailsActivity

/**
 * New episodes of followed series ("Notify me"): fetches the server's alerts,
 * posts one notification each (opening the series), and marks them delivered.
 * Runs when the app opens or comes back to the home screen.
 */
object EpisodeNotifier {
    private const val CHANNEL = "new_episodes"

    suspend fun deliver(context: Context) {
        val app = context.applicationContext as TvApp
        val alerts = app.api.episodeAlerts()
        if (alerts.isEmpty()) return
        if (!canNotify(context)) {
            // Left undelivered, so they show once notifications are allowed.
            AppLog.i("EpisodeNotifier", "${alerts.size} new episode(s), notifications not allowed")
            return
        }
        ensureChannel(context)
        val manager = NotificationManagerCompat.from(context)
        for (a in alerts) {
            val open = PendingIntent.getActivity(
                context,
                a.episodeId.hashCode(),
                Intent(context, DetailsActivity::class.java)
                    .putExtra(DetailsActivity.EXTRA_ID, a.titleId)
                    .putExtra(DetailsActivity.EXTRA_TITLE, a.title)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            val episode = String.format("S%02dE%02d", a.season, a.episode) +
                (a.episodeName?.takeIf { it.isNotBlank() }?.let { " · $it" } ?: "")
            val notification = NotificationCompat.Builder(context, CHANNEL)
                .setSmallIcon(R.drawable.ic_notifications)
                .setContentTitle(context.getString(R.string.new_episode_title, a.title))
                .setContentText(episode)
                .setContentIntent(open)
                .setAutoCancel(true)
                .setCategory(NotificationCompat.CATEGORY_RECOMMENDATION)
                .build()
            runCatching { manager.notify(a.episodeId.hashCode(), notification) }
        }
        runCatching { app.api.markAlertsDelivered(alerts.map { it.episodeId }) }
    }

    fun canNotify(context: Context): Boolean {
        if (Build.VERSION.SDK_INT >= 33 &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            return false
        }
        return NotificationManagerCompat.from(context).areNotificationsEnabled()
    }

    private fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT < 26) return
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        if (manager.getNotificationChannel(CHANNEL) != null) return
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL,
                context.getString(R.string.new_episodes_channel),
                NotificationManager.IMPORTANCE_DEFAULT,
            ),
        )
    }
}
