import '../../core/utils/app_time.dart';
import '../../data/models/printing_models.dart';
import 'esc_pos_generator.dart';

/// Conduce de una SALIDA de inventario (58/80mm).
///
/// Sale cuando un ajuste saca mercancía de la bodega y no es un cuadre: rotura,
/// vencimiento, limpieza, faltante o donación. Es el papel que queda del hecho
/// y el que se firma — la misma razón por la que existe el comprobante de
/// producto quitado de la cuenta ([RemovalVoucherTicket]): un ajuste sin papel
/// es una pérdida que nadie autorizó y que después no se puede reconstruir.
///
/// Dice las cinco cosas que alguien va a querer saber en el próximo conteo:
/// QUÉ salió, CUÁNTO, DE DÓNDE, POR QUÉ, y QUIÉN lo autorizó.
///
/// NO es un [GoodsReceipt] disfrazado. El conduce de recepción dice «Recibido
/// por» porque la mercancía entra; acá se va, así que las firmas son
/// «Entregado por» y «Autorizado por». Reusar el documento de entrada para una
/// salida haría que el papel mienta sobre lo que pasó.
class WasteExitTicket {
  const WasteExitTicket._();

  static PrintTicket generate({
    required String businessName,
    required String itemName,
    /// Lo que SALIÓ, en positivo. El ajuste se guarda como delta negativo; acá
    /// entra el valor absoluto porque el papel se lee, no se suma.
    required double quantity,
    required String unit,
    required String reasonLabel,
    required String warehouseName,
    String? notes,
    String? operatorName,
    double stockBefore = 0,
    double stockAfter = 0,
    double costPerUnit = 0,
    String? currencySymbol,
    int paperWidth = 80,
    DateTime? occurredAt,
  }) {
    final gen = EscPosGenerator(paperWidth: paperWidth);
    final when = AppTime.astFromInstant(occurredAt ?? DateTime.now());
    final symbol = currencySymbol ?? 'RD\$';

    gen.initialize();
    gen.lineFeed();
    gen.setTextSize(width: paperWidth <= 58 ? 1 : 2, height: 2);
    gen.setBold(true);
    gen.textCenteredWrapped(businessName);
    gen.setBold(false);
    gen.setTextSize();
    gen.doubleSeparator();

    gen.setTextSize(height: 2);
    gen.setBold(true);
    gen.textCenteredWrapped('SALIDA DE INVENTARIO');
    gen.setBold(false);
    gen.setTextSize();
    gen.textCentered(_dateTime(when));
    gen.separator();

    gen.setBold(true);
    gen.textRow('BODEGA:', _fit(warehouseName.toUpperCase(), gen.maxChars - 8));
    gen.setBold(false);
    gen.separator();

    // El insumo y la cantidad, en grande: es lo que se está botando.
    gen.setTextSize(height: 2);
    gen.setBold(true);
    gen.textWrapped('${_qty(quantity)} $unit');
    gen.setBold(false);
    gen.setTextSize();
    gen.textWrapped(itemName.toUpperCase());

    if (costPerUnit > 0) {
      gen.textRow('Costo:', '$symbol ${_money(quantity * costPerUnit)}');
    }
    gen.separator();

    // El motivo va en grande y solo: es la línea por la que se firma.
    gen.setBold(true);
    gen.text('MOTIVO:');
    gen.setTextSize(height: 2);
    gen.textCenteredWrapped(reasonLabel.toUpperCase());
    gen.setTextSize();
    gen.setBold(false);
    final note = notes?.trim();
    if (note != null && note.isNotEmpty) {
      gen.textWrapped('Nota: $note');
    }
    gen.separator();

    // El antes y el después: sin esto el papel no sirve para auditar, porque
    // no se puede saber si la cantidad que dice es la que de verdad se movió.
    gen.textRow('Stock antes:', '${_qty(stockBefore)} $unit');
    gen.textRow('Stock después:', '${_qty(stockAfter)} $unit');
    gen.doubleSeparator();

    if (operatorName != null && operatorName.trim().isNotEmpty) {
      gen.textWrapped('Registrado por: ${operatorName.trim().toUpperCase()}');
    }

    // Dos firmas, porque una salida tiene dos responsables: el que la saca de
    // la bodega y el que dio permiso. Con una sola no se sabe quién autorizó.
    final ancho = paperWidth <= 58 ? gen.maxChars : 30;
    gen.lineFeed(4);
    gen.text('_' * ancho);
    gen.textCentered('Entregado por');
    gen.lineFeed(3);
    gen.text('_' * ancho);
    gen.textCentered('Autorizado por');

    gen.lineFeed(2);
    gen.cut();

    return PrintTicket(
      type: 'inventory_waste_exit',
      escPosCommands: gen.getCommands(),
      rawText: gen.getPlainText(),
    );
  }

  static String _two(int v) => v.toString().padLeft(2, '0');

  static String _dateTime(DateTime d) =>
      '${_two(d.day)}/${_two(d.month)}/${d.year}  ${_two(d.hour)}:${_two(d.minute)}';

  /// Sin decimales cuando es entero: «3 lb», no «3.00 lb». Con hasta cuatro
  /// cuando no, porque una receta en onzas convertida a libras deja 0.0625.
  static String _qty(double v) => v == v.roundToDouble()
      ? v.toStringAsFixed(0)
      : v.toStringAsFixed(4).replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');

  static String _money(double v) {
    final s = v.toStringAsFixed(2);
    final parts = s.split('.');
    final miles = parts[0].replaceAllMapped(
      RegExp(r'(\d)(?=(\d{3})+$)'),
      (m) => '${m[1]},',
    );
    return '$miles.${parts[1]}';
  }

  static String _fit(String s, int max) =>
      s.length <= max ? s : s.substring(0, max);
}
