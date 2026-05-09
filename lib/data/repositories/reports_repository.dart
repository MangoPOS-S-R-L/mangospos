import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/utils/app_time.dart';
import '../datasources/queries/reports_queries.dart';
import '../utils/payment_amount_utils.dart';
import '../utils/order_pricing_utils.dart';
import '../models/sales_models.dart';
import '../../core/tax/tax_engine.dart';

class ReportsRepository {
  final SupabaseClient _client;
  static const int _inFilterBatchSize = 150;

  ReportsRepository(this._client);

  double _toDouble(dynamic value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '') ?? 0;
  }

  double _extractReportedAmount(String? notes, String label) {
    final source = notes ?? '';
    if (source.isEmpty) return 0;
    final escapedLabel = RegExp.escape(label);
    final match = RegExp(
      '$escapedLabel\\s*:\\s*([0-9]+(?:\\.[0-9]+)?)',
      caseSensitive: false,
    ).firstMatch(source);
    if (match == null) return 0;
    return double.tryParse(match.group(1) ?? '') ?? 0;
  }

  Future<List<Map<String, dynamic>>> _selectInBatches({
    required String table,
    required String select,
    required String column,
    required List<String> values,
    dynamic Function(dynamic query)? transform,
  }) async {
    if (values.isEmpty) return <Map<String, dynamic>>[];

    final rows = <Map<String, dynamic>>[];
    for (var start = 0; start < values.length; start += _inFilterBatchSize) {
      final end = (start + _inFilterBatchSize > values.length)
          ? values.length
          : start + _inFilterBatchSize;
      final chunk = values.sublist(start, end);
      var query = _client.from(table).select(select).inFilter(column, chunk);
      if (transform != null) {
        query = transform(query);
      }
      final chunkRows = await query;
      rows.addAll(List<Map<String, dynamic>>.from(chunkRows));
    }
    return rows;
  }

  Future<List<Map<String, dynamic>>> _loadScopedPaymentsForRange({
    required String businessId,
    required DateTime from,
    required DateTime to,
    required String select,
  }) async {
    final fromIso = AppTime.astToUtcIso(from);
    final toIso = AppTime.astToUtcIso(to);

    // Scope al business directamente en la query: PostgREST hace INNER
    // JOIN payments → orders → table_sessions y filtra por business_id.
    // Antes traíamos TODAS las payments globales del rango y filtrábamos
    // en memoria — con el límite default (1000 filas) de PostgREST, en
    // multi-tenant o alto volumen las ventas más recientes (hoy) caían
    // fuera del cut-off antes de poder ser filtradas localmente, y el
    // reporte se quedaba sin ellas. Ordenamos DESC además para que, si
    // se vuelve a tocar el límite, siempre estén las más nuevas.
    final selectWithScope =
        '$select, orders!inner(id, table_sessions!inner(business_id))';

    final paymentRows = List<Map<String, dynamic>>.from(
      await _client
          .from(ReportsQueries.tablePayments)
          .select(selectWithScope)
          .eq('orders.table_sessions.business_id', businessId)
          .gte('created_at', fromIso)
          .lt('created_at', toIso)
          .order('created_at', ascending: false)
          .limit(50000),
    );

    return paymentRows;
  }

  Future<Map<String, dynamic>> getSalesSummary({
    required String businessId,
    required DateTime from,
    required DateTime to,
  }) async {
    final fromIso = AppTime.astToUtcIso(from);
    final toIso = AppTime.astToUtcIso(to);
    final paymentRows = await _loadScopedPaymentsForRange(
      businessId: businessId,
      from: from,
      to: to,
      select:
          'id, amount, change_amount, order_id, check_id, fiscal_document_id, status, created_at, payment_method_id, payment_methods(name, code)',
    );
    final completedPayments = paymentRows
        .where((row) => row['status'] == 'completed' || row['status'] == null)
        .toList(growable: false);
    final voidedPayments = paymentRows
        .where((row) => row['status'] == 'void' || row['status'] == 'cancelled')
        .toList(growable: false);

    double totalSales = 0;
    for (final payment in completedPayments) {
      totalSales += netPaymentAmount(
        payment['amount'],
        payment['change_amount'],
      );
    }

    double voidedSales = 0;
    for (final payment in voidedPayments) {
      voidedSales += netPaymentAmount(
        payment['amount'],
        payment['change_amount'],
      );
    }

    final orderIds = completedPayments
        .map((row) => row['order_id']?.toString())
        .whereType<String>()
        .toSet()
        .toList(growable: false);

    final items = await _selectInBatches(
      table: ReportsQueries.tableOrderItems,
      select:
          'id, order_id, check_id, product_name, quantity, qty, subtotal, discounts, tax, total, status, product_id, notes',
      column: 'order_id',
      values: orderIds,
    );

    // Cargar orders.total para conocer la "verdad fiscal" de cada orden
    // (lo que efectivamente se cobró al cliente, redondeado a 2 dec).
    // Usado abajo para distribuir el ruido de redondeo entre items y
    // distinguir esos centavos de una propina voluntaria real.
    final orderRows = await _selectInBatches(
      table: 'orders',
      select: 'id, total',
      column: 'id',
      values: orderIds,
    );
    final orderTotalById = <String, double>{
      for (final row in orderRows)
        if ((row['id']?.toString() ?? '').isNotEmpty)
          row['id'].toString(): _toDouble(row['total']),
    };

    final itemById = <String, Map<String, dynamic>>{};
    for (final item in items) {
      final itemId = item['id']?.toString();
      if (itemId != null && itemId.isNotEmpty) {
        itemById[itemId] = item;
      }
    }

    // Largest Remainder Method (LRM): los items se almacenan a 4 decimales
    // y orders.total a 2. Sumar items raw produce residuos de centavos
    // que aparecen como "Otros cargos" en reportes. Aquí calculamos por
    // orden el delta de redondeo y lo asignamos al item de mayor monto
    // de esa orden — así la suma de items por categoría cuadra al
    // centavo con orders.total.
    //
    // Solo distribuimos diferencias pequeñas (< 1 RD$). Diferencias más
    // grandes son potencialmente data corrupta o casos especiales y se
    // dejan intactas para que el bug salga a la vista en lugar de
    // esconderse.
    final itemRoundingAdjustment = <String, double>{};
    final itemsByOrder = <String, List<Map<String, dynamic>>>{};
    for (final item in items) {
      if (item['status']?.toString() == 'void') continue;
      final orderId = item['order_id']?.toString() ?? '';
      if (orderId.isEmpty) continue;
      itemsByOrder.putIfAbsent(orderId, () => []).add(item);
    }
    itemsByOrder.forEach((orderId, orderItems) {
      final orderTotal = orderTotalById[orderId];
      if (orderTotal == null || orderTotal <= 0) return;
      double itemsSum = 0;
      String? largestItemId;
      double largestItemAmount = -1;
      for (final item in orderItems) {
        final amount =
            _toDouble(item['subtotal']) + _toDouble(item['tax']);
        itemsSum += amount;
        if (amount > largestItemAmount) {
          largestItemAmount = amount;
          largestItemId = item['id']?.toString();
        }
      }
      // Trabajamos en centavos para evitar cascadas de error.
      final delta = ((orderTotal - itemsSum) * 100).round() / 100;
      if (delta == 0 || largestItemId == null) return;
      // Solo redistribuir ruido de redondeo, no propina ni anomalías.
      if (delta.abs() >= 1.0) return;
      itemRoundingAdjustment[largestItemId] = delta;
    });

    final itemIds = itemById.keys.toList(growable: false);
    final modifierRows = await _selectInBatches(
      table: 'order_item_modifiers',
      select: 'item_id, name, qty, price',
      column: 'item_id',
      values: itemIds,
    );

    final checkIds = completedPayments
        .map((row) => row['check_id']?.toString())
        .whereType<String>()
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList(growable: false);
    final checkRows = await _selectInBatches(
      table: 'order_checks',
      select: 'id, order_id, label, position',
      column: 'id',
      values: checkIds,
    );
    final checkById = <String, Map<String, dynamic>>{
      for (final row in checkRows)
        if ((row['id']?.toString() ?? '').isNotEmpty) row['id'].toString(): row,
    };
    final checksCountByOrder = <String, int>{};
    for (final row in checkRows) {
      final orderId = row['order_id']?.toString() ?? '';
      if (orderId.isEmpty) continue;
      checksCountByOrder[orderId] = (checksCountByOrder[orderId] ?? 0) + 1;
    }

    final fiscalDocumentIds = completedPayments
        .map((row) => row['fiscal_document_id']?.toString())
        .whereType<String>()
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList(growable: false);
    final fiscalRows = await _selectInBatches(
      table: 'fiscal_documents',
      select: 'id, ncf_type, ncf_number, status',
      column: 'id',
      values: fiscalDocumentIds,
    );
    final fiscalById = <String, Map<String, dynamic>>{
      for (final row in fiscalRows)
        if ((row['id']?.toString() ?? '').isNotEmpty) row['id'].toString(): row,
    };

    String receiptLabelForPayment(Map<String, dynamic> payment) {
      final fiscalId = payment['fiscal_document_id']?.toString() ?? '';
      if (fiscalId.isNotEmpty) {
        final doc = fiscalById[fiscalId];
        final ncfType = doc?['ncf_type']?.toString() ?? 'Comprobante fiscal';
        return _ncfTypeLabel(ncfType);
      }

      final checkId = payment['check_id']?.toString() ?? '';
      if (checkId.isNotEmpty) {
        final check = checkById[checkId];
        final orderId = payment['order_id']?.toString() ?? '';
        final hasSplit = (checksCountByOrder[orderId] ?? 0) > 1;
        final baseLabel = hasSplit ? 'Recibo dividido' : 'Recibo de cuenta';
        final checkLabel = check?['label']?.toString().trim() ?? '';
        return checkLabel.isNotEmpty ? '$baseLabel · $checkLabel' : baseLabel;
      }

      return 'Recibo estándar';
    }

    String adjustmentLabelForItem(Map<String, dynamic> item) {
      final notes = item['notes']?.toString() ?? '';
      final lineGross = _toDouble(item['subtotal']) + _toDouble(item['tax']);
      final discount = _toDouble(item['discounts']);
      final isCourtesy =
          notes.contains('[CORTESIA:') ||
          (lineGross > 0 && discount >= lineGross - 0.01);
      if (isCourtesy) return 'Cortesías';
      if (notes.contains('[PROMO_AUTO:')) return 'Promociones automáticas';
      return 'Descuentos manuales';
    }

    // Collect unique product_ids to look up their categories
    final productIds = items
        .map((i) => i['product_id']?.toString())
        .whereType<String>()
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList(growable: false);
    final categoryByProductId = <String, String>{};
    final productCostById = <String, double>{};
    if (productIds.isNotEmpty) {
      final menuItems = await _selectInBatches(
        table: 'menu_items',
        select: 'id, category_id, cost, categories(name)',
        column: 'id',
        values: productIds,
      );
      for (final mi in menuItems) {
        final pid = mi['id']?.toString() ?? '';
        final cat = mi['categories'];
        final catMap = cat is Map<String, dynamic>
            ? cat
            : (cat is Map
                  ? Map<String, dynamic>.from(cat)
                  : <String, dynamic>{});
        final catName = catMap['name']?.toString().trim();
        if (pid.isNotEmpty) {
          productCostById[pid] = _toDouble(mi['cost']);
        }
        if (pid.isNotEmpty && catName != null && catName.isNotEmpty) {
          categoryByProductId[pid] = catName;
        }
      }
    }

    double totalItems = 0;
    double modifiersSalesTotal = 0;
    double discountsTotal = 0;
    double courtesyTotal = 0;
    int discountedLinesCount = 0;
    int courtesyLinesCount = 0;

    final topProducts = <String, Map<String, dynamic>>{};
    final productSales = <String, Map<String, dynamic>>{};
    final byCategory = <String, Map<String, dynamic>>{};
    final byModifier = <String, Map<String, dynamic>>{};
    final byAdjustment = <String, Map<String, dynamic>>{};

    for (final item in items) {
      final status = item['status']?.toString();
      if (status == 'void') continue;

      final qty = _toDouble(item['qty'] ?? item['quantity']);
      totalItems += qty;

      final label = item['product_name']?.toString().trim().isNotEmpty == true
          ? item['product_name'].toString().trim()
          : 'Producto sin nombre';
      final bucket = topProducts.putIfAbsent(
        label,
        () => {'label': label, 'amount': 0.0, 'quantity': 0.0, 'count': 0},
      );
      final productId = item['product_id']?.toString() ?? '';
      final categoryName = categoryByProductId[productId] ?? 'Sin categoría';
      final discount = _toDouble(item['discounts']);
      final adjustmentLabel =
          discount > 0.009 ? adjustmentLabelForItem(item) : null;
      final courtesyAmount = adjustmentLabel == 'Cortesías' ? discount : 0.0;
      // Use subtotal+tax instead of item['total']: the April-17 migration dropped
      // and re-added the total column (resetting historical rows to 0), while
      // subtotal and tax retained their correct values.
      // El ajuste LRM (calculado arriba) absorbe los centavos de
      // redondeo que antes salían como "Otros cargos" — solo se aplica
      // al item más grande de cada orden y solo si |delta| < 1 RD$.
      final itemId = item['id']?.toString() ?? '';
      final lrmAdjustment = itemRoundingAdjustment[itemId] ?? 0.0;
      final itemGrossSales =
          _toDouble(item['subtotal']) + _toDouble(item['tax']) + lrmAdjustment;
      final itemNetSales = itemGrossSales;
      bucket['amount'] = _toDouble(bucket['amount']) + itemNetSales;
      bucket['quantity'] = _toDouble(bucket['quantity']) + qty;
      bucket['count'] = (bucket['count'] as int) + 1;
      final itemCost = (productCostById[productId] ?? 0) * qty;
      final productKey = productId.isNotEmpty ? productId : label;
      final productBucket = productSales.putIfAbsent(
        productKey,
        () => {
          'product_id': productId,
          'product': label,
          'category': categoryName,
          'quantity_sold': 0.0,
          'gross_sales': 0.0,
          'discounts': 0.0,
          'courtesies': 0.0,
          'net_sales': 0.0,
          'cost': 0.0,
          'gross_profit': 0.0,
          'tickets': 0,
        },
      );
      productBucket['quantity_sold'] =
          _toDouble(productBucket['quantity_sold']) + qty;
      productBucket['gross_sales'] =
          _toDouble(productBucket['gross_sales']) + itemGrossSales;
      productBucket['discounts'] =
          _toDouble(productBucket['discounts']) + discount;
      productBucket['courtesies'] =
          _toDouble(productBucket['courtesies']) + courtesyAmount;
      productBucket['net_sales'] =
          _toDouble(productBucket['net_sales']) + itemNetSales;
      productBucket['cost'] = _toDouble(productBucket['cost']) + itemCost;
      productBucket['gross_profit'] =
          _toDouble(productBucket['gross_profit']) + (itemNetSales - itemCost);
      productBucket['tickets'] = (productBucket['tickets'] as int) + 1;

      final catBucket = byCategory.putIfAbsent(
        categoryName,
        () => {
          'label': categoryName,
          'amount': 0.0,
          'quantity': 0.0,
          'count': 0,
        },
      );
      catBucket['amount'] =
          _toDouble(catBucket['amount']) + itemNetSales;
      catBucket['quantity'] = _toDouble(catBucket['quantity']) + qty;
      catBucket['count'] = (catBucket['count'] as int) + 1;

      if (discount > 0.009) {
        discountsTotal += discount;
        discountedLinesCount += 1;
        if (adjustmentLabel == 'Cortesías') {
          courtesyTotal += discount;
          courtesyLinesCount += 1;
        }
        final adjustmentBucket = byAdjustment.putIfAbsent(
          adjustmentLabel ?? 'Ajuste',
          () => {
            'label': adjustmentLabel ?? 'Ajuste',
            'amount': 0.0,
            'quantity': 0.0,
            'count': 0,
          },
        );
        adjustmentBucket['amount'] =
            _toDouble(adjustmentBucket['amount']) + discount;
        adjustmentBucket['quantity'] =
            _toDouble(adjustmentBucket['quantity']) + qty;
        adjustmentBucket['count'] = (adjustmentBucket['count'] as int) + 1;
      }
    }

    for (final modifier in modifierRows) {
      final itemId = modifier['item_id']?.toString() ?? '';
      final item = itemById[itemId];
      if (item == null || item['status']?.toString() == 'void') continue;

      final label = modifier['name']?.toString().trim().isNotEmpty == true
          ? modifier['name'].toString().trim()
          : 'Modificador';
      final qty = _toDouble(modifier['qty']);
      final amount = _toDouble(modifier['price']) * qty;
      modifiersSalesTotal += amount;

      final bucket = byModifier.putIfAbsent(
        label,
        () => {'label': label, 'amount': 0.0, 'quantity': 0.0, 'count': 0},
      );
      bucket['amount'] = _toDouble(bucket['amount']) + amount;
      bucket['quantity'] = _toDouble(bucket['quantity']) + qty;
      bucket['count'] = (bucket['count'] as int) + 1;

      // Attribute the modifier amount to the parent item's category so the
      // category breakdown reflects what was actually charged on each ticket.
      final parentProductId = item['product_id']?.toString() ?? '';
      final parentCategoryName =
          categoryByProductId[parentProductId] ?? 'Sin categoría';
      final catBucket = byCategory.putIfAbsent(
        parentCategoryName,
        () => {
          'label': parentCategoryName,
          'amount': 0.0,
          'quantity': 0.0,
          'count': 0,
        },
      );
      catBucket['amount'] = _toDouble(catBucket['amount']) + amount;
    }

    final byMethod = <String, Map<String, dynamic>>{};
    final byHour = <int, Map<String, dynamic>>{};
    final byReceipt = <String, Map<String, dynamic>>{};

    for (final payment in completedPayments) {
      final method = payment['payment_methods'];
      final methodMap = method is Map<String, dynamic>
          ? method
          : (method is Map
                ? Map<String, dynamic>.from(method)
                : <String, dynamic>{});
      final code =
          methodMap['code']?.toString() ??
          payment['payment_method_id']?.toString() ??
          'other';
      final label = methodMap['name']?.toString() ?? code;
      final amount = netPaymentAmount(
        payment['amount'],
        payment['change_amount'],
      );

      final methodBucket = byMethod.putIfAbsent(
        code,
        () => {'label': label, 'amount': 0.0, 'count': 0},
      );
      methodBucket['amount'] = _toDouble(methodBucket['amount']) + amount;
      methodBucket['count'] = (methodBucket['count'] as int) + 1;

      final receiptLabel = receiptLabelForPayment(payment);
      final receiptBucket = byReceipt.putIfAbsent(
        receiptLabel,
        () => {'label': receiptLabel, 'amount': 0.0, 'count': 0},
      );
      receiptBucket['amount'] = _toDouble(receiptBucket['amount']) + amount;
      receiptBucket['count'] = (receiptBucket['count'] as int) + 1;

      final createdAt = DateTime.tryParse(
        payment['created_at']?.toString() ?? '',
      );
      if (createdAt != null) {
        final hour = AppTime.astFromInstant(createdAt).hour;
        final hourBucket = byHour.putIfAbsent(
          hour,
          () => {
            'label': '${hour.toString().padLeft(2, '0')}:00',
            'amount': 0.0,
            'count': 0,
            'hour': hour,
          },
        );
        hourBucket['amount'] = _toDouble(hourBucket['amount']) + amount;
        hourBucket['count'] = (hourBucket['count'] as int) + 1;
      }
    }

    final amountByOrder = <String, double>{};
    for (final payment in completedPayments) {
      final oid = payment['order_id']?.toString() ?? '';
      if (oid.isEmpty) continue;
      amountByOrder[oid] =
          (amountByOrder[oid] ?? 0.0) +
          netPaymentAmount(payment['amount'], payment['change_amount']);
    }

    final orderSessionRows = await _selectInBatches(
      table: ReportsQueries.tableOrders,
      select:
          'id, session_id, table_sessions!inner(waiter_user_id, profiles!table_sessions_waiter_user_id_profiles_fkey(full_name), dining_tables!left(zones!left(name)))',
      column: 'id',
      values: orderIds,
    );

    final byEmployee = <String, Map<String, dynamic>>{};
    final byZone = <String, Map<String, dynamic>>{};
    for (final row in orderSessionRows) {
      final oid = row['id']?.toString() ?? '';
      final amount = amountByOrder[oid] ?? 0.0;
      if (amount == 0) continue;

      final session = row['table_sessions'];
      final sessionMap = session is Map<String, dynamic>
          ? session
          : (session is Map
                ? Map<String, dynamic>.from(session)
                : <String, dynamic>{});

      final profile = sessionMap['profiles'];
      final profileMap = profile is Map<String, dynamic>
          ? profile
          : (profile is Map
                ? Map<String, dynamic>.from(profile)
                : <String, dynamic>{});
      final empName =
          profileMap['full_name']?.toString().trim().isNotEmpty == true
          ? profileMap['full_name'].toString().trim()
          : 'Sin empleado';
      final empBucket = byEmployee.putIfAbsent(
        empName,
        () => {'label': empName, 'amount': 0.0, 'count': 0},
      );
      empBucket['amount'] = _toDouble(empBucket['amount']) + amount;
      empBucket['count'] = (empBucket['count'] as int) + 1;

      final table = sessionMap['dining_tables'];
      final tableMap = table is Map<String, dynamic>
          ? table
          : (table is Map
                ? Map<String, dynamic>.from(table)
                : <String, dynamic>{});
      final zone = tableMap['zones'];
      final zoneMap = zone is Map<String, dynamic>
          ? zone
          : (zone is Map
                ? Map<String, dynamic>.from(zone)
                : <String, dynamic>{});
      final zoneName = zoneMap['name']?.toString().trim().isNotEmpty == true
          ? zoneMap['name'].toString().trim()
          : 'Sin zona';
      final zoneBucket = byZone.putIfAbsent(
        zoneName,
        () => {'label': zoneName, 'amount': 0.0, 'count': 0},
      );
      zoneBucket['amount'] = _toDouble(zoneBucket['amount']) + amount;
      zoneBucket['count'] = (zoneBucket['count'] as int) + 1;
    }

    final avgTicket = completedPayments.isEmpty
        ? 0.0
        : totalSales / completedPayments.length;

    final salesByMethod = byMethod.values.toList(
      growable: false,
    )..sort((a, b) => _toDouble(b['amount']).compareTo(_toDouble(a['amount'])));
    final salesByReceipt = byReceipt.values.toList(
      growable: false,
    )..sort((a, b) => _toDouble(b['amount']).compareTo(_toDouble(a['amount'])));
    final salesByHour = byHour.values.toList(growable: false)
      ..sort((a, b) => (a['hour'] as int).compareTo(b['hour'] as int));
    final salesByModifier = byModifier.values.toList(
      growable: false,
    )..sort((a, b) => _toDouble(b['amount']).compareTo(_toDouble(a['amount'])));
    final salesByAdjustment = byAdjustment.values.toList(
      growable: false,
    )..sort((a, b) => _toDouble(b['amount']).compareTo(_toDouble(a['amount'])));
    final topProductsList = topProducts.values.toList(
      growable: false,
    )..sort((a, b) => _toDouble(b['amount']).compareTo(_toDouble(a['amount'])));
    final productSalesList = productSales.values.toList(growable: false)
      ..sort(
        (a, b) => _toDouble(b['net_sales']).compareTo(_toDouble(a['net_sales'])),
      );

    return {
      'from': fromIso,
      'to': toIso,
      // total_sales y net_sales son iguales: ambos representan la suma de
      // payments con status='completed'. Antes net_sales se calculaba como
      // (totalSales - voidedSales), pero como completed/voided son sets
      // disjuntos (un payment es UNO o el OTRO), esa resta dejaba el "neto"
      // como un valor que no representaba ningun subset real. Ahora ambos
      // campos son la fuente unica de la verdad: ventas reales completadas.
      'total_sales': totalSales,
      'voided_sales': voidedSales,
      'net_sales': totalSales,
      'payments_count': completedPayments.length,
      'voided_payments_count': voidedPayments.length,
      'items_sold': totalItems.round(),
      'avg_ticket': avgTicket,
      'modifier_sales_total': modifiersSalesTotal,
      'discounts_total': discountsTotal,
      'courtesy_total': courtesyTotal,
      'discounted_lines_count': discountedLinesCount,
      'courtesy_lines_count': courtesyLinesCount,
      'sales_by_method': salesByMethod,
      'sales_by_receipt': salesByReceipt,
      'sales_by_hour': salesByHour,
      'sales_by_modifier': salesByModifier,
      'sales_by_adjustment': salesByAdjustment,
      'top_products': topProductsList,
      'product_sales': productSalesList,
      'sales_by_category': () {
        // Después del LRM por item (calculado arriba), la suma de
        // categorías ya cuadra con SUM(orders.total) al centavo. La
        // diferencia entre netSales (lo que entró por payments) y la
        // suma de items debe explicarse como propina voluntaria, NO
        // como ruido de redondeo.
        //
        // Fórmula PRD-11: propina_voluntaria = SUM(payments) - SUM(orders.total)
        // Ambos lados a 2 decimales = sin ruido. Solo aparece como
        // categoría "Propina (no facturada)" si supera el umbral de
        // 1 RD$ (anything below would be operational rounding, no real tip).
        final ordersTotalSum = orderTotalById.values.fold<double>(
          0,
          (sum, total) => sum + total,
        );
        final voluntaryTip = totalSales - ordersTotalSum;
        if (voluntaryTip >= 1.0) {
          byCategory['Propina (no facturada)'] = {
            'label': 'Propina (no facturada)',
            'amount': voluntaryTip,
            'quantity': 0.0,
            'count': 0,
            'is_voluntary_tip': true,
          };
        }
        return byCategory.values.toList(growable: false)
          ..sort(
            (a, b) => _toDouble(b['amount']).compareTo(_toDouble(a['amount'])),
          );
      }(),
      'sales_by_employee': byEmployee.values.toList(growable: false)
        ..sort(
          (a, b) => _toDouble(b['amount']).compareTo(_toDouble(a['amount'])),
        ),
      'sales_by_zone': byZone.values.toList(growable: false)
        ..sort(
          (a, b) => _toDouble(b['amount']).compareTo(_toDouble(a['amount'])),
        ),
    };
  }

  Future<Map<String, dynamic>> getCashSummary({
    required String businessId,
    required DateTime from,
    required DateTime to,
  }) async {
    final fromIso = AppTime.astToUtcIso(from);
    final toIso = AppTime.astToUtcIso(to);

    final sessions = await _client
        .from(ReportsQueries.tableCashSessions)
        .select(
          'id, cash_register_id, user_id, start_amount, end_amount, difference, status, opened_at, closed_at, notes, cash_registers!inner(business_id, name)',
        )
        .eq('cash_registers.business_id', businessId)
        .gte('opened_at', fromIso)
        .lt('opened_at', toIso)
        .order('opened_at', ascending: false);

    final sessionRows = List<Map<String, dynamic>>.from(sessions);

    double openingsTotal = 0;
    double closingsTotal = 0;
    double differencesTotal = 0;
    int openSessions = 0;
    int closedSessions = 0;

    for (final session in sessionRows) {
      final startAmount = session['start_amount'];
      final endAmount = session['end_amount'];
      final difference = session['difference'];
      final status = session['status']?.toString();

      if (startAmount is num) openingsTotal += startAmount.toDouble();
      if (endAmount is num) closingsTotal += endAmount.toDouble();
      if (difference is num) differencesTotal += difference.toDouble();
      if (status == 'open') {
        openSessions += 1;
      } else {
        closedSessions += 1;
      }
    }

    final sessionIds = sessionRows
        .map((row) => row['id']?.toString())
        .whereType<String>()
        .toSet()
        .toList(growable: false);

    final transactions = await _selectInBatches(
      table: ReportsQueries.tableCashTransactions,
      // related_order_id es necesario para excluir las ventas asociadas
      // a órdenes anuladas (su payment.status = 'cancelled' / 'void').
      select: 'session_id, amount, type, created_at, related_order_id',
      column: 'session_id',
      values: sessionIds,
      transform: (query) =>
          query.gte('created_at', fromIso).lt('created_at', toIso),
    );

    // Bug fix: cuando se anula una orden, payments.status pasa a
    // 'cancelled' pero la fila en cash_transactions (type='sale')
    // queda intacta y el cierre la seguía contando como venta. Aquí
    // resolvemos los order_ids cuyos pagos están anulados y los
    // excluimos del cálculo (tanto del total como del byType['sale']).
    final saleOrderIds = transactions
        .where(
          (tx) =>
              (tx['type']?.toString() ?? '') == 'sale' &&
              (tx['related_order_id']?.toString().trim().isNotEmpty ?? false),
        )
        .map((tx) => tx['related_order_id'].toString())
        .toSet()
        .toList(growable: false);

    final cancelledOrderIds = <String>{};
    if (saleOrderIds.isNotEmpty) {
      try {
        final cancelledRows = await _client
            .from('payments')
            .select('order_id')
            .inFilter('order_id', saleOrderIds)
            .inFilter('status', ['cancelled', 'void']);
        for (final row in cancelledRows as List) {
          final id = (row as Map)['order_id']?.toString();
          if (id != null && id.isNotEmpty) cancelledOrderIds.add(id);
        }
      } catch (_) {
        // Si falla la query, conservamos el behavior previo (sumar
        // todas las ventas) — preferimos un total ligeramente
        // inflado a un cierre vacío.
      }
    }

    double manualIn = 0;
    double manualOut = 0;
    double salesTotal = 0;
    double expensesTotal = 0;
    double withdrawalsTotal = 0;
    double voidedSalesTotal = 0; // visibilidad: ventas excluidas por anulación
    final byType = <String, Map<String, dynamic>>{};

    for (final tx in transactions) {
      final amount = tx['amount'];
      final type = tx['type']?.toString() ?? 'other';
      final normalized = _toDouble(amount);
      final relatedOrderId = tx['related_order_id']?.toString();
      final isVoidedSale =
          type == 'sale' &&
          relatedOrderId != null &&
          cancelledOrderIds.contains(relatedOrderId);

      // Las ventas anuladas no se suman al cierre — se reportan aparte
      // en `voided_sales` para que el comerciante sepa cuánto se anuló.
      if (isVoidedSale) {
        voidedSalesTotal += normalized;
        continue;
      }

      final bucket = byType.putIfAbsent(
        type,
        () => {'label': _cashTypeLabel(type), 'amount': 0.0, 'count': 0},
      );
      bucket['amount'] = _toDouble(bucket['amount']) + normalized;
      bucket['count'] = (bucket['count'] as int) + 1;

      if (type == 'deposit' || type == 'income') {
        manualIn += normalized;
      }
      if (type == 'withdrawal') {
        withdrawalsTotal += normalized;
        manualOut += normalized;
      }
      if (type == 'expense') {
        expensesTotal += normalized;
        manualOut += normalized;
      }
      if (type == 'sale') {
        salesTotal += normalized;
      }
    }

    final profileIds = sessionRows
        .map((row) => row['user_id']?.toString().trim())
        .whereType<String>()
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList(growable: false);
    final profileRows = profileIds.isEmpty
        ? const <Map<String, dynamic>>[]
        : List<Map<String, dynamic>>.from(
            await _client
                .from('profiles')
                .select('id, full_name')
                .inFilter('id', profileIds),
          );
    final profileNamesById = <String, String>{
      for (final profile in profileRows)
        if ((profile['id']?.toString() ?? '').isNotEmpty)
          profile['id'].toString():
              profile['full_name']?.toString().trim().isNotEmpty == true
              ? profile['full_name'].toString().trim()
              : 'Cajero',
    };

    final closureDetails = await Future.wait(
      sessionRows.map((session) async {
        final sessionId = session['id']?.toString() ?? '';
        Map<String, dynamic> summary = const <String, dynamic>{};
        if (sessionId.isNotEmpty) {
          try {
            final rpcResult = Map<String, dynamic>.from(
              await _client.rpc(
                'fn_get_cash_session_summary',
                params: {'p_session_id': sessionId},
              ),
            );
            final success = rpcResult['success'] as bool? ?? true;
            if (success) {
              summary = rpcResult;
            }
          } catch (_) {
            summary = const <String, dynamic>{};
          }
        }

        final notes = session['notes']?.toString();
        final status = session['status']?.toString() ?? 'open';
        final startAmount = _toDouble(session['start_amount']);
        final endAmount = _toDouble(session['end_amount']);
        final difference = _toDouble(session['difference']);
        final expectedCash = _toDouble(summary['expected_cash']);
        final expectedCard = _toDouble(summary['expected_card']);
        final expectedTransfer = _toDouble(summary['expected_transfer']);
        final expectedTotal = _toDouble(summary['expected_total']) > 0
            ? _toDouble(summary['expected_total'])
            : expectedCash + expectedCard + expectedTransfer;
        final reportedCash = _extractReportedAmount(notes, 'Efectivo');
        final reportedCard = _extractReportedAmount(notes, 'Tarjetas');
        final reportedTransfer = _extractReportedAmount(
          notes,
          'Transferencias',
        );
        final extractedReportedTotal = _extractReportedAmount(
          notes,
          'Total reportado',
        );
        final reportedTotal = extractedReportedTotal > 0
            ? extractedReportedTotal
            : (endAmount > 0
                  ? endAmount
                  : reportedCash + reportedCard + reportedTransfer);
        final totalSalesAllMethods = _toDouble(
          summary['total_sales_all_methods'],
        );
        final register = session['cash_registers'];
        final registerMap = register is Map<String, dynamic>
            ? register
            : (register is Map
                  ? Map<String, dynamic>.from(register)
                  : const <String, dynamic>{});
        final userId = session['user_id']?.toString() ?? '';
        final cashierName =
            profileNamesById[userId] ??
            (userId.isEmpty
                ? 'No identificado'
                : 'Usuario ${userId.substring(0, userId.length >= 8 ? 8 : userId.length).toUpperCase()}');

        return <String, dynamic>{
          'id': sessionId,
          'status': status,
          'cashier_name': cashierName,
          'cash_register_name': registerMap['name']?.toString() ?? 'Caja',
          'opened_at': session['opened_at'],
          'closed_at': session['closed_at'],
          'start_amount': startAmount,
          'end_amount': endAmount,
          'difference': difference,
          'expected_cash': expectedCash,
          'expected_card': expectedCard,
          'expected_transfer': expectedTransfer,
          'expected_total': expectedTotal,
          'reported_cash': reportedCash,
          'reported_card': reportedCard,
          'reported_transfer': reportedTransfer,
          'reported_total': reportedTotal,
          'sales_total_all_methods': totalSalesAllMethods,
          'sales_cash': _toDouble(summary['cash_sales_net']),
          'sales_card': _toDouble(summary['expected_card']),
          'sales_transfer': _toDouble(summary['expected_transfer']),
          'deposits_total': _toDouble(summary['total_deposits']),
          'withdrawals_total': _toDouble(summary['total_withdrawals']),
          'expenses_total': _toDouble(summary['total_expenses']),
          'transaction_count':
              (summary['transaction_count'] as num?)?.toInt() ?? 0,
          'notes': notes,
          'is_balanced': difference.abs() < 0.009,
        };
      }),
    );

    closureDetails.sort((a, b) {
      final aDate = DateTime.tryParse(a['opened_at']?.toString() ?? '');
      final bDate = DateTime.tryParse(b['opened_at']?.toString() ?? '');
      if (aDate == null && bDate == null) return 0;
      if (aDate == null) return 1;
      if (bDate == null) return -1;
      return bDate.compareTo(aDate);
    });

    final typeRows = byType.values.toList(
      growable: false,
    )..sort((a, b) => _toDouble(b['amount']).compareTo(_toDouble(a['amount'])));

    final averageDifference = sessionRows.isEmpty
        ? 0.0
        : differencesTotal / sessionRows.length;

    return {
      'from': fromIso,
      'to': toIso,
      'sessions_count': sessionRows.length,
      'open_sessions_count': openSessions,
      'closed_sessions_count': closedSessions,
      'openings_total': openingsTotal,
      'closings_total': closingsTotal,
      'differences_total': differencesTotal,
      'average_difference': averageDifference,
      'sales_total': salesTotal,
      // Ventas excluidas del cierre por anulación (payments.status =
      // cancelled/void). El UI puede mostrarlas como info aparte sin
      // sumarlas al efectivo esperado.
      'voided_sales_total': voidedSalesTotal,
      'expenses_total': expensesTotal,
      'withdrawals_total': withdrawalsTotal,
      'manual_in_total': manualIn,
      'manual_out_total': manualOut,
      'net_cash_flow': salesTotal + manualIn - manualOut,
      'transactions_by_type': typeRows,
      'cash_closures': closureDetails,
    };
  }

  Future<Map<String, dynamic>> getTaxSummary({
    required String businessId,
    required DateTime from,
    required DateTime to,
  }) async {
    final fromIso = AppTime.astToUtcIso(from);
    final toIso = AppTime.astToUtcIso(to);

    final taxes = List<Map<String, dynamic>>.from(
      await _client
          .from(ReportsQueries.tableTaxes)
          .select('id, name, rate, is_active, is_service_fee')
          .eq('business_id', businessId),
    );

    final businessSettings = await _client
        .from('business_settings')
        .select('service_fee_enabled, service_fee_rate')
        .eq('business_id', businessId)
        .maybeSingle();
    final serviceFeeEnabled = businessSettings?['service_fee_enabled'] == true;
    final serviceFeeRate = _toDouble(
      businessSettings?['service_fee_rate'],
    ).clamp(0, 100);

    final payments = await _loadScopedPaymentsForRange(
      businessId: businessId,
      from: from,
      to: to,
      select: 'id, order_id, amount, change_amount, status, created_at',
    );

    final completedOrderIds = payments
        .where((row) => row['status'] == 'completed' || row['status'] == null)
        .map((row) => row['order_id']?.toString())
        .whereType<String>()
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList(growable: false);

    final items = await _selectInBatches(
      table: ReportsQueries.tableOrderItems,
      select: 'id, order_id, product_name, qty, quantity, subtotal, total, tax, tax_rate, tax_mode, status, is_takeout, discounts',
      column: 'order_id',
      values: completedOrderIds,
    );

    final itemIds = items.map((i) => i['id']?.toString()).whereType<String>().toList();
    final modifierRows = await _selectInBatches(
      table: 'order_item_modifiers',
      select: 'item_id, name, qty, price',
      column: 'item_id',
      values: itemIds,
    );

    final modifiersByItem = <String, List<OrderItemModifier>>{};
    for (final row in modifierRows) {
      final itemId = row['item_id'] as String;
      final mod = OrderItemModifier.fromMap(row);
      modifiersByItem[itemId] = [...(modifiersByItem[itemId] ?? []), mod];
    }

    final orderRows = await _selectInBatches(
      table: ReportsQueries.tableOrders,
      select: 'id, subtotal, service_fee, total, status_ext, origin:table_sessions!inner(origin)',
      column: 'id',
      values: completedOrderIds,
    );
    
    final ordersById = <String, Order>{
      for (final row in orderRows) 
        row['id'] as String: Order.fromMap({
          ...row,
          'origin': (row['origin'] as Map?)?['origin'] ?? 'table',
        })
    };

    // Calculate how much was paid today vs total for each order
    final paymentParticipationByOrder = <String, double>{};
    for (final orderId in completedOrderIds) {
      final orderPayments = payments.where((p) => p['order_id'] == orderId);
      final paidInRange = orderPayments.fold<double>(0, (sum, p) => sum + netPaymentAmount(p['amount'], p['change_amount']));
      
      final orderRow = orderRows.firstWhere((r) => r['id'] == orderId, orElse: () => {});
      final orderTotal = _toDouble(orderRow['total']);
      
      // If total is 0 or payments cover it all, factor is proportional
      paymentParticipationByOrder[orderId] = (orderTotal <= 0) ? 1.0 : (paidInRange / orderTotal);
    }

    final taxesByRate = <String, Map<String, dynamic>>{};
    for (final tax in taxes) {
      final rate = _toDouble(tax['rate']);
      taxesByRate[rate.toStringAsFixed(4)] = tax;
    }

    double totalTaxCollected = 0;
    double totalServiceFee = 0;
    double taxableSales = 0;
    double exemptSales = 0;
    double grossSalesWithTax = 0;
    double totalQuantity = 0;
    double serviceFeeBaseTotal = 0;
    int serviceFeeOrdersCount = 0;
    final breakdown = <String, Map<String, dynamic>>{};

    final Set<String> ordersWithServiceFee = {};

    for (final row in items) {
      final status = row['status']?.toString();
      if (status == 'void') continue;

      final orderId = row['order_id'] as String;
      final itemId = row['id'] as String;
      final order = ordersById[orderId];
      if (order == null) continue;

      // PROPORTIONALITY FACTOR: Only count the part that was paid in this range
      final factor = paymentParticipationByOrder[orderId] ?? 1.0;

      final item = OrderItem.fromMap(row).copyWith(
        modifiers: modifiersByItem[itemId] ?? [],
      );

      // Use harmonized pricing to get the correct paid gross for this item.
      // We deliberately do NOT use s.tax / s.subtotal for the breakdown because
      // those values depend on what was stored in the DB (which may use wrong
      // divisors or intermediate bases). Instead, we recompute from the
      // actual paid gross using the CONFIGURED tax rates so that the effective
      // ITBIS rate always equals the configured rate (e.g. 18 %).
      final s = summarizeItemPricing(order, item, forcedOrigin: order.origin);
      final paidGross = (s.subtotal + s.tax + s.serviceFee) * factor;
      final qty = item.quantity * factor;

      grossSalesWithTax += paidGross;
      totalQuantity += qty;

      // Correcting combined rate stored as single tax_rate (e.g. 28 → 18 ITBIS)
      final effectiveItbisRate = item.taxRate >= 27.9 ? 18.0 : item.taxRate;

      if (effectiveItbisRate <= 0) {
        exemptSales += paidGross;
        continue;
      }

      // Determine whether propina de ley applies to this item
      final origin = parseSaleOrigin(order.origin);
      final applyLey = serviceFeeEnabled &&
          !item.isTakeout &&
          origin != SaleOrigin.quick &&
          origin != SaleOrigin.delivery;
      final leyRate = applyLey ? serviceFeeRate : 0.0;
      final fullRatePct = effectiveItbisRate + leyRate;

      // Recompute base and taxes from paidGross using configured rates.
      // This guarantees ITBIS / base == configuredItbisRate regardless of how
      // the order was originally stored.
      final rawBase = fullRatePct > 0 ? paidGross / (1 + fullRatePct / 100) : paidGross;
      final itbis = (rawBase * effectiveItbisRate / 100 * 100).round() / 100;
      final ley = (rawBase * leyRate / 100 * 100).round() / 100;
      // Base absorbs rounding residue so that base + itbis + ley == paidGross exactly
      final base = ((paidGross - itbis - ley) * 100).round() / 100;

      taxableSales += base;
      totalTaxCollected += itbis;

      final effectiveRateKey = effectiveItbisRate.toStringAsFixed(4);
      final taxConfig = taxesByRate[effectiveRateKey];
      final rateDisplay = effectiveItbisRate == effectiveItbisRate.truncateToDouble()
          ? effectiveItbisRate.toInt().toString()
          : effectiveItbisRate.toStringAsFixed(2);
      final label = taxConfig?['name']?.toString().trim().isNotEmpty == true
          ? taxConfig!['name'].toString().trim()
          : 'ITBIS ($rateDisplay%)';

      final bucket = breakdown.putIfAbsent(
        effectiveRateKey,
        () => {
          'label': label,
          'rate': effectiveItbisRate,
          'amount': 0.0,
          'taxable_amount': 0.0,
          'gross_amount': 0.0,
          'quantity': 0.0,
          'count': 0,
        },
      );
      bucket['amount'] = _toDouble(bucket['amount']) + itbis;
      bucket['taxable_amount'] = _toDouble(bucket['taxable_amount']) + base;
      bucket['gross_amount'] = _toDouble(bucket['gross_amount']) + paidGross;
      bucket['quantity'] = _toDouble(bucket['quantity']) + qty;
      bucket['count'] = (bucket['count'] as int) + 1;

      if (ley > 0) {
        totalServiceFee += ley;
        serviceFeeBaseTotal += base;
        ordersWithServiceFee.add(orderId);
      }
    }

    serviceFeeOrdersCount = ordersWithServiceFee.length;

    if (totalServiceFee > 0) {
      breakdown['__service_fee__'] = {
        'label': 'Propina de ley',
        'rate': 10.0,
        'amount': totalServiceFee,
        'taxable_amount': serviceFeeBaseTotal,
        'gross_amount': serviceFeeBaseTotal + totalServiceFee,
        'quantity': serviceFeeOrdersCount.toDouble(),
        'count': serviceFeeOrdersCount,
      };
    }

    final breakdownRows = breakdown.values.toList(
      growable: false,
    )..sort((a, b) => _toDouble(b['amount']).compareTo(_toDouble(a['amount'])));

    // Final rounding of aggregated totals for the report cards
    final rTotalTax = (totalTaxCollected * 100).round() / 100;
    final rTotalService = (totalServiceFee * 100).round() / 100;

    final effectiveRate = taxableSales <= 0
        ? 0.0
        : (totalTaxCollected / taxableSales) * 100;
    final totalChargesCollected = rTotalTax + rTotalService;

    return {
      'from': fromIso,
      'to': toIso,
      'configured_taxes_count': taxes.length,
      'active_taxes_count': taxes
          .where((tax) => tax['is_active'] == true)
          .length,
      'taxed_items_count': breakdownRows.fold<int>(
        0,
        (sum, row) => sum + ((row['count'] as int?) ?? 0),
      ),
      'items_quantity': totalQuantity,
      'gross_sales': (grossSalesWithTax * 100).round() / 100,
      'taxable_sales': (taxableSales * 100).round() / 100,
      'exempt_sales': (exemptSales * 100).round() / 100,
      'total_tax_collected': rTotalTax,
      'total_service_fee': rTotalService,
      // PRD 1: leer la tasa real del negocio en vez del hardcode 10.0.
      'service_fee_rate': serviceFeeEnabled ? serviceFeeRate.toDouble() : 0.0,
      'service_fee_orders_count': serviceFeeOrdersCount,
      'service_fee_base_total': (serviceFeeBaseTotal * 100).round() / 100,
      'total_charges_collected': (totalChargesCollected * 100).round() / 100,
      'effective_tax_rate': effectiveRate,
      'tax_breakdown': breakdownRows.map((r) => {
        ...r,
        'amount': (r['amount'] * 100).round() / 100,
        'taxable_amount': (r['taxable_amount'] * 100).round() / 100,
        'gross_amount': (r['gross_amount'] * 100).round() / 100,
      }).toList(),
    };
  }

  String _cashTypeLabel(String type) {
    switch (type) {
      case 'sale':
        return 'Ventas';
      case 'deposit':
        return 'Depósitos';
      case 'withdrawal':
        return 'Retiros';
      case 'expense':
        return 'Gastos';
      case 'income':
        return 'Ingresos';
      default:
        return type;
    }
  }

  Future<Map<String, dynamic>> getPurchasesSummary({
    required String businessId,
    required DateTime from,
    required DateTime to,
  }) async {
    final fromIso = AppTime.astToUtcIso(from);
    final toIso = AppTime.astToUtcIso(to);

    final orders = List<Map<String, dynamic>>.from(
      await _client
          .from(ReportsQueries.tablePurchaseOrders)
          .select('id, supplier_id, status, total, created_at')
          .eq('business_id', businessId)
          .gte('created_at', fromIso)
          .lt('created_at', toIso),
    );

    final suppliers = List<Map<String, dynamic>>.from(
      await _client
          .from(ReportsQueries.tableSuppliers)
          .select('id, name')
          .eq('business_id', businessId)
          .eq('is_active', true),
    );

    final supplierIds = orders
        .map((row) => row['supplier_id']?.toString())
        .whereType<String>()
        .toSet()
        .toList(growable: false);

    final suppliersById = <String, String>{
      for (final row in suppliers)
        row['id']?.toString() ?? '': row['name']?.toString() ?? 'Proveedor',
    };

    double totalOrdered = 0;
    double totalReceived = 0;
    int receivedCount = 0;
    int partialCount = 0;
    int draftCount = 0;
    final statusBuckets = <String, Map<String, dynamic>>{};
    final supplierBuckets = <String, Map<String, dynamic>>{};

    for (final order in orders) {
      final total = _toDouble(order['total']);
      final status = order['status']?.toString() ?? 'draft';
      final supplierId = order['supplier_id']?.toString() ?? '';
      totalOrdered += total;

      final statusBucket = statusBuckets.putIfAbsent(
        status,
        () => {
          'label': _purchaseStatusLabel(status),
          'amount': 0.0,
          'count': 0,
        },
      );
      statusBucket['amount'] = _toDouble(statusBucket['amount']) + total;
      statusBucket['count'] = (statusBucket['count'] as int) + 1;

      final supplierLabel =
          suppliersById[supplierId] ?? 'Proveedor no asignado';
      final supplierBucket = supplierBuckets.putIfAbsent(
        supplierLabel,
        () => {'label': supplierLabel, 'amount': 0.0, 'count': 0},
      );
      supplierBucket['amount'] = _toDouble(supplierBucket['amount']) + total;
      supplierBucket['count'] = (supplierBucket['count'] as int) + 1;

      switch (status) {
        case 'received':
          totalReceived += total;
          receivedCount += 1;
          break;
        case 'partial':
          partialCount += 1;
          break;
        case 'draft':
          draftCount += 1;
          break;
      }
    }

    final avgOrder = orders.isEmpty ? 0.0 : totalOrdered / orders.length;
    final supplierRows = supplierBuckets.values.toList(
      growable: false,
    )..sort((a, b) => _toDouble(b['amount']).compareTo(_toDouble(a['amount'])));
    final statusRows = statusBuckets.values.toList(
      growable: false,
    )..sort((a, b) => _toDouble(b['amount']).compareTo(_toDouble(a['amount'])));

    return {
      'from': fromIso,
      'to': toIso,
      'orders_count': orders.length,
      'suppliers_count': suppliers.length,
      'suppliers_with_orders_count': supplierIds.length,
      'total_ordered': totalOrdered,
      'total_received': totalReceived,
      'avg_order_total': avgOrder,
      'received_count': receivedCount,
      'partial_count': partialCount,
      'draft_count': draftCount,
      'status_breakdown': statusRows,
      'top_suppliers': supplierRows.take(8).toList(growable: false),
    };
  }

  Future<Map<String, dynamic>> getFiscalDocumentsSummary({
    required String businessId,
    required DateTime from,
    required DateTime to,
  }) async {
    final fromIso = AppTime.astToUtcIso(from);
    final toIso = AppTime.astToUtcIso(to);

    final rows = List<Map<String, dynamic>>.from(
      await _client
          .from('fiscal_documents')
          .select(
            'id, order_id, payment_id, customer_id, ncf_type, ncf_number, customer_rnc, customer_name, subtotal, taxable_amount, itbis_amount, service_fee, total, status, issued_at',
          )
          .eq('business_id', businessId)
          .gte('issued_at', fromIso)
          .lt('issued_at', toIso)
          .order('issued_at', ascending: true),
    );

    // --- Fetch configured taxes for label lookup ---
    final taxConfigs = List<Map<String, dynamic>>.from(
      await _client
          .from(ReportsQueries.tableTaxes)
          .select('id, name, rate, is_active, is_service_fee')
          .eq('business_id', businessId),
    );
    final taxNameByRate = <String, String>{};
    double configuredServiceFeeRate = 0;
    double configuredTaxOnlyRate = 0;
    String configuredServiceFeeName = 'Propina de ley';
    for (final t in taxConfigs) {
      final rate = _toDouble(t['rate']);
      final name = t['name']?.toString().trim() ?? '';
      if (name.isNotEmpty) {
        taxNameByRate[rate.toStringAsFixed(4)] = name;
      }
      final isService = t['is_service_fee'] == true;
      final nameLower = name.toLowerCase();
      // Heurística para detectar "propina de ley" en config legacy
      // donde el flag is_service_fee no está seteado: nombre contiene
      // alguna palabra clave + rate típico (10%). "ley" cubre el caso
      // del usuario que tiene el tax llamado solo "LEY".
      final isHeuristic = (rate - 10).abs() < 0.001 &&
          (nameLower.contains('propina') ||
              nameLower.contains('servicio') ||
              nameLower == 'ley' ||
              nameLower.contains(' ley') ||
              nameLower.startsWith('ley '));
      if (t['is_active'] == true) {
        if (isService || isHeuristic) {
          configuredServiceFeeRate = rate;
          if (name.isNotEmpty) configuredServiceFeeName = name;
        } else {
          configuredTaxOnlyRate += rate;
        }
      }
    }

    // --- Collect order IDs from active fiscal docs ---
    final activeRows = rows.where(
      (d) => (d['status']?.toString() ?? 'active') == 'active',
    );
    final orderIds = activeRows
        .map((d) => d['order_id']?.toString())
        .whereType<String>()
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList(growable: false);

    // --- Fetch order items (tax_rate, tax, subtotal) for those orders ---
    final orderItems = orderIds.isEmpty
        ? <Map<String, dynamic>>[]
        : await _selectInBatches(
            table: ReportsQueries.tableOrderItems,
            select:
                'order_id, tax, tax_rate, subtotal, total, qty, quantity, status',
            column: 'order_id',
            values: orderIds,
          );

    // --- Fetch orders for service_fee ---
    final orderRows = orderIds.isEmpty
        ? <Map<String, dynamic>>[]
        : await _selectInBatches(
            table: ReportsQueries.tableOrders,
            select: 'id, service_fee, status_ext',
            column: 'id',
            values: orderIds,
          );
    final serviceFeeByOrder = <String, double>{};
    for (final o in orderRows) {
      final oid = o['id']?.toString() ?? '';
      final status = o['status_ext']?.toString().trim().toLowerCase() ?? '';
      if (status == 'void' || status == 'cancelled') continue;
      final fee = _toDouble(o['service_fee']);
      if (fee > 0 && oid.isNotEmpty) {
        serviceFeeByOrder[oid] = fee;
      }
    }

    // --- Build per-order tax breakdown ---
    // key: order_id -> list of { label, rate, taxAmount, base }
    final taxBreakdownByOrder = <String, List<Map<String, dynamic>>>{};
    // Derivado: porción de propina cuando los items vienen con
    // tax_rate combinado (28% = ITBIS+Ley). Los pagos viejos / flujos
    // que no separan la propina al guardarla la dejan baked dentro
    // del item.tax, así que la rescatamos para que la columna
    // "Propina de ley" no salga en cero cuando sí se cobró.
    final derivedServiceFeeByOrder = <String, double>{};
    for (final item in orderItems) {
      final status = item['status']?.toString();
      if (status == 'void') continue;
      final oid = item['order_id']?.toString() ?? '';
      if (oid.isEmpty) continue;

      var taxAmount = _toDouble(item['tax']);
      var taxRate = _toDouble(item['tax_rate']);
      final subtotal = _toDouble(item['subtotal']);

      if (taxRate <= 0 && taxAmount <= 0) continue;

      // Items con tax_rate ≈ configured service fee son propina baked
      // adentro de items.tax (caso legacy donde el motor viejo trataba
      // la propina como un impuesto más). La rescatamos al
      // derivedServiceFeeByOrder y NO la metemos al breakdown — si no,
      // sale como columna "LEY (10%)" duplicando "Propina de ley".
      if (configuredServiceFeeRate > 0 &&
          (taxRate - configuredServiceFeeRate).abs() < 0.01) {
        derivedServiceFeeByOrder[oid] =
            (derivedServiceFeeByOrder[oid] ?? 0) + taxAmount;
        continue;
      }

      // Detect combined rate (e.g. 28 = 18% ITBIS + 10% Ley) y partir
      // el tax_amount proporcionalmente. Antes solo cambiábamos el rate
      // a 18 pero seguíamos sumando los 28 puntos al bucket ITBIS — eso
      // inflaba ITBIS y hacía desaparecer la propina del breakdown.
      if (configuredServiceFeeRate > 0 &&
          configuredTaxOnlyRate > 0 &&
          (taxRate - configuredTaxOnlyRate - configuredServiceFeeRate).abs() <
              0.01) {
        final combined = configuredTaxOnlyRate + configuredServiceFeeRate;
        final propinaPortion =
            taxAmount * (configuredServiceFeeRate / combined);
        final itbisPortion = taxAmount - propinaPortion;
        derivedServiceFeeByOrder[oid] =
            (derivedServiceFeeByOrder[oid] ?? 0) + propinaPortion;
        taxRate = configuredTaxOnlyRate;
        taxAmount = itbisPortion;
      }

      final rateKey = taxRate.toStringAsFixed(4);
      final label =
          taxNameByRate[rateKey] ?? 'Impuesto ${taxRate.toStringAsFixed(2)}%';

      final list = taxBreakdownByOrder.putIfAbsent(oid, () => []);
      // Merge into existing bucket for same rate in same order
      final existing = list
          .where((b) => b['rate_key'] == rateKey)
          .toList(growable: false);
      if (existing.isNotEmpty) {
        existing.first['tax_amount'] =
            _toDouble(existing.first['tax_amount']) + taxAmount;
        existing.first['base'] = _toDouble(existing.first['base']) + subtotal;
      } else {
        list.add({
          'rate_key': rateKey,
          'label': label,
          'rate': taxRate,
          'tax_amount': taxAmount,
          'base': subtotal,
        });
      }
    }

    // --- Global tax type aggregation ---
    final globalTaxBreakdown = <String, Map<String, dynamic>>{};

    for (final oid in orderIds) {
      final items = taxBreakdownByOrder[oid] ?? const [];
      for (final item in items) {
        final rateKey = item['rate_key'] as String;
        final bucket = globalTaxBreakdown.putIfAbsent(
          rateKey,
          () => {
            'label': item['label'],
            'rate': item['rate'],
            'tax_amount': 0.0,
            'base': 0.0,
            'count': 0,
          },
        );
        bucket['tax_amount'] =
            _toDouble(bucket['tax_amount']) + _toDouble(item['tax_amount']);
        bucket['base'] = _toDouble(bucket['base']) + _toDouble(item['base']);
        bucket['count'] = (bucket['count'] as int) + 1;
      }
    }

    // taxBreakdownRows is built after standard aggregations so it can use
    // totalServiceFee read directly from fiscal_documents.service_fee.

    // --- Standard aggregations (all values read directly from fiscal_documents) ---
    double totalSubtotal = 0;
    double totalItbis = 0;
    double totalServiceFee = 0;
    double totalAmount = 0;
    int activeCount = 0;
    int voidCount = 0;
    final byType = <String, Map<String, dynamic>>{};

    final enrichedDocs = <Map<String, dynamic>>[];
    for (final doc in rows) {
      final status = doc['status']?.toString() ?? 'active';
      final subtotal = _toDouble(doc['subtotal']);
      final itbis = _toDouble(doc['itbis_amount']);
      final docServiceFee = _toDouble(doc['service_fee']);
      final total = _toDouble(doc['total']);
      final ncfType = doc['ncf_type']?.toString() ?? 'B02';
      final oid = doc['order_id']?.toString() ?? '';
      final docTaxes = taxBreakdownByOrder[oid] ?? const [];

      // service_fee = (orden-level: doc.service_fee o orders.service_fee)
      //              + (items-level: derivado de rate=10 baked o split 28%).
      // Suma, no prioridad: hay docs mixtos donde parte de la propina
      // se computó al cierre vía calculate_order_totals (queda en
      // doc.service_fee) y otra parte estaba baked dentro de items.tax
      // como rate=10 (legacy). Ambos representan propina cobrada al
      // cliente y deben sumarse para reflejar el total real.
      // En docs limpios (modernos o backfilled) derived = 0, así que
      // no hay double-count.
      final orderLevelServiceFee = docServiceFee > 0
          ? docServiceFee
          : (serviceFeeByOrder[oid] ?? 0);
      final serviceFee =
          orderLevelServiceFee + (derivedServiceFeeByOrder[oid] ?? 0);

      if (status == 'active') {
        activeCount += 1;
        totalSubtotal += subtotal;
        totalItbis += itbis;
        totalServiceFee += serviceFee;
        totalAmount += total;
      } else {
        voidCount += 1;
      }

      final bucket = byType.putIfAbsent(
        ncfType,
        () => {
          'label': _ncfTypeLabel(ncfType),
          'amount': 0.0,
          'itbis': 0.0,
          'service_fee': 0.0,
          'count': 0,
        },
      );
      if (status == 'active') {
        bucket['amount'] = _toDouble(bucket['amount']) + total;
        bucket['itbis'] = _toDouble(bucket['itbis']) + itbis;
        bucket['service_fee'] = _toDouble(bucket['service_fee']) + serviceFee;
        bucket['count'] = (bucket['count'] as int) + 1;
      }

      enrichedDocs.add({
        ...doc,
        'service_fee': serviceFee,
        'tax_breakdown': docTaxes,
      });
    }

    final typeRows = byType.values.toList(
      growable: false,
    )..sort((a, b) => _toDouble(b['amount']).compareTo(_toDouble(a['amount'])));

    // Add service fee bucket using the fiscal_documents.service_fee total
    if (totalServiceFee > 0) {
      globalTaxBreakdown['__service_fee__'] = {
        'label': configuredServiceFeeName,
        'rate': configuredServiceFeeRate,
        'tax_amount': totalServiceFee,
        'base': configuredServiceFeeRate > 0
            ? totalServiceFee / (configuredServiceFeeRate / 100.0)
            : totalSubtotal,
        'count': activeCount,
      };
    }

    final taxBreakdownRows = globalTaxBreakdown.values.toList(growable: false)
      ..sort((a, b) =>
          _toDouble(b['tax_amount']).compareTo(_toDouble(a['tax_amount'])));

    return {
      'from': fromIso,
      'to': toIso,
      'documents_count': rows.length,
      'active_count': activeCount,
      'void_count': voidCount,
      'total_subtotal': totalSubtotal,
      'total_itbis': totalItbis,
      'total_amount': totalAmount,
      'total_service_fee': totalServiceFee,
      'service_fee_label': configuredServiceFeeName,
      'service_fee_rate': configuredServiceFeeRate,
      'by_type': typeRows,
      'tax_breakdown': taxBreakdownRows,
      'documents': enrichedDocs,
    };
  }

  String _ncfTypeLabel(String type) {
    switch (type) {
      case 'B01':
      case 'E31':
        return 'Crédito Fiscal';
      case 'B02':
      case 'E32':
        return 'Consumo';
      case 'B03':
      case 'E33':
        return 'Nota de Débito';
      case 'B04':
      case 'E34':
        return 'Nota de Crédito';
      case 'B11':
      case 'E41':
        return 'Compras';
      case 'B13':
      case 'E43':
        return 'Gastos Menores';
      case 'B14':
      case 'E44':
        return 'Regímenes Especiales';
      case 'B15':
      case 'E45':
        return 'Gubernamental';
      case 'B16':
      case 'E46':
        return 'Exportaciones';
      default:
        return type;
    }
  }

  String _purchaseStatusLabel(String status) {
    switch (status) {
      case 'received':
        return 'Recibidas';
      case 'partial':
        return 'Parciales';
      case 'draft':
        return 'Borradores';
      case 'cancelled':
        return 'Canceladas';
      default:
        return status;
    }
  }

  Future<Map<String, dynamic>> getInventorySummary({
    required String businessId,
    required DateTime from,
    required DateTime to,
  }) async {
    final items = List<Map<String, dynamic>>.from(
      await _client
          .from(ReportsQueries.tableInventoryItems)
          .select('id, sku, name, unit, cost, min_stock, max_stock, is_active')
          .eq('business_id', businessId),
    );

    final itemIds = items
        .map((row) => row['id']?.toString())
        .whereType<String>()
        .toList(growable: false);

    final stockRows = await _selectInBatches(
      table: ReportsQueries.tableInventoryStock,
      select: 'item_id, quantity',
      column: 'item_id',
      values: itemIds,
    );

    final fromIso = AppTime.astToUtcIso(from);
    final toIso = AppTime.astToUtcIso(to);

    final movementRows = itemIds.isEmpty
        ? <Map<String, dynamic>>[]
        : List<Map<String, dynamic>>.from(
            await _client
                .from(ReportsQueries.tableInventoryMovements)
                .select('item_id, movement_type, quantity, created_at')
                .eq('business_id', businessId)
                .gte('created_at', fromIso)
                .lt('created_at', toIso)
                .order('created_at', ascending: false)
                .limit(120),
          );

    final stockByItem = <String, double>{};
    for (final row in stockRows) {
      final itemId = row['item_id']?.toString();
      if (itemId == null || itemId.isEmpty) continue;
      stockByItem[itemId] =
          (stockByItem[itemId] ?? 0) + _toDouble(row['quantity']);
    }

    double totalUnits = 0;
    double totalStockValue = 0;
    int activeItems = 0;
    int lowStock = 0;
    int outOfStock = 0;
    final topStock = <Map<String, dynamic>>[];
    final alertItems = <Map<String, dynamic>>[];

    for (final item in items) {
      final itemId = item['id']?.toString();
      if (itemId == null || itemId.isEmpty) continue;
      final stock = stockByItem[itemId] ?? 0;
      final minStock = _toDouble(item['min_stock']);
      final cost = _toDouble(item['cost']);
      final isActive = item['is_active'] == true;
      final name = item['name']?.toString() ?? 'Insumo';
      final unit = item['unit']?.toString() ?? 'unidad';

      totalUnits += stock;
      totalStockValue += stock * cost;
      if (isActive) activeItems += 1;
      if (stock <= 0) {
        outOfStock += 1;
      } else if (minStock > 0 && stock <= minStock) {
        lowStock += 1;
      }

      topStock.add({
        'label': name,
        'amount': stock,
        'quantity': stock,
        'count': 1,
        'unit': unit,
      });

      if (stock <= 0 || (minStock > 0 && stock <= minStock)) {
        alertItems.add({
          'label': name,
          'amount': stock,
          'quantity': minStock,
          'count': stock <= 0 ? 0 : 1,
          'unit': unit,
        });
      }
    }

    topStock.sort(
      (a, b) => _toDouble(b['amount']).compareTo(_toDouble(a['amount'])),
    );
    alertItems.sort((a, b) {
      final aOut = _toDouble(a['amount']) <= 0 ? 1 : 0;
      final bOut = _toDouble(b['amount']) <= 0 ? 1 : 0;
      if (aOut != bOut) return bOut.compareTo(aOut);
      return _toDouble(a['amount']).compareTo(_toDouble(b['amount']));
    });

    final movementBuckets = <String, Map<String, dynamic>>{};
    for (final row in movementRows) {
      final type = row['movement_type']?.toString() ?? 'adjustment';
      final qty = _toDouble(row['quantity']).abs();
      final bucket = movementBuckets.putIfAbsent(
        type,
        () => {
          'label': _inventoryMovementLabel(type),
          'amount': 0.0,
          'count': 0,
        },
      );
      bucket['amount'] = _toDouble(bucket['amount']) + qty;
      bucket['count'] = (bucket['count'] as int) + 1;
    }

    final movementSummary = movementBuckets.values.toList(
      growable: false,
    )..sort((a, b) => _toDouble(b['amount']).compareTo(_toDouble(a['amount'])));

    return {
      'from': fromIso,
      'to': toIso,
      'items_count': items.length,
      'active_items_count': activeItems,
      'total_units': totalUnits,
      'total_stock_value': totalStockValue,
      'low_stock_count': lowStock,
      'out_of_stock_count': outOfStock,
      'top_stock_items': topStock.take(8).toList(growable: false),
      'alert_items': alertItems.take(8).toList(growable: false),
      'movement_summary': movementSummary,
    };
  }

  String _inventoryMovementLabel(String type) {
    switch (type) {
      case 'purchase':
        return 'Compras';
      case 'sale':
        return 'Ventas';
      case 'adjustment':
        return 'Ajustes';
      case 'waste':
        return 'Mermas';
      case 'transfer':
        return 'Transferencias';
      default:
        return type;
    }
  }

  /// Proyección de cantidades vendidas por producto para el mes en curso.
  ///
  /// Algoritmo: usa los últimos 56 días (8 semanas) de ventas pagadas como
  /// base, y agrupa por día de la semana — los restaurantes tienen
  /// patrones semanales fuertes (ej: lunes flojo, viernes alto). Para
  /// proyectar cada día restante del mes en curso, usa el promedio
  /// histórico de ese día de la semana.
  ///
  /// Para los días del mes que ya pasaron, usa la cantidad real
  /// (incluyendo ceros), no el promedio. Eso evita inflar la
  /// proyección para productos que aún no se han vendido este mes.
  ///
  /// Retorna `Map<productId, projectedQty>`. Productos sin historial
  /// no aparecen en el map.
  Future<Map<String, double>> getMonthlyProductProjection({
    required String businessId,
  }) async {
    final now = AppTime.nowAst();
    final monthStart = DateTime(now.year, now.month, 1);
    final monthEnd = now.month == 12
        ? DateTime(now.year + 1, 1, 1)
        : DateTime(now.year, now.month + 1, 1);
    final today = DateTime(now.year, now.month, now.day);
    final tomorrow = today.add(const Duration(days: 1));
    final histStart = today.subtract(const Duration(days: 56));

    // 1. Pagos completados en la ventana histórica → mapa order_id → fecha.
    final paymentRows = await _loadScopedPaymentsForRange(
      businessId: businessId,
      from: histStart,
      to: tomorrow,
      select: 'id, order_id, status, created_at',
    );

    final orderIdToDate = <String, DateTime>{};
    for (final p in paymentRows) {
      final status = p['status']?.toString();
      if (status == 'void' || status == 'cancelled') continue;
      final orderId = p['order_id']?.toString() ?? '';
      if (orderId.isEmpty) continue;
      final created = DateTime.tryParse(p['created_at']?.toString() ?? '');
      if (created == null) continue;
      final ast = AppTime.astFromInstant(created);
      final dateOnly = DateTime(ast.year, ast.month, ast.day);
      final existing = orderIdToDate[orderId];
      if (existing == null || dateOnly.isBefore(existing)) {
        orderIdToDate[orderId] = dateOnly;
      }
    }

    if (orderIdToDate.isEmpty) return const {};

    // 2. Items de esas órdenes.
    final items = await _selectInBatches(
      table: ReportsQueries.tableOrderItems,
      select: 'order_id, product_id, qty, quantity, status',
      column: 'order_id',
      values: orderIdToDate.keys.toList(growable: false),
    );

    // 3. Acumular cantidad diaria por producto.
    final dailyPerProduct = <String, Map<DateTime, double>>{};
    for (final item in items) {
      final status = item['status']?.toString();
      if (status == 'void') continue;
      final productId = item['product_id']?.toString() ?? '';
      if (productId.isEmpty) continue;
      final orderId = item['order_id']?.toString() ?? '';
      final date = orderIdToDate[orderId];
      if (date == null) continue;
      final qty = _toDouble(item['qty']) > 0
          ? _toDouble(item['qty'])
          : _toDouble(item['quantity']);
      if (qty <= 0) continue;

      final perDate = dailyPerProduct.putIfAbsent(productId, () => {});
      perDate[date] = (perDate[date] ?? 0) + qty;
    }

    // 4. Cuántas veces aparece cada día de la semana en la ventana
    //    histórica. Necesario para promediar correctamente, incluyendo
    //    días con cero ventas (sin esto, los productos vendidos solo
    //    en ciertos días tendrían un promedio inflado).
    final daysByDow = <int, int>{};
    var checkDate = histStart;
    while (checkDate.isBefore(tomorrow)) {
      daysByDow[checkDate.weekday] = (daysByDow[checkDate.weekday] ?? 0) + 1;
      checkDate = checkDate.add(const Duration(days: 1));
    }

    // 5. Para cada producto: avg por DOW, luego proyectar el mes en curso.
    final projection = <String, double>{};
    for (final entry in dailyPerProduct.entries) {
      final productId = entry.key;
      final perDate = entry.value;

      final qtyByDow = <int, double>{};
      perDate.forEach((date, qty) {
        qtyByDow[date.weekday] = (qtyByDow[date.weekday] ?? 0) + qty;
      });

      final avgByDow = <int, double>{};
      daysByDow.forEach((dow, count) {
        avgByDow[dow] = count > 0 ? (qtyByDow[dow] ?? 0) / count : 0;
      });

      double projected = 0;
      var d = monthStart;
      while (d.isBefore(monthEnd)) {
        if (d.isBefore(tomorrow)) {
          // Día del mes que ya pasó: usar cantidad real (0 si no se vendió).
          projected += perDate[d] ?? 0;
        } else {
          // Día futuro del mes: usar promedio del día de la semana.
          projected += avgByDow[d.weekday] ?? 0;
        }
        d = d.add(const Duration(days: 1));
      }

      projection[productId] = projected;
    }

    return projection;
  }
}
