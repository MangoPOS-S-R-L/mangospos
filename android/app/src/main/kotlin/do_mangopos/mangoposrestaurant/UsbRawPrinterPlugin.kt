package do_mangopos.mangoposrestaurant

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbConstants
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbEndpoint
import android.hardware.usb.UsbInterface
import android.hardware.usb.UsbManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * Impresión USB (OTG) **síncrona y verificada** para impresoras térmicas.
 *
 * Reemplaza el `write()` de `flutter_usb_printer`, que dispara el
 * `bulkTransfer` en un Thread suelto y devuelve `true` de inmediato: el lado
 * Dart cree que ya terminó, cierra la conexión y el ticket sale por la mitad.
 * Además ese plugin manda el buffer completo en UNA llamada (en Android < 9
 * `bulkTransfer` trunca a 16 KB en silencio) e ignora el valor de retorno,
 * así que las transferencias parciales se pierden sin error.
 *
 * Aquí la escritura:
 *   - corre en un executor y el result se entrega SOLO cuando el último byte
 *     fue aceptado por el dispositivo (o con error si no);
 *   - va troceada en bloques de 4 KB y avanza por los bytes REALMENTE
 *     transferidos que reporta `bulkTransfer` (maneja escrituras cortas);
 *   - reintenta una vez por bloque ante un fallo transitorio (buffer de la
 *     impresora lleno a mitad de un raster grande).
 *
 * Canal: MethodChannel `mangopos/usb_raw_printer` — listDevices, write.
 * Lado Dart: [AndroidUsbRawPrinter] en lib/core/printing/.
 */
class UsbRawPrinterPlugin(private val context: Context) {

    companion object {
        private const val METHOD_CHANNEL = "mangopos/usb_raw_printer"
        private const val ACTION_USB_PERMISSION =
            "do_mangopos.mangoposrestaurant.USB_PERMISSION"
        private const val CHUNK_SIZE = 4 * 1024
        // Por bloque: una térmica con el buffer lleno puede tardar en drenar
        // mientras imprime un logo raster; 15s por 4 KB es holgadísimo y aun
        // así acota un cuelgue real.
        private const val CHUNK_TIMEOUT_MS = 15_000
        // El diálogo de permiso USB requiere interacción del usuario.
        private const val PERMISSION_TIMEOUT_S = 30L
    }

    private val main = Handler(Looper.getMainLooper())
    private val io = Executors.newSingleThreadExecutor()

    private val usbManager: UsbManager?
        get() = context.getSystemService(Context.USB_SERVICE) as? UsbManager

    fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger, METHOD_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "listDevices" -> listDevices(result)
                "write" -> write(
                    call.argument<Int>("vendorId"),
                    call.argument<Int>("productId"),
                    call.argument<ByteArray>("data"),
                    result,
                )
                else -> result.notImplemented()
            }
        }
    }

    private fun listDevices(result: MethodChannel.Result) {
        io.execute {
            try {
                val devices = usbManager?.deviceList?.values.orEmpty()
                    .filter { findBulkOut(it) != null }
                    .map { d ->
                        mapOf(
                            "vendorId" to d.vendorId,
                            "productId" to d.productId,
                            "manufacturer" to d.manufacturerName,
                            "productName" to d.productName,
                            "deviceName" to d.deviceName,
                        )
                    }
                main.post { result.success(devices) }
            } catch (e: Exception) {
                main.post { result.error("usb_list_error", e.message, null) }
            }
        }
    }

    private fun write(
        vendorId: Int?,
        productId: Int?,
        data: ByteArray?,
        result: MethodChannel.Result,
    ) {
        if (vendorId == null || productId == null || data == null) {
            result.error("usb_bad_args", "vendorId/productId/data requeridos", null)
            return
        }
        io.execute {
            try {
                writeBlocking(vendorId, productId, data)
                main.post { result.success(true) }
            } catch (e: UsbPrintException) {
                main.post { result.error(e.code, e.message, null) }
            } catch (e: Exception) {
                main.post { result.error("usb_write_error", e.message, null) }
            }
        }
    }

    private class UsbPrintException(val code: String, message: String) :
        Exception(message)

    private fun writeBlocking(vendorId: Int, productId: Int, data: ByteArray) {
        val manager = usbManager
            ?: throw UsbPrintException("usb_unavailable", "USB no disponible en este equipo")

        val device = manager.deviceList.values
            .firstOrNull { it.vendorId == vendorId && it.productId == productId }
            ?: throw UsbPrintException(
                "usb_device_not_found",
                "Impresora USB $vendorId:$productId no conectada",
            )

        ensurePermission(manager, device)

        val (iface, endpoint) = findBulkOut(device)
            ?: throw UsbPrintException(
                "usb_no_endpoint",
                "El dispositivo no expone un endpoint de impresión (bulk OUT)",
            )

        val connection = manager.openDevice(device)
            ?: throw UsbPrintException(
                "usb_open_failed",
                "No se pudo abrir la impresora USB (¿permiso revocado o cable OTG?)",
            )
        try {
            if (!connection.claimInterface(iface, true)) {
                throw UsbPrintException(
                    "usb_claim_failed",
                    "No se pudo reclamar la interfaz de la impresora USB",
                )
            }
            try {
                var offset = 0
                while (offset < data.size) {
                    val len = minOf(CHUNK_SIZE, data.size - offset)
                    var sent = connection.bulkTransfer(
                        endpoint, data, offset, len, CHUNK_TIMEOUT_MS,
                    )
                    if (sent < 0) {
                        // Reintento único: buffer de la impresora lleno o bump
                        // transitorio del bus; darle aire y volver a intentar.
                        Thread.sleep(250)
                        sent = connection.bulkTransfer(
                            endpoint, data, offset, len, CHUNK_TIMEOUT_MS,
                        )
                    }
                    if (sent < 0) {
                        throw UsbPrintException(
                            "usb_transfer_failed",
                            "La impresora dejó de aceptar datos en el byte " +
                                "$offset de ${data.size}",
                        )
                    }
                    // `sent` puede ser menor que `len` (escritura corta):
                    // avanzamos exactamente lo aceptado, sin perder bytes.
                    offset += sent
                }
            } finally {
                connection.releaseInterface(iface)
            }
        } finally {
            connection.close()
        }
    }

    /** Pide el permiso USB al sistema si falta y espera la respuesta del usuario. */
    private fun ensurePermission(manager: UsbManager, device: UsbDevice) {
        if (manager.hasPermission(device)) return

        val latch = CountDownLatch(1)
        var granted = false
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(ctx: Context?, intent: Intent?) {
                if (intent?.action == ACTION_USB_PERMISSION) {
                    granted = intent.getBooleanExtra(
                        UsbManager.EXTRA_PERMISSION_GRANTED, false,
                    )
                    latch.countDown()
                }
            }
        }
        ContextCompat.registerReceiver(
            context,
            receiver,
            IntentFilter(ACTION_USB_PERMISSION),
            ContextCompat.RECEIVER_NOT_EXPORTED,
        )
        try {
            // FLAG_MUTABLE: el sistema rellena los extras del resultado.
            val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                PendingIntent.FLAG_MUTABLE
            } else {
                0
            }
            val pi = PendingIntent.getBroadcast(
                context, 0,
                Intent(ACTION_USB_PERMISSION).setPackage(context.packageName),
                flags,
            )
            manager.requestPermission(device, pi)
            if (!latch.await(PERMISSION_TIMEOUT_S, TimeUnit.SECONDS) || !granted) {
                throw UsbPrintException(
                    "usb_permission_denied",
                    "Permiso USB no concedido para la impresora",
                )
            }
        } finally {
            try {
                context.unregisterReceiver(receiver)
            } catch (_: Exception) {
                // best-effort
            }
        }
    }

    /**
     * Busca la pareja interfaz + endpoint bulk OUT. Prefiere la interfaz de
     * clase PRINTER (7); si no hay, cae a la primera con bulk OUT (algunas
     * térmicas genéricas se anuncian como vendor-specific).
     */
    private fun findBulkOut(device: UsbDevice): Pair<UsbInterface, UsbEndpoint>? {
        var fallback: Pair<UsbInterface, UsbEndpoint>? = null
        for (i in 0 until device.interfaceCount) {
            val iface = device.getInterface(i)
            for (e in 0 until iface.endpointCount) {
                val ep = iface.getEndpoint(e)
                val isBulkOut = ep.type == UsbConstants.USB_ENDPOINT_XFER_BULK &&
                    ep.direction == UsbConstants.USB_DIR_OUT
                if (!isBulkOut) continue
                if (iface.interfaceClass == UsbConstants.USB_CLASS_PRINTER) {
                    return iface to ep
                }
                if (fallback == null) fallback = iface to ep
            }
        }
        return fallback
    }
}
