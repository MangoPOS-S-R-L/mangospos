import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/data/repositories/purchase_projection_repository.dart';
import 'package:mangopos/presentation/purchases/state/purchases_state.dart';

void main() {
  test('la orden del lote viaja en unidad base, con totales y foto del empaque', () {
    final order = SuggestedOrderBatchOrder(
      supplierId: 'sb',
      supplierName: 'SB',
      expectedDate: DateTime(2026, 9, 20, 15, 45),
      notes: 'Pedido sugerido',
      items: const [
        PurchaseDraftItem(
          inventoryItemId: 'refresco',
          description: 'Refresco',
          quantity: 48,
          unitCost: 22,
          purchaseUnit: 'Caja',
          packSize: 24,
        ),
        PurchaseDraftItem(
          inventoryItemId: 'queso',
          description: 'Queso',
          quantity: 4.9,
          unitCost: 200,
          taxRate: 0,
          purchaseUnit: '  ',
        ),
      ],
    );
    final json = order.toJson();
    expect(json['supplier_id'], 'sb');
    expect(json['expected_date'], '2026-09-20');
    final header = json['header'] as Map<String, dynamic>;
    expect(header['subtotal'], closeTo(1056 + 980, 1e-9));
    expect(header['tax'], closeTo(1056 * 0.18, 1e-9));
    expect(header['total'], closeTo(1056 * 1.18 + 980, 1e-9));
    final lines = json['lines'] as List;
    expect(lines.first, containsPair('quantity_ordered', 48));
    expect(lines.first, containsPair('purchase_unit', 'Caja'));
    expect(lines.first, containsPair('pack_size', 24));
    expect(lines.last, containsPair('purchase_unit', null));
  });

  test('el resultado de la base se lee con su suplidor y si fue reusada', () {
    final created = CreatedSupplierOrder.fromMap({
      'supplier_id': 'sb',
      'id': 'po-1',
      'order_number': 'PO-00012',
      'reused': true,
      'lines': 2,
    });
    expect(created.supplierId, 'sb');
    expect(created.orderNumber, 'PO-00012');
    expect(created.reused, isTrue);
  });
}
