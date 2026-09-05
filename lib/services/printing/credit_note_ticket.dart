// Nota de crédito — versión térmica (ESC/POS).
//
// POR QUÉ ES UN DOCUMENTO APARTE Y NO UNA FACTURA:
//   La nota no vende: anula. Lo que el cliente (y sobre todo el contador)
//   necesita del papel son dos números juntos —el NCF de la nota y el NCF de
//   la factura que anula— y el monto que se reversa. Reimprimir el detalle de
//   la venta encima de eso solo invita a confundir la nota con la factura.
//
// Vive en su propio archivo por la misma razón que el recibo de abono:
// PrintTicketService ya pasa de 2,900 líneas y este documento no comparte
// estructura con la factura.
//
// La nota sale SIEMPRE que se anule una venta con comprobante: es la prueba
// física de que la venta se reversó. En e-CF además lleva el QR de la DGII,
// igual que la factura (Norma 01-2020).

import '../../core/currency/business_currency.dart';
import '../../core/fiscal/ncf_types.dart';
import '../../core/utils/app_time.dart';
import '../../data/models/printing.dart';
import '../../data/models/sales_models.dart';
import 'esc_pos_generator.dart';

class CreditNoteTicket {
  const CreditNoteTicket._();

  /// Arma la nota de crédito para papel térmico.
  ///
  /// [note] es el `fiscal_document` de la nota (E34 o B04); [originalNcf] el
  /// comprobante que anula. [qrBytes] solo aplica a e-CF aceptado por la
  /// DGII: si viene null se imprime el estado en texto, nunca un hueco.
  static PrintTicket build({
    required FiscalDocument note,
    required String originalNcf,
    DateTime? originalIssuedAt,
    String? reason,
    required String businessName,
    String? businessBranch,
    String? businessAddress,
    String? businessPhone,
    String? businessRnc,
    BusinessCurrency? currency,
    int paperWidth = 80,
    bool isReprint = false,
    String? cashierName,
    List<int>? qrBytes,
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
      businessRnc == null || businessRnc.trim().isEmpty
          ? null
          : 'RNC: ${businessRnc.trim()}',
    ]) {
      final value = line?.trim() ?? '';
      if (value.isEmpty) continue;
      gen.textCenteredWrapped(value);
    }
    gen.doubleSeparator();

    // ── Título ──
    // Dice NOTA DE CRÉDITO en grande porque es lo que distingue este papel de
    // la factura que el cliente ya tiene en la mano.
    gen.setTextSize(width: narrow ? 1 : 2, height: 2);
    gen.setBold(true);
    gen.textCentered(narrow ? 'NOTA CREDITO' : 'NOTA DE CREDITO');
    gen.setTextSize();
    gen.textCentered(
      note.isElectronic ? 'ANULACION (e-CF 34)' : 'ANULACION (NCF B04)',
    );
    gen.setBold(false);
    if (isReprint) {
      gen.textCentered('*** REIMPRESION ***');
    }
    gen.separator();

    // ── Identificación fiscal ──
    // Los dos NCF pegados y en negrita: es el par que se busca cuando alguien
    // reclama, y el que la DGII cruza en el 607.
    gen.setBold(true);
    gen.textRow('NCF Nota:', note.ncfNumber);
    gen.setBold(false);
    gen.textRow('Tipo:', ncfTypeName(note.ncfType));
    gen.setBold(true);
    gen.textRow('Anula NCF:', originalNcf);
    gen.setBold(false);
    if (originalIssuedAt != null) {
      gen.textRow('Fecha factura:', _formatDate(originalIssuedAt));
    }
    gen.textRow('Fecha nota:', _formatDateTime(note.issuedAt));
    gen.separator();

    // ── Cliente ──
    if (note.customerName.trim().isNotEmpty) {
      gen.textRow('Cliente:', _fit(note.customerName.trim(), width - 10));
    }
    if ((note.customerRnc ?? '').trim().isNotEmpty) {
      gen.textRow('RNC/Cédula:', note.customerRnc!.trim());
    }
    if ((cashierName ?? '').trim().isNotEmpty) {
      gen.textRow('Anulado por:', _fit(cashierName!.trim(), width - 14));
    }

    // ── Motivo ──
    // Se imprime porque es lo primero que se pregunta al ver una anulación,
    // y porque es el mismo texto que viaja a la DGII como RazonModificacion.
    final motivo = (reason ?? '').trim();
    if (motivo.isNotEmpty) {
      gen.separator();
      gen.text('Motivo:');
      gen.textWrapped(motivo);
    }

    // ── El dinero ──
    gen.separator();
    if (note.subtotal > 0) {
      gen.dotRow('Subtotal', money.formatAmount(note.subtotal));
    }
    if (note.itbisAmount.abs() >= 0.005) {
      gen.dotRow('ITBIS', money.formatAmount(note.itbisAmount));
    }
    gen.doubleSeparator();
    gen.setBold(true);
    gen.setTextSize(width: narrow ? 1 : 2, height: 2);
    gen.textRow('TOTAL:', money.formatAmount(note.total));
    gen.setTextSize();
    gen.setBold(false);
    gen.textCentered('MONTO ANULADO');

    // ── DGII ──
    if (note.isElectronic) {
      gen.separator();
      if (qrBytes != null && qrBytes.isNotEmpty) {
        gen.lineFeed();
        gen.appendRaw(
          qrBytes,
          plainPlaceholder: '[ Código QR de verificación DGII ]',
        );
        gen.setAlignment(Alignment.center);
        gen.setBold(true);
        if ((note.ecfSecurityCode ?? '').isNotEmpty) {
          gen.text('Código de Seguridad: ${note.ecfSecurityCode}');
        }
        final signed = note.ecfSignedAt;
        if (signed != null) {
          gen.text('Fecha de Firma Digital: ${_formatDateTime(signed)}');
        }
        gen.setBold(false);
        gen.setAlignment(Alignment.left);
      } else {
        // Sin QR se dice el estado: un hueco en blanco haría pensar que la
        // impresora falló, cuando lo que pasa es que la DGII no ha respondido.
        gen.setAlignment(Alignment.center);
        gen.text(_ecfStatusMessage(note.ecfStatus));
        gen.setAlignment(Alignment.left);
      }
    }

    gen.doubleSeparator();
    gen.textCentered('Conserve esta nota junto a su factura');
    gen.textCentered(_formatDateTime(DateTime.now()));
    gen.lineFeed();
    gen.cut();

    return PrintTicket(
      type: 'credit_note',
      escPosCommands: gen.getCommands(),
      rawText: gen.getPlainText(),
    );
  }

  static String _ecfStatusMessage(String status) {
    switch (status) {
      case 'accepted':
        return 'Aceptada por la DGII';
      case 'rejected':
        return 'RECHAZADA POR LA DGII - revisar';
      case 'sent':
        return 'Enviada a la DGII, en proceso';
      default:
        return 'En proceso de envio a la DGII';
    }
  }

  /// Recorta sin partir el renglón: un nombre largo empuja el valor fuera del
  /// papel y deja la línea ilegible.
  static String _fit(String value, int max) {
    if (max <= 1 || value.length <= max) return value;
    return '${value.substring(0, max - 1)}…';
  }

  static String _formatDate(DateTime dt) {
    final ast = AppTime.astFromInstant(dt);
    return '${ast.day.toString().padLeft(2, '0')}/'
        '${ast.month.toString().padLeft(2, '0')}/${ast.year}';
  }

  static String _formatDateTime(DateTime dt) {
    final ast = AppTime.astFromInstant(dt);
    final h = '${ast.hour.toString().padLeft(2, '0')}:'
        '${ast.minute.toString().padLeft(2, '0')}';
    return '${_formatDate(dt)} $h';
  }
}
