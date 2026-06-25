package do_mangopos.mangoposrestaurant

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat

/**
 * Foreground Service que mantiene el proceso de MangoPOS vivo y priorizado
 * mientras hay una impresora Bluetooth (BLE) activa (PRD BT — Fase 1).
 *
 * Por qué existe: la conexión GATT BLE a la impresora la gestiona
 * `flutter_blue_plus` dentro del proceso de la app. Cuando la pantalla se
 * apaga o la app pasa a background, Android puede matar el proceso o
 * deprorizarlo (Doze), y con él se cae la conexión y se pierde la impresión.
 * Un foreground service de tipo `connectedDevice` evita ese kill y exime al
 * proceso de los límites de ejecución en background, de modo que el manager
 * Dart [BlePrinterConnectionManager] puede sostener el socket y reconectar.
 *
 * Este servicio NO posee el socket: su único trabajo es conservar el proceso
 * y mostrar la notificación persistente. El arranque/parada lo controla el
 * lado Dart vía el channel `mangopos/printer_fgs` (ver MainActivity).
 */
class PrinterForegroundService : Service() {

    companion object {
        private const val CHANNEL_ID = "mangopos_printer_connection"
        private const val NOTIFICATION_ID = 4711
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        ensureChannel()
        startForegroundCompat()
        // START_STICKY: si el sistema mata el servicio por presión de memoria,
        // lo reintenta recrear (sin el último intent). El manager Dart vuelve a
        // pedir conexión al relanzarse la app. La parada limpia se hace desde
        // fuera con stopService() (ver MainActivity), no con un ACTION_STOP, para
        // no violar el contrato de startForeground() en API 26+.
        return START_STICKY
    }

    private fun startForegroundCompat() {
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun buildNotification(): Notification {
        // Intent para reabrir la app al tocar la notificación.
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        val contentIntent = launchIntent?.let {
            val piFlags =
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M)
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                else PendingIntent.FLAG_UPDATE_CURRENT
            PendingIntent.getActivity(this, 0, it, piFlags)
        }

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("MangoPOS")
            .setContentText("Impresora conectada")
            .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setShowWhen(false)
            .apply { contentIntent?.let { setContentIntent(it) } }
            .build()
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Conexión de impresora",
            // IMPORTANCE_LOW: sin sonido ni heads-up; notificación discreta y
            // persistente (PRD BT — mitigación de fricción UX).
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "Mantiene la impresora Bluetooth conectada en segundo plano"
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }
}
