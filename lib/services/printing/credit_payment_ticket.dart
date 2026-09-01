// Recibo de abono a crédito — versión térmica (ESC/POS).
//
// POR QUÉ ES UN DOCUMENTO APARTE Y NO UNA FACTURA:
//   Un abono no vende nada. No lleva ítems, ni ITBIS, ni NCF: el impuesto ya
//   se declaró el día que se fió la mercancía, y volver a imprimirlo acá
//   haría que el mismo ITBIS aparezca dos veces en el papel. Lo que el
//   cliente necesita del abono es otra cosa: cuánto debía, cuánto entregó,
//   cuánto le queda y con qué número reclamar.
//
// Vive en su propio archivo por la misma razón que el conduce: PrintTicketService
// ya pasa de 2,900 líneas y este documento no comparte nada con la factura.
//
// El recibo sale SIEMPRE, pague como pague. Un abono con tarjeta o
// transferencia también deja al cliente sin comprobante si no se imprime, y
// es justo el caso donde no hay ni voucher de la caja que lo respalde.

import '../../core/currency/business_currency.dart';
import '../../core/utils/app_time.dart';
import '../../data/models/printing.dart';
import '../../presentation/credits/state/credit_payment_receipt.dart';
import 'esc_pos_generator.dart';

class CreditPaymentTicket {
  const CreditPaymentTicket._();

  /// Arma el recibo de abono para papel térmico.
  ///
  /// [paperWidth] sale de `printers.paper_width` (58 u 80). En 58mm el papel
  /// solo da 32 columnas: lo que en 80mm va en doble ancho pasa a ancho
  /// simple con altura doble, igual que en la factura y el conduce.
  static PrintTicket build({
    required CreditPaymentReceipt receipt,
    required String businessName,
    String? businessBranch,
    String? businessAddress,
    String? businessPhone,
    String? businessRnc,
    BusinessCurrency? currency,
    int paperWidth = 80,
    bool isReprint = false,
    String? cashierName,
  }) {
    final money = currency ?? BusinessCurrency.fallbackDop;
    final gen = EscPosGenerator(paperWidth: paperWidth);
    final narrow = gen.paperWidth <= 58;
    final width = gen.maxChars;

    gen.initialize();
    gen.lineFeed();

    // ── Encabezado del negocio ──
    if (businessName.trim().isNotEmpty) {
      gen.setTextSize(width: narrow ? 1 : 2, height: 2);
      gen.setBold(true);
      gen.textCenteredWrapped(businessName.trim());
      gen.setBold(false);
      gen.setTextSize();
    }
    for (final line in [
      businessBranch,
      businessAddress,
      businessPhone,
      businessRnc,
    ]) {
      final value = line?.trim() ?? '';
      if (value.isEmpty) continue;
      gen.textCenteredWrapped(value);
    }
    gen.doubleSeparator();

    // ── Título ──
    // Dice ABONO A CRÉDITO, no "Recibo" a secas: quien lo archive o lo
    // encuentre en una gaveta tiene que saber de qué es sin leer el detalle,
    // y sobre todo tiene que quedar claro que NO es una factura de venta.
    gen.setTextSize(width: narrow ? 1 : 2, height: 2);
    gen.setBold(true);
    gen.textCentered(narrow ? 'ABONO' : 'ABONO A CREDITO');
    gen.setTextSize();
    gen.textCentered('RECIBO DE PAGO');
    gen.setBold(false);
    if (isReprint) {
      gen.textCentered('*** REIMPRESION ***');
    }
    gen.separator();

    // ── Identificación del documento ──
    gen.setBold(true);
    if (receipt.code.isNotEmpty) {
      gen.textRow('Recibo:', receipt.code);
    }
    gen.setBold(false);
    gen.textRow('Fecha:', _formatDateTime(receipt.createdAt));
    if ((receipt.customerName ?? '').isNotEmpty) {
      gen.textRow('Cliente:', _fit(receipt.customerName!, width - 10));
    }
    if ((cashierName ?? '').trim().isNotEmpty) {
      gen.textRow('Recibido por:', _fit(cashierName!.trim(), width - 15));
    }
    gen.separator();

    // ── El dinero ──
    // Tres líneas y en este orden: lo que debía, lo que entregó, lo que le
    // queda. Es la pregunta que el cliente hace en el mostrador, en ese orden.
    gen.dotRow('Deuda original', money.formatAmount(receipt.originalAmount));

    final priorBalance = receipt.balanceAfter + receipt.amount;
    gen.dotRow('Saldo anterior', money.formatAmount(priorBalance));

    gen.separator();
    gen.setBold(true);
    gen.setTextSize(width: 1, height: 2);
    gen.dotRow('ABONO', money.formatAmount(receipt.amount));
    gen.setTextSize();
    gen.setBold(false);

    gen.textRow('Forma de pago:', receipt.methodName);
    if ((receipt.reference ?? '').isNotEmpty) {
      gen.textRow('Referencia:', _fit(receipt.reference!, width - 14));
    }

    gen.separator();
    gen.setBold(true);
    gen.setTextSize(width: 1, height: 2);
    gen.dotRow('SALDO PENDIENTE', money.formatAmount(receipt.balanceAfter));
    gen.setTextSize();
    gen.setBold(false);

    // Saldar una cuenta es el momento que el cliente quiere ver impreso. Sin
    // esta marca, un saldo en 0.00 se lee igual que cualquier otro renglón.
    if (receipt.isSettled) {
      gen.lineFeed();
      gen.setBold(true);
      gen.setTextSize(width: narrow ? 1 : 2, height: 2);
      gen.textCentered('CUENTA SALDADA');
      gen.setTextSize();
      gen.setBold(false);
    }

    gen.doubleSeparator();

    // ── Firma ──
    // El recibo de abono se firma: es la prueba de que el dinero cambió de
    // manos cuando no hay voucher de tarjeta que lo respalde.
    final signWidth = narrow ? width : 30;
    gen.lineFeed(2);
    gen.text('_' * signWidth);
    gen.text('Recibido por');

    gen.lineFeed();
    gen.textCentered('Conserve este recibo');
    gen.textCentered(_formatDateTime(DateTime.now()));
    gen.lineFeed();
    gen.cut();

    return PrintTicket(
      type: 'credit_payment',
      escPosCommands: gen.getCommands(),
      rawText: gen.getPlainText(),
    );
  }

  /// Recorta sin partir el renglón: el nombre largo de un cliente empuja el
  /// monto fuera del papel y deja la línea ilegible.
  static String _fit(String value, int max) {
    if (max <= 1 || value.length <= max) return value;
    return '${value.substring(0, max - 1)}…';
  }

  static String _formatDateTime(DateTime dt) {
    final ast = AppTime.astFromInstant(dt);
    final d = '${ast.day.toString().padLeft(2, '0')}/'
        '${ast.month.toString().padLeft(2, '0')}/${ast.year}';
    final h = '${ast.hour.toString().padLeft(2, '0')}:'
        '${ast.minute.toString().padLeft(2, '0')}';
    return '$d $h';
  }
}
