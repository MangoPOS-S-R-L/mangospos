import '../../core/utils/app_time.dart';
import '../../data/models/order_item_removal_reason.dart';
import '../../data/models/printing_models.dart';
import 'esc_pos_generator.dart';

/// Comprobante de un producto quitado de la cuenta (58/80mm).
///
/// Sale SIEMPRE que se quita un producto: es el papel que queda del hecho y
/// el que se firma. Antes de esto, quitar un trago ya servido no dejaba ni
/// rastro digital ni papel — así se perdieron RD$214,200 de vista en una
/// noche hasta que hubo que reconstruirlo con siete consultas.
///
/// Dice las tres cosas que alguien va a querer saber después: QUÉ se quitó
/// (con su valor), POR QUÉ, y si el producto volvió al inventario o se
/// contó como merma.
class RemovalVoucherTicket {
  const RemovalVoucherTicket._();

  static PrintTicket generate({
    required String businessName,
    required String productName,
    required double quantity,
    required OrderItemRemovalDecision decision,
    String? tableName,
    String? orderNumber,
    double unitPrice = 0,
    DateTime? sentAt,
    String? operatorName,
    String? currencySymbol,
    int paperWidth = 80,
    DateTime? removedAt,

    /// Copia para la estación: el bar o la cocina ya tienen la comanda en la
    /// mano y nadie les avisa por el sistema.
    bool forStation = false,
  }) {
    final gen = EscPosGenerator(paperWidth: paperWidth);
    final when = AppTime.astFromInstant(removedAt ?? DateTime.now());
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
    gen.textCenteredWrapped(
      forStation ? 'CANCELAR ESTE PRODUCTO' : 'PRODUCTO QUITADO DE LA CUENTA',
    );
    gen.setBold(false);
    gen.setTextSize();
    gen.textCentered(_dateTime(when));
    gen.separator();

    if (tableName != null && tableName.isNotEmpty) {
      gen.setBold(true);
      gen.textRow(
        tableName.toUpperCase(),
        orderNumber == null ? '' : '#$orderNumber',
      );
      gen.setBold(false);
    }
    if (sentAt != null) {
      final sent = AppTime.astFromInstant(sentAt);
      gen.textWrapped('Enviado a cocina: ${_dateTime(sent)}');
    }
    gen.separator();

    // El producto, en grande: es lo que el bar tiene que cancelar.
    gen.setTextSize(height: 2);
    gen.setBold(true);
    gen.textWrapped('${_qty(quantity)} x ${productName.toUpperCase()}');
    gen.setBold(false);
    gen.setTextSize();
    if (unitPrice > 0) {
      gen.textRow('Valor:', '$symbol ${_money(quantity * unitPrice)}');
    }
    gen.separator();

    gen.setBold(true);
    gen.text('MOTIVO:');
    gen.setBold(false);
    gen.textWrapped(decision.reason.label);
    final note = decision.note?.trim();
    if (note != null && note.isNotEmpty) {
      gen.textWrapped('Nota: $note');
    }
    gen.lineFeed();

    // Lo que pasó con la mercancía: la línea que decide si el conteo del mes
    // cuadra o no.
    gen.setBold(true);
    gen.textCenteredWrapped(
      decision.isWaste ? '*** MERMA ***' : 'DEVUELTO AL INVENTARIO',
    );
    gen.setBold(false);
    gen.textCenteredWrapped(
      decision.isWaste
          ? 'El producto NO vuelve al inventario'
          : 'El producto vuelve al inventario',
    );
    gen.doubleSeparator();

    if (operatorName != null && operatorName.isNotEmpty) {
      gen.textWrapped('Autorizado por: ${operatorName.toUpperCase()}');
    }

    if (!forStation) {
      // Aire real para firmar: la raya pegada al texto se firma encima.
      gen.lineFeed(4);
      gen.text('_' * (paperWidth <= 58 ? gen.maxChars : 30));
      gen.textCentered('Firma');
    }

    gen.lineFeed(2);
    gen.cut();

    return PrintTicket(
      type: 'order_item_removal',
      escPosCommands: gen.getCommands(),
      rawText: gen.getPlainText(),
    );
  }

  static String _two(int v) => v.toString().padLeft(2, '0');

  static String _dateTime(DateTime d) =>
      '${_two(d.day)}/${_two(d.month)}/${d.year} ${_two(d.hour)}:${_two(d.minute)}';

  /// 1 → "1", 0.5 → "0.5".
  static String _qty(double v) => v == v.roundToDouble()
      ? v.toInt().toString()
      : v.toStringAsFixed(2).replaceFirst(RegExp(r'0+$'), '');

  static String _money(double v) {
    final fixed = v.toStringAsFixed(2);
    final parts = fixed.split('.');
    final digits = parts[0];
    final buffer = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(',');
      buffer.write(digits[i]);
    }
    return '$buffer.${parts[1]}';
  }
}
