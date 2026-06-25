package do_mangopos.mangoposrestaurant

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothSocket
import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.IOException
import java.io.OutputStream
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors

/**
 * Transporte Bluetooth **Classic / RFCOMM (SPP)** para impresoras térmicas
 * (PRD BT — cerrar la brecha de transporte vs Loyverse y soportar impresoras
 * Classic-only). Es el complemento del camino BLE (`flutter_blue_plus`): el
 * lado Dart elige Classic cuando el equipo lo expone, y cae a BLE si no.
 *
 * El socket RFCOMM vive en el proceso de la app; el Foreground Service
 * ([PrinterForegroundService]) mantiene ese proceso vivo en background, así que
 * el socket persiste igual que la conexión GATT.
 *
 * Canales:
 *   - MethodChannel `mangopos/classic_bt`: bondedDevices, connect, write,
 *     disconnect, isConnected, isSupported.
 *   - EventChannel  `mangopos/classic_bt/events`: emite {address, connected}
 *     en cada cambio de estado del enlace (lo usa el manager Dart para
 *     reconectar).
 *
 * Toda la E/S de socket corre fuera del hilo principal; los resultados y los
 * eventos se entregan en el main looper (requisito de los channels de Flutter).
 */
class ClassicBtPlugin(private val context: Context) {

    companion object {
        private const val METHOD_CHANNEL = "mangopos/classic_bt"
        private const val EVENT_CHANNEL = "mangopos/classic_bt/events"
        // Serial Port Profile — el UUID estándar de impresoras térmicas SPP.
        private val SPP_UUID: UUID =
            UUID.fromString("00001101-0000-1000-8000-00805F9B34FB")
    }

    private val main = Handler(Looper.getMainLooper())
    private val io = Executors.newCachedThreadPool()
    private val sockets = ConcurrentHashMap<String, BluetoothSocket>()
    private val streams = ConcurrentHashMap<String, OutputStream>()
    private var eventSink: EventChannel.EventSink? = null

    private val adapter: BluetoothAdapter?
        get() = (context.getSystemService(Context.BLUETOOTH_SERVICE)
                as? BluetoothManager)?.adapter

    fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger, METHOD_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "isSupported" -> result.success(adapter != null)
                "bondedDevices" -> bondedDevices(result)
                "connect" -> connect(call.argument<String>("address"), result)
                "write" -> write(
                    call.argument<String>("address"),
                    call.argument<ByteArray>("data"),
                    result,
                )
                "disconnect" -> {
                    disconnect(call.argument<String>("address"))
                    result.success(true)
                }
                "isConnected" ->
                    result.success(isConnected(call.argument<String>("address")))
                else -> result.notImplemented()
            }
        }

        EventChannel(messenger, EVENT_CHANNEL).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
                    eventSink = sink
                }

                override fun onCancel(arguments: Any?) {
                    eventSink = null
                }
            },
        )
    }

    // ── bondedDevices (Fase 0 + selección de transporte) ────────────────────────

    /**
     * Lista los dispositivos BT **pareados** con su capacidad SPP. `hasSpp`
     * indica que el equipo expone el perfil serie (Classic) → la app puede
     * imprimirle por RFCOMM. Si está pareado pero sin SPP, probablemente sea
     * BLE-only y haya que usar GATT.
     */
    private fun bondedDevices(result: MethodChannel.Result) {
        io.execute {
            try {
                val a = adapter
                if (a == null) {
                    main.post { result.success(emptyList<Map<String, Any?>>()) }
                    return@execute
                }
                val list = a.bondedDevices.orEmpty().map { d ->
                    // device.uuids son los UUID SDP cacheados del pairing.
                    val hasSpp = d.uuids?.any { it.uuid == SPP_UUID } ?: false
                    mapOf(
                        "name" to (d.name ?: ""),
                        "address" to d.address,
                        "hasSpp" to hasSpp,
                    )
                }
                main.post { result.success(list) }
            } catch (e: SecurityException) {
                // Falta BLUETOOTH_CONNECT (no concedido en runtime).
                main.post { result.error("permission", e.message, null) }
            } catch (e: Exception) {
                main.post { result.error("bonded_error", e.message, null) }
            }
        }
    }

    // ── connect / write / disconnect ────────────────────────────────────────────

    private fun connect(address: String?, result: MethodChannel.Result) {
        if (address.isNullOrBlank()) {
            result.error("bad_args", "address requerido", null); return
        }
        io.execute {
            try {
                val a = adapter ?: throw IOException("Adaptador BT no disponible")
                // Cierra cualquier socket previo para este address.
                closeQuietly(address)
                val device = a.getRemoteDevice(address)
                // El discovery activo ralentiza/rompe la conexión RFCOMM.
                try {
                    a.cancelDiscovery()
                } catch (_: SecurityException) {
                }
                val socket = device.createRfcommSocketToServiceRecord(SPP_UUID)
                socket.connect() // bloqueante
                sockets[address] = socket
                streams[address] = socket.outputStream
                emit(address, true)
                startReader(address, socket)
                main.post { result.success(true) }
            } catch (e: Exception) {
                closeQuietly(address)
                emit(address, false)
                main.post { result.error("connect_failed", e.message, null) }
            }
        }
    }

    private fun write(address: String?, data: ByteArray?, result: MethodChannel.Result) {
        if (address.isNullOrBlank() || data == null) {
            result.error("bad_args", "address y data requeridos", null); return
        }
        io.execute {
            val out = streams[address]
            if (out == null) {
                main.post { result.error("not_connected", "Sin enlace para $address", null) }
                return@execute
            }
            try {
                // RFCOMM streamea: escribimos el buffer completo de un tirón (a
                // diferencia de BLE, sin trocear por MTU).
                out.write(data)
                out.flush()
                main.post { result.success(true) }
            } catch (e: IOException) {
                // Caída del enlace: cerramos y notificamos para que el manager
                // dispare la reconexión.
                closeQuietly(address)
                emit(address, false)
                main.post { result.error("write_failed", e.message, null) }
            }
        }
    }

    private fun disconnect(address: String?) {
        if (address.isNullOrBlank()) return
        closeQuietly(address)
        emit(address, false)
    }

    private fun isConnected(address: String?): Boolean {
        if (address.isNullOrBlank()) return false
        val s = sockets[address] ?: return false
        return try {
            s.isConnected
        } catch (_: Exception) {
            false
        }
    }

    // ── helpers ─────────────────────────────────────────────────────────────────

    /** Lee y descarta del socket solo para detectar EOF/IOException (caída). */
    private fun startReader(address: String, socket: BluetoothSocket) {
        io.execute {
            val buf = ByteArray(256)
            try {
                val input = socket.inputStream
                while (true) {
                    val n = input.read(buf)
                    if (n < 0) break // EOF → el otro extremo cerró
                }
            } catch (_: Exception) {
                // IOException típica cuando el enlace cae.
            } finally {
                // Solo notificamos si seguíamos considerándolo este socket
                // (evita falsos negativos si ya se reconectó con otro socket).
                if (sockets[address] === socket) {
                    closeQuietly(address)
                    emit(address, false)
                }
            }
        }
    }

    private fun closeQuietly(address: String) {
        streams.remove(address)?.let { try { it.close() } catch (_: Exception) {} }
        sockets.remove(address)?.let { try { it.close() } catch (_: Exception) {} }
    }

    private fun emit(address: String, connected: Boolean) {
        main.post {
            eventSink?.success(mapOf("address" to address, "connected" to connected))
        }
    }
}
