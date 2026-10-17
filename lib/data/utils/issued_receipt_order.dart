import '../models/sales_models.dart';
import 'order_pricing_utils.dart';

/// Importes del documento emitido, independientes del saldo actual del check.
/// Las notas guardan `tax`/`discount`; los NCF, `itbis_amount` y (en algunos
/// servidores) solo los componentes de los que se deriva el descuento.
Order issuedReceiptOrder(Order source, Map<String, dynamic> document) {
  double amount(String key, {String? alternative, bool required = false}) {
    final raw = document[key] ?? document[alternative];
    final value = raw is num ? raw.toDouble() : double.tryParse('$raw');
    if ((required && value == null) ||
        (value != null && (!value.isFinite || value < 0))) {
      throw StateError(
        'El comprobante emitido tiene importes incompletos. '
        'Recarga el historial antes de reimprimir.',
      );
    }
    return value ?? 0;
  }

  final subtotal = amount('subtotal', required: true);
  final tax = amount('itbis_amount', alternative: 'tax', required: true);
  final service = amount('service_fee');
  final delivery = amount('delivery_fee');
  final total = amount('total', required: true);
  final hasDiscount =
      document['discounts'] != null || document['discount'] != null;
  final storedDiscount = hasDiscount
      ? amount('discounts', alternative: 'discount')
      : null;
  final inferredDiscount = (subtotal + tax + service + delivery - total)
      .clamp(0, double.infinity)
      .toDouble();
  // La emisión fiscal conserva los componentes y el total, pero en algunos
  // servidores deja `discount` en su cero por defecto incluso con ofertas.
  // Reconstruir ese descuento desde el documento evita borrar el de la venta;
  // validateIssuedReceiptItems todavía exige que coincida con sus productos.
  // Las notas de venta y los descuentos fiscales explícitos no se reemplazan.
  final isFiscalDocument =
      (document['ncf_number']?.toString().trim().isNotEmpty ?? false) ||
      (document['ncf_type']?.toString().trim().isNotEmpty ?? false);
  final discount =
      storedDiscount == null || (isFiscalDocument && storedDiscount == 0)
      ? inferredDiscount
      : storedDiscount;
  return source.copyWith(
    subtotal: subtotal,
    tax: tax,
    serviceFee: service,
    deliveryFee: delivery,
    discounts: double.parse(discount.toStringAsFixed(2)),
    total: total,
  );
}

/// Una lista no vacía no acredita un comprobante completo. Contrastar los
/// componentes almacenados de cada línea con los importes emitidos permite
/// detectar detalle parcial, cantidades alteradas y descuentos desaparecidos.
void validateIssuedReceiptItems(Order document, Iterable<OrderItem> items) {
  final rows = items.where((i) => i.status != 'void').toList();
  final subtotal = rows.fold<double>(0, (s, i) => s + i.subtotal);
  final tax = rows.fold<double>(0, (s, i) => s + i.tax);
  final discount = rows.fold<double>(0, (s, i) => s + i.discounts);
  // Los componentes de filas históricas pueden estar redondeados por línea.
  final tolerance = 0.02 + rows.length * 0.005;
  if (rows.isEmpty ||
      rows.any(
        (i) =>
            i.quantity <= 0 ||
            !i.quantity.isFinite ||
            [
              i.unitPrice,
              i.subtotal,
              i.tax,
              i.discounts,
              i.total,
            ].any((v) => !v.isFinite),
      ) ||
      rows.map((i) => i.id).toSet().length != rows.length ||
      (subtotal - document.subtotal).abs() > tolerance ||
      (tax - document.tax - document.serviceFee).abs() > tolerance ||
      (discount - document.discounts).abs() > tolerance ||
      (subtotal + tax - discount + document.deliveryFee - document.total)
              .abs() >
          tolerance) {
    throw StateError(
      'El detalle está incompleto o no coincide con el comprobante emitido. '
      'No se imprimió: revisa los productos originales antes de reimprimir.',
    );
  }
}

/// Conservar las tasas de la venta solo si sus snapshots cuadran con el
/// documento. Las tasas actuales del negocio no reconstruyen una factura vieja.
List<({String label, double amount})> issuedReceiptTaxBreakdown(
  Order document,
  Iterable<OrderItem> items,
) {
  final snapshot = buildBreakdownFromTaxLines(items);
  if (snapshot != null &&
      (snapshot.fold<double>(0, (sum, line) => sum + line.amount) -
                  document.tax -
                  document.serviceFee)
              .abs() <=
          0.02) {
    return snapshot;
  }
  return [
    if (document.tax > 0.005) (label: 'ITBIS', amount: document.tax),
    if (document.serviceFee > 0.005)
      (label: 'Servicio', amount: document.serviceFee),
  ];
}
