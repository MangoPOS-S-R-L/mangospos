import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:mangopos/core/business/business_features_provider.dart';
import 'package:mangopos/core/offline/offline_catalog_service.dart';
import 'package:mangopos/core/business/business_model.dart';
import 'package:mangopos/services/session/session_controller.dart';
import '../viewmodel/sales_viewmodel.dart';

/// Escucha un lector de código de barras USB/HID (RF-R1). Un lector HID se
/// comporta como un teclado: emite los caracteres del código en ráfaga rápida
/// y termina con Enter. Distinguimos ráfaga (lector) de tecleo humano por el
/// tiempo entre teclas: si pasa más de [_interKeyResetMs] entre dos teclas,
/// reiniciamos el buffer, así nadie dispara un "escaneo" tecleando a mano.
///
/// Se registra en [ScanDispatcher] mientras [enabled] es true, sin robar foco
/// a los campos de texto. Caveat v1: si hay un TextField enfocado, el lector
/// escribe ahí (no consumimos los caracteres). En el POS en reposo no hay
/// campo enfocado, que es el caso normal de caja.
///
/// Cuando hay varias pantallas montadas a la vez (mesa encima de venta
/// rápida), SOLO la de arriba recibe el escaneo — ver [ScanDispatcher].
class BarcodeScanListener extends StatefulWidget {
  const BarcodeScanListener({
    super.key,
    required this.enabled,
    required this.onScan,
    required this.child,
  });

  final bool enabled;
  final ValueChanged<String> onScan;
  final Widget child;

  @override
  State<BarcodeScanListener> createState() => _BarcodeScanListenerState();
}

/// Despachador ÚNICO del lector HID.
///
/// POR QUÉ EXISTE — bug de campo: "la pistola no me agrega nada, ni en venta
/// rápida ni por zona".
///
///   `HardwareKeyboard` invoca TODOS los handlers registrados; no se detiene
///   en el primero que responde. Y en esta app hay más de un
///   `PosBarcodeScanner` vivo a la vez: la rama de ventas del
///   `StatefulShellRoute.indexedStack` NO se desmonta al abrir una mesa,
///   porque la ruta de mesa se empuja FUERA del shell, encima de ella.
///
///   Con dos escáneres vivos, un escaneo disparaba dos `onScan`. El de la
///   mesa agregaba el producto y el de venta rápida —que trae
///   `autoOpenQuick`— intentaba abrir OTRA orden sobre el mismo provider
///   global, o gritaba "Inicia la venta antes de escanear". Como cada uno
///   hace `hideCurrentSnackBar()` antes del suyo, el cajero solo veía el
///   ÚLTIMO mensaje, casi siempre el error. De ahí "no funciona".
///
/// CÓMO LO RESUELVE: un solo handler de teclado para toda la app y una PILA
/// de suscriptores. El escaneo va únicamente al último registrado, que es
/// siempre la pantalla de arriba. Al cerrarla, el de abajo vuelve a mandar.
class ScanDispatcher {
  ScanDispatcher._();
  static final ScanDispatcher instance = ScanDispatcher._();

  final List<ValueChanged<String>> _stack = [];
  bool _attached = false;

  // Un lector dispara teclas con < 30ms de separación; un humano rápido teclea
  // a > 100ms. 120ms deja margen sin confundir tecleo lento con escaneo.
  static const int _interKeyResetMs = 120;
  // Piso de longitud para tratar un buffer como código: evita falsos disparos
  // por un Enter suelto. EAN/UPC tienen 8–13 dígitos.
  static const int _minLength = 3;

  /// Cierre por INACTIVIDAD, para lectores sin sufijo configurado.
  ///
  /// El disparo por Enter cubre el caso de fábrica más común, pero no todos:
  /// hay lectores que vienen con sufijo Tab y otros sin sufijo ninguno. Con
  /// solo Enter, esos NUNCA disparaban un escaneo — la pistola "no hacía
  /// nada" y no había forma de distinguirlo de un problema de la app. Si tras
  /// el último carácter no llega otra tecla en esta ventana, se cierra el
  /// código igual.
  static const int _idleFlushMs = 140;

  /// Un cierre por inactividad SOLO se acepta si todas las teclas llegaron en
  /// ráfaga (< este umbral entre sí). Un lector va a ~30ms; ningún humano
  /// sostiene 50ms tecla a tecla. Sin esta condición, alguien tecleando
  /// rápido en un campo dispararía escaneos fantasma.
  static const int _burstGapMs = 50;

  final StringBuffer _buffer = StringBuffer();
  DateTime? _lastKeyTime;
  Timer? _idleTimer;

  /// ¿Todas las teclas del buffer actual llegaron a velocidad de lector?
  bool _isBurst = true;

  void subscribe(ValueChanged<String> onScan) {
    // `remove` primero: re-suscribir mueve al tope en vez de duplicar.
    _stack.remove(onScan);
    _stack.add(onScan);
    if (!_attached) {
      HardwareKeyboard.instance.addHandler(_onKey);
      _attached = true;
    }
  }

  void unsubscribe(ValueChanged<String> onScan) {
    _stack.remove(onScan);
    _idleTimer?.cancel();
    _idleTimer = null;
    _buffer.clear();
    _lastKeyTime = null;
    _isBurst = true;
    if (_stack.isEmpty && _attached) {
      HardwareKeyboard.instance.removeHandler(_onKey);
      _attached = false;
    }
  }

  /// Cuántas pantallas hay escuchando. Solo para pruebas y diagnóstico.
  @visibleForTesting
  int get subscriberCount => _stack.length;

  /// Inyecta un evento como si viniera del teclado. Solo para pruebas.
  @visibleForTesting
  bool feedKey(KeyEvent event) => _onKey(event);

  @visibleForTesting
  void resetForTest() {
    if (_attached) {
      HardwareKeyboard.instance.removeHandler(_onKey);
      _attached = false;
    }
    _idleTimer?.cancel();
    _idleTimer = null;
    _stack.clear();
    _buffer.clear();
    _lastKeyTime = null;
    _isBurst = true;
  }

  bool _isBarcodeChar(String ch) {
    final c = ch.codeUnitAt(0);
    final isDigit = c >= 48 && c <= 57;
    final isUpper = c >= 65 && c <= 90;
    final isLower = c >= 97 && c <= 122;
    return isDigit || isUpper || isLower || ch == '-';
  }

  /// Cierra el código en curso y lo entrega al suscriptor de arriba.
  /// Devuelve true si hubo escaneo.
  bool _flush({required bool requireBurst}) {
    _idleTimer?.cancel();
    _idleTimer = null;
    final code = _buffer.toString();
    _buffer.clear();
    _lastKeyTime = null;
    final wasBurst = _isBurst;
    _isBurst = true;

    if (code.length < _minLength) return false;
    if (requireBurst && !wasBurst) return false;
    if (_stack.isEmpty) return false;

    // SOLO el tope de la pila: la pantalla que el cajero está viendo.
    _stack.last(code);
    return true;
  }

  bool _onKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    if (_stack.isEmpty) return false;

    final key = event.logicalKey;
    // Enter y Tab son los dos sufijos de fábrica habituales en los lectores
    // HID. Se aceptan ambos; el que no traiga ninguno cae al cierre por
    // inactividad de abajo.
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.tab) {
      // Con sufijo explícito no exigimos ráfaga: el terminador ya es señal
      // suficiente, y así un lector lento o una tecla perdida no lo anulan.
      final scanned = _flush(requireBurst: false);
      // Consumimos la tecla solo si cerró un escaneo; el Enter/Tab humano
      // sigue su curso normal.
      return scanned;
    }

    final now = DateTime.now();
    final gapMs = _lastKeyTime == null
        ? null
        : now.difference(_lastKeyTime!).inMilliseconds;
    if (gapMs != null && gapMs > _interKeyResetMs) {
      _buffer.clear();
      _isBurst = true;
    } else if (gapMs != null && gapMs > _burstGapMs) {
      // Llegó dentro de la ventana pero a ritmo humano: sirve para un cierre
      // por Enter, no para uno por inactividad.
      _isBurst = false;
    }
    _lastKeyTime = now;

    final ch = event.character;
    if (ch != null && ch.length == 1 && _isBarcodeChar(ch)) {
      _buffer.write(ch);
      _idleTimer?.cancel();
      _idleTimer = Timer(
        const Duration(milliseconds: _idleFlushMs),
        () => _flush(requireBurst: true),
      );
    }
    // Observamos sin consumir: no rompemos el tecleo normal (caveat v1).
    return false;
  }
}

class _BarcodeScanListenerState extends State<BarcodeScanListener> {
  // Identidad estable dentro de la pila del despachador. Si se suscribiera
  // `widget.onScan` directo, cada rebuild del padre traería un closure nuevo
  // y `remove` no encontraría el anterior: la pila se llenaría de zombis.
  void _dispatch(String code) => widget.onScan(code);

  @override
  void initState() {
    super.initState();
    if (widget.enabled) {
      ScanDispatcher.instance.subscribe(_dispatch);
    }
  }

  @override
  void didUpdateWidget(BarcodeScanListener oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.enabled != oldWidget.enabled) {
      if (widget.enabled) {
        ScanDispatcher.instance.subscribe(_dispatch);
      } else {
        ScanDispatcher.instance.unsubscribe(_dispatch);
      }
    }
  }

  @override
  void dispose() {
    // Sin condicionar a `enabled`: si el flag cambió a false y luego el widget
    // se destruye, la suscripción vieja tiene que salir igual.
    ScanDispatcher.instance.unsubscribe(_dispatch);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Conecta el lector HID al POS: gateado por `barcodeEnabled`, resuelve el
/// código a un producto (catálogo offline primero, fallback online) y lo agrega
/// a la orden actual vía [currentOrderProvider]. Da feedback con un SnackBar.
///
/// Agregar con solo `menuItemId` es tax-safe: el backend resuelve precio e
/// impuestos. Si [autoOpenQuick] y no hay orden abierta, abre venta rápida.
class PosBarcodeScanner extends ConsumerStatefulWidget {
  const PosBarcodeScanner({
    super.key,
    required this.child,
    this.autoOpenQuick = false,
  });

  final Widget child;
  final bool autoOpenQuick;

  @override
  ConsumerState<PosBarcodeScanner> createState() => _PosBarcodeScannerState();
}

class _PosBarcodeScannerState extends ConsumerState<PosBarcodeScanner> {
  final OfflineCatalogService _catalog = OfflineCatalogService();
  bool _busy = false;

  // Solo aceptamos códigos alfanuméricos (y guion): valida la entrada y
  // mantiene seguro el `.or()` de PostgREST en el fallback online.
  static final RegExp _validCode = RegExp(r'^[A-Za-z0-9\-]{3,}$');

  Future<void> _handleScan(String rawCode) async {
    if (_busy) return;
    final code = rawCode.trim();
    if (!_validCode.hasMatch(code)) {
      debugPrint('[scan] descartado (formato): "$rawCode"');
      return;
    }

    final businessId = ref.read(sessionProvider).activeBusinessId;
    if (businessId == null || businessId.isEmpty) {
      debugPrint('[scan] sin negocio activo, se ignora "$code"');
      return;
    }

    _busy = true;
    try {
      final hit = await _resolve(code, businessId);
      if (!mounted) return;
      if (hit == null) {
        debugPrint('[scan] "$code" no resolvió a ningún producto');
        _toast('Código no encontrado: $code', error: true);
        return;
      }

      final notifier = ref.read(currentOrderProvider.notifier);
      if (ref.read(currentOrderProvider).order == null) {
        if (widget.autoOpenQuick) {
          // Retail: enrutar por el sistema de carritos (ensureQuickOrder crea
          // el primer carrito si no hay), no abrir una sesión quick única.
          if (ref.read(currentBusinessModelProvider).isRetail) {
            await notifier.ensureQuickOrder();
          } else {
            await notifier.openQuick();
          }
          if (!mounted) return;
        } else {
          _toast('Inicia la venta antes de escanear', error: true);
          return;
        }
      }

      // `addItem` NO lanza cuando lo rechaza el gate de permisos ni cuando el
      // backend falla: deja el motivo en `state.error` y vuelve. Sin comparar
      // el antes/después, el escáner cantaba "Agregado" con la cuenta intacta
      // — el cajero escaneaba diez veces creyendo que la pistola fallaba.
      final errorBefore = ref.read(currentOrderProvider).error;
      await notifier.addItem(menuItemId: hit.id, qty: 1);
      if (!mounted) return;

      final errorAfter = ref.read(currentOrderProvider).error;
      if (errorAfter != null && errorAfter != errorBefore) {
        debugPrint('[scan] "$code" → ${hit.name}: rechazado ($errorAfter)');
        _toast(errorAfter, error: true);
        return;
      }

      debugPrint('[scan] "$code" → ${hit.name}: agregado');
      _toast('Agregado: ${hit.name}');
    } finally {
      _busy = false;
    }
  }

  /// Resuelve el código: snapshot offline primero (funciona sin conexión),
  /// luego fallback online por si el snapshot aún no trae barcode/sku.
  Future<_ScanHit?> _resolve(String code, String businessId) async {
    final snapshot = await _catalog.loadSnapshot(businessId);
    final local = snapshot?.findByBarcode(code);
    if (local != null) {
      return _ScanHit(
        id: local['id'].toString(),
        name: local['name']?.toString() ?? 'Producto',
      );
    }

    try {
      final row = await Supabase.instance.client
          .from('menu_items')
          .select('id,name')
          .eq('business_id', businessId)
          .eq('is_active', true)
          .or('barcode.eq.$code,sku.eq.$code')
          .limit(1)
          .maybeSingle();
      if (row != null) {
        return _ScanHit(
          id: row['id'].toString(),
          name: row['name']?.toString() ?? 'Producto',
        );
      }
    } catch (_) {
      // Sin conexión o error: ya intentamos offline; devolvemos null.
    }
    return null;
  }

  void _toast(String message, {bool error = false}) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          duration: const Duration(milliseconds: 1400),
          behavior: SnackBarBehavior.floating,
          backgroundColor: error ? Colors.red.shade700 : Colors.green.shade700,
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final enabled =
        ref.watch(businessFeaturesProvider).value?.barcodeEnabled ?? false;
    return BarcodeScanListener(
      enabled: enabled,
      onScan: _handleScan,
      child: widget.child,
    );
  }
}

class _ScanHit {
  const _ScanHit({required this.id, required this.name});
  final String id;
  final String name;
}
