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

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:mangopos/core/currency/business_currency_provider.dart';

import 'package:mangopos/app/router/routes.dart';
import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/core/theme/app_breakpoints.dart';
import 'package:mangopos/data/repositories/sales_by_waiter_repository.dart';
import 'package:mangopos/presentation/reports/widgets/report_widgets.dart';
import 'package:mangopos/services/session/session_controller.dart';

class SalesByWaiterView extends ConsumerStatefulWidget {
  const SalesByWaiterView({super.key});

  @override
  ConsumerState<SalesByWaiterView> createState() => _SalesByWaiterViewState();
}

class _SalesByWaiterViewState extends ConsumerState<SalesByWaiterView> {
  late DateTime _from;
  late DateTime _to;
  Future<List<WaiterSalesRow>>? _future;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _to = DateTime(now.year, now.month, now.day);
    _from = _to.subtract(const Duration(days: 6));
    _reload();
  }

  void _reload() {
    final businessId = ref.read(sessionProvider).activeBusinessId;
    if (businessId == null || businessId.isEmpty) {
      setState(() => _future = Future.value(const []));
      return;
    }
    setState(() {
      _future = ref
          .read(salesByWaiterRepositoryProvider)
          .fetch(businessId: businessId, from: _from, to: _to);
    });
  }

  Future<void> _pickDateRange() async {
    final range = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
      initialDateRange: DateTimeRange(start: _from, end: _to),
      builder: (ctx, child) => Theme(
        data: Theme.of(ctx).copyWith(
          colorScheme: ColorScheme.fromSeed(seedColor: MangoColors.primaryOrange),
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
              Row(
                children: [
                  OutlinedButton.icon(
                    onPressed: _pickDateRange,
                    icon: const Icon(Icons.calendar_today, size: 16),
                    label: Text(
                      '${dateFormat.format(_from)} → ${dateFormat.format(_to)}',
                    ),
                  ),
                  const SizedBox(width: 12),
                  IconButton(
                    tooltip: 'Refrescar',
                    icon: const Icon(Icons.refresh),
                    onPressed: _reload,
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Expanded(
                child: FutureBuilder<List<WaiterSalesRow>>(
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
                    final rows = snap.data ?? const [];
                    if (rows.isEmpty) {
                      return Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.people_outline,
                              size: 64,
                              color: MangoColors.muted,
                            ),
                            const SizedBox(height: 12),
                            const Text(
                              'Sin ventas atribuidas en el rango',
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                color: MangoColors.darkGray,
                              ),
                            ),
                            const SizedBox(height: 4),
                            const Text(
                              'Activa el modo multimesero en Configuración → '
                              'Modos de negocio para empezar a trackear ventas '
                              'por mesero.',
                              textAlign: TextAlign.center,
                              style: TextStyle(
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
                                ReportRecordField('Órdenes',
                                    numberFormat.format(r.ordersCount)),
                                ReportRecordField('Items',
                                    numberFormat.format(r.itemsCount)),
                                ReportRecordField(
                                    'Bruto', currency.format(r.grossAmount)),
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
                                  'Items', numberFormat.format(totalItems)),
                              ReportRecordField(
                                  'Bruto', currency.format(totalGross)),
                              ReportRecordField(
                                'Neto',
                                currency.format(totalNet),
                                valueColor: MangoColors.primaryOrange,
                                emphasize: true,
                              ),
                            ],
                          ),
                        ],
                      );
                    }

                    return Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: const Color(0xFFE5E7EB)),
                      ),
                      child: Column(
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
                          Expanded(
                            child: ListView.separated(
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
