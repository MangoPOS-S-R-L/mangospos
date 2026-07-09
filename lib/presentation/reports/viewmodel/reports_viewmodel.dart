import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/currency/business_currency.dart';
import '../../../core/currency/business_currency_provider.dart';
import '../../../core/utils/app_time.dart';
import '../../../data/repositories/reports_repository.dart';
import '../../../data/utils/business_id_resolver.dart';

enum ReportCategory { sales, offers, purchases, finances, inventory, taxes, fiscal }

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
  byProductionArea,
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

/// Filtro de tipo en el reporte de ofertas: todas, solo combos/ofertas de tile
/// (`[DEAL:]`) o solo promociones automáticas (`[PROMO_AUTO:]`).
enum OfferTypeFilter { all, deal, promo }

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
  final String productId;
  final String product;
  final String category;
  final double quantitySold;
  final double projectedQuantity;
  final double grossSales;
  final double discounts;
  final double courtesies;
  final double netSales;
  final double cost;
  final double grossProfit;
  // RF-R1: margen % = utilidad / venta neta × 100. Null cuando net_sales <= 0.
  final double? marginPct;
  final int tickets;

  const ProductSalesReportRow({
    required this.productId,
    required this.product,
    required this.category,
    required this.quantitySold,
    required this.projectedQuantity,
    required this.grossSales,
    required this.discounts,
    required this.courtesies,
    required this.netSales,
    required this.cost,
    required this.grossProfit,
    this.marginPct,
    required this.tickets,
  });
}

/// Una fila del listado detallado de ofertas (una por cada vez que se aplicó
/// una oferta a una línea): Fecha · Oferta · Producto · Cantidad · Monto.
class OfferDetailLine {
  /// Fecha/hora local (AST) en que se registró la línea; null si no se pudo
  /// parsear el timestamp del servidor.
  final DateTime? dateTime;
  final String offerName;
  final String productName;
  final double quantity;

  /// Valor a precio de menú de la línea = cantidad × precio unitario.
  final double valorMenu;

  /// Descuento otorgado por la oferta en la línea (lo que se regaló).
  final double descuento;

  /// True si la línea es un combo/oferta vendida desde el tile (`[DEAL:]`);
  /// false si es una promoción automática (`[PROMO_AUTO:]`).
  final bool isDeal;

  const OfferDetailLine({
    required this.dateTime,
    required this.offerName,
    required this.productName,
    required this.quantity,
    required this.valorMenu,
    required this.descuento,
    required this.isDeal,
  });
}

/// Cantidad total despachada de un producto en oferta (pivote del listado).
class OfferProductTotal {
  final String productName;
  final double quantity;

  const OfferProductTotal({
    required this.productName,
    required this.quantity,
  });
}

class ReportsState {
  final ReportCategory? selectedCategory;
  final bool loading;
  final String? error;
  final Map<String, dynamic>? salesSummary;
  final Map<String, dynamic>? offersSummary;
  final Map<String, dynamic>? cashSummary;
  final Map<String, dynamic>? purchasesSummary;
  final Map<String, dynamic>? inventorySummary;
  final Map<String, dynamic>? taxSummary;
  final Map<String, dynamic>? fiscalSummary;
  final Map<String, double>? productProjection;
  final SalesReportRangePreset salesRangePreset;
  final SalesBreakdownFilter salesBreakdownFilter;
  final SalesSubReport salesSubReport;
  final DateTime salesFrom;
  final DateTime salesTo;
  final String? fiscalTypeFilter;
  final String productSalesQuery;
  final String? productSalesCategoryFilter;

  // Filtros del reporte de ofertas (null/all/'' = sin filtrar).
  final String? offerOfferFilter;
  final String? offerProductFilter;
  final OfferTypeFilter offerTypeFilter;
  final String offerSearchQuery;

  /// Moneda del negocio activo. Single source of truth para formateo de
  /// montos en todos los reportes — elimina el hardcoded `RD$` que vivía
  /// repartido en 10 archivos. Default DOP mientras carga.
  final BusinessCurrency currency;

  const ReportsState({
    this.selectedCategory,
    this.loading = false,
    this.error,
    this.salesSummary,
    this.offersSummary,
    this.cashSummary,
    this.purchasesSummary,
    this.inventorySummary,
    this.taxSummary,
    this.fiscalSummary,
    this.productProjection,
    this.salesRangePreset = SalesReportRangePreset.thisWeek,
    this.salesBreakdownFilter = SalesBreakdownFilter.paymentMethod,
    this.salesSubReport = SalesSubReport.overview,
    required this.salesFrom,
    required this.salesTo,
    this.fiscalTypeFilter,
    this.productSalesQuery = '',
    this.productSalesCategoryFilter,
    this.offerOfferFilter,
    this.offerProductFilter,
    this.offerTypeFilter = OfferTypeFilter.all,
    this.offerSearchQuery = '',
    this.currency = BusinessCurrency.fallbackDop,
  });

  factory ReportsState.initial() {
    final range = ReportsViewModel.resolveRange(
      SalesReportRangePreset.today,
    );
    return ReportsState(
      salesRangePreset: SalesReportRangePreset.today,
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
    Map<String, dynamic>? offersSummary,
    Map<String, dynamic>? cashSummary,
    Map<String, dynamic>? purchasesSummary,
    Map<String, dynamic>? inventorySummary,
    Map<String, dynamic>? taxSummary,
    Map<String, dynamic>? fiscalSummary,
    Map<String, double>? productProjection,
    SalesReportRangePreset? salesRangePreset,
    SalesBreakdownFilter? salesBreakdownFilter,
    SalesSubReport? salesSubReport,
    DateTime? salesFrom,
    DateTime? salesTo,
    String? fiscalTypeFilter,
    String? productSalesQuery,
    String? productSalesCategoryFilter,
    String? offerOfferFilter,
    String? offerProductFilter,
    OfferTypeFilter? offerTypeFilter,
    String? offerSearchQuery,
    BusinessCurrency? currency,
    bool clearFiscalTypeFilter = false,
    bool clearProductSalesCategoryFilter = false,
    bool clearOfferOfferFilter = false,
    bool clearOfferProductFilter = false,
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
      offersSummary: offersSummary ?? this.offersSummary,
      cashSummary: cashSummary ?? this.cashSummary,
      purchasesSummary: purchasesSummary ?? this.purchasesSummary,
      inventorySummary: inventorySummary ?? this.inventorySummary,
      taxSummary: taxSummary ?? this.taxSummary,
      fiscalSummary: fiscalSummary ?? this.fiscalSummary,
      productProjection: productProjection ?? this.productProjection,
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
      offerOfferFilter: clearOfferOfferFilter
          ? null
          : (offerOfferFilter ?? this.offerOfferFilter),
      offerProductFilter: clearOfferProductFilter
          ? null
          : (offerProductFilter ?? this.offerProductFilter),
      offerTypeFilter: offerTypeFilter ?? this.offerTypeFilter,
      offerSearchQuery: offerSearchQuery ?? this.offerSearchQuery,
      currency: currency ?? this.currency,
    );
  }
}

final reportsRepositoryProvider = Provider<ReportsRepository>((ref) {
  return ReportsRepository(Supabase.instance.client);
});

final reportsViewModelProvider =
    StateNotifierProvider<ReportsViewModel, ReportsState>((ref) {
      final reportsRepository = ref.watch(reportsRepositoryProvider);
      return ReportsViewModel(reportsRepository, ref);
    });

class ReportsViewModel extends StateNotifier<ReportsState> {
  final ReportsRepository _repository;
  final Ref _ref;

  // Cada loadCategory/loadHubSummary incrementa este token. Si un load
  // viejo termina después de uno nuevo (race), su token ya no coincide
  // con `_loadToken` y descarta su escritura — así el último click gana
  // siempre, incluso si la app entró con un load en vuelo.
  int _loadToken = 0;

  ReportsViewModel(this._repository, this._ref) : super(ReportsState.initial());

  /// Refresca [ReportsState.currency] desde el provider global. Se llama
  /// dentro de cada load para que si el owner cambió de moneda en Settings,
  /// el próximo render del reporte ya muestre el símbolo correcto. Es
  /// barato: el provider tiene cache por business_id.
  void _syncCurrency() {
    final fresh = currentBusinessCurrencyOrFallbackRef(_ref);
    if (fresh != state.currency) {
      state = state.copyWith(currency: fresh);
    }
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
        // "Este mes" = del 1ro al CIERRE DE HOY (no al fin de mes futuro).
        // Antes incluía días futuros que llenaban el header con "01/05 -
        // 31/05" cuando estabas recién en el día 15, además de ser
        // inconsistente con "Esta semana" que sí va hasta hoy.
        final from = DateTime(now.year, now.month, 1);
        return (from: from, to: todayStart.add(const Duration(days: 1)));
      case SalesReportRangePreset.custom:
        return (from: todayStart, to: todayStart.add(const Duration(days: 1)));
    }
  }

  // Re-resolvemos el rango si el preset es relativo (today, yesterday,
  // thisWeek, thisMonth). Sin esto, abrir la app un día y volver al
  // siguiente sigue mostrando el "hoy" del día anterior — la fecha
  // queda congelada en el state desde que se construyó el provider.
  void _refreshRangeIfRelative() {
    if (state.salesRangePreset != SalesReportRangePreset.custom) {
      final fresh = resolveRange(state.salesRangePreset);
      state = state.copyWith(salesFrom: fresh.from, salesTo: fresh.to);
    }
  }

  Future<String> _requireBusinessId() async {
    final businessId = await resolveBusinessIdOrNull(
      Supabase.instance.client,
      'auto',
    );
    if (businessId == null) {
      throw Exception('No se pudo resolver el negocio actual');
    }
    return businessId;
  }

  /// Carga UNA sola categoría. Lo que usa cada pantalla de detalle al
  /// abrir o al cambiar de rango — un solo round-trip al backend en vez
  /// de los 7 que disparaba `load()` antes.
  Future<void> loadCategory(ReportCategory category) async {
    final myToken = ++_loadToken;
    _refreshRangeIfRelative();
    _syncCurrency();
    state = state.copyWith(
      loading: true,
      clearError: true,
      selectedCategory: category,
    );

    try {
      final businessId = await _requireBusinessId();
      final from = state.salesFrom;
      final to = state.salesTo;

      switch (category) {
        case ReportCategory.sales:
          // getSalesSummary cae a cache offline (F5) si no hay red. La
          // proyección mensual es secundaria y SOLO sirve online; si falla
          // (offline) no debe tumbar el reporte → best-effort, queda vacía.
          final salesSummary = await _repository.getSalesSummary(
              businessId: businessId, from: from, to: to);
          Map<String, double> projection = const {};
          try {
            projection = Map<String, double>.from(
              await _repository.getMonthlyProductProjection(
                  businessId: businessId),
            );
          } catch (_) {
            // Sin red: nos quedamos sin proyección, el resumen (posiblemente
            // cacheado) igual se muestra.
          }
          // El subreporte "Por comprobante" (SalesSubReport.byReceipt) pinta el
          // detalle de NCFs desde `fiscalSummary['documents']`, igual que el
          // reporte de Comprobantes Fiscales. La categoría Ventas no lo cargaba,
          // así que esa pestaña salía siempre vacía aunque hubiera NCFs en la
          // base. Lo cargamos best-effort: si falla (offline / RPC), el resto
          // del reporte de Ventas se muestra igual.
          Map<String, dynamic>? fiscal;
          try {
            fiscal = await _repository.getFiscalDocumentsSummary(
                businessId: businessId, from: from, to: to);
          } catch (_) {
            // Sin red / RPC no disponible: el subreporte por comprobante queda
            // vacío, pero las demás vistas de Ventas siguen funcionando.
          }
          if (myToken != _loadToken) return; // superseded
          state = state.copyWith(
            salesSummary: salesSummary,
            productProjection: projection,
            fiscalSummary: fiscal ?? state.fiscalSummary,
          );
        case ReportCategory.offers:
          final summary = await _repository.getOffersSummary(
              businessId: businessId, from: from, to: to);
          if (myToken != _loadToken) return;
          state = state.copyWith(offersSummary: summary);
        case ReportCategory.finances:
          final summary = await _repository.getCashSummary(
            businessId: businessId, from: from, to: to);
          if (myToken != _loadToken) return;
          state = state.copyWith(cashSummary: summary);
        case ReportCategory.purchases:
          final summary = await _repository.getPurchasesSummary(
            businessId: businessId, from: from, to: to);
          if (myToken != _loadToken) return;
          state = state.copyWith(purchasesSummary: summary);
        case ReportCategory.inventory:
          final summary = await _repository.getInventorySummary(
            businessId: businessId, from: from, to: to);
          if (myToken != _loadToken) return;
          state = state.copyWith(inventorySummary: summary);
        case ReportCategory.taxes:
          // El reporte de Impuestos pinta su data SOLO desde `fiscalSummary`
          // (NCFs emitidos = fuente oficial DGII). NO cargamos `taxSummary`
          // aquí: es legacy y solo lo consumen los tiles del hub
          // (loadHubSummary) y `getTaxMetricCards`. Cargarlo en esta pantalla
          // duplicaba el wall-clock con el método más pesado del repo
          // (payments + items + modifiers + orders + summarizeItemPricing por
          // ítem) sin que el view lo use.
          final fiscal = await _repository.getFiscalDocumentsSummary(
              businessId: businessId, from: from, to: to);
          if (myToken != _loadToken) return;
          state = state.copyWith(fiscalSummary: fiscal);
        case ReportCategory.fiscal:
          final summary = await _repository.getFiscalDocumentsSummary(
            businessId: businessId, from: from, to: to);
          if (myToken != _loadToken) return;
          state = state.copyWith(fiscalSummary: summary);
      }

      if (myToken != _loadToken) return;
      state = state.copyWith(loading: false, clearError: true);
    } catch (e) {
      if (myToken != _loadToken) return;
      state = state.copyWith(
        loading: false,
        error: 'Error cargando reportes: $e',
      );
    }
  }

  /// Carga las 6 categorías para los tiles del hub. Las hace en serie
  /// (no Future.wait) para no martillar Supabase con 7 conexiones a la
  /// vez — cada tile se va llenando a medida que llega su query.
  Future<void> loadHubSummary() async {
    final myToken = ++_loadToken;
    _refreshRangeIfRelative();
    _syncCurrency();
    state = state.copyWith(loading: true, clearError: true);

    try {
      final businessId = await _requireBusinessId();
      final from = state.salesFrom;
      final to = state.salesTo;

      final sales = await _repository.getSalesSummary(
        businessId: businessId, from: from, to: to);
      if (myToken != _loadToken) return;
      state = state.copyWith(salesSummary: sales);

      final cash = await _repository.getCashSummary(
        businessId: businessId, from: from, to: to);
      if (myToken != _loadToken) return;
      state = state.copyWith(cashSummary: cash);

      final purchases = await _repository.getPurchasesSummary(
        businessId: businessId, from: from, to: to);
      if (myToken != _loadToken) return;
      state = state.copyWith(purchasesSummary: purchases);

      final inventory = await _repository.getInventorySummary(
        businessId: businessId, from: from, to: to);
      if (myToken != _loadToken) return;
      state = state.copyWith(inventorySummary: inventory);

      final tax = await _repository.getTaxSummary(
        businessId: businessId, from: from, to: to);
      if (myToken != _loadToken) return;
      state = state.copyWith(taxSummary: tax);

      final fiscal = await _repository.getFiscalDocumentsSummary(
        businessId: businessId, from: from, to: to);
      if (myToken != _loadToken) return;
      state = state.copyWith(fiscalSummary: fiscal);

      state = state.copyWith(loading: false, clearError: true);
    } catch (e) {
      if (myToken != _loadToken) return;
      state = state.copyWith(
        loading: false,
        error: 'Error cargando reportes: $e',
      );
    }
  }

  /// Compat: si hay una categoría seleccionada, recarga solo esa. Si no,
  /// asume que estamos en el hub y carga el resumen completo en serie.
  Future<void> load() async {
    final category = state.selectedCategory;
    if (category != null) {
      await loadCategory(category);
    } else {
      await loadHubSummary();
    }
  }

  /// Llamada desde el hub al entrar — borra la marca de "última
  /// categoría vista" para que `load()` caiga en `loadHubSummary`.
  void clearSelectedCategory() {
    state = state.copyWith(clearCategory: true);
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
    // Normalizamos a fecha (descartamos horas) y aplicamos exclusive-end:
    // sumamos 1 día a `to` para que la query incluya el último día completo
    // (00:00 del día siguiente como upper bound).
    var start = DateTime(from.year, from.month, from.day);
    var end = DateTime(to.year, to.month, to.day);
    // Si llegan invertidas (defensivo — el modal lo corrige antes pero igual
    // protegemos contra callers programáticos), swap silencioso.
    if (end.isBefore(start)) {
      final tmp = start;
      start = end;
      end = tmp;
    }
    final endExclusive = end.add(const Duration(days: 1));
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
      case SalesSubReport.byProductionArea:
        return 'Por área de producción';
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
        final currency = state.currency.formatter;
        final numberFormat = NumberFormat('#,##0', 'en_US');
        return [
          ReportItem(
            title: 'Ventas por rango',
            description:
                'Total: ${currency.format(total)} | Transacciones: ${numberFormat.format(txCount)}',
          ),
          ReportItem(
            title: 'Items vendidos',
            description: 'Items cobrados en el rango: ${numberFormat.format(itemsSold)}',
          ),
        ];
      case ReportCategory.offers:
        final offersCount =
            (state.offersSummary?['offers_count'] as num?)?.toInt() ?? 0;
        final totalNet =
            (state.offersSummary?['total_net'] as num?)?.toDouble() ?? 0;
        final totalQty =
            (state.offersSummary?['total_quantity'] as num?)?.toDouble() ?? 0;
        final totalDiscounts =
            (state.offersSummary?['total_discounts'] as num?)?.toDouble() ?? 0;
        final currency = state.currency.formatter;
        final numberFormat = NumberFormat('#,##0', 'en_US');
        return [
          ReportItem(
            title: 'Ventas por oferta',
            description:
                'Ofertas con ventas: ${numberFormat.format(offersCount)} | Ventas netas: ${currency.format(totalNet)}',
          ),
          ReportItem(
            title: 'Productos y descuentos',
            description:
                'Productos despachados: ${numberFormat.format(totalQty)} | Descuento otorgado: ${currency.format(totalDiscounts)}',
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
        final currency = state.currency.formatter;
        final numberFormat = NumberFormat('#,##0', 'en_US');
        return [
          ReportItem(
            title: 'Órdenes de compra',
            description:
                'Órdenes: ${numberFormat.format(ordersCount)} | Total ordenado: ${currency.format(totalOrdered)}',
          ),
          ReportItem(
            title: 'Recepción y proveedores',
            description:
                'Recibidas: ${numberFormat.format(receivedCount)} | Parciales: ${numberFormat.format(partialCount)} | Borradores: ${numberFormat.format(draftCount)} | Proveedores activos: ${numberFormat.format(suppliersCount)} | Recibido: ${currency.format(totalReceived)}',
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
        final currency = state.currency.formatter;
        final numberFormat = NumberFormat('#,##0', 'en_US');
        return [
          ReportItem(
            title: 'Resumen de caja',
            description:
                'Sesiones: ${numberFormat.format(sessions)} | Diferencia acumulada: ${currency.format(differences)}',
          ),
          ReportItem(
            title: 'Movimientos manuales',
            description:
                'Entradas: ${currency.format(inTotal)} | Salidas: ${currency.format(outTotal)}',
          ),
        ];
      case ReportCategory.inventory:
        final itemsCount = state.inventorySummary?['items_count'] ?? 0;
        final activeItems = state.inventorySummary?['active_items_count'] ?? 0;
        final totalUnits =
            (state.inventorySummary?['total_units'] as num?)?.toDouble() ?? 0;
        final lowStock = state.inventorySummary?['low_stock_count'] ?? 0;
        final outOfStock = state.inventorySummary?['out_of_stock_count'] ?? 0;
        final numberFormat = NumberFormat('#,##0', 'en_US');
        final decFormat = NumberFormat('#,##0.00', 'en_US');
        return [
          ReportItem(
            title: 'Estado de inventario',
            description:
                'Items: ${numberFormat.format(itemsCount)} | Activos: ${numberFormat.format(activeItems)} | Stock total: ${decFormat.format(totalUnits)} unidades',
          ),
          ReportItem(
            title: 'Alertas de stock',
            description: 'Bajo mínimo: ${numberFormat.format(lowStock)} | Agotados: ${numberFormat.format(outOfStock)}',
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
        final currency = state.currency.formatter;
        final numberFormat = NumberFormat('#,##0', 'en_US');
        // Enumera cada impuesto configurado por su nombre real (ITBIS, LEY,
        // IVA…) en vez del par fijo "Impuestos | Propina de ley". Refleja
        // exactamente lo que el negocio configuró en Ajustes → Impuestos, sin
        // depender de is_service_fee.
        final breakdown =
            (state.taxSummary?['tax_breakdown'] as List?)?.cast<Map>() ??
                const <Map>[];
        final perTax = breakdown
            .where((r) => ((r['amount'] as num?)?.toDouble() ?? 0).abs() > 0.005)
            .map((r) {
          final label = (r['label']?.toString().trim().isNotEmpty == true)
              ? r['label'].toString().trim()
              : 'Impuesto';
          final amount = (r['amount'] as num?)?.toDouble() ?? 0;
          return '$label: ${currency.format(amount)}';
        }).join(' | ');
        final taxesDesc = perTax.isEmpty
            ? 'Total: ${currency.format(totalCharges)}'
            : '$perTax | Total: ${currency.format(totalCharges)}';
        return [
          ReportItem(
            title: 'Impuestos generados',
            description: taxesDesc,
          ),
          ReportItem(
            title: 'Configuración fiscal',
            description:
                'Tipos configurados: ${numberFormat.format(configured)} | Activos: ${numberFormat.format(active)} | Base gravable: ${currency.format(taxableSales)}',
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
        final currency = state.currency.formatter;
        final numberFormat = NumberFormat('#,##0', 'en_US');
        return [
          ReportItem(
            title: 'Comprobantes fiscales',
            description:
                'Documentos: ${numberFormat.format(docsCount)} | Activos: ${numberFormat.format(activeCount)} | Anulados: ${numberFormat.format(voidCount)}',
          ),
          ReportItem(
            title: 'Totales facturados',
            description:
                'Total: ${currency.format(totalAmount)} | ITBIS: ${currency.format(totalItbis)}',
          ),
        ];
    }
  }

  /// Si el resumen de ventas actual viene del cache offline (F5), devuelve
  /// cuándo se capturó; null si es data fresca (online). La vista lo usa para
  /// mostrar el aviso "datos sin conexión al …".
  DateTime? get salesDataCachedAt => _cachedAtOf(state.salesSummary);

  /// Igual que [salesDataCachedAt] pero para el resumen de finanzas/caja (F5-2).
  DateTime? get financesDataCachedAt =>
      _cachedAtOf(state.cashSummary);

  /// Frescura del cache offline para las demás categorías (F5-resto).
  DateTime? get purchasesDataCachedAt => _cachedAtOf(state.purchasesSummary);
  DateTime? get inventoryDataCachedAt => _cachedAtOf(state.inventorySummary);
  DateTime? get taxDataCachedAt => _cachedAtOf(state.taxSummary);
  DateTime? get fiscalDataCachedAt => _cachedAtOf(state.fiscalSummary);

  DateTime? _cachedAtOf(Map<String, dynamic>? summary) {
    final raw = summary?['_offline_cached_at']?.toString();
    if (raw == null || raw.isEmpty) return null;
    return DateTime.tryParse(raw);
  }

  List<SalesMetricCardData> getSalesMetricCards() {
    final summary = state.salesSummary ?? const <String, dynamic>{};
    final totalSales = (summary['total_sales'] as num?)?.toDouble() ?? 0;
    final voidedSales = (summary['voided_sales'] as num?)?.toDouble() ?? 0;
    final netSales = (summary['net_sales'] as num?)?.toDouble() ?? totalSales;
    final paymentsCount = (summary['payments_count'] as num?)?.toInt() ?? 0;
    final itemsSold = (summary['items_sold'] as num?)?.toInt() ?? 0;
    final avgTicket = (summary['avg_ticket'] as num?)?.toDouble() ?? 0;
    // RF-R1: rentabilidad. gross_profit_total/total_cost vienen del RPC; margin_pct
    // es null cuando no hay ventas. Calculado con el costo ACTUAL del producto.
    final grossProfit = (summary['gross_profit_total'] as num?)?.toDouble() ?? 0;
    final totalCost = (summary['total_cost'] as num?)?.toDouble() ?? 0;
    final marginPct = (summary['margin_pct_total'] as num?)?.toDouble();

    final currency = state.currency.formatter;
    final numberFormat = NumberFormat('#,##0', 'en_US');

    return [
      SalesMetricCardData(
        title: 'Ventas',
        value: currency.format(netSales),
        subtitle:
            '${numberFormat.format(paymentsCount)} transacciones completadas',
        icon: Icons.payments_outlined,
        color: const Color(0xFF2563EB),
      ),
      SalesMetricCardData(
        title: 'Ticket promedio',
        value: currency.format(avgTicket),
        subtitle: 'Promedio por transacción completada',
        icon: Icons.receipt_long_outlined,
        color: const Color(0xFF7C3AED),
      ),
      SalesMetricCardData(
        title: 'Items vendidos',
        value: numberFormat.format(itemsSold),
        subtitle: 'Cantidad total de productos cobrados',
        icon: Icons.inventory_2_outlined,
        color: const Color(0xFF059669),
      ),
      SalesMetricCardData(
        title: 'Ventas anuladas',
        value: currency.format(voidedSales),
        subtitle: 'Montos cancelados o void en el rango',
        icon: Icons.cancel_outlined,
        color: const Color(0xFFDC2626),
      ),
      SalesMetricCardData(
        title: 'Utilidad bruta',
        value: currency.format(grossProfit),
        subtitle: 'Ventas netas menos costo (costo actual)',
        icon: Icons.trending_up_outlined,
        color: const Color(0xFF0F766E),
      ),
      SalesMetricCardData(
        title: 'Costo de ventas',
        value: currency.format(totalCost),
        subtitle: 'Costo actual de los productos vendidos',
        icon: Icons.sell_outlined,
        color: const Color(0xFFB45309),
      ),
      SalesMetricCardData(
        title: 'Margen',
        value: marginPct == null
            ? '--'
            : '${NumberFormat('#,##0.0', 'en_US').format(marginPct)}%',
        subtitle: 'Utilidad bruta sobre ventas netas',
        icon: Icons.percent_outlined,
        color: const Color(0xFF7C3AED),
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
    final projection = state.productProjection ?? const <String, double>{};
    return rows
        .map((row) => Map<String, dynamic>.from(row as Map))
        .map(
          (row) {
            final productId = row['product_id']?.toString() ?? '';
            return ProductSalesReportRow(
              productId: productId,
              product: row['product']?.toString() ?? 'Producto',
              category: row['category']?.toString() ?? 'Sin categoría',
              quantitySold: (row['quantity_sold'] as num?)?.toDouble() ?? 0,
              projectedQuantity:
                  productId.isNotEmpty ? (projection[productId] ?? 0) : 0,
              grossSales: (row['gross_sales'] as num?)?.toDouble() ?? 0,
              discounts: (row['discounts'] as num?)?.toDouble() ?? 0,
              courtesies: (row['courtesies'] as num?)?.toDouble() ?? 0,
              netSales: (row['net_sales'] as num?)?.toDouble() ?? 0,
              cost: (row['cost'] as num?)?.toDouble() ?? 0,
              grossProfit: (row['gross_profit'] as num?)?.toDouble() ?? 0,
              marginPct: (row['margin_pct'] as num?)?.toDouble(),
              tickets: (row['tickets'] as num?)?.toInt() ?? 0,
            );
          },
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

  List<SalesBreakdownRow> getProductionAreaRows() {
    final rows =
        (state.salesSummary?['sales_by_production_area'] as List?) ?? const [];
    return rows
        .map((row) => Map<String, dynamic>.from(row as Map))
        .map(
          (row) => SalesBreakdownRow(
            label: row['label']?.toString() ?? 'Sin área',
            amount: (row['amount'] as num?)?.toDouble() ?? 0,
            quantity: (row['quantity'] as num?)?.toDouble() ?? 0,
            count: (row['count'] as num?)?.toInt() ?? 0,
          ),
        )
        .toList(growable: false);
  }

  List<SalesBreakdownRow> getReceiptRows() {
    // Fuente primaria: sales_by_receipt del RPC de ventas. Hoy el RPC v2 no lo
    // puebla (siempre llega vacío), así que caemos al desglose por tipo de NCF
    // de `fiscalSummary['by_type']`, que ya trae label/amount/count por
    // comprobante. Así la tarjeta-resumen queda consistente con el detalle.
    var rows = (state.salesSummary?['sales_by_receipt'] as List?) ?? const [];
    if (rows.isEmpty) {
      rows = (state.fiscalSummary?['by_type'] as List?) ?? const [];
    }
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
            label: row['label']?.toString() ?? 'Descuento',
            amount: (row['amount'] as num?)?.toDouble() ?? 0,
            quantity: (row['quantity'] as num?)?.toDouble() ?? 0,
            count: (row['count'] as num?)?.toInt() ?? 0,
          ),
        )
        .toList(growable: false);
  }

  /// Todas las líneas de oferta del rango, sin aplicar filtros de la pestaña.
  /// Fuente: `lines` de [ReportsRepository.getOffersSummary].
  List<OfferDetailLine> _allOfferLines() {
    final rows = (state.offersSummary?['lines'] as List?) ?? const [];
    return rows
        .map((row) => Map<String, dynamic>.from(row as Map))
        .map(
          (row) => OfferDetailLine(
            dateTime: AppTime.tryParseServerToAst(row['created_at']),
            offerName: row['offer_name']?.toString() ?? 'Oferta',
            productName: row['product_name']?.toString() ?? 'Producto',
            quantity: (row['quantity'] as num?)?.toDouble() ?? 0,
            valorMenu: (row['valor_menu'] as num?)?.toDouble() ?? 0,
            descuento: (row['descuento'] as num?)?.toDouble() ?? 0,
            isDeal: row['is_deal'] == true,
          ),
        )
        .toList(growable: false);
  }

  /// Listado detallado de ofertas tras aplicar los filtros de la pestaña
  /// (oferta, producto, tipo y búsqueda por texto), en orden cronológico.
  List<OfferDetailLine> getOfferDetailRows() {
    final offer = state.offerOfferFilter;
    final product = state.offerProductFilter;
    final type = state.offerTypeFilter;
    final search = state.offerSearchQuery.trim().toLowerCase();
    return _allOfferLines().where((line) {
      if (offer != null && line.offerName != offer) return false;
      if (product != null && line.productName != product) return false;
      if (type == OfferTypeFilter.deal && !line.isDeal) return false;
      if (type == OfferTypeFilter.promo && line.isDeal) return false;
      if (search.isNotEmpty) {
        final hay = '${line.offerName} ${line.productName}'.toLowerCase();
        if (!hay.contains(search)) return false;
      }
      return true;
    }).toList(growable: false);
  }

  /// Conteo de cantidad despachada por producto (pivote) sobre lo filtrado.
  List<OfferProductTotal> getOfferProductTotals() {
    final totals = <String, double>{};
    for (final line in getOfferDetailRows()) {
      totals[line.productName] = (totals[line.productName] ?? 0) + line.quantity;
    }
    final list = totals.entries
        .map((e) =>
            OfferProductTotal(productName: e.key, quantity: e.value))
        .toList()
      ..sort((a, b) => b.quantity.compareTo(a.quantity));
    return list;
  }

  /// Opciones para el selector "Por oferta" (todos los nombres del rango).
  List<String> offerNameOptions() {
    final set = <String>{for (final l in _allOfferLines()) l.offerName};
    final list = set.toList()..sort();
    return list;
  }

  /// Opciones para el selector "Por producto".
  List<String> offerProductOptions() {
    final set = <String>{for (final l in _allOfferLines()) l.productName};
    final list = set.toList()..sort();
    return list;
  }

  /// True si hay algún filtro de ofertas activo.
  bool get hasOfferFilters =>
      state.offerOfferFilter != null ||
      state.offerProductFilter != null ||
      state.offerTypeFilter != OfferTypeFilter.all ||
      state.offerSearchQuery.trim().isNotEmpty;

  void setOfferOfferFilter(String? offerName) {
    state = state.copyWith(
      offerOfferFilter: offerName,
      clearOfferOfferFilter: offerName == null,
    );
  }

  void setOfferProductFilter(String? productName) {
    state = state.copyWith(
      offerProductFilter: productName,
      clearOfferProductFilter: productName == null,
    );
  }

  void setOfferTypeFilter(OfferTypeFilter type) {
    state = state.copyWith(offerTypeFilter: type);
  }

  void setOfferSearchQuery(String query) {
    state = state.copyWith(offerSearchQuery: query);
  }

  void clearOfferFilters() {
    state = state.copyWith(
      clearOfferOfferFilter: true,
      clearOfferProductFilter: true,
      offerTypeFilter: OfferTypeFilter.all,
      offerSearchQuery: '',
    );
  }

  /// Valor total a precio de menú de lo filtrado.
  double get offersTotalValorMenu =>
      getOfferDetailRows().fold<double>(0, (s, l) => s + l.valorMenu);

  /// Descuento total otorgado en lo filtrado (lo regalado).
  double get offersTotalDescuento =>
      getOfferDetailRows().fold<double>(0, (s, l) => s + l.descuento);

  double get offersTotalQuantity =>
      getOfferDetailRows().fold<double>(0, (s, l) => s + l.quantity);

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
        value: state.currency.formatAmount(netCashFlow),
        subtitle: 'Ventas + entradas manuales - salidas manuales',
        icon: Icons.account_balance_wallet_outlined,
        color: const Color(0xFF2563EB),
      ),
      SalesMetricCardData(
        title: 'Ventas en caja',
        value: state.currency.formatAmount(salesTotal),
        subtitle: '$sessions sesiones en el rango',
        icon: Icons.point_of_sale_outlined,
        color: const Color(0xFFF97316),
      ),
      SalesMetricCardData(
        title: 'Entradas manuales',
        value: state.currency.formatAmount(manualIn),
        subtitle: 'Depósitos e ingresos de caja',
        icon: Icons.south_west_outlined,
        color: const Color(0xFF059669),
      ),
      SalesMetricCardData(
        title: 'Salidas manuales',
        value: state.currency.formatAmount(manualOut),
        subtitle: 'Retiros y gastos registrados',
        icon: Icons.north_east_outlined,
        color: const Color(0xFFDC2626),
      ),
      SalesMetricCardData(
        title: 'Diferencia acumulada',
        value: state.currency.formatAmount(differences),
        subtitle:
            'Promedio por sesión: ${state.currency.formatAmount(avgDifference)}',
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
        value: state.currency.formatAmount(stockValue),
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
        value: state.currency.formatAmount(totalOrdered),
        subtitle: 'Total emitido en el rango',
        icon: Icons.request_quote_outlined,
        color: const Color(0xFFF97316),
      ),
      SalesMetricCardData(
        title: 'Monto recibido',
        value: state.currency.formatAmount(totalReceived),
        subtitle: 'Órdenes completamente recibidas',
        icon: Icons.inventory_outlined,
        color: const Color(0xFF059669),
      ),
      SalesMetricCardData(
        title: 'Promedio por orden',
        value: state.currency.formatAmount(avgOrder),
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

  /// Cards del Reporte de Impuestos. Fuente: `fiscalSummary` (= tabla
  /// `fiscal_documents` = NCFs emitidos = oficial DGII).
  ///
  /// IMPORTANTE: este método reemplaza al legacy `getTaxMetricCards()` que
  /// leía de `taxSummary` (reconstrucción Dart desde payments+items con
  /// heurística `27.9`). Ese path daba números distintos a los del view —
  /// divergencia confirmada del 30% (RD$19,956 vs RD$13,972 en el reporte
  /// de impuestos del 26/05/2026).
  ///
  /// La única verdad para impuestos es lo que se emitió como NCF. Punto.
  /// Tanto la pantalla como el PDF/CSV ahora usan este método → cero
  /// divergencia posible.
  List<SalesMetricCardData> getTaxReportMetricCards() {
    final summary = state.fiscalSummary ?? const <String, dynamic>{};
    final selectedType = state.fiscalTypeFilter;

    // Si el usuario filtró por tipo de NCF, los totales se reducen al bucket
    // de ese tipo. Sin filtro, usamos los totales globales del rango.
    Map<String, dynamic>? activeBucket;
    if (selectedType != null) {
      final byType = (summary['by_type'] as List?) ?? const [];
      for (final raw in byType) {
        final row = Map<String, dynamic>.from(raw as Map);
        if (row['ncf_type']?.toString() == selectedType) {
          activeBucket = row;
          break;
        }
      }
    }

    final totalItbis = activeBucket != null
        ? (activeBucket['itbis'] as num?)?.toDouble() ?? 0
        : (summary['total_itbis'] as num?)?.toDouble() ?? 0;
    final totalServiceFee = activeBucket != null
        ? (activeBucket['service_fee'] as num?)?.toDouble() ?? 0
        : (summary['total_service_fee'] as num?)?.toDouble() ?? 0;
    final totalSubtotal = activeBucket != null
        ? (activeBucket['subtotal'] as num?)?.toDouble() ?? 0
        : (summary['total_subtotal'] as num?)?.toDouble() ?? 0;
    final totalAmount = activeBucket != null
        ? (activeBucket['amount'] as num?)?.toDouble() ?? 0
        : (summary['total_amount'] as num?)?.toDouble() ?? 0;
    // Con filtro activo no contamos anulados por tipo (el bucket es solo
    // activos). Sin filtro mostramos el contador global de anulados.
    final voidCount = activeBucket != null
        ? 0
        : (summary['void_count'] as num?)?.toInt() ?? 0;

    // Tasa efectiva derivada — NO hardcodeada al 18%. Si totalSubtotal=0 (sin
    // ventas), cae a "Sin base gravable" en vez de mostrar 0% que confunde.
    final effectiveRate = totalSubtotal > 0
        ? (totalItbis / totalSubtotal) * 100
        : 0;
    final effectiveRateLabel = totalSubtotal > 0
        ? '${effectiveRate.toStringAsFixed(2)}% sobre base gravable'
        : 'Sin base gravable en el rango';

    // Label del impuesto principal: derivado de tax_breakdown[0].label si hay
    // una sola tasa configurada (ITBIS, IVA, IGV...). Si hay varias, fallback
    // genérico. Antes hardcoded "ITBIS" → rompía multi-país y multi-impuesto.
    final taxBreakdown =
        (summary['tax_breakdown'] as List?)?.cast<Map>() ?? const <Map>[];
    final primaryTaxName = taxBreakdown.length == 1
        ? ((taxBreakdown.first['label']?.toString().trim() ?? '').isNotEmpty
            ? taxBreakdown.first['label'].toString().trim()
            : 'Impuestos')
        : 'Impuestos';
    final taxCardTitle = '$primaryTaxName cobrado${taxBreakdown.length > 1 ? 's' : ''}';

    // Label del cargo de servicio: viene de service_fee_label configurado por
    // el comercio. Fallback genérico "Cargo de servicio" si no hay nombre
    // configurado — preferimos algo neutral antes que asumir "Propina de ley"
    // (que es específico de RD).
    final serviceFeeRaw = (summary['service_fee_label'] as String?)?.trim();
    final serviceFeeTitle = (serviceFeeRaw?.isNotEmpty ?? false)
        ? serviceFeeRaw!
        : 'Cargo de servicio';
    final serviceFeeRate = (summary['service_fee_rate'] as num?)?.toDouble() ?? 0;
    final serviceFeeSubtitle = serviceFeeRate > 0
        ? '${serviceFeeRate.toStringAsFixed(serviceFeeRate.truncateToDouble() == serviceFeeRate ? 0 : 2)}% sobre base'
        : 'Cargo legal aplicado en el ticket';

    // Excedente no gravable: la diferencia entre lo cobrado (totalAmount)
    // y los componentes facturables (subtotal + itbis + service_fee).
    // Cuando un cliente paga más que la cuenta (propina voluntaria o
    // vuelto no registrado), ese excedente se cobra pero NO se factura
    // como ingreso gravable. La función fn_recompute_fd_for_scope v4
    // (migración 20260530_0012) mantiene los componentes limpios del
    // menú y deja el excedente implícito en fd.total; esta card lo
    // hace explícito en el reporte para que la math cuadre visualmente.
    final excedenteNoGravable =
        totalAmount - totalSubtotal - totalItbis - totalServiceFee;
    final hayExcedente = excedenteNoGravable > 0.01;

    return [
      SalesMetricCardData(
        title: taxCardTitle,
        value: state.currency.formatAmount(totalItbis),
        subtitle: effectiveRateLabel,
        icon: Icons.account_balance_outlined,
        color: const Color(0xFF2563EB),
      ),
      SalesMetricCardData(
        title: serviceFeeTitle,
        value: state.currency.formatAmount(totalServiceFee),
        subtitle: serviceFeeSubtitle,
        icon: Icons.room_service_outlined,
        color: const Color(0xFFF97316),
      ),
      SalesMetricCardData(
        title: 'Base gravable',
        value: state.currency.formatAmount(totalSubtotal),
        subtitle: 'Subtotal antes de impuestos',
        icon: Icons.sell_outlined,
        color: const Color(0xFF7C3AED),
      ),
      if (hayExcedente)
        SalesMetricCardData(
          title: 'Excedente no gravable',
          value: state.currency.formatAmount(excedenteNoGravable),
          subtitle: 'Propina / vuelto sin registrar',
          icon: Icons.savings_outlined,
          color: const Color(0xFF94A3B8),
        ),
      SalesMetricCardData(
        title: 'Total facturado',
        value: state.currency.formatAmount(totalAmount),
        subtitle: 'Incluyendo impuestos',
        icon: Icons.receipt_long_outlined,
        color: const Color(0xFF059669),
      ),
      SalesMetricCardData(
        title: 'Anulados',
        value: '$voidCount',
        subtitle: 'Comprobantes anulados',
        icon: Icons.cancel_outlined,
        color: const Color(0xFFDC2626),
      ),
    ];
  }

  /// Desglose por tipo de NCF (B01, B02, etc.) para el reporte de Impuestos.
  /// Mismas filas que muestra el view en la sección "Desglose por tipo".
  /// Antes salía de `taxSummary.tax_breakdown` (otro camino) — ahora de
  /// `fiscalSummary.by_type` igual que el view.
  List<SalesBreakdownRow> getTaxReportTypeRows() {
    final rows = (state.fiscalSummary?['by_type'] as List?) ?? const [];
    return rows
        .map((row) => Map<String, dynamic>.from(row as Map))
        .map(
          (row) => SalesBreakdownRow(
            label: row['label']?.toString() ?? 'Tipo',
            amount: (row['amount'] as num?)?.toDouble() ?? 0,
            quantity: (row['itbis'] as num?)?.toDouble() ?? 0,
            count: (row['count'] as num?)?.toInt() ?? 0,
          ),
        )
        .toList(growable: false);
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

    // Labels derivados del BD — ver comentario en getTaxReportMetricCards.
    final taxBreakdown =
        (summary['tax_breakdown'] as List?)?.cast<Map>() ?? const <Map>[];
    final primaryTaxName = taxBreakdown.length == 1
        ? ((taxBreakdown.first['label']?.toString().trim() ?? '').isNotEmpty
            ? taxBreakdown.first['label'].toString().trim()
            : 'Impuestos')
        : 'Impuestos';
    final taxCardTitle = '$primaryTaxName cobrado${taxBreakdown.length > 1 ? 's' : ''}';
    final serviceFeeRaw = (summary['service_fee_label'] as String?)?.trim();
    final serviceFeeTitle = (serviceFeeRaw?.isNotEmpty ?? false)
        ? serviceFeeRaw!
        : 'Cargo de servicio';

    return [
      SalesMetricCardData(
        title: 'Total facturado',
        value: state.currency.formatAmount(totalAmount),
        subtitle: '$docsCount comprobantes emitidos',
        icon: Icons.receipt_long_outlined,
        color: const Color(0xFF2563EB),
      ),
      SalesMetricCardData(
        title: 'Subtotal',
        value: state.currency.formatAmount(totalSubtotal),
        subtitle: 'Monto antes de impuestos',
        icon: Icons.attach_money_outlined,
        color: const Color(0xFFF97316),
      ),
      SalesMetricCardData(
        title: taxCardTitle,
        value: state.currency.formatAmount(totalItbis),
        subtitle: 'Total $primaryTaxName en comprobantes activos',
        icon: Icons.account_balance_outlined,
        color: const Color(0xFF059669),
      ),
      if (totalServiceFee > 0)
        SalesMetricCardData(
          title: serviceFeeTitle,
          value: state.currency.formatAmount(totalServiceFee),
          subtitle: 'Total $serviceFeeTitle en el rango',
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
            quantity: (row['itbis'] as num?)?.toDouble() ?? 0,
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
      case ReportCategory.offers:
        return 'Ventas por oferta';
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
      case ReportCategory.offers:
        return Icons.local_offer;
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
