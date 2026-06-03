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
/// Observa el teclado global ([HardwareKeyboard]) mientras [enabled] es true,
/// sin robar foco a los campos de texto. Caveat v1: si hay un TextField
/// enfocado, el lector escribe ahí (no consumimos los caracteres). En el POS
/// en reposo no hay campo enfocado, que es el caso normal de caja.
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

class _BarcodeScanListenerState extends State<BarcodeScanListener> {
  // Un lector dispara teclas con < 30ms de separación; un humano rápido teclea
  // a > 100ms. 120ms deja margen sin confundir tecleo lento con escaneo.
  static const int _interKeyResetMs = 120;
  // Piso de longitud para tratar un buffer como código: evita falsos disparos
  // por un Enter suelto. EAN/UPC tienen 8–13 dígitos.
  static const int _minLength = 3;

  final StringBuffer _buffer = StringBuffer();
  DateTime? _lastKeyTime;

  @override
  void initState() {
    super.initState();
    if (widget.enabled) {
      HardwareKeyboard.instance.addHandler(_onKey);
    }
  }

  @override
  void didUpdateWidget(BarcodeScanListener oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.enabled != oldWidget.enabled) {
      if (widget.enabled) {
        HardwareKeyboard.instance.addHandler(_onKey);
      } else {
        HardwareKeyboard.instance.removeHandler(_onKey);
        _buffer.clear();
        _lastKeyTime = null;
      }
    }
  }

  @override
  void dispose() {
    if (widget.enabled) {
      HardwareKeyboard.instance.removeHandler(_onKey);
    }
    super.dispose();
  }

  bool _isBarcodeChar(String ch) {
    final c = ch.codeUnitAt(0);
    final isDigit = c >= 48 && c <= 57;
    final isUpper = c >= 65 && c <= 90;
    final isLower = c >= 97 && c <= 122;
    return isDigit || isUpper || isLower || ch == '-';
  }

  bool _onKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;

    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      final code = _buffer.toString();
      _buffer.clear();
      _lastKeyTime = null;
      if (code.length >= _minLength) {
        widget.onScan(code);
        return true; // consumimos el Enter del escaneo
      }
      return false; // Enter humano normal pasa
    }

    final now = DateTime.now();
    if (_lastKeyTime != null &&
        now.difference(_lastKeyTime!).inMilliseconds > _interKeyResetMs) {
      _buffer.clear();
    }
    _lastKeyTime = now;

    final ch = event.character;
    if (ch != null && ch.length == 1 && _isBarcodeChar(ch)) {
      _buffer.write(ch);
    }
    // Observamos sin consumir: no rompemos el tecleo normal (caveat v1).
    return false;
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
    if (!_validCode.hasMatch(code)) return;

    final businessId = ref.read(sessionProvider).activeBusinessId;
    if (businessId == null || businessId.isEmpty) return;

    _busy = true;
    try {
      final hit = await _resolve(code, businessId);
      if (!mounted) return;
      if (hit == null) {
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
        } else {
          _toast('Inicia la venta antes de escanear', error: true);
          return;
        }
      }

      await notifier.addItem(menuItemId: hit.id, qty: 1);
      if (!mounted) return;
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
    final enabled = ref.watch(businessFeaturesProvider).value?.barcodeEnabled ??
        false;
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
