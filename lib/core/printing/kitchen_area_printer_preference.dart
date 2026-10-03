// Impresora de comanda por dispositivo cuando un área de producción tiene
// 2+ impresoras (p. ej. "Cocina 1" y "Cocina 2"). Igual que la precuenta
// (`PrechecPrinterPreference`): se elige al tocar «Enviar Pedido» y queda
// fijada en ESTE dispositivo; mantener presionado el botón vuelve a preguntar.
//
// Local a propósito: funciona sin internet y cada tablet decide la suya.
// La clave va por CÓDIGO de área (único por negocio) y no por id porque el
// envío sin internet solo conoce el código.

import 'package:shared_preferences/shared_preferences.dart';

import 'package:mangopos/data/models/printing.dart';

/// Pregunta en qué impresora imprime ESTE dispositivo un área con 2+
/// impresoras de comanda (lo provee la pantalla de venta: necesita
/// BuildContext). Devuelve el id de la impresora,
/// [KitchenAreaPrinterPreference.allPrinters], o null si cerraron el
/// selector sin elegir. [current] es la elección fijada (para marcarla).
typedef KitchenAreaPrinterChooser =
    Future<String?> Function(
      String areaName,
      List<PrinterConfig> printers,
      String? current,
    );

class KitchenAreaPrinterPreference {
  static const _keyPrefix = 'kitchen_area_printer_';

  /// Elección "todas las impresoras del área". Coincide con el `persistKey`
  /// del destino `PrintDestination.allPrinters()`.
  static const allPrinters = '__allPrinters';

  static String _key(String deviceId, String areaCode) =>
      '$_keyPrefix${deviceId}_$areaCode';

  /// Id de la impresora fijada, [allPrinters], o null si nunca se eligió.
  static Future<String?> read({
    required String deviceId,
    required String areaCode,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_key(deviceId, areaCode));
    } catch (_) {
      return null;
    }
  }

  /// Fail-soft: si SharedPreferences falla, la comanda sale igual.
  static Future<void> save({
    required String deviceId,
    required String areaCode,
    required String choice,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key(deviceId, areaCode), choice);
    } catch (_) {
      // ignore
    }
  }

  /// La elección sigue sirviendo: es "todas" o una impresora que todavía
  /// está en el área. Si la quitaron del área, hay que volver a elegir.
  static bool isValid(String? choice, List<PrinterConfig> printers) =>
      choice == allPrinters ||
      (choice != null && printers.any((p) => p.id == choice));

  /// Impresoras de comanda que usa este dispositivo en un área. Con una sola
  /// es esa. Con 2+ manda la elección fijada; si falta o ya no sirve y hay
  /// [chooser], se pregunta y se guarda. [forceChoose] pregunta aunque haya
  /// una fijada. Si cierran sin elegir: la fijada, o todas sin guardar.
  static Future<List<PrinterConfig>> resolve({
    required String deviceId,
    required String areaCode,
    required String areaLabel,
    required List<PrinterConfig> printers,
    KitchenAreaPrinterChooser? chooser,
    bool forceChoose = false,
  }) async {
    if (printers.length < 2) return printers;
    final saved = await read(deviceId: deviceId, areaCode: areaCode);
    var choice = isValid(saved, printers) ? saved : null;
    if (chooser != null && (forceChoose || choice == null)) {
      final picked = await chooser(areaLabel, printers, choice);
      if (isValid(picked, printers)) {
        choice = picked;
        await save(deviceId: deviceId, areaCode: areaCode, choice: picked!);
      }
    }
    return apply(choice, printers);
  }

  /// Impresoras a usar según [choice]. Sin elección válida: todas, que es
  /// como funcionaba antes de existir la elección por dispositivo.
  static List<PrinterConfig> apply(
    String? choice,
    List<PrinterConfig> printers,
  ) {
    if (choice == null || choice == allPrinters) return printers;
    final match = printers.where((p) => p.id == choice).toList(growable: false);
    return match.isEmpty ? printers : match;
  }
}
