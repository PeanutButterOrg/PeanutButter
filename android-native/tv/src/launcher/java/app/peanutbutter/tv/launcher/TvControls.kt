package app.peanutbutter.tv.launcher

import android.app.Activity
import android.Manifest
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.content.pm.PackageManager
import android.media.AudioManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.wifi.WifiManager
import android.os.Build
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.media.tv.TvContract
import android.media.tv.TvInputInfo
import android.media.tv.TvInputManager
import android.provider.Settings
import android.widget.Toast
import app.peanutbutter.tv.R
import app.peanutbutter.tv.asTv
import app.peanutbutter.tv.ui.PairingActivity
import app.peanutbutter.tv.ui.SearchActivity
import app.peanutbutter.tv.ui.SettingsActivity

/** The TV's own controls: input sources and the system settings pages. */
object TvControls {
    data class Input(val label: String, val intent: Intent, val connected: Boolean)

    fun open(context: Context, intent: Intent) {
        try {
            context.startActivity(intent)
        } catch (_: ActivityNotFoundException) {
            Toast.makeText(context, R.string.open_failed, Toast.LENGTH_SHORT).show()
        } catch (_: SecurityException) {
            Toast.makeText(context, R.string.open_failed, Toast.LENGTH_SHORT).show()
        }
    }

    /**
     * Live TV + the HDMI/AV inputs (Android TvInputManager), each opening
     * straight on that source in the TV's own player.
     */
    fun inputs(context: Context): List<Input> {
        val tim = context.getSystemService(Context.TV_INPUT_SERVICE) as? TvInputManager ?: return emptyList()
        val all = runCatching { tim.tvInputList }.getOrDefault(emptyList())
        val result = mutableListOf<Input>()
        val liveTv = Intent("tcl.sys.intent.action.TV").takeIf { it.resolveActivity(context.packageManager) != null }
            ?: context.packageManager.getLeanbackLaunchIntentForPackage("com.google.android.tv")
        if (liveTv != null && all.any { it.type == TvInputInfo.TYPE_TUNER }) {
            result += Input(context.getString(R.string.live_tv), liveTv, connected = true)
        }
        all.filter { it.isPassthroughInput && it.parentId == null && !it.isHidden(context) }
            .sortedWith(compareBy({ it.type }, { it.loadLabel(context).toString() }))
            .forEach { info ->
                val base = (info.loadCustomLabel(context) ?: info.loadLabel(context)).toString()
                // HDMI-CEC device behind the port (e.g. a console), if it reports one.
                val device = all.firstOrNull { it.parentId == info.id }?.loadLabel(context)?.toString()
                val state = runCatching { tim.getInputState(info.id) }
                    .getOrDefault(TvInputManager.INPUT_STATE_CONNECTED)
                result += Input(
                    label = if (device.isNullOrBlank()) base else "$base · $device",
                    intent = Intent(Intent.ACTION_VIEW).setDataAndType(
                        TvContract.buildChannelUriForPassthroughInput(info.id),
                        TvContract.Channels.CONTENT_ITEM_TYPE,
                    ),
                    connected = state != TvInputManager.INPUT_STATE_DISCONNECTED,
                )
            }
        return result
    }

    /**
     * Reading the TV's inputs takes over a second on some sets; the home screen
     * refreshes this in the background so the panel opens at once.
     */
    @Volatile
    private var cachedInputs: List<Input>? = null

    fun refreshInputs(context: Context) {
        Thread { cachedInputs = runCatching { inputs(context.applicationContext) }.getOrNull() ?: cachedInputs }.start()
    }

    fun showInputs(activity: Activity) {
        val panel = ControlPanel(activity, activity.getString(R.string.inputs))
        (cachedInputs ?: inputs(activity)).forEach { input ->
            panel.action(
                icon = if (input.label == activity.getString(R.string.live_tv)) R.drawable.ic_live_tv else R.drawable.ic_input,
                label = input.label,
                detail = if (input.connected) null else activity.getString(R.string.nothing_connected),
                dot = input.connected,
            ) { open(activity, input.intent) }
        }
        panel.show()
        // Pick up anything plugged in / out for next time.
        refreshInputs(activity)
    }

    /**
     * What is wrong right now, for the red dot on the Wi‑Fi button.
     * [serverOk]: null = not paired / not checked yet.
     */
    fun issues(context: Context, serverOk: Boolean?): List<String> {
        val out = mutableListOf<String>()
        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val caps = cm.getNetworkCapabilities(cm.activeNetwork)
        if (caps == null || !caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) {
            out += context.getString(R.string.issue_network)
        }
        if (serverOk == false) out += context.getString(R.string.issue_server)
        val adapter = (context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager)?.adapter
        @Suppress("MissingPermission")
        if (adapter != null && hasBluetoothPermission(context) && !adapter.isEnabled &&
            runCatching { adapter.bondedDevices }.getOrNull().orEmpty().isNotEmpty()
        ) {
            out += context.getString(R.string.issue_bluetooth)
        }
        return out
    }

    /** Devices connected right now (not every device ever paired). */
    @Suppress("MissingPermission")
    private fun connectedDevices(adapter: BluetoothAdapter): List<BluetoothDevice> =
        runCatching { adapter.bondedDevices }.getOrNull().orEmpty().filter { device ->
            // BluetoothDevice.isConnected() is not in the public SDK but present on every release.
            runCatching { device.javaClass.getMethod("isConnected").invoke(device) as Boolean }.getOrDefault(false)
        }

    fun showConnectivity(activity: Activity, serverOk: Boolean? = null, onRetry: () -> Unit = {}) {
        val adapter = (activity.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager)?.adapter
        if (adapter != null && !hasBluetoothPermission(activity)) {
            // Android 12+: ask once; the panel opens once answered.
            activity.requestPermissions(arrayOf(Manifest.permission.BLUETOOTH_CONNECT), REQ_BLUETOOTH)
            return
        }
        val panel = ControlPanel(activity, activity.getString(R.string.connectivity))
        addNetwork(activity, panel)
        addServer(activity, panel, serverOk, onRetry)
        addBluetooth(activity, panel)
        panel.show()
    }

    private fun addNetwork(activity: Activity, panel: ControlPanel) {
        panel.header(activity.getString(R.string.network))
        val wifi = activity.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        val cm = activity.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val caps = cm.getNetworkCapabilities(cm.activeNetwork)
        when {
            caps?.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) == true ->
                panel.info(R.drawable.ic_ethernet, activity.getString(R.string.connected_ethernet))
            caps?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true -> {
                @Suppress("DEPRECATION")
                val info = wifi.connectionInfo
                @Suppress("DEPRECATION")
                val ssid = info?.ssid?.trim('"')?.takeUnless { it.isBlank() || it == WifiManager.UNKNOWN_SSID }
                @Suppress("DEPRECATION")
                val bars = WifiManager.calculateSignalLevel(info?.rssi ?: -100, 5)
                panel.info(
                    R.drawable.ic_wifi,
                    ssid ?: activity.getString(R.string.connected_wifi),
                    activity.getString(R.string.signal_level, bars, 4),
                )
            }
            else -> panel.info(R.drawable.ic_wifi_off, activity.getString(R.string.not_connected))
        }
        panel.toggle(R.drawable.ic_wifi, activity.getString(R.string.wifi), null, wifi.isWifiEnabled) { want ->
            // Apps may only switch Wi-Fi themselves before Android 10; after that, Android's page does it.
            @Suppress("DEPRECATION")
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q && wifi.setWifiEnabled(want)) {
                want
            } else {
                open(activity, systemIntent(activity, Settings.ACTION_WIFI_SETTINGS))
                null
            }
        }
        panel.action(R.drawable.ic_open, activity.getString(R.string.network_settings)) {
            open(activity, systemIntent(activity, Settings.ACTION_WIFI_SETTINGS))
        }
    }

    private fun addServer(activity: Activity, panel: ControlPanel, serverOk: Boolean?, onRetry: () -> Unit) {
        val session = activity.application.asTv().session
        panel.header(activity.getString(R.string.hero_connect_kicker))
        when {
            !session.isPaired -> panel.action(R.drawable.ic_server, activity.getString(R.string.hero_connect_title), activity.getString(R.string.not_connected), dot = false) {
                activity.startActivity(Intent(activity, PairingActivity::class.java))
            }
            serverOk == false -> panel.action(R.drawable.ic_server, activity.getString(R.string.issue_server), activity.getString(R.string.tap_to_retry), dot = false) { onRetry() }
            else -> panel.info(R.drawable.ic_server, activity.getString(R.string.server_connected), session.serverUrl)
        }
    }

    private fun addBluetooth(activity: Activity, panel: ControlPanel) {
        panel.header(activity.getString(R.string.bluetooth))
        val adapter = (activity.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager)?.adapter
        val settings = systemIntent(activity, Settings.ACTION_BLUETOOTH_SETTINGS)
        if (adapter == null) {
            panel.info(R.drawable.ic_bluetooth, activity.getString(R.string.bluetooth_missing))
        } else {
            panel.toggle(R.drawable.ic_bluetooth, activity.getString(R.string.bluetooth), null, adapter.isEnabled) { want ->
                @Suppress("DEPRECATION", "MissingPermission")
                val ok = runCatching { if (want) adapter.enable() else adapter.disable() }.getOrDefault(false)
                if (ok) want else {
                    open(activity, settings)
                    null
                }
            }
            @Suppress("MissingPermission")
            if (adapter.isEnabled) {
                connectedDevices(adapter).sortedBy { it.name.orEmpty().lowercase() }.forEach { device ->
                    panel.action(R.drawable.ic_bluetooth, device.name ?: device.address, activity.getString(R.string.bt_connected), dot = true) {
                        open(activity, settings)
                    }
                }
            }
        }
        panel.action(R.drawable.ic_add, activity.getString(R.string.pair_new_device)) { open(activity, settings) }
    }

    private fun hasBluetoothPermission(context: Context) =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.S ||
            context.checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED

    fun showSound(activity: Activity) {
        val audio = activity.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val stream = AudioManager.STREAM_MUSIC
        val panel = ControlPanel(activity, activity.getString(R.string.sound))
        val max = audio.getStreamMaxVolume(stream)
        val prefs = activity.getSharedPreferences("launcher", Context.MODE_PRIVATE)
        // Volume 0 counts as muted, whoever set it.
        val muted = audio.isStreamMute(stream) || audio.getStreamVolume(stream) == 0
        panel.toggle(R.drawable.ic_volume_off, activity.getString(R.string.mute), null, muted) { want ->
            if (want) {
                // Remember the level, then mute; some TVs (TCL) ignore mute for their
                // speakers, so fall back to volume 0.
                prefs.edit().putInt(KEY_UNMUTE_VOLUME, audio.getStreamVolume(stream)).apply()
                audio.adjustStreamVolume(stream, AudioManager.ADJUST_MUTE, 0)
                if (!audio.isStreamMute(stream)) audio.setStreamVolume(stream, 0, 0)
            } else {
                audio.adjustStreamVolume(stream, AudioManager.ADJUST_UNMUTE, 0)
                if (audio.getStreamVolume(stream) == 0) {
                    // Back to the level we muted from; if the volume was turned
                    // down to 0 by hand, 10% so the TV is audible again.
                    val saved = prefs.getInt(KEY_UNMUTE_VOLUME, 0)
                    audio.setStreamVolume(stream, if (saved > 0) saved else (max / 10).coerceAtLeast(1), 0)
                }
                prefs.edit().remove(KEY_UNMUTE_VOLUME).apply()
            }
            want
        }
        val (label, intent) = pictureAndSound(activity)
        panel.link(activity.getString(label)) { open(activity, intent) }
        panel.show()
    }

    /** One place for both: PeanutButter (server, app settings) and the TV's own settings. */
    fun showSettings(activity: Activity) {
        val session = activity.application.asTv().session
        val panel = ControlPanel(activity, activity.getString(R.string.all_settings))
        panel.header(activity.getString(R.string.hero_connect_kicker))
        if (session.isPaired) {
            panel.action(R.drawable.ic_server, activity.getString(R.string.pb_settings), session.serverUrl) {
                activity.startActivity(Intent(activity, SettingsActivity::class.java))
            }
            panel.action(R.drawable.ic_search, activity.getString(R.string.search)) {
                activity.startActivity(Intent(activity, SearchActivity::class.java))
            }
        } else {
            panel.action(R.drawable.ic_server, activity.getString(R.string.hero_connect_title), activity.getString(R.string.not_connected)) {
                activity.startActivity(Intent(activity, PairingActivity::class.java))
            }
        }
        panel.header(activity.getString(R.string.tv_section))
        listOf(
            Triple(R.drawable.ic_wifi, R.string.network_settings, Settings.ACTION_WIFI_SETTINGS),
            Triple(R.drawable.ic_bluetooth, R.string.remotes_accessories, Settings.ACTION_BLUETOOTH_SETTINGS),
        ).forEach { (icon, label, action) -> systemRow(activity, panel, icon, label, action) }
        val (picture, intent) = pictureAndSound(activity)
        panel.action(R.drawable.ic_picture, activity.getString(picture)) { open(activity, intent) }
        listOf(
            Triple(R.drawable.ic_apps, R.string.manage_apps, Settings.ACTION_APPLICATION_SETTINGS),
            Triple(R.drawable.ic_clock, R.string.date_time, Settings.ACTION_DATE_SETTINGS),
        ).forEach { (icon, label, action) -> systemRow(activity, panel, icon, label, action) }
        panel.link(activity.getString(R.string.all_settings_full)) { open(activity, systemIntent(activity, Settings.ACTION_SETTINGS)) }
        panel.show()
    }

    private fun systemRow(activity: Activity, panel: ControlPanel, icon: Int, label: Int, action: String) {
        if (Intent(action).resolveActivity(activity.packageManager) != null) {
            panel.action(icon, activity.getString(label)) { open(activity, systemIntent(activity, action)) }
        }
    }

    const val REQ_BLUETOOTH = 41
    private const val KEY_UNMUTE_VOLUME = "unmute_volume"

    /** The TV maker's picture/sound panel (what the remote's settings key opens), else Android's Sound page. */
    fun pictureAndSound(context: Context): Pair<Int, Intent> {
        val tcl = Intent().setClassName("com.tcl.settings", "com.tcl.settings.MainActivity")
        return if (tcl.resolveActivity(context.packageManager) != null) {
            R.string.picture_sound to tcl
        } else {
            R.string.sound to systemIntent(context, Settings.ACTION_SOUND_SETTINGS)
        }
    }

    /** Some TVs ship two Settings apps; go straight to the system one instead of a chooser. */
    fun systemIntent(context: Context, action: String): Intent {
        val intent = Intent(action)
        val handlers = context.packageManager.queryIntentActivities(intent, 0)
        val pick = handlers.firstOrNull { it.activityInfo.applicationInfo.flags and ApplicationInfo.FLAG_SYSTEM != 0 }
            ?: handlers.firstOrNull()
            ?: return intent
        return intent.setClassName(pick.activityInfo.packageName, pick.activityInfo.name)
    }
}
