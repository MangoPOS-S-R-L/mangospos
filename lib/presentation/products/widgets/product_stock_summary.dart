/// Existencia de un producto en la lista de Productos.
///
/// Son dos cifras distintas:
///   - [sale]: lo que el punto de venta puede vender (`v_menu_items_stock`:
///     el almacén del área del producto, o los marcados para venta). Es la
///     que apaga el producto al llegar a 0.
///   - [total]: la suma de TODOS los almacenes activos del negocio. Null
///     mientras no se ha leído o si la lectura falló.
class ProductStockSummary {
  const ProductStockSummary({
    required this.sale,
    required this.unit,
    this.total,
  });

  final num sale;
  final num? total;
  final String unit;

  static const tooltip =
      'Total: suma de todos los almacenes activos.\n'
      'Venta: lo que puede vender el punto de venta (el almacén del área '
      'o los marcados para venta).';

  bool get isLow => sale <= 0;

  /// «Total: 120 und · Venta: 20»; solo el total si coinciden, y
  /// «Stock: 20 und» si todavía no hay total.
  String get text {
    final suffix = unit.isEmpty ? '' : ' $unit';
    final total = this.total;
    if (total == null) return 'Stock: ${_format(sale)}$suffix';
    if (total == sale) return 'Total: ${_format(total)}$suffix';
    return 'Total: ${_format(total)}$suffix · Venta: ${_format(sale)}';
  }

  static String _format(num n) {
    final value = n.toDouble();
    return value == value.truncate()
        ? value.toInt().toString()
        : value.toStringAsFixed(2);
  }
}

/// Null si el producto no lleva inventario o no tiene un insumo 1:1 (esos
/// no muestran existencia).
ProductStockSummary? productStockSummary(Map<String, dynamic> product) {
  if (product['is_inventory_tracked'] != true) return null;
  final stockRaw = product['stock'];
  if (stockRaw is! Map) return null;
  final sale = _toNum(stockRaw['available_units']);
  if (sale == null) return null;
  return ProductStockSummary(
    sale: sale,
    unit: stockRaw['unit']?.toString() ?? '',
    total: _toNum(product['stock_total_units']),
  );
}

num? _toNum(dynamic v) {
  if (v == null) return null;
  return v is num ? v : num.tryParse(v.toString());
}
