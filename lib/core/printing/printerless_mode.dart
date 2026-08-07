// lib/core/printing/printerless_mode.dart
//
// "Modo sin impresora": la POS opera sin hardware térmico. Cuando está
// activo, los documentos que el usuario pide explícitamente (factura,
// precuenta, reimpresión, cierre de caja, recibo de movimiento) se muestran
// en pantalla con opción de compartir PDF, en vez de mandarse al papel, y
// ningún flujo se bloquea con "Impresora no configurada".
//
// Dos niveles, resueltos en este orden:
//   1. Override del DISPOSITIVO (SharedPreferences). Depende del hardware
//      físico de esa caja/tablet, así que nunca viaja al servidor.
//        - `inherit`      → usa lo que diga el negocio (default).
//        - `alwaysPrint`  → esta caja SIEMPRE imprime (tiene impresora),
//                           aunque el negocio esté en modo sin impresora.
//        - `neverPrint`   → esta caja NUNCA imprime (no tiene impresora),
//                           aunque el negocio sí imprima.
//   2. Flag del NEGOCIO (`business_settings.printerless_mode`).
//
// Las comandas a cocina son el caso aparte: NO abren modal (el mesero
// manda muchas rondas seguidas y la cocina ya ve todo en el KDS) y las
// gobierna SOLO el flag del negocio — [businessEnabled], no [isEnabled] —
// porque la impresora de cocina es compartida: que esta tablet no tenga
// impresora propia no significa que la cocina no deba recibir su comanda.
// Lo que sí desaparece ahí son los errores de "no hay impresora asignada".

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../data/repositories/pos_settings_repository.dart';

/// Decisión local de este dispositivo sobre el modo sin impresora.
enum PrinterlessDeviceOverride {
  /// Sigue la configuración del negocio (default).
  inherit,

  /// Este equipo tiene impresora y siempre debe imprimir.
  alwaysPrint,

  /// Este equipo no tiene impresora: todo va a pantalla.
  neverPrint;

  String get wireName => name;

  static PrinterlessDeviceOverride fromWire(String? raw) {
    switch (raw) {
      case 'alwaysPrint':
        return PrinterlessDeviceOverride.alwaysPrint;
      case 'neverPrint':
        return PrinterlessDeviceOverride.neverPrint;
      default:
        return PrinterlessDeviceOverride.inherit;
    }
  }

  String get label {
    switch (this) {
      case PrinterlessDeviceOverride.inherit:
        return 'Usar la configuración del negocio';
      case PrinterlessDeviceOverride.alwaysPrint:
        return 'Este equipo siempre imprime';
      case PrinterlessDeviceOverride.neverPrint:
        return 'Este equipo nunca imprime (solo pantalla)';
    }
  }

  String get description {
    switch (this) {
      case PrinterlessDeviceOverride.inherit:
        return 'Hereda el interruptor del negocio.';
      case PrinterlessDeviceOverride.alwaysPrint:
        return 'Aunque el negocio esté en modo sin impresora, esta caja '
            'manda los tickets a su impresora.';
      case PrinterlessDeviceOverride.neverPrint:
        return 'Los documentos se muestran en pantalla con opción de '
            'compartir en PDF. Útil para tablets de meseros sin impresora.';
    }
  }
}

/// Resuelve si un flujo debe imprimir o mostrar en pantalla.
///
/// El resultado se cachea en memoria por [_cacheTtl] porque se consulta en
/// caminos calientes (cada cobro, cada precuenta) y el flag cambia muy de
/// vez en cuando. `invalidate()` lo limpia al guardar desde ajustes.
class PrinterlessMode {
  PrinterlessMode._();

  static const _overrideKey = 'printerless_device_override';
  static const _cacheTtl = Duration(minutes: 2);

  static PrinterlessDeviceOverride? _overrideCache;
  static final Map<String, ({bool value, DateTime at})> _businessCache = {};

  /// Override guardado en este dispositivo. Fail-soft: si SharedPreferences
  /// no está disponible, devuelve `inherit`.
  static Future<PrinterlessDeviceOverride> deviceOverride() async {
    final cached = _overrideCache;
    if (cached != null) return cached;
    try {
      final prefs = await SharedPreferences.getInstance();
      final value = PrinterlessDeviceOverride.fromWire(
        prefs.getString(_overrideKey),
      );
      _overrideCache = value;
      return value;
    } catch (_) {
      return PrinterlessDeviceOverride.inherit;
    }
  }

  static Future<void> setDeviceOverride(
    PrinterlessDeviceOverride override,
  ) async {
    _overrideCache = override;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_overrideKey, override.wireName);
    } catch (_) {
      // Fail-soft: queda aplicado en memoria para esta sesión.
    }
  }

  /// Flag del negocio, cacheado. Nunca lanza: ante cualquier fallo (red,
  /// RLS, columna sin migrar) devuelve `false` = seguir imprimiendo, que es
  /// el comportamiento histórico.
  static Future<bool> businessEnabled(String businessId) async {
    if (businessId.isEmpty) return false;
    final hit = _businessCache[businessId];
    if (hit != null && DateTime.now().difference(hit.at) < _cacheTtl) {
      return hit.value;
    }
    try {
      final value = await PosSettingsRepository(
        Supabase.instance.client,
      ).getPrinterlessMode(businessId);
      _businessCache[businessId] = (value: value, at: DateTime.now());
      return value;
    } catch (_) {
      return hit?.value ?? false;
    }
  }

  /// Decisión efectiva: `true` = no mandar nada al papel, mostrar el
  /// documento en pantalla.
  static Future<bool> isEnabled(String? businessId) async {
    final override = await deviceOverride();
    switch (override) {
      case PrinterlessDeviceOverride.alwaysPrint:
        return false;
      case PrinterlessDeviceOverride.neverPrint:
        return true;
      case PrinterlessDeviceOverride.inherit:
        return businessEnabled(businessId ?? '');
    }
  }

  /// Limpia los caches. Se llama al guardar desde ajustes y al cambiar de
  /// negocio activo, para que el cambio se sienta de inmediato.
  static void invalidate() {
    _overrideCache = null;
    _businessCache.clear();
  }
}

/// Provider del flag del negocio (para la pantalla de ajustes). No usar en
/// caminos de impresión — ahí va [PrinterlessMode.isEnabled], que además
/// aplica el override del dispositivo.
final printerlessBusinessFlagProvider = FutureProvider.family<bool, String>((
  ref,
  businessId,
) async {
  return PrinterlessMode.businessEnabled(businessId);
});

/// Provider de la decisión efectiva para el negocio activo.
final printerlessEnabledProvider = FutureProvider.family<bool, String?>((
  ref,
  businessId,
) async {
  return PrinterlessMode.isEnabled(businessId);
});
