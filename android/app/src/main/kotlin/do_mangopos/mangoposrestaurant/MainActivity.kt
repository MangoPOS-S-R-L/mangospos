package do_mangopos.mangoposrestaurant

import android.content.Context
import android.content.Intent
import android.net.wifi.WifiManager
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Platform channel para priorizar la impresión por red en Android.
 *
 * Android, por ahorro de energía, hace dos cosas que rompen la impresión por
 * red/subredes:
 *   1. El driver WiFi descarta el tráfico MULTICAST entrante salvo que la app
 *      mantenga un [WifiManager.MulticastLock]. Sin él, el descubrimiento mDNS
 *      (impresoras AirPrint/IPP y print agents `_mangoprint._tcp`) regresa
 *      vacío aunque el equipo esté en la misma LAN.
 *   2. El radio WiFi entra en power-save al inactivarse la pantalla, lo que
 *      hace que el primer `Socket.connect` a la impresora tras un rato falle o
 *      tarde varios segundos (el cajero ve un "blip" en el primer cobro).
 *
 * Este canal expone locks contados por referencia:
 *   - MulticastLock: se toma solo durante una pasada de descubrimiento mDNS.
 *   - WifiLock (alto rendimiento): se mantiene durante toda la sesión POS
 *     activa para que el radio no duerma y el TCP a la térmica sea inmediato.
 *
 * El conteo por referencia permite acquire/release anidados sin soltar el lock
 * antes de tiempo. Lado Dart: [AndroidNetLock] en lib/core/network/.
 */
class MainActivity : FlutterActivity() {
    private val channelName = "mangopos/net_lock"
    private val printerFgsChannelName = "mangopos/printer_fgs"

    private var multicastLock: WifiManager.MulticastLock? = null
    private var multicastRefCount = 0

    private var wifiLock: WifiManager.WifiLock? = null
    private var wifiRefCount = 0

    private val wifiManager: WifiManager?
        get() = applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "acquireMulticastLock" -> {
                            acquireMulticastLock()
                            result.success(true)
                        }
                        "releaseMulticastLock" -> {
                            releaseMulticastLock()
                            result.success(true)
                        }
                        "acquireWifiLock" -> {
                            acquireWifiLock()
                            result.success(true)
                        }
                        "releaseWifiLock" -> {
                            releaseWifiLock()
                            result.success(true)
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    // Nunca propagamos: el lado Dart trata cualquier fallo como
                    // no-op (la impresión sigue funcionando, solo sin la mejora).
                    result.error("net_lock_error", e.message, null)
                }
            }

        // Channel del Foreground Service de impresora (PRD BT — Fase 1). El
        // lado Dart (AndroidPrinterForegroundService) llama start/stop según
        // haya o no una impresora BT activa configurada.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, printerFgsChannelName)
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "start" -> {
                            startPrinterService()
                            result.success(true)
                        }
                        "stop" -> {
                            stopPrinterService()
                            result.success(true)
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    // Best-effort: si el servicio no arranca, la impresión sigue
                    // funcionando en foreground; solo se pierde la persistencia.
                    result.error("printer_fgs_error", e.message, null)
                }
            }

        // Transporte Classic/RFCOMM (registra mangopos/classic_bt + events).
        classicBt.register(flutterEngine.dartExecutor.binaryMessenger)

        // Impresión USB OTG síncrona/verificada (registra mangopos/usb_raw_printer).
        usbRawPrinter.register(flutterEngine.dartExecutor.binaryMessenger)
    }

    // Transporte Classic/RFCOMM (SPP) para impresoras térmicas. El lado Dart
    // (ClassicBluetooth) lo usa para Fase 0 (bondedDevices+SPP) y como backend
    // de impresión cuando el equipo expone Classic.
    private val classicBt by lazy { ClassicBtPlugin(applicationContext) }

    // Impresión USB OTG con bulkTransfer troceado y verificado (arregla los
    // tickets que salían por la mitad con flutter_usb_printer).
    private val usbRawPrinter by lazy { UsbRawPrinterPlugin(applicationContext) }

    private fun printerServiceIntent() =
        Intent(this, PrinterForegroundService::class.java)

    private fun startPrinterService() {
        // startForegroundService obliga al servicio a llamar startForeground()
        // en ≤5s; PrinterForegroundService lo hace en onStartCommand.
        ContextCompat.startForegroundService(this, printerServiceIntent())
    }

    private fun stopPrinterService() {
        // stopService dispara onDestroy y retira la notificación foreground,
        // sin violar el contrato de startForeground() (a diferencia de mandar
        // un ACTION_STOP por startForegroundService).
        stopService(printerServiceIntent())
    }

    @Synchronized
    private fun acquireMulticastLock() {
        if (multicastRefCount == 0) {
            val wm = wifiManager ?: return
            val lock = wm.createMulticastLock("mangopos:mdns").apply {
                setReferenceCounted(false)
                acquire()
            }
            multicastLock = lock
        }
        multicastRefCount++
    }

    @Synchronized
    private fun releaseMulticastLock() {
        if (multicastRefCount == 0) return
        multicastRefCount--
        if (multicastRefCount == 0) {
            multicastLock?.let { if (it.isHeld) it.release() }
            multicastLock = null
        }
    }

    @Synchronized
    private fun acquireWifiLock() {
        if (wifiRefCount == 0) {
            val wm = wifiManager ?: return
            // FULL_HIGH_PERF mantiene el radio activo y sin power-save. Está
            // deprecado desde API 29 pero sigue siendo el modo correcto y
            // soportado para baja latencia sostenida (un POS suele estar
            // enchufado, así que el costo de batería es aceptable).
            @Suppress("DEPRECATION")
            val mode = WifiManager.WIFI_MODE_FULL_HIGH_PERF
            val lock = wm.createWifiLock(mode, "mangopos:print").apply {
                setReferenceCounted(false)
                acquire()
            }
            wifiLock = lock
        }
        wifiRefCount++
    }

    @Synchronized
    private fun releaseWifiLock() {
        if (wifiRefCount == 0) return
        wifiRefCount--
        if (wifiRefCount == 0) {
            wifiLock?.let { if (it.isHeld) it.release() }
            wifiLock = null
        }
    }

    override fun onDestroy() {
        // Garantía de no fugar locks si la Activity se destruye con la sesión
        // POS aún "activa" (p.ej. el usuario mata la app sin logout).
        multicastLock?.let { if (it.isHeld) it.release() }
        multicastLock = null
        multicastRefCount = 0
        wifiLock?.let { if (it.isHeld) it.release() }
        wifiLock = null
        wifiRefCount = 0
        super.onDestroy()
    }
}
