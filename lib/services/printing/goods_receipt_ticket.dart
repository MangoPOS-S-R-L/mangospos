// El papel de la compra — versión térmica (ESC/POS).
//
// Imprime los DOS documentos que produce una compra, según [GoodsReceipt.kind]:
// la ORDEN DE COMPRA (al registrarla) y la RECEPCIÓN DE MERCANCÍA (al
// recibirla en almacén). Mismo cuerpo, mismas firmas, distinto título y
// distinto bloque de totales.
//
// Vive en su propio archivo y no dentro de PrintTicketService porque ese ya
// pasa de 2,900 líneas y este documento no comparte nada con la factura: no
// tiene pagos ni NCF propio. Lo que comparte —EscPosGenerator y
// BusinessCurrency— lo importa.
//
// El mismo contenido sale también en PDF carta (goods_receipt_pdf.dart) para
// el archivo del contable. Los dos leen el MISMO [GoodsReceipt], así que el
// papel térmico del almacén y el PDF de contabilidad no pueden divergir.

import '../../core/currency/business_currency.dart';
import '../../core/utils/app_time.dart';
import '../../data/models/printing.dart';
import '../../presentation/purchases/state/goods_receipt.dart';
import 'esc_pos_generator.dart';

class GoodsReceiptTicket {
  const GoodsReceiptTicket._();

  /// Arma el conduce para papel térmico.
  ///
  /// [paperWidth] sale de `printers.paper_width` (58 u 80). En 58mm el papel
  /// solo da 32 columnas: lo que en 80mm va en doble ancho pasa a ancho
  /// simple con altura doble, igual que en la factura.
  static PrintTicket build({
    required GoodsReceipt receipt,
    required String businessName,
    String? businessBranch,
    String? businessAddress,
    String? businessPhone,
    String? businessRnc,
    BusinessCurrency? currency,
    int paperWidth = 80,
    bool isReprint = false,
  }) {
    final money = currency ?? BusinessCurrency.fallbackDop;
    final gen = EscPosGenerator(paperWidth: paperWidth);
    final narrow = gen.paperWidth <= 58;
    final width = gen.maxChars;

    gen.initialize();
    gen.lineFeed();

    // ── Encabezado del NEGOCIO que recibe ──
    // Si no hay nombre no se imprime una línea en blanco: mejor un ticket sin
    // encabezado que uno con un hueco donde debería ir quién recibió.
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
    gen.setTextSize(width: narrow ? 1 : 2, height: 2);
    gen.setBold(true);
    gen.textCentered(narrow ? receipt.shortTitle : receipt.documentTitle);
    gen.setTextSize();
    gen.textCentered(receipt.documentSubtitle);
    gen.setBold(false);
    // Una recepción parcial deja mercancía pendiente: quien archiva el papel
    // tiene que verlo sin leer las líneas.
    if (receipt.isPartial) {
      gen.textCentered('** ENTREGA PARCIAL **');
    }
    if (isReprint) {
      gen.textCentered('*** REIMPRESION ***');
    }
    // Un documento armado desde la orden no puede pasar por uno emitido el
    // día de la entrega: se dice en la cabeza, no en letra chica.
    if (receipt.isReconstructed) {
      gen.separator();
      gen.textCenteredWrapped(
        'SIN RECEPCION REGISTRADA - reconstruido de la orden',
      );
    }
    gen.separator();

    // ── Datos del documento ──
    void field(String label, String value) {
      if (value.trim().isEmpty) return;
      gen.textRow(label, value);
    }

    field('No.:', receipt.number.isEmpty ? 's/n' : receipt.number);
    field('Fecha:', _formatDate(receipt.date));
    field('Hora:', _formatTime(receipt.createdAt));
    field('Almacen:', receipt.warehouseName);
    // En la orden, el número del documento YA es el de la orden: repetirlo
    // debajo solo gasta papel.
    if (!receipt.isOrder) field('Orden:', receipt.orderNumber);
    field('Factura:', receipt.invoiceNumber);
    field('NCF:', receipt.ncf);
    field('Realizado por:', receipt.issuedByName.toUpperCase());
    field('Recibido por:', receipt.receivedByName.toUpperCase());
    gen.separator();

    gen.setBold(true);
    gen.text('SUPLIDOR');
    gen.setBold(false);
    gen.textWrapped(receipt.supplierName.toUpperCase());
    if (receipt.supplierRnc.trim().isNotEmpty) {
      gen.text('RNC: ${receipt.supplierRnc}');
    }
    gen.separator();

    // ── Líneas ──
    // Dos renglones por producto en vez de seis columnas apretadas: en 48
    // caracteres (80mm) una tabla de código+cantidad+descripción+costo+importe
    // trunca el nombre hasta volverlo inservible, y el nombre es justo lo que
    // el almacenista compara contra la caja que tiene en la mano.
    gen.setBold(true);
    gen.textRow('CANT / DESCRIPCION', 'IMPORTE');
    gen.setBold(false);
    gen.separator();

    for (final line in receipt.lines) {
      final code = line.code.trim();
      gen.setBold(true);
      gen.textWrapped(
        code.isEmpty ? line.description : '[$code] ${line.description}',
      );
      gen.setBold(false);
      final qty = '${_formatQty(line.quantity)} ${line.unit}';
      gen.textRow(
        '  $qty x ${money.formatAmount(line.unitCost)}',
        money.formatAmount(line.amount),
      );
    }

    gen.separator();

    // ── Totales ──
    gen.textRow('Renglones:', receipt.lines.length.toString());
    gen.textRow('Unidades:', _formatQty(receipt.totalUnits));
    // La orden declara el dinero de la factura del suplidor; el conduce solo
    // declara mercancía. Sin desglose no se inventan renglones en cero.
    if (receipt.hasAmountBreakdown) {
      gen.textRow('Subtotal:', money.formatAmount(receipt.subtotal ?? 0));
      if ((receipt.taxTotal ?? 0) != 0) {
        gen.textRow('ITBIS:', money.formatAmount(receipt.taxTotal ?? 0));
      }
      if ((receipt.discountTotal ?? 0) != 0) {
        gen.textRow(
          'Descuento:',
          '-${money.formatAmount(receipt.discountTotal ?? 0)}',
        );
      }
    }
    gen.setBold(true);
    gen.setTextSize(width: narrow ? 1 : 2, height: 2);
    gen.textRow('TOTAL:', money.formatAmount(receipt.grandTotal));
    gen.setTextSize();
    gen.setBold(false);

    if (receipt.notes.trim().isNotEmpty) {
      gen.separator();
      gen.setBold(true);
      gen.text('OBSERVACIONES:');
      gen.setBold(false);
      gen.textWrapped(receipt.notes.trim());
    }

    gen.doubleSeparator();

    // ── Firmas ──
    // El papel sin firmas no prueba nada: el valor del documento es que
    // alguien reconoce que lo hizo y alguien reconoce que recibió. Los dos
    // documentos llevan las MISMAS dos firmas (pedido del dueño), y el nombre
    // impreso debajo de la raya no reemplaza a la firma: la identifica.
    final signWidth = narrow ? width : 30;
    gen.lineFeed(2);
    gen.text('_' * signWidth);
    gen.text('Realizado por');
    if (receipt.issuedByName.trim().isNotEmpty) {
      gen.text(receipt.issuedByName.toUpperCase());
    }
    gen.lineFeed(2);
    gen.text('_' * signWidth);
    gen.text('Recibido por');
    if (receipt.receivedByName.trim().isNotEmpty) {
      gen.text(receipt.receivedByName.toUpperCase());
    }

    gen.lineFeed();
    gen.textCentered(_formatDateTime(DateTime.now()));
    gen.lineFeed();
    gen.cut();

    return PrintTicket(
      type: receipt.isOrder ? 'purchase_order' : 'goods_receipt',
      escPosCommands: gen.getCommands(),
      rawText: gen.getPlainText(),
    );
  }

  static String _formatQty(double qty) {
    if ((qty - qty.roundToDouble()).abs() < 0.001) {
      return qty.toStringAsFixed(0);
    }
    if ((qty * 10 - (qty * 10).roundToDouble()).abs() < 0.001) {
      return qty.toStringAsFixed(1);
    }
    return qty.toStringAsFixed(2);
  }

  static String _formatDate(DateTime dt) {
    final ast = AppTime.astFromInstant(dt);
    return '${ast.day.toString().padLeft(2, '0')}/'
        '${ast.month.toString().padLeft(2, '0')}/${ast.year}';
  }

  static String _formatTime(DateTime dt) {
    final ast = AppTime.astFromInstant(dt);
    final hour = ast.hour % 12 == 0 ? 12 : ast.hour % 12;
    final period = ast.hour < 12 ? 'AM' : 'PM';
    return '$hour:${ast.minute.toString().padLeft(2, '0')} $period';
  }

  static String _formatDateTime(DateTime dt) =>
      '${_formatDate(dt)} ${_formatTime(dt)}';
}
