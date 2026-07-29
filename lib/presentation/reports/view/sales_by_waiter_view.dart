// Reporte "Ventas por mesero" — feature multimesero.
//
// Muestra una tabla con totales por empleado en el rango de fechas
// seleccionado. Atribución de items:
//   1) created_by_employee_id si está seteado
//   2) si no, fallback al opened_by_employee_id de la mesa
//   3) items sin atribución se excluyen
//
// Implementada como vista standalone (no usa ReportScaffold) para
// mantenerla simple — solo filtro de fechas + tabla + total.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:mangopos/core/currency/business_currency_provider.dart';

import 'package:mangopos/app/router/routes.dart';
import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/core/theme/app_breakpoints.dart';
import 'package:mangopos/data/repositories/sales_by_waiter_repository.dart';
import 'package:mangopos/presentation/reports/services/sales_by_waiter_export_service.dart';
import 'package:mangopos/presentation/reports/widgets/report_widgets.dart';
import 'package:mangopos/services/session/session_controller.dart';

/// Resultado combinado del reporte: resumen por mesero + desglose de
/// productos. El desglose viene de una RPC aparte (mig 20260728_0002);
/// si aún no está aplicada, llega vacío y solo se muestra el resumen.
typedef _WaiterReportData = (List<WaiterSalesRow>, List<WaiterProductRow>);

class SalesByWaiterView extends ConsumerStatefulWidget {
  const SalesByWaiterView({super.key});

  @override
  ConsumerState<SalesByWaiterView> createState() => _SalesByWaiterViewState();
}

class _SalesByWaiterViewState extends ConsumerState<SalesByWaiterView> {
  late DateTime _from;
  late DateTime _to;
  Future<_WaiterReportData>? _future;
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  Timer? _searchDebounce;
  String _search = '';
  bool _exporting = false;

  /// Productos vendidos en el rango actual (sin filtro), para el dropdown
  /// del selector. Se refresca en cada carga.
  List<String> _productOptions = const [];

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _to = DateTime(now.year, now.month, now.day);
    _from = _to.subtract(const Duration(days: 6));
    _reload();
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  void _reload() {
    final businessId = ref.read(sessionProvider).activeBusinessId;
    if (businessId == null || businessId.isEmpty) {
      setState(
        () => _future = Future.value((
          const <WaiterSalesRow>[],
          const <WaiterProductRow>[],
        )),
      );
      return;
    }
    final repo = ref.read(salesByWaiterRepositoryProvider);
    setState(() {
      _future = () async {
        final summary = repo.fetch(
          businessId: businessId,
          from: _from,
          to: _to,
          productSearch: _search,
        );
        // El desglose es best-effort: si la RPC del desglose no existe
        // todavía (migración sin aplicar), mostramos solo el resumen en
        // vez de romper todo el reporte.
        final products = repo
            .fetchProducts(
              businessId: businessId,
              from: _from,
              to: _to,
              productSearch: _search,
            )
            .catchError((_) => const <WaiterProductRow>[]);
        // Opciones del selector: todo lo vendido en el rango SIN filtro.
        // Si no hay filtro activo, reutilizamos la misma consulta del
        // desglose en vez de pedirla dos veces.
        final options = _search.isEmpty
            ? products
            : repo
                  .fetchProducts(businessId: businessId, from: _from, to: _to)
                  .catchError((_) => const <WaiterProductRow>[]);
        final result = (await summary, await products);
        final names = (await options).map((p) => p.productName).toSet().toList()
          ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
        if (mounted) _productOptions = names;
        return result;
      }();
    });
  }

  void _onSearchChanged(String value) {
    // Rebuild inmediato para que el botón de limpiar aparezca/desaparezca
    // al escribir; la consulta espera al debounce.
    setState(() {});
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 450), () {
      if (!mounted) return;
      final term = value.trim();
      if (term == _search) return;
      _search = term;
      _reload();
    });
  }

  void _clearSearch() {
    _searchDebounce?.cancel();
    _searchController.clear();
    if (_search.isEmpty) return;
    _search = '';
    _reload();
  }

  /// Selección desde el dropdown: aplica el filtro de inmediato, sin
  /// esperar el debounce de tipeo.
  void _selectProduct(String value) {
    _searchDebounce?.cancel();
    _searchFocusNode.unfocus();
    final term = value.trim();
    if (term == _search) return;
    _search = term;
    _reload();
  }

  Future<void> _exportPdf() async {
    final future = _future;
    if (future == null || _exporting) return;
    setState(() => _exporting = true);
    try {
      final (rows, productRows) = await future;
      if (!mounted) return;
      if (rows.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No hay datos para exportar')),
        );
        return;
      }
      await SalesByWaiterExportService.exportPdf(
        rows: rows,
        productRows: productRows,
        from: _from,
        to: _to,
        currency: currentBusinessCurrencyOrFallback(ref).formatter,
        productSearch: _search,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error exportando PDF: $e')));
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _pickDateRange() async {
    final range = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
      initialDateRange: DateTimeRange(start: _from, end: _to),
      builder: (ctx, child) => Theme(
        data: Theme.of(ctx).copyWith(
          colorScheme: ColorScheme.fromSeed(
            seedColor: MangoColors.primaryOrange,
          ),
        ),
        child: child!,
      ),
    );
    if (range != null) {
      setState(() {
        _from = DateTime(range.start.year, range.start.month, range.start.day);
        _to = DateTime(range.end.year, range.end.month, range.end.day);
      });
      _reload();
    }
  }

  /// Sección "Desglose de productos por mesero": un ExpansionTile por
  /// empleado con los productos que vendió en el rango (respetando el
  /// filtro de búsqueda). Vacío si la RPC del desglose no está
  /// disponible (migración 20260728_0002 sin aplicar) o no hay datos.
  List<Widget> _buildProductBreakdown(
    List<WaiterSalesRow> rows,
    List<WaiterProductRow> productRows,
    NumberFormat currency,
  ) {
    if (productRows.isEmpty) return const [];
    final qtyFormat = NumberFormat('#,##0.##', 'en_US');

    final byEmployee = <String, List<WaiterProductRow>>{};
    for (final p in productRows) {
      byEmployee.putIfAbsent(p.employeeId, () => []).add(p);
    }
    // Mismo orden que la tabla resumen (neto desc). Empleados que solo
    // aparezcan en el desglose (no debería pasar: ambas RPC comparten
    // filtros) van al final.
    final orderedIds = <String>[
      ...rows.map((r) => r.employeeId).where(byEmployee.containsKey),
      ...byEmployee.keys.where((id) => !rows.any((r) => r.employeeId == id)),
    ];

    return [
      const SizedBox(height: 20),
      const Text(
        'Desglose de productos por mesero',
        style: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w800,
          color: MangoColors.darkGray,
        ),
      ),
      const SizedBox(height: 8),
      Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFFE5E7EB)),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            for (var i = 0; i < orderedIds.length; i++) ...[
              if (i > 0) const Divider(height: 1, color: Color(0xFFF1F5F9)),
              _waiterProductsTile(
                byEmployee[orderedIds[i]]!,
                currency,
                qtyFormat,
              ),
            ],
          ],
        ),
      ),
    ];
  }

  Widget _waiterProductsTile(
    List<WaiterProductRow> products,
    NumberFormat currency,
    NumberFormat qtyFormat,
  ) {
    final name = products.first.employeeName.isNotEmpty
        ? products.first.employeeName
        : 'Sin mesero';
    final net = products.fold<double>(0, (s, p) => s + p.netAmount);
    final units = products.fold<double>(0, (s, p) => s + p.units);

    return ExpansionTile(
      shape: const Border(),
      collapsedShape: const Border(),
      leading: CircleAvatar(
        radius: 16,
        backgroundColor: MangoColors.primaryOrange.withValues(alpha: 0.12),
        child: Text(
          name[0].toUpperCase(),
          style: const TextStyle(
            color: MangoColors.primaryOrange,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
      title: Text(name, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(
        '${products.length} producto${products.length == 1 ? '' : 's'} · '
        '${qtyFormat.format(units)} und · ${currency.format(net)}',
        style: const TextStyle(fontSize: 12, color: MangoColors.muted),
      ),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Row(
            children: const [
              Expanded(
                flex: 6,
                child: Text(
                  'Producto',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 11,
                    color: MangoColors.muted,
                  ),
                ),
              ),
              Expanded(
                flex: 2,
                child: Text(
                  'Cant.',
                  textAlign: TextAlign.end,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 11,
                    color: MangoColors.muted,
                  ),
                ),
              ),
              Expanded(
                flex: 3,
                child: Text(
                  'Neto',
                  textAlign: TextAlign.end,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 11,
                    color: MangoColors.muted,
                  ),
                ),
              ),
            ],
          ),
        ),
        ...products.map(
          (p) => Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Row(
              children: [
                Expanded(
                  flex: 6,
                  child: Text(
                    p.sku.isNotEmpty
                        ? '${p.productName} · ${p.sku}'
                        : p.productName,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: Text(
                    qtyFormat.format(p.units),
                    textAlign: TextAlign.end,
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
                Expanded(
                  flex: 3,
                  child: Text(
                    currency.format(p.netAmount),
                    textAlign: TextAlign.end,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final currency = currentBusinessCurrencyOrFallback(ref).formatter;
    final numberFormat = NumberFormat('#,##0', 'en_US');
    final dateFormat = DateFormat('dd MMM yyyy');

    return Scaffold(
      backgroundColor: const Color(0xFFF7F7F7),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextButton.icon(
                style: TextButton.styleFrom(
                  foregroundColor: MangoColors.darkGray,
                  padding: const EdgeInsets.symmetric(horizontal: 0),
                ),
                onPressed: () => context.go(AppRoutes.reports),
                icon: const Icon(Icons.arrow_back),
                label: const Text('Regresar'),
              ),
              const SizedBox(height: 12),
              const Text(
                'Ventas por mesero',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  color: MangoColors.darkGray,
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                'Suma de items agregados por cada mesero. Si un item no '
                'tiene mesero asignado, se atribuye al que abrió la mesa.',
                style: TextStyle(fontSize: 13, color: MangoColors.muted),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  OutlinedButton.icon(
                    onPressed: _pickDateRange,
                    icon: const Icon(Icons.calendar_today, size: 16),
                    label: Text(
                      '${dateFormat.format(_from)} → ${dateFormat.format(_to)}',
                    ),
                  ),
                  SizedBox(
                    width: 260,
                    child: RawAutocomplete<String>(
                      textEditingController: _searchController,
                      focusNode: _searchFocusNode,
                      optionsBuilder: (textEditingValue) {
                        final q = textEditingValue.text.trim().toLowerCase();
                        if (q.isEmpty) return _productOptions;
                        return _productOptions.where(
                          (n) => n.toLowerCase().contains(q),
                        );
                      },
                      onSelected: _selectProduct,
                      optionsViewBuilder: (ctx, onSelected, options) {
                        return Align(
                          alignment: Alignment.topLeft,
                          child: Material(
                            elevation: 4,
                            borderRadius: BorderRadius.circular(10),
                            clipBehavior: Clip.antiAlias,
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(
                                maxHeight: 280,
                                maxWidth: 260,
                              ),
                              child: ListView.builder(
                                padding: EdgeInsets.zero,
                                shrinkWrap: true,
                                itemCount: options.length,
                                itemBuilder: (ctx, i) {
                                  final option = options.elementAt(i);
                                  return ListTile(
                                    dense: true,
                                    title: Text(
                                      option,
                                      style: const TextStyle(fontSize: 13),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    onTap: () => onSelected(option),
                                  );
                                },
                              ),
                            ),
                          ),
                        );
                      },
                      fieldViewBuilder:
                          (ctx, controller, focusNode, onFieldSubmitted) {
                            return TextField(
                              controller: controller,
                              focusNode: focusNode,
                              onChanged: _onSearchChanged,
                              onSubmitted: (_) => onFieldSubmitted(),
                              textInputAction: TextInputAction.search,
                              decoration: InputDecoration(
                                hintText: 'Seleccionar producto…',
                                hintStyle: const TextStyle(
                                  fontSize: 13,
                                  color: MangoColors.muted,
                                ),
                                prefixIcon: const Icon(Icons.search, size: 18),
                                suffixIcon:
                                    _search.isNotEmpty ||
                                        _searchController.text.isNotEmpty
                                    ? IconButton(
                                        tooltip: 'Limpiar',
                                        icon: const Icon(Icons.close, size: 16),
                                        onPressed: _clearSearch,
                                      )
                                    : const Icon(
                                        Icons.arrow_drop_down,
                                        size: 20,
                                      ),
                                isDense: true,
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 10,
                                ),
                                filled: true,
                                fillColor: Colors.white,
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(10),
                                  borderSide: const BorderSide(
                                    color: Color(0xFFE5E7EB),
                                  ),
                                ),
                                enabledBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(10),
                                  borderSide: const BorderSide(
                                    color: Color(0xFFE5E7EB),
                                  ),
                                ),
                              ),
                            );
                          },
                    ),
                  ),
                  IconButton(
                    tooltip: 'Refrescar',
                    icon: const Icon(Icons.refresh),
                    onPressed: _reload,
                  ),
                  OutlinedButton.icon(
                    onPressed: _exporting ? null : _exportPdf,
                    icon: _exporting
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.picture_as_pdf, size: 16),
                    label: Text(_exporting ? 'Exportando…' : 'Exportar PDF'),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Expanded(
                child: FutureBuilder<_WaiterReportData>(
                  future: _future,
                  builder: (ctx, snap) {
                    if (snap.connectionState == ConnectionState.waiting) {
                      return const Center(
                        child: CircularProgressIndicator(
                          valueColor: AlwaysStoppedAnimation(
                            MangoColors.primaryOrange,
                          ),
                        ),
                      );
                    }
                    if (snap.hasError) {
                      return Center(
                        child: Text(
                          'Error: ${snap.error}',
                          style: const TextStyle(color: Color(0xFFDC2626)),
                        ),
                      );
                    }
                    final (rows, productRows) =
                        snap.data ??
                        (const <WaiterSalesRow>[], const <WaiterProductRow>[]);
                    if (rows.isEmpty) {
                      final filtering = _search.isNotEmpty;
                      return Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              filtering
                                  ? Icons.search_off
                                  : Icons.people_outline,
                              size: 64,
                              color: MangoColors.muted,
                            ),
                            const SizedBox(height: 12),
                            Text(
                              filtering
                                  ? 'Sin ventas de "$_search" en el rango'
                                  : 'Sin ventas atribuidas en el rango',
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                                color: MangoColors.darkGray,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              filtering
                                  ? 'Prueba con otro nombre de producto o '
                                        'limpia el filtro.'
                                  : 'Activa el modo multimesero en '
                                        'Configuración → Modos de negocio para '
                                        'empezar a trackear ventas por mesero.',
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontSize: 12,
                                color: MangoColors.muted,
                              ),
                            ),
                          ],
                        ),
                      );
                    }

                    final totalGross = rows.fold<double>(
                      0,
                      (s, r) => s + r.grossAmount,
                    );
                    final totalNet = rows.fold<double>(
                      0,
                      (s, r) => s + r.netAmount,
                    );
                    final totalItems = rows.fold<int>(
                      0,
                      (s, r) => s + r.itemsCount,
                    );

                    // En teléfono la tabla de 6 columnas no cabe (avatar +
                    // montos se aplastan). Renderizamos cada mesero como una
                    // tarjeta apilada, más una tarjeta de totales al final.
                    if (ResponsiveHelper.isMobile(ctx)) {
                      return ListView(
                        padding: EdgeInsets.zero,
                        children: [
                          ...rows.map(
                            (r) => ReportRecordCard(
                              title: r.employeeName.isNotEmpty
                                  ? r.employeeName
                                  : 'Sin mesero',
                              fields: [
                                ReportRecordField(
                                  'Órdenes',
                                  numberFormat.format(r.ordersCount),
                                ),
                                ReportRecordField(
                                  'Items',
                                  numberFormat.format(r.itemsCount),
                                ),
                                ReportRecordField(
                                  'Bruto',
                                  currency.format(r.grossAmount),
                                ),
                                ReportRecordField(
                                  'Descuentos',
                                  currency.format(r.discountsAmount),
                                  valueColor: r.discountsAmount > 0
                                      ? const Color(0xFFDC2626)
                                      : MangoColors.muted,
                                ),
                                ReportRecordField(
                                  'Neto',
                                  currency.format(r.netAmount),
                                  emphasize: true,
                                ),
                              ],
                            ),
                          ),
                          ReportRecordCard(
                            title: 'Total',
                            highlight: true,
                            fields: [
                              ReportRecordField(
                                'Items',
                                numberFormat.format(totalItems),
                              ),
                              ReportRecordField(
                                'Bruto',
                                currency.format(totalGross),
                              ),
                              ReportRecordField(
                                'Neto',
                                currency.format(totalNet),
                                valueColor: MangoColors.primaryOrange,
                                emphasize: true,
                              ),
                            ],
                          ),
                          ..._buildProductBreakdown(
                            rows,
                            productRows,
                            currency,
                          ),
                        ],
                      );
                    }

                    return ListView(
                      padding: EdgeInsets.zero,
                      children: [
                        Container(
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: const Color(0xFFE5E7EB)),
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              // Header
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 12,
                                ),
                                decoration: const BoxDecoration(
                                  color: Color(0xFFF8FAFC),
                                  borderRadius: BorderRadius.vertical(
                                    top: Radius.circular(14),
                                  ),
                                ),
                                child: const Row(
                                  children: [
                                    Expanded(
                                      flex: 4,
                                      child: Text(
                                        'Mesero',
                                        style: TextStyle(
                                          fontWeight: FontWeight.w700,
                                          fontSize: 12,
                                          color: MangoColors.muted,
                                        ),
                                      ),
                                    ),
                                    Expanded(
                                      flex: 2,
                                      child: Text(
                                        'Órdenes',
                                        textAlign: TextAlign.end,
                                        style: TextStyle(
                                          fontWeight: FontWeight.w700,
                                          fontSize: 12,
                                          color: MangoColors.muted,
                                        ),
                                      ),
                                    ),
                                    Expanded(
                                      flex: 2,
                                      child: Text(
                                        'Items',
                                        textAlign: TextAlign.end,
                                        style: TextStyle(
                                          fontWeight: FontWeight.w700,
                                          fontSize: 12,
                                          color: MangoColors.muted,
                                        ),
                                      ),
                                    ),
                                    Expanded(
                                      flex: 3,
                                      child: Text(
                                        'Bruto',
                                        textAlign: TextAlign.end,
                                        style: TextStyle(
                                          fontWeight: FontWeight.w700,
                                          fontSize: 12,
                                          color: MangoColors.muted,
                                        ),
                                      ),
                                    ),
                                    Expanded(
                                      flex: 3,
                                      child: Text(
                                        'Descuentos',
                                        textAlign: TextAlign.end,
                                        style: TextStyle(
                                          fontWeight: FontWeight.w700,
                                          fontSize: 12,
                                          color: MangoColors.muted,
                                        ),
                                      ),
                                    ),
                                    Expanded(
                                      flex: 3,
                                      child: Text(
                                        'Neto',
                                        textAlign: TextAlign.end,
                                        style: TextStyle(
                                          fontWeight: FontWeight.w700,
                                          fontSize: 12,
                                          color: MangoColors.muted,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              ListView.separated(
                                shrinkWrap: true,
                                physics: const NeverScrollableScrollPhysics(),
                                itemCount: rows.length,
                                separatorBuilder: (_, _) => const Divider(
                                  height: 1,
                                  color: Color(0xFFF1F5F9),
                                ),
                                itemBuilder: (ctx, i) {
                                  final r = rows[i];
                                  return Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 16,
                                      vertical: 14,
                                    ),
                                    child: Row(
                                      children: [
                                        Expanded(
                                          flex: 4,
                                          child: Row(
                                            children: [
                                              CircleAvatar(
                                                radius: 16,
                                                backgroundColor: MangoColors
                                                    .primaryOrange
                                                    .withValues(alpha: 0.12),
                                                child: Text(
                                                  r.employeeName.isNotEmpty
                                                      ? r.employeeName[0]
                                                            .toUpperCase()
                                                      : '?',
                                                  style: const TextStyle(
                                                    color: MangoColors
                                                        .primaryOrange,
                                                    fontWeight: FontWeight.w800,
                                                  ),
                                                ),
                                              ),
                                              const SizedBox(width: 10),
                                              Expanded(
                                                child: Text(
                                                  r.employeeName,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: const TextStyle(
                                                    fontWeight: FontWeight.w600,
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        Expanded(
                                          flex: 2,
                                          child: Text(
                                            numberFormat.format(r.ordersCount),
                                            textAlign: TextAlign.end,
                                          ),
                                        ),
                                        Expanded(
                                          flex: 2,
                                          child: Text(
                                            numberFormat.format(r.itemsCount),
                                            textAlign: TextAlign.end,
                                          ),
                                        ),
                                        Expanded(
                                          flex: 3,
                                          child: Text(
                                            currency.format(r.grossAmount),
                                            textAlign: TextAlign.end,
                                          ),
                                        ),
                                        Expanded(
                                          flex: 3,
                                          child: Text(
                                            currency.format(r.discountsAmount),
                                            textAlign: TextAlign.end,
                                            style: TextStyle(
                                              color: r.discountsAmount > 0
                                                  ? const Color(0xFFDC2626)
                                                  : MangoColors.muted,
                                            ),
                                          ),
                                        ),
                                        Expanded(
                                          flex: 3,
                                          child: Text(
                                            currency.format(r.netAmount),
                                            textAlign: TextAlign.end,
                                            style: const TextStyle(
                                              fontWeight: FontWeight.w800,
                                              color: MangoColors.darkGray,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  );
                                },
                              ),
                              // Footer con totales
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 14,
                                ),
                                decoration: const BoxDecoration(
                                  color: Color(0xFFFFF7ED),
                                  borderRadius: BorderRadius.vertical(
                                    bottom: Radius.circular(14),
                                  ),
                                  border: Border(
                                    top: BorderSide(color: Color(0xFFFFD7B5)),
                                  ),
                                ),
                                child: Row(
                                  children: [
                                    const Expanded(
                                      flex: 4,
                                      child: Text(
                                        'Total',
                                        style: TextStyle(
                                          fontWeight: FontWeight.w800,
                                          color: MangoColors.darkGray,
                                        ),
                                      ),
                                    ),
                                    const Expanded(flex: 2, child: SizedBox()),
                                    Expanded(
                                      flex: 2,
                                      child: Text(
                                        numberFormat.format(totalItems),
                                        textAlign: TextAlign.end,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w800,
                                        ),
                                      ),
                                    ),
                                    Expanded(
                                      flex: 3,
                                      child: Text(
                                        currency.format(totalGross),
                                        textAlign: TextAlign.end,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w800,
                                        ),
                                      ),
                                    ),
                                    const Expanded(flex: 3, child: SizedBox()),
                                    Expanded(
                                      flex: 3,
                                      child: Text(
                                        currency.format(totalNet),
                                        textAlign: TextAlign.end,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w800,
                                          color: MangoColors.primaryOrange,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                        ..._buildProductBreakdown(rows, productRows, currency),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
