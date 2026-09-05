// El papel de una compra manual (recepción directa, sin orden de compra).
//
// Convierte lo que la pantalla de Recepciones ya tiene cargado en el MISMO
// documento que emite una recepción contra orden de compra ([GoodsReceipt]),
// para que las dos entradas de mercancía impriman igual: mismo formato,
// mismas firmas «Realizado por» y «Recibido por».
//
// La conversión vive acá y no en el modelo porque `DirectReceipt` es de
// inventario y `GoodsReceipt` de compras: el puente pertenece a quien lo
// cruza, no a ninguno de los dos lados.

import '../../purchases/state/goods_receipt.dart';
import '../state/direct_receipts_state.dart';

/// Arma el documento imprimible de una recepción directa.
///
/// Requiere que [receipt] traiga sus líneas cargadas (`copyWith(items: …)`):
/// desde el listado vienen vacías y el papel saldría sin mercancía.
GoodsReceipt directReceiptDocument(DirectReceipt receipt) {
  final createdAt = receipt.createdAt ?? DateTime.now();
  final notes = (receipt.notes ?? '').trim();
  // Una recepción cancelada se puede reimprimir —el papel viejo sigue en el
  // archivo—, pero no puede salir como si la mercancía siguiera dentro.
  final cancelled = receipt.status == DirectReceiptStatus.cancelled;
  final reason = (receipt.cancelReason ?? '').trim();
  final cancelNote = cancelled
      ? '** RECEPCION CANCELADA **${reason.isEmpty ? '' : ' $reason'}'
      : '';

  return GoodsReceipt(
    id: receipt.id,
    number: receipt.receiptNumber,
    date: createdAt,
    createdAt: createdAt,
    // 'received' / 'cancelled' no son estados parciales: la recepción directa
    // entra completa o no entra.
    status: 'complete',
    orderId: null,
    orderNumber: '',
    invoiceNumber: '',
    ncf: '',
    supplierName: (receipt.supplierName ?? '').trim().isEmpty
        ? 'Sin proveedor'
        : receipt.supplierName!.trim(),
    supplierRnc: '',
    warehouseName: receipt.warehouseName,
    // En una compra manual quien registra es quien recibió: la RPC guarda su
    // `auth.uid()` en `created_by` y el papel dice lo mismo.
    receivedByName: (receipt.createdByName ?? '').trim(),
    notes: [
      if (cancelNote.isNotEmpty) cancelNote,
      if (notes.isNotEmpty) notes,
    ].join('\n'),
    lines: receipt.items
        .map(
          (line) => GoodsReceiptLine(
            code: line.itemSku,
            reference: '',
            description: line.itemName,
            quantity: line.quantity,
            unit: line.unit,
            unitCost: line.unitCost ?? 0,
          ),
        )
        .toList(growable: false),
  );
}
