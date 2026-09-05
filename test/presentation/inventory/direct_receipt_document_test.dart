// El papel de una compra manual.
//
// Lo que se reclamaría si faltara: que una recepción directa imprima el mismo
// documento que una recepción contra orden de compra (con sus líneas y su
// número), y que una recepción CANCELADA no salga como si la mercancía
// siguiera dentro.

import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/presentation/inventory/state/direct_receipts_state.dart';
import 'package:mangopos/presentation/inventory/utils/direct_receipt_document.dart';

DirectReceipt _receipt({
  DirectReceiptStatus status = DirectReceiptStatus.received,
  String? supplierName = 'Ferreteria Bellon SRL',
  String? cancelReason,
  String? notes,
}) {
  return DirectReceipt(
    id: 'rd-1',
    businessId: 'b-1',
    warehouseId: 'wh-1',
    warehouseName: 'Bodega Principal',
    supplierId: 'sup-1',
    supplierName: supplierName,
    receiptNumber: 'RD-00004',
    status: status,
    total: 1200,
    notes: notes,
    cancelReason: cancelReason,
    createdBy: 'u-1',
    createdByName: 'Juan Perez',
    cancelledBy: null,
    cancelledByName: null,
    createdAt: DateTime(2026, 9, 5, 9, 15),
    cancelledAt: null,
    itemCount: 1,
    totalQuantity: 20,
    items: const [
      DirectReceiptLine(
        id: 'l1',
        itemId: 'i1',
        itemName: 'Aceite vegetal',
        itemSku: '000021',
        unit: 'litro',
        quantity: 20,
        unitCost: 60,
        lineTotal: 1200,
        notes: null,
      ),
    ],
  );
}

void main() {
  test('la compra manual imprime el mismo documento que el conduce', () {
    final doc = directReceiptDocument(_receipt());

    expect(doc.isOrder, isFalse);
    expect(doc.number, 'RD-00004');
    expect(doc.warehouseName, 'Bodega Principal');
    expect(doc.supplierName, 'Ferreteria Bellon SRL');
    // Quien registró la compra manual ES quien recibió.
    expect(doc.receivedByName, 'Juan Perez');
    expect(doc.lines, hasLength(1));
    expect(doc.total, closeTo(1200, 0.01));
  });

  test('sin proveedor no deja el renglón en blanco', () {
    final doc = directReceiptDocument(_receipt(supplierName: null));
    expect(doc.supplierName, 'Sin proveedor');
  });

  test('una recepción cancelada lo dice en el papel', () {
    final doc = directReceiptDocument(
      _receipt(
        status: DirectReceiptStatus.cancelled,
        cancelReason: 'Mercancía devuelta',
        notes: 'Entró por la puerta de atrás',
      ),
    );
    expect(doc.notes, contains('RECEPCION CANCELADA'));
    expect(doc.notes, contains('Mercancía devuelta'));
    // Y no se traga la observación original.
    expect(doc.notes, contains('Entró por la puerta de atrás'));
  });
}
