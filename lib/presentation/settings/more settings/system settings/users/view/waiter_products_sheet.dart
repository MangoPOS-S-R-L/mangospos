// Desglose de productos vendidos por un mozo en el día. Se abre al tocar
// su fila en la pantalla de Mozos (/ajustes/mozos).
//
// Atribución: NO se recalcula aquí. La pantalla ya resolvió el dueño de
// cada sesión con la prioridad de v_zone_table_status
// (opened_by_employee_id > waiter_user_id > opened_by) y nos pasa las
// órdenes con pago de hoy y los items pendientes de ese mozo, así el
// desglose cuadra con las columnas "Ventas actuales" y "Pendiente".
//
// El pie suma LÍNEAS DE PRODUCTO; el monto de la pestaña viene de los
// pagos (cobrado) o del total de la orden (pendiente), que además
// cargan propina, fee y descuentos a nivel de orden. Por eso el pie se
// rotula "Total en productos" y no se presenta como el mismo número.
//
// "Cobrado" se arma con los items de las órdenes que tienen pago de hoy:
//   - orden cerrada/pagada -> todos sus items (menos anulados)
//   - orden aún abierta    -> solo los items de checks cerrados
// que es el complemento exacto de lo que la pantalla cuenta como
// pendiente, así una cuenta dividida no aparece en las dos listas.

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:mangopos/core/utils/friendly_error.dart';
import 'package:mangopos/data/models/sales_models.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Lotes para `inFilter`: PostgREST manda los ids en la query string y
/// con listas grandes el proxy responde 414. Convención del repo: 150.
const int _inFilterBatchSize = 150;

class WaiterProductsSheet extends StatefulWidget {
  const WaiterProductsSheet({
    super.key,
    required this.waiterName,
    required this.initials,
    required this.paidOrderIds,
    required this.pendingItems,
    required this.paidTotal,
    required this.pendingTotal,
  });

  final String waiterName;
  final String initials;

  /// Órdenes del mozo con al menos un pago completado hoy.
  final List<String> paidOrderIds;

  /// Items aún por cobrar de las mesas abiertas del mozo. Ya vienen
  /// cargados por la pantalla, así que esta pestaña no pide nada.
  final List<OrderItem> pendingItems;

  final double paidTotal;
  final double pendingTotal;

  static Future<void> show(
    BuildContext context, {
    required String waiterName,
    required String initials,
    required List<String> paidOrderIds,
    required List<OrderItem> pendingItems,
    required double paidTotal,
    required double pendingTotal,
  }) {
    return showDialog<void>(
      context: context,
      builder: (_) => WaiterProductsSheet(
        waiterName: waiterName,
        initials: initials,
        paidOrderIds: paidOrderIds,
        pendingItems: pendingItems,
        paidTotal: paidTotal,
        pendingTotal: pendingTotal,
      ),
    );
  }

  @override
  State<WaiterProductsSheet> createState() => _WaiterProductsSheetState();
}

class _WaiterProductsSheetState extends State<WaiterProductsSheet> {
  static const _accent = Color(0xFFFF7F1F);

  bool _showPending = false;
  bool _loadingPaid = true;
  String? _paidError;
  List<OrderItem> _paidItems = const [];

  @override
  void initState() {
    super.initState();
    _loadPaidItems();
  }

  Future<void> _loadPaidItems() async {
    setState(() {
      _loadingPaid = true;
      _paidError = null;
    });

    final orderIds = widget.paidOrderIds;
    if (orderIds.isEmpty) {
      setState(() {
        _paidItems = const [];
        _loadingPaid = false;
      });
      return;
    }

    try {
      final sb = Supabase.instance.client;

      final orderRows = await _selectInBatches(
        sb,
        table: 'orders',
        select: 'id,status_ext,closed_at',
        column: 'id',
        values: orderIds,
      );

      // Orden cerrada o pagada => todo lo suyo ya se cobró. La que sigue
      // abierta viene de un split: solo cuenta lo de checks cerrados.
      final settledOrderIds = <String>{};
      final openOrderIds = <String>[];
      for (final row in orderRows) {
        final id = row['id']?.toString().trim();
        if (id == null || id.isEmpty) continue;
        final status = row['status_ext']?.toString().trim();
        if (status == 'paid' || row['closed_at'] != null) {
          settledOrderIds.add(id);
        } else {
          openOrderIds.add(id);
        }
      }

      final closedCheckIds = <String>{};
      if (openOrderIds.isNotEmpty) {
        final checkRows = await _selectInBatches(
          sb,
          table: 'order_checks',
          select: 'id,order_id,is_closed',
          column: 'order_id',
          values: openOrderIds,
        );
        for (final row in checkRows) {
          if (row['is_closed'] != true) continue;
          final checkId = row['id']?.toString().trim();
          if (checkId == null || checkId.isEmpty) continue;
          closedCheckIds.add(checkId);
        }
      }

      final itemRows = await _selectInBatches(
        sb,
        table: 'order_items',
        select:
            'id,order_id,product_id,product_name,sku,qty,quantity,unit_price,'
            'subtotal,discounts,tax,total,check_id,is_takeout,status,notes,'
            'tax_mode,tax_rate,created_at',
        column: 'order_id',
        values: orderIds,
      );

      // El anulado se filtra aquí y no en la query: `status` es un enum
      // nullable, y un `not.eq` en SQL también bota las filas con NULL.
      final items = itemRows
          .map(OrderItem.fromMap)
          .where((item) => item.status != 'void')
          .where((item) {
            if (settledOrderIds.contains(item.orderId)) return true;
            final checkId = item.checkId?.trim();
            return checkId != null && closedCheckIds.contains(checkId);
          })
          .toList(growable: false);

      if (!mounted) return;
      setState(() {
        _paidItems = items;
        _loadingPaid = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingPaid = false;
        _paidError = FriendlyError.humanize(
          'Error al cargar los productos: $e',
        );
      });
    }
  }

  Future<List<Map<String, dynamic>>> _selectInBatches(
    SupabaseClient client, {
    required String table,
    required String select,
    required String column,
    required List<String> values,
  }) async {
    if (values.isEmpty) return <Map<String, dynamic>>[];
    final rows = <Map<String, dynamic>>[];
    for (var start = 0; start < values.length; start += _inFilterBatchSize) {
      final end = (start + _inFilterBatchSize > values.length)
          ? values.length
          : start + _inFilterBatchSize;
      final chunk = values.sublist(start, end);
      final chunkRows = await client
          .from(table)
          .select(select)
          .inFilter(column, chunk);
      rows.addAll(List<Map<String, dynamic>>.from(chunkRows));
    }
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final lines = _showPending
        ? _groupByProduct(widget.pendingItems)
        : _groupByProduct(_paidItems);

    return Dialog(
      backgroundColor: Colors.white,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 620,
          maxHeight: size.height * 0.85,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _header(context),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 10),
              child: Row(
                children: [
                  Expanded(
                    child: _TabChip(
                      label: 'Cobrado',
                      amount: _money(widget.paidTotal),
                      selected: !_showPending,
                      onTap: () => setState(() => _showPending = false),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _TabChip(
                      label: 'Pendiente',
                      amount: _money(widget.pendingTotal),
                      selected: _showPending,
                      onTap: () => setState(() => _showPending = true),
                    ),
                  ),
                ],
              ),
            ),
            Flexible(child: _body(lines)),
            if (lines.isNotEmpty) ...[const Divider(height: 1), _footer(lines)],
          ],
        ),
      ),
    );
  }

  Widget _header(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 12, 14),
      child: Row(
        children: [
          CircleAvatar(
            radius: 22,
            backgroundColor: const Color(0xFFFFF2E8),
            foregroundColor: _accent,
            child: Text(
              widget.initials,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.waiterName,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Productos vendidos hoy',
                  style: TextStyle(color: Colors.grey[600], fontSize: 12),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Cerrar',
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close),
          ),
        ],
      ),
    );
  }

  Widget _body(List<_ProductLine> lines) {
    if (!_showPending && _loadingPaid) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 48),
        child: Center(child: CircularProgressIndicator()),
      );
    }

    if (!_showPending && _paidError != null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _paidError!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.redAccent),
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: _loadPaidItems,
              child: const Text('Reintentar'),
            ),
          ],
        ),
      );
    }

    if (lines.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(20, 36, 20, 36),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _showPending
                  ? Icons.table_restaurant_outlined
                  : Icons.receipt_long_outlined,
              size: 34,
              color: Colors.grey[400],
            ),
            const SizedBox(height: 10),
            Text(
              _showPending
                  ? 'Este mozo no tiene productos por cobrar.'
                  : 'Este mozo no ha cobrado productos hoy.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey[600]),
            ),
          ],
        ),
      );
    }

    return ListView.separated(
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
      itemCount: lines.length,
      separatorBuilder: (_, _) =>
          Divider(height: 1, color: Colors.grey.shade200),
      itemBuilder: (_, index) => _ProductRow(line: lines[index], money: _money),
    );
  }

  Widget _footer(List<_ProductLine> lines) {
    final units = lines.fold<double>(0, (sum, line) => sum + line.units);
    final total = lines.fold<double>(0, (sum, line) => sum + line.total);

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 16),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Total en productos',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 2),
                Text(
                  '${lines.length} productos · ${_units(units)} unidades',
                  style: TextStyle(color: Colors.grey[700], fontSize: 12),
                ),
              ],
            ),
          ),
          Text(
            _money(total),
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
          ),
        ],
      ),
    );
  }

  /// Agrupa por nombre de producto — `order_items` guarda el nombre al
  /// momento de la venta, así que es la llave estable del desglose.
  List<_ProductLine> _groupByProduct(List<OrderItem> items) {
    final byName = <String, _ProductLine>{};
    for (final item in items) {
      final name = item.productName.trim().isEmpty
          ? 'Sin nombre'
          : item.productName.trim();
      final line = byName.putIfAbsent(
        name,
        () => _ProductLine(name: name, sku: item.sku?.trim() ?? ''),
      );
      line.units += item.quantity;
      line.total += item.total;
      line.lines += 1;
    }

    final lines = byName.values.toList(growable: false)
      ..sort((a, b) {
        final byTotal = b.total.compareTo(a.total);
        if (byTotal != 0) return byTotal;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
    return lines;
  }

  // RD usa formato US (,000.00) — ver nota en waiters_view._formatMoney.
  String _money(double value) => NumberFormat.currency(
    locale: 'en_US',
    symbol: 'RD\$ ',
    decimalDigits: 2,
  ).format(value);

  String _units(double value) {
    if ((value - value.roundToDouble()).abs() < 0.001) {
      return value.round().toString();
    }
    return value.toStringAsFixed(2);
  }
}

class _ProductLine {
  _ProductLine({required this.name, required this.sku});

  final String name;
  final String sku;
  double units = 0;
  double total = 0;
  int lines = 0;
}

class _ProductRow extends StatelessWidget {
  const _ProductRow({required this.line, required this.money});

  final _ProductLine line;
  final String Function(double value) money;

  @override
  Widget build(BuildContext context) {
    final units = (line.units - line.units.roundToDouble()).abs() < 0.001
        ? line.units.round().toString()
        : line.units.toStringAsFixed(2);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          Container(
            constraints: const BoxConstraints(minWidth: 42),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFFFFF2E8),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              '$units x',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Color(0xFFFF7F1F),
                fontWeight: FontWeight.w800,
                fontSize: 12,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  line.name,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                if (line.sku.isNotEmpty)
                  Text(
                    line.sku,
                    style: TextStyle(color: Colors.grey[600], fontSize: 12),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Text(
            money(line.total),
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}

class _TabChip extends StatelessWidget {
  const _TabChip({
    required this.label,
    required this.amount,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final String amount;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFFFFF2E8) : Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? const Color(0xFFFF7F1F) : Colors.grey.shade300,
            width: selected ? 1.4 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: selected ? const Color(0xFFFF7F1F) : Colors.grey[700],
              ),
            ),
            const SizedBox(height: 2),
            Text(
              amount,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
            ),
          ],
        ),
      ),
    );
  }
}
