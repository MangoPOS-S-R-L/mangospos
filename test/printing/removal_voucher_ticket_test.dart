// Comprobante del producto quitado de la cuenta: tiene que decir QUÉ se
// quitó, POR QUÉ y si volvió al inventario o se contó como merma. Y a 58mm
// (32 columnas) nada se puede salir del papel.

import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/data/models/order_item_removal_reason.dart';
import 'package:mangopos/services/printing/removal_voucher_ticket.dart';

const _merma = OrderItemRemovalReason(
  code: 'prepared',
  label: 'Ya preparado, se botó',
  isWaste: true,
);
const _devuelve = OrderItemRemovalReason(
  code: 'typo',
  label: 'Error de digitación',
  isWaste: false,
);

String _ticket({
  required OrderItemRemovalReason reason,
  bool? isWaste,
  String? note,
  int paperWidth = 80,
  bool forStation = false,
  String product = 'Old Parr 18 Años 750Ml',
  double quantity = 1,
}) =>
    RemovalVoucherTicket.generate(
      businessName: 'El Prodigio Y La Super Banda - Arena',
      productName: product,
      quantity: quantity,
      decision: OrderItemRemovalDecision(
        reason: reason,
        isWaste: isWaste ?? reason.isWaste,
        note: note,
      ),
      tableName: 'MUEBLE51',
      orderNumber: '60A6FC1B',
      unitPrice: 24000,
      sentAt: DateTime.utc(2026, 9, 20, 3, 20),
      operatorName: 'Johan Osma',
      paperWidth: paperWidth,
      removedAt: DateTime.utc(2026, 9, 20, 3, 26),
      forStation: forStation,
    ).rawText ??
    '';

int _widest(String raw) =>
    raw.split('\n').fold<int>(0, (m, l) => l.length > m ? l.length : m);

void main() {
  test('dice qué se quitó, de dónde y cuánto vale', () {
    final raw = _ticket(reason: _merma);
    expect(raw, contains('PRODUCTO QUITADO DE LA CUENTA'));
    expect(raw, contains('1 x OLD PARR 18 AÑOS 750ML'));
    expect(raw, contains('MUEBLE51'));
    expect(raw, contains('#60A6FC1B'));
    expect(raw, contains('24,000.00'));
    // 03:26 UTC = 23:26 del 19 en RD.
    expect(raw, contains('19/09/2026 23:26'));
    expect(raw, contains('Enviado a cocina: 19/09/2026 23:20'));
    expect(raw, contains('Autorizado por: JOHAN OSMA'));
  });

  test('merma y devolución se leen distinto', () {
    final merma = _ticket(reason: _merma);
    expect(merma, contains('*** MERMA ***'));
    expect(merma, contains('NO vuelve al inventario'));

    final devuelto = _ticket(reason: _devuelve);
    expect(devuelto, contains('DEVUELTO AL INVENTARIO'));
    expect(devuelto, isNot(contains('MERMA')));
  });

  test('el cajero puede cambiar el destino que trae el motivo', () {
    // Motivo que devuelve, pero esta vez el trago sí se había servido.
    final raw = _ticket(reason: _devuelve, isWaste: true);
    expect(raw, contains('Error de digitación'));
    expect(raw, contains('*** MERMA ***'));
  });

  test('la nota sale cuando se escribió', () {
    expect(
      _ticket(reason: _merma, note: 'Se cayó la botella'),
      contains('Nota: Se cayó la botella'),
    );
    expect(_ticket(reason: _merma), isNot(contains('Nota:')));
  });

  test('el comprobante lleva raya de firma; la copia del bar no', () {
    expect(_ticket(reason: _merma), contains('Firma'));

    final bar = _ticket(reason: _merma, forStation: true);
    expect(bar, contains('CANCELAR ESTE PRODUCTO'));
    expect(bar, isNot(contains('Firma')));
  });

  test('a 58mm nada se sale del papel', () {
    final raw = _ticket(
      reason: _merma,
      paperWidth: 58,
      product: 'Johnnie Walker Blue Label Edición Limitada 750Ml',
      quantity: 2,
      note: 'El cliente la devolvió porque ya estaba abierta',
    );
    expect(_widest(raw), lessThanOrEqualTo(32));
    expect(raw, contains('2 x JOHNNIE WALKER BLUE LABEL'));
  });
}
