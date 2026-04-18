import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/utils/app_time.dart';
import '../../../data/repositories/reports_repository.dart';
import '../../../data/utils/business_id_resolver.dart';

enum ReportCategory { sales, purchases, finances, inventory, taxes, fiscal }

enum SalesReportRangePreset { today, yesterday, thisWeek, thisMonth, custom }

enum SalesSubReport {
  overview,
  byCategory,
  byEmployee,
  byPayment,
  byReceipt,
  byModifiers,
  byDiscounts,
  byProduct,
  byZone,
  byHour,
}

enum SalesBreakdownFilter {
  paymentMethod,
  product,
  category,
  employee,
  zone,
  hourly,
}

class ReportItem {
  final String title;
  final String description;
  final VoidCallback? onTap;

  const ReportItem({
    required this.title,
    required this.description,
    this.onTap,
  });
}

class SalesMetricCardData {
  final String title;
  final String value;
  final String subtitle;
  final IconData icon;
  final Color color;

  const SalesMetricCardData({
    required this.title,
    required this.value,
    required this.subtitle,
    required this.icon,
    required this.color,
  });
}

class SalesBreakdownRow {
  final String label;
  final double amount;
  final int count;
  final double quantity;

  const SalesBreakdownRow({
    required this.label,
    required this.amount,
    this.count = 0,
    this.quantity = 0,
  });
}

class ProductSalesReportRow {
  final String product;
  final String category;
  final double quantitySold;
  final double grossSales;
  final double discounts;
  final double courtesies;
  final double netSales;
  final double cost;
  final double grossProfit;
  final int tickets;

  const ProductSalesReportRow({
    required this.product,
    required this.category,
    required this.quantitySold,
    required this.grossSales,
    required this.discounts,
    required this.courtesies,
    required this.netSales,
    required this.cost,
    required this.grossProfit,
    required this.tickets,
  });
}

class ReportsState {
  final ReportCategory? selectedCategory;
  final bool loading;
  final String? error;
  final Map<String, dynamic>? salesSummary;
  final Map<String, dynamic>? cashSummary;
  final Map<String, dynamic>? purchasesSummary;
  final Map<String, dynamic>? inventorySummary;
  final Map<String, dynamic>? taxSummary;
  final Map<String, dynamic>? fiscalSummary;
  final SalesReportRangePreset salesRangePreset;
  final SalesBreakdownFilter salesBreakdownFilter;
  final SalesSubReport salesSubReport;
  final DateTime salesFrom;
  final DateTime salesTo;
  final String? fiscalTypeFilter;
  final String productSalesQuery;
  final String? productSalesCategoryFilter;

  const ReportsState({
    this.selectedCategory,
    this.loading = false,
    this.error,
    this.salesSummary,
    this.cashSummary,
    this.purchasesSummary,
    this.inventorySummary,
    this.taxSummary,
    this.fiscalSummary,
    this.salesRangePreset = SalesReportRangePreset.thisWeek,
    this.salesBreakdownFilter = SalesBreakdownFilter.paymentMethod,
    this.salesSubReport = SalesSubReport.overview,
    required this.salesFrom,
    required this.salesTo,
    this.fiscalTypeFilter,
    this.productSalesQuery = '',
    this.productSalesCategoryFilter,
  });

  factory ReportsState.initial() {
    final range = ReportsViewModel.resolveRange(
      SalesReportRangePreset.thisWeek,
    );
    return ReportsState(
      salesFrom: range.from,
      salesTo: range.to,
      selectedCategory: null,
    );
  }

  ReportsState copyWith({
    ReportCategory? selectedCategory,
    bool? loading,
    String? error,
    Map<String, dynamic>? salesSummary,
    Map<String, dynamic>? cashSummary,
    Map<String, dynamic>? purchasesSummary,
    Map<String, dynamic>? inventorySummary,
    Map<String, dynamic>? taxSummary,
    Map<String, dynamic>? fiscalSummary,
    SalesReportRangePreset? salesRangePreset,
    SalesBreakdownFilter? salesBreakdownFilter,
    SalesSubReport? salesSubReport,
    DateTime? salesFrom,
    DateTime? salesTo,
    String? fiscalTypeFilter,
    String? productSalesQuery,
    String? productSalesCategoryFilter,
    bool clearFiscalTypeFilter = false,
    bool clearProductSalesCategoryFilter = false,
    bool clearError = false,
    bool clearCategory = false,
  }) {
    return ReportsState(
      selectedCategory: clearCategory
          ? null
          : (selectedCategory ?? this.selectedCategory),
      loading: loading ?? this.loading,
      error: clearError ? null : (error ?? this.error),
      salesSummary: salesSummary ?? this.salesSummary,
      cashSummary: cashSummary ?? this.cashSummary,
      purchasesSummary: purchasesSummary ?? this.purchasesSummary,
      inventorySummary: inventorySummary ?? this.inventorySummary,
      taxSummary: taxSummary ?? this.taxSummary,
      fiscalSummary: fiscalSummary ?? this.fiscalSummary,
      salesRangePreset: salesRangePreset ?? this.salesRangePreset,
      salesBreakdownFilter: salesBreakdownFilter ?? this.salesBreakdownFilter,
      salesSubReport: salesSubReport ?? this.salesSubReport,
      salesFrom: salesFrom ?? this.salesFrom,
      salesTo: salesTo ?? this.salesTo,
      fiscalTypeFilter: clearFiscalTypeFilter
          ? null
          : (fiscalTypeFilter ?? this.fiscalTypeFilter),
      productSalesQuery: productSalesQuery ?? this.productSalesQuery,
      productSalesCategoryFilter: clearProductSalesCategoryFilter
          ? null
          : (productSalesCategoryFilter ?? this.productSalesCategoryFilter),
    );
  }
}

final reportsRepositoryProvider = Provider<ReportsRepository>((ref) {
  return ReportsRepository(Supabase.instance.client);
});

final reportsViewModelProvider =
    StateNotifierProvider<ReportsViewModel, ReportsState>((ref) {
      final reportsRepository = ref.watch(reportsRepositoryProvider);
      return ReportsViewModel(reportsRepository);
    });

class ReportsViewModel extends StateNotifier<ReportsState> {
  final ReportsRepository _repository;

  ReportsViewModel(this._repository) : super(ReportsState.initial()) {
    Future<void>.microtask(load);
  }

  static ({DateTime from, DateTime to}) resolveRange(
    SalesReportRangePreset preset,
  ) {
    final now = AppTime.nowAst();
    final todayStart = DateTime(now.year, now.month, now.day);

    switch (preset) {
      case SalesReportRangePreset.today:
        return (from: todayStart, to: todayStart.add(const Duration(days: 1)));
      case SalesReportRangePreset.yesterday:
        final from = todayStart.subtract(const Duration(days: 1));
        return (from: from, to: todayStart);
      case SalesReportRangePreset.thisWeek:
        final weekdayOffset = now.weekday - DateTime.monday;
        final from = todayStart.subtract(Duration(days: weekdayOffset));
        return (from: from, to: todayStart.add(const Duration(days: 1)));
      case SalesReportRangePreset.thisMonth:
        final from = DateTime(now.year, now.month, 1);
        final to = now.month == 12
            ? DateTime(now.year + 1, 1, 1)
            : DateTime(now.year, now.month + 1, 1);
        return (from: from, to: to);
      case SalesReportRangePreset.custom:
        return (from: todayStart, to: todayStart.add(const Duration(days: 1)));
    }
  }

  Future<void> load() async {
    state = state.copyWith(loading: true, clearError: true);

    try {
      final businessId = await resolveBusinessIdOrNull(
        Supabase.instance.client,
        'auto',
      );

      if (businessId == null) {
        throw Exception('No se pudo resolver el negocio actual');
      }

      final results = await Future.wait([
        _repository.getSalesSummary(
          businessId: businessId,
          from: state.salesFrom,
          to: state.salesTo,
        ),
        _repository.getCashSummary(
          businessId: businessId,
          from: state.salesFrom,
          to: state.salesTo,
        ),
        _repository.getPurchasesSummary(
          businessId: businessId,
          from: state.salesFrom,
          to: state.salesTo,
        ),
        _repository.getInventorySummary(
          businessId: businessId,
          from: state.salesFrom,
          to: state.salesTo,
        ),
        _repository.getTaxSummary(
          businessId: businessId,
          from: state.salesFrom,
          to: state.salesTo,
        ),
        _repository.getFiscalDocumentsSummary(
          businessId: businessId,
          from: state.salesFrom,
          to: state.salesTo,
        ),
      ]);

      state = state.copyWith(
        loading: false,
        salesSummary: results[0],
        cashSummary: results[1],
        purchasesSummary: results[2],
        inventorySummary: results[3],
        taxSummary: results[4],
        fiscalSummary: results[5],
        clearError: true,
      );
    } catch (e) {
      state = state.copyWith(
        loading: false,
        error: 'Error cargando reportes: $e',
      );
    }
  }

  Future<void> setSalesPreset(SalesReportRangePreset preset) async {
    final range = resolveRange(preset);
    state = state.copyWith(
      salesRangePreset: preset,
      salesFrom: range.from,
      salesTo: range.to,
    );
    await load();
  }

  Future<void> setCustomSalesRange(DateTime from, DateTime to) async {
    final start = DateTime(from.year, from.month, from.day);
    final endExclusive = DateTime(
      to.year,
      to.month,
      to.day,
    ).add(const Duration(days: 1));
    state = state.copyWith(
      salesRangePreset: SalesReportRangePreset.custom,
      salesFrom: start,
      salesTo: endExclusive,
    );
    await load();
  }

  void setSalesBreakdownFilter(SalesBreakdownFilter filter) {
    state = state.copyWith(salesBreakdownFilter: filter);
  }

  void setSalesSubReport(SalesSubReport subReport) {
    state = state.copyWith(salesSubReport: subReport);
  }

  String salesSubReportLabel(SalesSubReport sub) {
    switch (sub) {
      case SalesSubReport.overview:
        return 'Vista general';
      case SalesSubReport.byCategory:
        return 'Por categoría';
      case SalesSubReport.byEmployee:
        return 'Por empleado';
      case SalesSubReport.byPayment:
        return 'Por tipo de pago';
      case SalesSubReport.byReceipt:
        return 'Por comprobante';
      case SalesSubReport.byModifiers:
        return 'Modificadores';
      case SalesSubReport.byDiscounts:
        return 'Descuentos y cortesías';
      case SalesSubReport.byProduct:
        return 'Ventas por producto';
      case SalesSubReport.byZone:
        return 'Por zona';
      case SalesSubReport.byHour:
        return 'Por hora';
    }
  }

  void setFiscalTypeFilter(String? type) {
    state = state.copyWith(
      fiscalTypeFilter: type,
      clearFiscalTypeFilter: type == null,
    );
  }

  void setProductSalesQuery(String value) {
    state = state.copyWith(productSalesQuery: value);
  }

  void setProductSalesCategoryFilter(String? category) {
    state = state.copyWith(
      productSalesCategoryFilter: category,
      clearProductSalesCategoryFilter: category == null,
    );
  }

  void clearProductSalesFilters() {
    state = state.copyWith(
      productSalesQuery: '',
      clearProductSalesCategoryFilter: true,
    );
  }

  void selectCategory(ReportCategory? category) {
    if (category == null) {
      state = state.copyWith(clearCategory: true);
    } else {
      state = state.copyWith(selectedCategory: category, clearCategory: false);
    }
  }

  List<ReportItem> getReportsForCategory(ReportCategory category) {
    switch (category) {
      case ReportCategory.sales:
        final total =
            (state.salesSummary?['total_sales'] as num?)?.toDouble() ?? 0;
        final txCount = state.salesSummary?['payments_count'] ?? 0;
        final itemsSold = state.salesSummary?['items_sold'] ?? 0;
        return [
          ReportItem(
            title: 'Ventas por rango',
            description:
                'Total: RD\$${total.toStringAsFixed(2)} | Transacciones: $txCount',
          ),
          ReportItem(
            title: 'Items vendidos',
            description: 'Items cobrados en el rango: $itemsSold',
          ),
        ];
      case ReportCategory.purchases:
        final ordersCount = state.purchasesSummary?['orders_count'] ?? 0;
        final suppliersCount = state.purchasesSummary?['suppliers_count'] ?? 0;
        final totalOrdered =
            (state.purchasesSummary?['total_ordered'] as num?)?.toDouble() ?? 0;
        final totalReceived =
            (state.purchasesSummary?['total_received'] as num?)?.toDouble() ??
            0;
        final receivedCount = state.purchasesSummary?['received_count'] ?? 0;
        final partialCount = state.purchasesSummary?['partial_count'] ?? 0;
        final draftCount = state.purchasesSummary?['draft_count'] ?? 0;
        return [
          ReportItem(
            title: 'Órdenes de compra',
            description:
                'Órdenes: $ordersCount | Total ordenado: RD\$${totalOrdered.toStringAsFixed(2)}',
          ),
          ReportItem(
            title: 'Recepción y proveedores',
            description:
                'Recibidas: $receivedCount | Parciales: $partialCount | Borradores: $draftCount | Proveedores activos: $suppliersCount | Recibido: RD\$${totalReceived.toStringAsFixed(2)}',
          ),
        ];
      case ReportCategory.finances:
        final sessions = state.cashSummary?['sessions_count'] ?? 0;
        final differences =
            (state.cashSummary?['differences_total'] as num?)?.toDouble() ?? 0;
        final inTotal =
            (state.cashSummary?['manual_in_total'] as num?)?.toDouble() ?? 0;
        final outTotal =
            (state.cashSummary?['manual_out_total'] as num?)?.toDouble() ?? 0;
        return [
          ReportItem(
            title: 'Resumen de caja',
            description:
                'Sesiones: $sessions | Diferencia acumulada: RD\$${differences.toStringAsFixed(2)}',
          ),
          ReportItem(
            title: 'Movimientos manuales',
            description:
                'Entradas: RD\$${inTotal.toStringAsFixed(2)} | Salidas: RD\$${outTotal.toStringAsFixed(2)}',
          ),
        ];
      case ReportCategory.inventory:
        final itemsCount = state.inventorySummary?['items_count'] ?? 0;
        final activeItems = state.inventorySummary?['active_items_count'] ?? 0;
        final totalUnits =
            (state.inventorySummary?['total_units'] as num?)?.toDouble() ?? 0;
        final lowStock = state.inventorySummary?['low_stock_count'] ?? 0;
        final outOfStock = state.inventorySummary?['out_of_stock_count'] ?? 0;
        return [
          ReportItem(
            title: 'Estado de inventario',
            description:
                'Items: $itemsCount | Activos: $activeItems | Stock total: ${totalUnits.toStringAsFixed(2)} unidades',
          ),
          ReportItem(
            title: 'Alertas de stock',
            description: 'Bajo mínimo: $lowStock | Agotados: $outOfStock',
          ),
        ];
      case ReportCategory.taxes:
        final totalTax =
            (state.taxSummary?['total_tax_collected'] as num?)?.toDouble() ?? 0;
        final serviceFee =
            (state.taxSummary?['total_service_fee'] as num?)?.toDouble() ?? 0;
        final totalCharges =
            (state.taxSummary?['total_charges_collected'] as num?)
                ?.toDouble() ??
            (totalTax + serviceFee);
        final taxableSales =
            (state.taxSummary?['taxable_sales'] as num?)?.toDouble() ?? 0;
        final configured = state.taxSummary?['configured_taxes_count'] ?? 0;
        final active = state.taxSummary?['active_taxes_count'] ?? 0;
        return [
          ReportItem(
            title: 'Impuestos y ley generados',
            description:
                'Impuestos: RD\$${totalTax.toStringAsFixed(2)} | Propina de ley: RD\$${serviceFee.toStringAsFixed(2)} | Total: RD\$${totalCharges.toStringAsFixed(2)}',
          ),
          ReportItem(
            title: 'Configuración fiscal',
            description:
                'Tipos configurados: $configured | Activos: $active | Base gravable: RD\$${taxableSales.toStringAsFixed(2)}',
          ),
        ];
      case ReportCategory.fiscal:
        final docsCount = state.fiscalSummary?['documents_count'] ?? 0;
        final activeCount = state.fiscalSummary?['active_count'] ?? 0;
        final voidCount = state.fiscalSummary?['void_count'] ?? 0;
        final totalAmount =
            (state.fiscalSummary?['total_amount'] as num?)?.toDouble() ?? 0;
        final totalItbis =
            (state.fiscalSummary?['total_itbis'] as num?)?.toDouble() ?? 0;
        return [
          ReportItem(
            title: 'Comprobantes fiscales',
            description:
                'Documentos: $docsCount | Activos: $activeCount | Anulados: $voidCount',
          ),
          ReportItem(
            title: 'Totales facturados',
            description:
                'Total: RD\$${totalAmount.toStringAsFixed(2)} | ITBIS: RD\$${totalItbis.toStringAsFixed(2)}',
          ),
        ];
    }
  }

  List<SalesMetricCardData> getSalesMetricCards() {
    final summary = state.salesSummary ?? const <String, dynamic>{};
    final totalSales = (summary['total_sales'] as num?)?.toDouble() ?? 0;
    final voidedSales = (summary['voided_sales'] as num?)?.toDouble() ?? 0;
    final netSales = (summary['net_sales'] as num?)?.toDouble() ?? totalSales;
    final paymentsCount = (summary['payments_count'] as num?)?.toInt() ?? 0;
    final itemsSold = (summary['items_sold'] as num?)?.toInt() ?? 0;
    final avgTicket = (summary['avg_ticket'] as num?)?.toDouble() ?? 0;

    return [
      SalesMetricCardData(
        title: 'Ventas netas',
        value: 'RD\$${netSales.toStringAsFixed(2)}',
        subtitle: 'Ventas completadas menos anuladas',
        icon: Icons.payments_outlined,
        color: const Color(0xFF2563EB),
      ),
      SalesMetricCardData(
        title: 'Ventas brutas',
        value: 'RD\$${totalSales.toStringAsFixed(2)}',
        subtitle: '$paymentsCount transacciones cobradas',
        icon: Icons.point_of_sale_outlined,
        color: const Color(0xFFF97316),
      ),
      SalesMetricCardData(
        title: 'Ticket promedio',
        value: 'RD\$${avgTicket.toStringAsFixed(2)}',
        subtitle: 'Promedio por transacción completada',
        icon: Icons.receipt_long_outlined,
        color: const Color(0xFF7C3AED),
      ),
      SalesMetricCardData(
        title: 'Items vendidos',
        value: '$itemsSold',
        subtitle: 'Cantidad total de productos cobrados',
        icon: Icons.inventory_2_outlined,
        color: const Color(0xFF059669),
      ),
      SalesMetricCardData(
        title: 'Ventas anuladas',
        value: 'RD\$${voidedSales.toStringAsFixed(2)}',
        subtitle: 'Montos cancelados o void en el rango',
        icon: Icons.cancel_outlined,
        color: const Color(0xFFDC2626),
      ),
    ];
  }

  List<SalesBreakdownRow> getPaymentMethodRows() {
    final rows = (state.salesSummary?['sales_by_method'] as List?) ?? const [];
    return rows
        .map((row) => Map<String, dynamic>.from(row as Map))
        .map(
          (row) => SalesBreakdownRow(
            label: row['label']?.toString() ?? 'Sin método',
            amount: (row['amount'] as num?)?.toDouble() ?? 0,
            count: (row['count'] as num?)?.toInt() ?? 0,
          ),
        )
        .toList(growable: false);
  }

  List<SalesBreakdownRow> getHourlyRows() {
    final rows = (state.salesSummary?['sales_by_hour'] as List?) ?? const [];
    return rows
        .map((row) => Map<String, dynamic>.from(row as Map))
        .map(
          (row) => SalesBreakdownRow(
            label: row['label']?.toString() ?? '--',
            amount: (row['amount'] as num?)?.toDouble() ?? 0,
            count: (row['count'] as num?)?.toInt() ?? 0,
          ),
        )
        .toList(growable: false);
  }

  List<SalesBreakdownRow> getTopProductRows() {
    final rows = (state.salesSummary?['top_products'] as List?) ?? const [];
    return rows
        .map((row) => Map<String, dynamic>.from(row as Map))
        .map(
          (row) => SalesBreakdownRow(
            label: row['label']?.toString() ?? 'Producto',
            amount: (row['amount'] as num?)?.toDouble() ?? 0,
            quantity: (row['quantity'] as num?)?.toDouble() ?? 0,
            count: (row['count'] as num?)?.toInt() ?? 0,
          ),
        )
        .toList(growable: false);
  }

  List<ProductSalesReportRow> getProductSalesRows() {
    final rows = (state.salesSummary?['product_sales'] as List?) ?? const [];
    return rows
        .map((row) => Map<String, dynamic>.from(row as Map))
        .map(
          (row) => ProductSalesReportRow(
            product: row['product']?.toString() ?? 'Producto',
            category: row['category']?.toString() ?? 'Sin categoría',
            quantitySold: (row['quantity_sold'] as num?)?.toDouble() ?? 0,
            grossSales: (row['gross_sales'] as num?)?.toDouble() ?? 0,
            discounts: (row['discounts'] as num?)?.toDouble() ?? 0,
            courtesies: (row['courtesies'] as num?)?.toDouble() ?? 0,
            netSales: (row['net_sales'] as num?)?.toDouble() ?? 0,
            cost: (row['cost'] as num?)?.toDouble() ?? 0,
            grossProfit: (row['gross_profit'] as num?)?.toDouble() ?? 0,
            tickets: (row['tickets'] as num?)?.toInt() ?? 0,
          ),
        )
        .toList(growable: false);
  }

  List<String> getAvailableProductSalesCategories() {
    final categories = <String>{};
    for (final row in getProductSalesRows()) {
      final category = row.category.trim();
      if (category.isNotEmpty) {
        categories.add(category);
      }
    }
    final ordered = categories.toList(growable: false)..sort();
    return ordered;
  }

  List<ProductSalesReportRow> getFilteredProductSalesRows() {
    final query = state.productSalesQuery.trim().toLowerCase();
    final selectedCategory = state.productSalesCategoryFilter;
    return getProductSalesRows().where((row) {
      final matchesCategory =
          selectedCategory == null || row.category == selectedCategory;
      if (!matchesCategory) return false;
      if (query.isEmpty) return true;
      return row.product.toLowerCase().contains(query) ||
          row.category.toLowerCase().contains(query);
    }).toList(growable: false);
  }

  List<SalesBreakdownRow> getCategoryRows() {
    final rows =
        (state.salesSummary?['sales_by_category'] as List?) ?? const [];
    return rows
        .map((row) => Map<String, dynamic>.from(row as Map))
        .map(
          (row) => SalesBreakdownRow(
            label: row['label']?.toString() ?? 'Sin categoría',
            amount: (row['amount'] as num?)?.toDouble() ?? 0,
            quantity: (row['quantity'] as num?)?.toDouble() ?? 0,
            count: (row['count'] as num?)?.toInt() ?? 0,
          ),
        )
        .toList(growable: false);
  }

  List<SalesBreakdownRow> getEmployeeRows() {
    final rows =
        (state.salesSummary?['sales_by_employee'] as List?) ?? const [];
    return rows
        .map((row) => Map<String, dynamic>.from(row as Map))
        .map(
          (row) => SalesBreakdownRow(
            label: row['label']?.toString() ?? 'Sin empleado',
            amount: (row['amount'] as num?)?.toDouble() ?? 0,
            count: (row['count'] as num?)?.toInt() ?? 0,
          ),
        )
        .toList(growable: false);
  }

  List<SalesBreakdownRow> getZoneRows() {
    final rows = (state.salesSummary?['sales_by_zone'] as List?) ?? const [];
    return rows
        .map((row) => Map<String, dynamic>.from(row as Map))
        .map(
          (row) => SalesBreakdownRow(
            label: row['label']?.toString() ?? 'Sin zona',
            amount: (row['amount'] as num?)?.toDouble() ?? 0,
            count: (row['count'] as num?)?.toInt() ?? 0,
          ),
        )
        .toList(growable: false);
  }

  List<SalesBreakdownRow> getReceiptRows() {
    final rows = (state.salesSummary?['sales_by_receipt'] as List?) ?? const [];
    return rows
        .map((row) => Map<String, dynamic>.from(row as Map))
        .map(
          (row) => SalesBreakdownRow(
            label: row['label']?.toString() ?? 'Recibo',
            amount: (row['amount'] as num?)?.toDouble() ?? 0,
            count: (row['count'] as num?)?.toInt() ?? 0,
          ),
        )
        .toList(growable: false);
  }

  List<SalesBreakdownRow> getModifierRows() {
    final rows =
        (state.salesSummary?['sales_by_modifier'] as List?) ?? const [];
    return rows
        .map((row) => Map<String, dynamic>.from(row as Map))
        .map(
          (row) => SalesBreakdownRow(
            label: row['label']?.toString() ?? 'Modificador',
            amount: (row['amount'] as num?)?.toDouble() ?? 0,
            quantity: (row['quantity'] as num?)?.toDouble() ?? 0,
            count: (row['count'] as num?)?.toInt() ?? 0,
          ),
        )
        .toList(growable: false);
  }

  List<SalesBreakdownRow> getDiscountRows() {
    final rows =
        (state.salesSummary?['sales_by_adjustment'] as List?) ?? const [];
    return rows
        .map((row) => Map<String, dynamic>.from(row as Map))
        .map(
          (row) => SalesBreakdownRow(
            label: row['label']?.toString() ?? 'Ajuste',
            amount: (row['amount'] as num?)?.toDouble() ?? 0,
            quantity: (row['quantity'] as num?)?.toDouble() ?? 0,
            count: (row['count'] as num?)?.toInt() ?? 0,
          ),
        )
        .toList(growable: false);
  }

  String breakdownFilterLabel(SalesBreakdownFilter filter) {
    switch (filter) {
      case SalesBreakdownFilter.paymentMethod:
        return 'Método de pago';
      case SalesBreakdownFilter.product:
        return 'Productos';
      case SalesBreakdownFilter.category:
        return 'Categorías';
      case SalesBreakdownFilter.employee:
        return 'Empleados';
      case SalesBreakdownFilter.zone:
        return 'Zonas';
      case SalesBreakdownFilter.hourly:
        return 'Por hora';
    }
  }

  List<SalesMetricCardData> getFinanceMetricCards() {
    final summary = state.cashSummary ?? const <String, dynamic>{};
    final sessions = (summary['sessions_count'] as num?)?.toInt() ?? 0;
    final netCashFlow = (summary['net_cash_flow'] as num?)?.toDouble() ?? 0;
    final salesTotal = (summary['sales_total'] as num?)?.toDouble() ?? 0;
    final manualIn = (summary['manual_in_total'] as num?)?.toDouble() ?? 0;
    final manualOut = (summary['manual_out_total'] as num?)?.toDouble() ?? 0;
    final differences = (summary['differences_total'] as num?)?.toDouble() ?? 0;
    final avgDifference =
        (summary['average_difference'] as num?)?.toDouble() ?? 0;

    return [
      SalesMetricCardData(
        title: 'Flujo neto de caja',
        value: 'RD\$${netCashFlow.toStringAsFixed(2)}',
        subtitle: 'Ventas + entradas manuales - salidas manuales',
        icon: Icons.account_balance_wallet_outlined,
        color: const Color(0xFF2563EB),
      ),
      SalesMetricCardData(
        title: 'Ventas en caja',
        value: 'RD\$${salesTotal.toStringAsFixed(2)}',
        subtitle: '$sessions sesiones en el rango',
        icon: Icons.point_of_sale_outlined,
        color: const Color(0xFFF97316),
      ),
      SalesMetricCardData(
        title: 'Entradas manuales',
        value: 'RD\$${manualIn.toStringAsFixed(2)}',
        subtitle: 'Depósitos e ingresos de caja',
        icon: Icons.south_west_outlined,
        color: const Color(0xFF059669),
      ),
      SalesMetricCardData(
        title: 'Salidas manuales',
        value: 'RD\$${manualOut.toStringAsFixed(2)}',
        subtitle: 'Retiros y gastos registrados',
        icon: Icons.north_east_outlined,
        color: const Color(0xFFDC2626),
      ),
      SalesMetricCardData(
        title: 'Diferencia acumulada',
        value: 'RD\$${differences.toStringAsFixed(2)}',
        subtitle:
            'Promedio por sesión: RD\$${avgDifference.toStringAsFixed(2)}',
        icon: Icons.balance_outlined,
        color: const Color(0xFF7C3AED),
      ),
    ];
  }

  List<SalesBreakdownRow> getFinanceTypeRows() {
    final rows =
        (state.cashSummary?['transactions_by_type'] as List?) ?? const [];
    return rows
        .map((row) => Map<String, dynamic>.from(row as Map))
        .map(
          (row) => SalesBreakdownRow(
            label: row['label']?.toString() ?? 'Movimiento',
            amount: (row['amount'] as num?)?.toDouble() ?? 0,
            count: (row['count'] as num?)?.toInt() ?? 0,
          ),
        )
        .toList(growable: false);
  }

  List<SalesBreakdownRow> getFinanceSessionRows() {
    final summary = state.cashSummary ?? const <String, dynamic>{};
    return [
      SalesBreakdownRow(
        label: 'Sesiones abiertas',
        amount: 0,
        count: (summary['open_sessions_count'] as num?)?.toInt() ?? 0,
      ),
      SalesBreakdownRow(
        label: 'Sesiones cerradas',
        amount: 0,
        count: (summary['closed_sessions_count'] as num?)?.toInt() ?? 0,
      ),
      SalesBreakdownRow(
        label: 'Monto de aperturas',
        amount: (summary['openings_total'] as num?)?.toDouble() ?? 0,
      ),
      SalesBreakdownRow(
        label: 'Monto de cierres',
        amount: (summary['closings_total'] as num?)?.toDouble() ?? 0,
      ),
    ];
  }

  List<SalesMetricCardData> getInventoryMetricCards() {
    final summary = state.inventorySummary ?? const <String, dynamic>{};
    final itemsCount = (summary['items_count'] as num?)?.toInt() ?? 0;
    final activeItems = (summary['active_items_count'] as num?)?.toInt() ?? 0;
    final totalUnits = (summary['total_units'] as num?)?.toDouble() ?? 0;
    final stockValue = (summary['total_stock_value'] as num?)?.toDouble() ?? 0;
    final lowStock = (summary['low_stock_count'] as num?)?.toInt() ?? 0;
    final outOfStock = (summary['out_of_stock_count'] as num?)?.toInt() ?? 0;

    return [
      SalesMetricCardData(
        title: 'Insumos registrados',
        value: '$itemsCount',
        subtitle: '$activeItems activos actualmente',
        icon: Icons.inventory_2_outlined,
        color: const Color(0xFF2563EB),
      ),
      SalesMetricCardData(
        title: 'Unidades en stock',
        value: totalUnits.toStringAsFixed(2),
        subtitle: 'Suma consolidada en almacenes',
        icon: Icons.stacked_bar_chart_outlined,
        color: const Color(0xFFF97316),
      ),
      SalesMetricCardData(
        title: 'Valor del stock',
        value: 'RD\$${stockValue.toStringAsFixed(2)}',
        subtitle: 'Calculado por costo registrado',
        icon: Icons.paid_outlined,
        color: const Color(0xFF059669),
      ),
      SalesMetricCardData(
        title: 'Bajo mínimo',
        value: '$lowStock',
        subtitle: 'Insumos con stock crítico',
        icon: Icons.warning_amber_outlined,
        color: const Color(0xFFD97706),
      ),
      SalesMetricCardData(
        title: 'Agotados',
        value: '$outOfStock',
        subtitle: 'Insumos sin existencia',
        icon: Icons.remove_shopping_cart_outlined,
        color: const Color(0xFFDC2626),
      ),
    ];
  }

  List<SalesBreakdownRow> getInventoryTopStockRows() {
    final rows =
        (state.inventorySummary?['top_stock_items'] as List?) ?? const [];
    return rows
        .map((row) => Map<String, dynamic>.from(row as Map))
        .map(
          (row) => SalesBreakdownRow(
            label: row['label']?.toString() ?? 'Insumo',
            amount: (row['amount'] as num?)?.toDouble() ?? 0,
            quantity: (row['quantity'] as num?)?.toDouble() ?? 0,
            count: (row['count'] as num?)?.toInt() ?? 0,
          ),
        )
        .toList(growable: false);
  }

  List<SalesBreakdownRow> getInventoryAlertRows() {
    final rows = (state.inventorySummary?['alert_items'] as List?) ?? const [];
    return rows
        .map((row) => Map<String, dynamic>.from(row as Map))
        .map(
          (row) => SalesBreakdownRow(
            label: row['label']?.toString() ?? 'Insumo',
            amount: (row['amount'] as num?)?.toDouble() ?? 0,
            quantity: (row['quantity'] as num?)?.toDouble() ?? 0,
            count: (row['count'] as num?)?.toInt() ?? 0,
          ),
        )
        .toList(growable: false);
  }

  List<SalesBreakdownRow> getInventoryMovementRows() {
    final rows =
        (state.inventorySummary?['movement_summary'] as List?) ?? const [];
    return rows
        .map((row) => Map<String, dynamic>.from(row as Map))
        .map(
          (row) => SalesBreakdownRow(
            label: row['label']?.toString() ?? 'Movimiento',
            amount: (row['amount'] as num?)?.toDouble() ?? 0,
            count: (row['count'] as num?)?.toInt() ?? 0,
          ),
        )
        .toList(growable: false);
  }

  List<SalesMetricCardData> getPurchaseMetricCards() {
    final summary = state.purchasesSummary ?? const <String, dynamic>{};
    final ordersCount = (summary['orders_count'] as num?)?.toInt() ?? 0;
    final suppliersCount = (summary['suppliers_count'] as num?)?.toInt() ?? 0;
    final suppliersWithOrders =
        (summary['suppliers_with_orders_count'] as num?)?.toInt() ?? 0;
    final totalOrdered = (summary['total_ordered'] as num?)?.toDouble() ?? 0;
    final totalReceived = (summary['total_received'] as num?)?.toDouble() ?? 0;
    final avgOrder = (summary['avg_order_total'] as num?)?.toDouble() ?? 0;
    final partialCount = (summary['partial_count'] as num?)?.toInt() ?? 0;

    return [
      SalesMetricCardData(
        title: 'Órdenes registradas',
        value: '$ordersCount',
        subtitle: '$suppliersWithOrders proveedores con órdenes',
        icon: Icons.shopping_cart_outlined,
        color: const Color(0xFF2563EB),
      ),
      SalesMetricCardData(
        title: 'Monto ordenado',
        value: 'RD\$${totalOrdered.toStringAsFixed(2)}',
        subtitle: 'Total emitido en el rango',
        icon: Icons.request_quote_outlined,
        color: const Color(0xFFF97316),
      ),
      SalesMetricCardData(
        title: 'Monto recibido',
        value: 'RD\$${totalReceived.toStringAsFixed(2)}',
        subtitle: 'Órdenes completamente recibidas',
        icon: Icons.inventory_outlined,
        color: const Color(0xFF059669),
      ),
      SalesMetricCardData(
        title: 'Promedio por orden',
        value: 'RD\$${avgOrder.toStringAsFixed(2)}',
        subtitle: '$suppliersCount proveedores activos',
        icon: Icons.receipt_long_outlined,
        color: const Color(0xFF7C3AED),
      ),
      SalesMetricCardData(
        title: 'Recepciones parciales',
        value: '$partialCount',
        subtitle: 'Órdenes pendientes por completar',
        icon: Icons.timelapse_outlined,
        color: const Color(0xFFD97706),
      ),
    ];
  }

  List<SalesBreakdownRow> getPurchaseStatusRows() {
    final rows =
        (state.purchasesSummary?['status_breakdown'] as List?) ?? const [];
    return rows
        .map((row) => Map<String, dynamic>.from(row as Map))
        .map(
          (row) => SalesBreakdownRow(
            label: row['label']?.toString() ?? 'Estado',
            amount: (row['amount'] as num?)?.toDouble() ?? 0,
            count: (row['count'] as num?)?.toInt() ?? 0,
          ),
        )
        .toList(growable: false);
  }

  List<SalesBreakdownRow> getPurchaseSupplierRows() {
    final rows =
        (state.purchasesSummary?['top_suppliers'] as List?) ?? const [];
    return rows
        .map((row) => Map<String, dynamic>.from(row as Map))
        .map(
          (row) => SalesBreakdownRow(
            label: row['label']?.toString() ?? 'Proveedor',
            amount: (row['amount'] as num?)?.toDouble() ?? 0,
            count: (row['count'] as num?)?.toInt() ?? 0,
          ),
        )
        .toList(growable: false);
  }

  List<SalesMetricCardData> getTaxMetricCards() {
    final summary = state.taxSummary ?? const <String, dynamic>{};
    final totalTax = (summary['total_tax_collected'] as num?)?.toDouble() ?? 0;
    final totalServiceFee =
        (summary['total_service_fee'] as num?)?.toDouble() ?? 0;
    final totalCharges =
        (summary['total_charges_collected'] as num?)?.toDouble() ??
        (totalTax + totalServiceFee);
    final taxableSales = (summary['taxable_sales'] as num?)?.toDouble() ?? 0;
    final exemptSales = (summary['exempt_sales'] as num?)?.toDouble() ?? 0;
    final effectiveRate =
        (summary['effective_tax_rate'] as num?)?.toDouble() ?? 0;
    final configured =
        (summary['configured_taxes_count'] as num?)?.toInt() ?? 0;
    final active = (summary['active_taxes_count'] as num?)?.toInt() ?? 0;
    final serviceFeeOrders =
        (summary['service_fee_orders_count'] as num?)?.toInt() ?? 0;
    final serviceFeeRate =
        (summary['service_fee_rate'] as num?)?.toDouble() ?? 0;

    return [
      SalesMetricCardData(
        title: 'Impuestos cobrados',
        value: 'RD\$${totalTax.toStringAsFixed(2)}',
        subtitle: 'Total acumulado en el rango seleccionado',
        icon: Icons.receipt_outlined,
        color: const Color(0xFF2563EB),
      ),
      SalesMetricCardData(
        title: 'Propina de ley',
        value: 'RD\$${totalServiceFee.toStringAsFixed(2)}',
        subtitle: serviceFeeOrders > 0
            ? '$serviceFeeOrders cuentas con cargo legal'
            : 'Sin cargos de ley en el rango',
        icon: Icons.room_service_outlined,
        color: const Color(0xFFF97316),
      ),
      SalesMetricCardData(
        title: 'Total fiscal y ley',
        value: 'RD\$${totalCharges.toStringAsFixed(2)}',
        subtitle: 'Suma de impuestos + propina de ley',
        icon: Icons.account_balance_wallet_outlined,
        color: const Color(0xFF059669),
      ),
      SalesMetricCardData(
        title: 'Ventas gravadas',
        value: 'RD\$${taxableSales.toStringAsFixed(2)}',
        subtitle: 'Base imponible sujeta a impuestos',
        icon: Icons.sell_outlined,
        color: const Color(0xFF7C3AED),
      ),
      SalesMetricCardData(
        title: 'Ventas exentas',
        value: 'RD\$${exemptSales.toStringAsFixed(2)}',
        subtitle: 'Items sin impuesto en el rango',
        icon: Icons.remove_circle_outline,
        color: const Color(0xFF0F766E),
      ),
      SalesMetricCardData(
        title: 'Tasa efectiva ITBIS',
        value: '${effectiveRate.toStringAsFixed(2)}%',
        subtitle: serviceFeeRate > 0
            ? 'Propina de ley configurada: ${serviceFeeRate == serviceFeeRate.truncateToDouble() ? serviceFeeRate.toInt() : serviceFeeRate.toStringAsFixed(2)}%'
            : 'Sin propina de ley configurada',
        icon: Icons.percent_outlined,
        color: const Color(0xFF6D28D9),
      ),
      SalesMetricCardData(
        title: 'Tipos de impuesto',
        value: '$active/$configured',
        subtitle: 'Activos frente a configurados',
        icon: Icons.account_balance_outlined,
        color: const Color(0xFFD97706),
      ),
    ];
  }

  List<SalesBreakdownRow> getTaxTypeRows() {
    final rows = (state.taxSummary?['tax_breakdown'] as List?) ?? const [];
    return rows
        .map((row) => Map<String, dynamic>.from(row as Map))
        .map(
          (row) => SalesBreakdownRow(
            label: _formatTaxRowLabel(row),
            amount: (row['amount'] as num?)?.toDouble() ?? 0,
            quantity: (row['taxable_amount'] as num?)?.toDouble() ?? 0,
            count: (row['count'] as num?)?.toInt() ?? 0,
          ),
        )
        .toList(growable: false);
  }

  String _formatTaxRowLabel(Map<String, dynamic> row) {
    final label = row['label']?.toString().trim();
    final safeLabel = (label?.isNotEmpty ?? false) ? label! : 'Impuesto';
    final rate = (row['rate'] as num?)?.toDouble() ?? 0;
    if (rate <= 0) return safeLabel;
    final rateStr = rate == rate.truncateToDouble()
        ? rate.toInt().toString()
        : rate.toStringAsFixed(2);
    return '$safeLabel ($rateStr%)';
  }

  // --- Fiscal (comprobantes) helpers ---

  List<SalesMetricCardData> getFiscalMetricCards() {
    final summary = state.fiscalSummary ?? const <String, dynamic>{};
    final docsCount = (summary['documents_count'] as num?)?.toInt() ?? 0;
    final activeCount = (summary['active_count'] as num?)?.toInt() ?? 0;
    final voidCount = (summary['void_count'] as num?)?.toInt() ?? 0;
    final totalSubtotal = (summary['total_subtotal'] as num?)?.toDouble() ?? 0;
    final totalItbis = (summary['total_itbis'] as num?)?.toDouble() ?? 0;
    final totalAmount = (summary['total_amount'] as num?)?.toDouble() ?? 0;
    final totalServiceFee =
        (summary['total_service_fee'] as num?)?.toDouble() ?? 0;

    return [
      SalesMetricCardData(
        title: 'Total facturado',
        value: 'RD\$${totalAmount.toStringAsFixed(2)}',
        subtitle: '$docsCount comprobantes emitidos',
        icon: Icons.receipt_long_outlined,
        color: const Color(0xFF2563EB),
      ),
      SalesMetricCardData(
        title: 'Subtotal',
        value: 'RD\$${totalSubtotal.toStringAsFixed(2)}',
        subtitle: 'Monto antes de impuestos',
        icon: Icons.attach_money_outlined,
        color: const Color(0xFFF97316),
      ),
      SalesMetricCardData(
        title: 'ITBIS cobrado',
        value: 'RD\$${totalItbis.toStringAsFixed(2)}',
        subtitle: 'Total ITBIS en comprobantes activos',
        icon: Icons.account_balance_outlined,
        color: const Color(0xFF059669),
      ),
      if (totalServiceFee > 0)
        SalesMetricCardData(
          title: 'Propina de ley',
          value: 'RD\$${totalServiceFee.toStringAsFixed(2)}',
          subtitle: 'Total propina de ley en el rango',
          icon: Icons.room_service_outlined,
          color: const Color(0xFFD97706),
        ),
      SalesMetricCardData(
        title: 'Comprobantes activos',
        value: '$activeCount',
        subtitle: 'Documentos válidos en el rango',
        icon: Icons.check_circle_outline,
        color: const Color(0xFF7C3AED),
      ),
      SalesMetricCardData(
        title: 'Comprobantes anulados',
        value: '$voidCount',
        subtitle: 'Documentos anulados en el rango',
        icon: Icons.cancel_outlined,
        color: const Color(0xFFDC2626),
      ),
    ];
  }

  List<SalesBreakdownRow> getFiscalTypeRows() {
    final rows = (state.fiscalSummary?['by_type'] as List?) ?? const [];
    return rows
        .map((row) => Map<String, dynamic>.from(row as Map))
        .map(
          (row) => SalesBreakdownRow(
            label: row['label']?.toString() ?? 'Tipo',
            amount: (row['amount'] as num?)?.toDouble() ?? 0,
            count: (row['count'] as num?)?.toInt() ?? 0,
          ),
        )
        .toList(growable: false);
  }

  /// Desglose de impuestos individuales en los comprobantes fiscales
  /// (ITBIS, propina de ley, y cualquier otro impuesto configurado).
  List<SalesBreakdownRow> getFiscalTaxBreakdownRows() {
    final rows = (state.fiscalSummary?['tax_breakdown'] as List?) ?? const [];
    return rows
        .map((row) => Map<String, dynamic>.from(row as Map))
        .map((row) {
          final label = row['label']?.toString() ?? 'Impuesto';
          final rate = (row['rate'] as num?)?.toDouble() ?? 0;
          final displayLabel = rate > 0
              ? '$label (${rate.toStringAsFixed(rate.truncateToDouble() == rate ? 0 : 2)}%)'
              : label;
          return SalesBreakdownRow(
            label: displayLabel,
            amount: (row['tax_amount'] as num?)?.toDouble() ?? 0,
            quantity: (row['base'] as num?)?.toDouble() ?? 0,
            count: (row['count'] as num?)?.toInt() ?? 0,
          );
        })
        .toList(growable: false);
  }

  List<Map<String, dynamic>> getFiscalDocuments() {
    final docs = (state.fiscalSummary?['documents'] as List?) ?? const [];
    return docs
        .map((d) => Map<String, dynamic>.from(d as Map))
        .toList(growable: false);
  }

  List<Map<String, dynamic>> getFilteredFiscalDocuments() {
    final selectedType = state.fiscalTypeFilter;
    final documents = getFiscalDocuments();
    if (selectedType == null || selectedType.isEmpty) return documents;
    return documents
        .where((doc) => doc['ncf_type']?.toString() == selectedType)
        .toList(growable: false);
  }

  List<String> getAvailableFiscalTypes() {
    final seen = <String>{};
    final ordered = <String>[];
    for (final doc in getFiscalDocuments()) {
      final type = doc['ncf_type']?.toString().trim();
      if (type == null || type.isEmpty || !seen.add(type)) continue;
      ordered.add(type);
    }
    return ordered;
  }

  List<Map<String, dynamic>> getCashClosureDetails() {
    final rows = (state.cashSummary?['cash_closures'] as List?) ?? const [];
    return rows
        .map((row) => Map<String, dynamic>.from(row as Map))
        .toList(growable: false);
  }

  String getCategoryTitle(ReportCategory category) {
    switch (category) {
      case ReportCategory.sales:
        return 'Informe de ventas';
      case ReportCategory.purchases:
        return 'Informe de compras';
      case ReportCategory.finances:
        return 'Informe de finanzas';
      case ReportCategory.inventory:
        return 'Informe de inventario';
      case ReportCategory.taxes:
        return 'Reporte de impuestos';
      case ReportCategory.fiscal:
        return 'Comprobantes fiscales';
    }
  }

  IconData getCategoryIcon(ReportCategory category) {
    switch (category) {
      case ReportCategory.sales:
        return Icons.point_of_sale;
      case ReportCategory.purchases:
        return Icons.shopping_cart;
      case ReportCategory.finances:
        return Icons.attach_money;
      case ReportCategory.inventory:
        return Icons.inventory_2;
      case ReportCategory.taxes:
        return Icons.receipt_long;
      case ReportCategory.fiscal:
        return Icons.description_outlined;
    }
  }
}
