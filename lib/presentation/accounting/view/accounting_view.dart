import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'package:mangopos/core/currency/business_currency.dart';
import 'package:mangopos/core/currency/business_currency_provider.dart';
import 'package:mangopos/core/theme/app_colors.dart';
import 'package:mangopos/core/theme/app_spacing.dart';
import 'package:mangopos/core/utils/app_toast.dart';
import 'package:mangopos/core/utils/export/report_exporter.dart';
import 'package:mangopos/data/models/accounting_models.dart';
import 'package:mangopos/presentation/accounting/viewmodel/accounting_viewmodel.dart';
import 'package:mangopos/presentation/accounting/widgets/accounting_dialogs.dart';
import 'package:mangopos/presentation/accounting/widgets/accounting_ui.dart';
import 'package:mangopos/presentation/accounting/widgets/quick_entry_dialog.dart';
import 'package:mangopos/services/session/session_controller.dart';

/// Pestañas del módulo contable. El orden define el índice del TabBar y los
/// valores de `?tab=` con los que Más Opciones entra directo a cada una.
enum AccountingTab { entries, catalog, trialBalance, income, balance, periods }

/// Resuelve `?tab=` de la URL. Mismo patrón que Reportes
/// (`_reportCategoryFromQuery` en app_router.dart).
AccountingTab accountingTabFromQuery(String? value) => switch (value) {
      'catalog' => AccountingTab.catalog,
      'trial' => AccountingTab.trialBalance,
      'income' => AccountingTab.income,
      'balance' => AccountingTab.balance,
      'periods' => AccountingTab.periods,
      _ => AccountingTab.entries,
    };

/// Módulo de Contabilidad (PRD_CONTABILIDAD.md, Fase 1).
///
/// Seis pestañas sobre el mismo rango de fechas: asientos, catálogo, balanza,
/// estado de resultados, balance general y períodos. Los asientos automáticos
/// se generan por lote desde acá — el POS nunca los dispara solo.
class AccountingView extends ConsumerStatefulWidget {
  /// Pestaña con la que abre. Permite que cada tarjeta de Más Opciones caiga
  /// directo en su sección en vez de obligar a buscarla en el TabBar.
  final AccountingTab initialTab;

  const AccountingView({super.key, this.initialTab = AccountingTab.entries});

  @override
  ConsumerState<AccountingView> createState() => _AccountingViewState();
}

class _AccountingViewState extends ConsumerState<AccountingView>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  String? _lastBusinessId;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: 6,
      initialIndex: widget.initialTab.index,
      vsync: this,
    );
    _tabController.addListener(_onTabChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await ref.read(accountingViewModelProvider).init();
      // El listener del TabController no dispara en el arranque, así que la
      // pestaña con la que se entró carga su reporte a mano.
      if (mounted) _loadReportForTab(_tabController.index);
    });
  }

  @override
  void dispose() {
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    super.dispose();
  }

  /// Cada reporte se carga cuando se entra a su pestaña, no en el init.
  void _onTabChanged() {
    if (!mounted || _tabController.indexIsChanging) return;
    _loadReportForTab(_tabController.index);
    setState(() {});
  }

  void _loadReportForTab(int index) {
    final vm = ref.read(accountingViewModelProvider);
    if (!vm.initialized) return;
    switch (index) {
      case 2:
        if (vm.trialBalance.isEmpty) vm.loadTrialBalance();
        break;
      case 3:
        if (vm.incomeStatement.isEmpty) vm.loadIncomeStatement();
        break;
      case 4:
        if (vm.balanceSheet.isEmpty) vm.loadBalanceSheet();
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider);
    final canSeeReports = ref
        .watch(sessionProvider.notifier)
        .hasPermission('contabilidad.reportes');
    final vm = ref.watch(accountingViewModelProvider);
    final currency = currentBusinessCurrencyOrFallback(ref);

    if (session.activeBusinessId != null &&
        session.activeBusinessId != _lastBusinessId) {
      _lastBusinessId = session.activeBusinessId;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) ref.read(accountingViewModelProvider).init();
      });
    }

    final isNarrow = MediaQuery.sizeOf(context).width < 900;
    final pad = isNarrow ? AppSpacing.lg : AppSpacing.xxl;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(pad, pad, pad, AppSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _headerCard(vm, isNarrow),
              if (vm.error != null) ...[
                const SizedBox(height: AppSpacing.md),
                _errorBanner(vm.error!),
              ],
              const SizedBox(height: AppSpacing.lg),
              if (vm.isLoading)
                const Expanded(
                    child: Center(child: CircularProgressIndicator()))
              else if (!vm.initialized)
                Expanded(child: AccountingCard(child: _notInitialized(vm)))
              else
                Expanded(
                  child: TabBarView(
                    controller: _tabController,
                    children: [
                      _EntriesTab(vm: vm, currency: currency),
                      _CatalogTab(vm: vm),
                      // Balanza, estado de resultados y balance general son
                      // los estados financieros: `contabilidad.reportes`.
                      // Mantenemos las 6 pestañas (el TabController es de
                      // largo fijo) y sustituimos el contenido por un aviso.
                      if (canSeeReports)
                        _TrialBalanceTab(vm: vm, currency: currency)
                      else
                        const _NoReportAccess(),
                      if (canSeeReports)
                        _IncomeStatementTab(vm: vm, currency: currency)
                      else
                        const _NoReportAccess(),
                      if (canSeeReports)
                        _BalanceSheetTab(vm: vm, currency: currency)
                      else
                        const _NoReportAccess(),
                      _PeriodsTab(vm: vm),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Encabezado: título + acciones + pestañas, todo en una card ────────────

  Widget _headerCard(AccountingViewModel vm, bool isNarrow) {
    // `contabilidad.acceso` gatea la ruta; crear asientos es otra cosa.
    // Antes cualquiera que abriera Contabilidad podía postear al libro mayor.
    final canCreateEntries = ref
        .watch(sessionProvider.notifier)
        .hasPermission('contabilidad.asientos.crear');
    final df = DateFormat('dd/MM/yyyy');
    return AccountingCard(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            alignment: WrapAlignment.spaceBetween,
            spacing: AppSpacing.md,
            runSpacing: AppSpacing.md,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: AppColors.primary.withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.account_balance_rounded,
                        size: 20, color: AppColors.primary),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  const Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Contabilidad',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w800,
                            color: AppColors.foreground,
                          )),
                      Text('Partida doble sobre las operaciones del POS',
                          style: TextStyle(
                              fontSize: 12,
                              color: AppColors.mutedForeground)),
                    ],
                  ),
                ],
              ),
              if (vm.initialized)
                Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: AppSpacing.sm,
                  runSpacing: AppSpacing.sm,
                  children: [
                    OutlinedButton.icon(
                      icon: const Icon(Icons.date_range_rounded, size: 16),
                      label: Text('${df.format(vm.from)} — ${df.format(vm.to)}'),
                      onPressed: () async {
                        final picked = await showDateRangePicker(
                          context: context,
                          firstDate: DateTime(2020),
                          lastDate:
                              DateTime.now().add(const Duration(days: 365)),
                          initialDateRange:
                              DateTimeRange(start: vm.from, end: vm.to),
                        );
                        if (picked != null) vm.setRange(picked.start, picked.end);
                      },
                    ),
                    if (vm.isCurrentRangeClosed)
                      const AccountingBadge(
                          text: 'MES CERRADO', color: AppColors.destructive),
                    if (canCreateEntries)
                      FilledButton.icon(
                        icon: const Icon(Icons.auto_awesome_rounded, size: 16),
                        label: Text(
                            isNarrow ? 'Generar' : 'Generar automáticos'),
                        onPressed: vm.isBusy
                            ? null
                            : () async {
                                final msg = await vm.generateAutomatic();
                                if (!mounted || msg == null) return;
                                _toast(msg, isError: vm.error != null);
                              },
                      ),
                    if (canCreateEntries)
                      FilledButton.tonalIcon(
                        icon: const Icon(Icons.bolt_rounded, size: 16),
                        label: Text(isNarrow ? 'Rápido' : 'Asiento rápido'),
                        onPressed: vm.isBusy ? null : () => _quickEntry(vm),
                      ),
                    if (canCreateEntries)
                      OutlinedButton.icon(
                        icon: const Icon(Icons.post_add_rounded, size: 16),
                        label: Text(isNarrow ? 'Manual' : 'Asiento manual'),
                        onPressed: vm.isBusy ? null : () => _newEntry(vm),
                      ),
                    IconButton(
                      tooltip: 'Actualizar',
                      icon: vm.isBusy || vm.isLoading
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child:
                                  CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.refresh_rounded),
                      onPressed:
                          vm.isLoading ? null : () => vm.reload(),
                    ),
                  ],
                ),
            ],
          ),
          if (vm.initialized) ...[
            const SizedBox(height: AppSpacing.sm),
            TabBar(
              controller: _tabController,
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              labelColor: AppColors.primary,
              unselectedLabelColor: AppColors.mutedForeground,
              indicatorColor: AppColors.primary,
              indicatorSize: TabBarIndicatorSize.label,
              dividerColor: Colors.transparent,
              labelStyle: const TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w700),
              unselectedLabelStyle: const TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w500),
              tabs: const [
                Tab(text: 'Asientos'),
                Tab(text: 'Catálogo'),
                Tab(text: 'Balanza'),
                Tab(text: 'Estado de resultados'),
                Tab(text: 'Balance general'),
                Tab(text: 'Períodos'),
              ],
            ),
          ] else
            const SizedBox(height: AppSpacing.lg),
        ],
      ),
    );
  }

  Widget _errorBanner(String message) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(kAcctRadius),
        border: Border.all(color: AppColors.destructive.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline_rounded,
              size: 18, color: AppColors.destructive),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(message,
                style: const TextStyle(
                    color: AppColors.destructive, fontSize: 13)),
          ),
        ],
      ),
    );
  }

  Widget _notInitialized(AccountingViewModel vm) {
    return AccountingEmpty(
      icon: Icons.account_balance_rounded,
      title: 'Contabilidad sin inicializar',
      subtitle:
          'Se va a crear el catálogo de cuentas estándar y el mapeo de eventos '
          'del POS a cuentas contables. Puedes editar todo después: nada queda '
          'fijo en código.',
      action: FilledButton.icon(
        icon: const Icon(Icons.play_arrow_rounded),
        label: const Text('Inicializar contabilidad'),
        onPressed: vm.isBusy
            ? null
            : () async {
                final msg = await vm.seedChart();
                if (!mounted || msg == null) return;
                _toast(msg, isError: vm.error != null);
              },
      ),
    );
  }

  /// Asiento rápido: plantilla de dos líneas (gasto, ingreso, aporte,
  /// depósito, retiro). Mismo posteo que el manual, sin armar el asiento.
  Future<void> _quickEntry(AccountingViewModel vm) async {
    final res = await showQuickEntryDialog(
      context,
      accounts: vm.postableAccounts,
    );
    if (res == null || !mounted) return;
    final msg = await vm.postEntry(
      date: res.date,
      description: res.description,
      lines: res.lines,
    );
    if (!mounted || msg == null) return;
    _toast(msg, isError: vm.error != null);
  }

  Future<void> _newEntry(AccountingViewModel vm) async {
    final draft = await showJournalEntryDialog(
      context,
      accounts: vm.postableAccounts,
      costCenters: vm.costCenters,
    );
    if (draft == null || !mounted) return;
    final msg = await vm.postEntry(
      date: draft.date,
      description: draft.description,
      lines: draft.lines,
      reference: draft.reference,
    );
    if (!mounted || msg == null) return;
    _toast(msg, isError: vm.error != null);
  }

  void _toast(String message, {bool isError = false}) {
    if (isError) {
      AppToast.error(context, message);
    } else {
      AppToast.success(context, message);
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Pestaña: asientos (libro diario)
// ─────────────────────────────────────────────────────────────────────────────

class _EntriesTab extends StatelessWidget {
  final AccountingViewModel vm;
  final BusinessCurrency currency;

  const _EntriesTab({required this.vm, required this.currency});

  @override
  Widget build(BuildContext context) {
    final df = DateFormat('dd/MM/yyyy');

    if (vm.entries.isEmpty) {
      return const AccountingCard(
        child: AccountingEmpty(
          icon: Icons.receipt_long_rounded,
          title: 'Sin asientos en el rango',
          subtitle: 'Usa "Generar automáticos" para traer ventas, compras, '
              'movimientos de caja y créditos del período.',
        ),
      );
    }

    final totalDebit = vm.entries.fold(0.0, (s, e) => s + e.totalDebit);

    return AccountingCard(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AccountingCardHeader(
            title: 'Libro diario',
            subtitle:
                '${vm.entries.length} asientos · ${currency.formatAmount(totalDebit)} '
                'movidos · toca una fila para ver sus líneas',
            trailing: _ExportMenu(
              filename: 'libro_diario',
              title: 'Libro Diario',
              subtitle: '${df.format(vm.from)} — ${df.format(vm.to)}',
              headers: const [
                'Número',
                'Fecha',
                'Descripción',
                'Origen',
                'Estado',
                'Débito',
                'Crédito'
              ],
              rows: [
                for (final e in vm.entries)
                  [
                    e.number.toString(),
                    df.format(e.date),
                    e.description,
                    e.sourceLabel,
                    e.status,
                    e.totalDebit.toStringAsFixed(2),
                    e.totalCredit.toStringAsFixed(2),
                  ],
              ],
              numericColumns: const [5, 6],
              landscape: true,
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          Expanded(
            child: AccountingTable(
              minWidth: 820,
              columns: const [
                AcctColumn('N°', width: 64),
                AcctColumn('Fecha', width: 104),
                AcctColumn('Descripción', flex: 4),
                AcctColumn('Origen', width: 124),
                AcctColumn('Debe', width: 130, numeric: true),
                AcctColumn('Haber', width: 130, numeric: true),
              ],
              rows: [
                for (final e in vm.entries)
                  AcctRow(
                    [
                      Text('#${e.number}',
                          style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              color: AppColors.mutedForeground)),
                      Text(df.format(e.date)),
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              e.description,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                decoration: e.isReversed
                                    ? TextDecoration.lineThrough
                                    : null,
                                color: e.isReversed
                                    ? AppColors.mutedForeground
                                    : null,
                              ),
                            ),
                          ),
                          if (e.isReversed) ...[
                            const SizedBox(width: AppSpacing.sm),
                            const AccountingBadge(
                                text: 'Revertido',
                                color: AppColors.destructive),
                          ],
                        ],
                      ),
                      AccountingBadge(text: e.sourceLabel),
                      Text(currency.formatAmount(e.totalDebit)),
                      Text(currency.formatAmount(e.totalCredit)),
                    ],
                    expanded: _EntryLines(
                        entry: e, vm: vm, currency: currency),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Sustituto de las pestañas de estados financieros para quien tiene acceso
/// al módulo pero no `contabilidad.reportes`.
class _NoReportAccess extends StatelessWidget {
  const _NoReportAccess();

  @override
  Widget build(BuildContext context) {
    return const AccountingCard(
      child: AccountingEmpty(
        icon: Icons.lock_outline_rounded,
        title: 'Sin acceso a los estados financieros',
        subtitle: 'Necesitas el permiso "Reportes contables" para ver la '
            'balanza, el estado de resultados y el balance general.',
      ),
    );
  }
}

/// Detalle de líneas de un asiento, con la acción de revertir.
class _EntryLines extends ConsumerWidget {
  final AccountingEntry entry;
  final AccountingViewModel vm;
  final BusinessCurrency currency;

  const _EntryLines({
    required this.entry,
    required this.vm,
    required this.currency,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: vm.entryLines(entry.id),
      builder: (context, snap) {
        if (!snap.hasData) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: AppSpacing.md),
            child: LinearProgressIndicator(minHeight: 2),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (entry.reference != null && entry.reference!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                child: Text('Referencia: ${entry.reference}',
                    style: const TextStyle(
                        fontSize: 12, color: AppColors.mutedForeground)),
              ),
            for (final l in snap.data!) _line(l),
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: [
                Text(
                  entry.isReversal
                      ? 'Este asiento es una reversión.'
                      : entry.isReversed
                          ? 'Asiento revertido: el espejo está en la lista.'
                          : '',
                  style: const TextStyle(
                      fontSize: 12, color: AppColors.mutedForeground),
                ),
                const Spacer(),
                // Revertir un asiento contrapartea el libro mayor:
                // `contabilidad.asientos.anular`.
                if (!entry.isReversed &&
                    !entry.isReversal &&
                    ref
                        .read(sessionProvider.notifier)
                        .hasPermission('contabilidad.asientos.anular'))
                  TextButton.icon(
                    icon: const Icon(Icons.undo_rounded, size: 16),
                    label: const Text('Revertir'),
                    onPressed: () => _confirmReverse(context),
                  ),
              ],
            ),
          ],
        );
      },
    );
  }

  Widget _line(Map<String, dynamic> l) {
    final account = l['accounting_accounts'] as Map<String, dynamic>?;
    final cc = l['accounting_cost_centers'] as Map<String, dynamic>?;
    final debit = (l['debit'] as num?)?.toDouble() ?? 0;
    final credit = (l['credit'] as num?)?.toDouble() ?? 0;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 78,
            child: Text('${account?['code'] ?? ''}',
                style: const TextStyle(
                    fontSize: 12, color: AppColors.mutedForeground)),
          ),
          Expanded(
            child: Text(
              '${account?['name'] ?? ''}'
              '${cc != null ? '  ·  ${cc['name']}' : ''}'
              '${l['description'] != null ? '  —  ${l['description']}' : ''}',
              style: const TextStyle(fontSize: 13),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          SizedBox(
            width: 130,
            child: Text(debit > 0 ? currency.formatAmount(debit) : '',
                textAlign: TextAlign.right,
                style: const TextStyle(fontSize: 13)),
          ),
          SizedBox(
            width: 130,
            child: Text(credit > 0 ? currency.formatAmount(credit) : '',
                textAlign: TextAlign.right,
                style: const TextStyle(fontSize: 13)),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmReverse(BuildContext context) async {
    final reasonCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Revertir asiento #${entry.number}'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'El asiento original NO se borra. Se emite un asiento espejo '
                'con la fecha de hoy y ambos quedan enlazados.',
                style: TextStyle(color: AppColors.mutedForeground),
              ),
              const SizedBox(height: AppSpacing.md),
              TextField(
                controller: reasonCtrl,
                decoration: const InputDecoration(
                  labelText: 'Motivo',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Revertir'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    final msg =
        await vm.reverseEntry(entry.id, reason: reasonCtrl.text.trim());
    if (!context.mounted || msg == null) return;
    if (vm.error != null) {
      AppToast.error(context, msg);
    } else {
      AppToast.success(context, msg);
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Pestaña: catálogo (cuentas, centros de costo, mapeos)
// ─────────────────────────────────────────────────────────────────────────────

class _CatalogTab extends ConsumerStatefulWidget {
  final AccountingViewModel vm;
  const _CatalogTab({required this.vm});

  @override
  ConsumerState<_CatalogTab> createState() => _CatalogTabState();
}

class _CatalogTabState extends ConsumerState<_CatalogTab> {
  int _section = 0;

  @override
  Widget build(BuildContext context) {
    final vm = widget.vm;
    // Alta/edición del catálogo de cuentas y centros de costo:
    // `contabilidad.catalogo.gestionar`.
    final canManageCatalog = ref
        .watch(sessionProvider.notifier)
        .hasPermission('contabilidad.catalogo.gestionar');
    return AccountingCard(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AccountingCardHeader(
            title: switch (_section) {
              1 => 'Centros de costo',
              2 => 'Mapeo contable',
              _ => 'Catálogo de cuentas',
            },
            subtitle: switch (_section) {
              1 => 'Centros de costo, departamentos, proyectos y sucursales '
                  'para clasificar las líneas de asiento',
              2 => 'Qué cuenta usa cada evento del POS al generar los asientos '
                  'automáticos',
              _ => '${vm.accounts.length} cuentas · las de agrupación no '
                  'admiten asientos',
            },
            trailing: !canManageCatalog
                ? null
                : switch (_section) {
                    0 => OutlinedButton.icon(
                        icon: const Icon(Icons.add_rounded, size: 16),
                        label: const Text('Nueva cuenta'),
                        onPressed: () => _editAccount(null),
                      ),
                    1 => OutlinedButton.icon(
                        icon: const Icon(Icons.add_rounded, size: 16),
                        label: const Text('Nuevo centro'),
                        onPressed: () => _editCostCenter(null),
                      ),
                    _ => null,
                  },
          ),
          const SizedBox(height: AppSpacing.md),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SegmentedButton<int>(
              style: const ButtonStyle(visualDensity: VisualDensity.compact),
              segments: const [
                ButtonSegment(value: 0, label: Text('Cuentas')),
                ButtonSegment(value: 1, label: Text('Centros de costo')),
                ButtonSegment(value: 2, label: Text('Mapeo contable')),
              ],
              selected: {_section},
              onSelectionChanged: (s) {
                setState(() => _section = s.first);
                if (_section == 2 && vm.mappings.isEmpty) vm.loadMappings();
              },
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          const Divider(height: 1, color: AppColors.border),
          Expanded(child: switch (_section) {
            1 => _costCenters(),
            2 => _mappings(),
            _ => _accounts(),
          }),
        ],
      ),
    );
  }

  Widget _accounts() {
    final canManageCatalog = ref
        .watch(sessionProvider.notifier)
        .hasPermission('contabilidad.catalogo.gestionar');
    final vm = widget.vm;
    if (vm.accounts.isEmpty) {
      return const AccountingEmpty(
        icon: Icons.list_alt_rounded,
        title: 'Catálogo vacío',
        subtitle: 'Crea cuentas o vuelve a inicializar el catálogo estándar.',
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.only(top: AppSpacing.sm),
      itemCount: vm.accounts.length,
      separatorBuilder: (_, _) =>
          Divider(height: 1, color: AppColors.border.withValues(alpha: 0.55)),
      itemBuilder: (context, i) {
        final a = vm.accounts[i];
        final dim = !a.isActive;
        return Padding(
          padding: EdgeInsets.fromLTRB(
              AppSpacing.xs + a.depth * 18, AppSpacing.sm, 0, AppSpacing.sm),
          child: Row(
            children: [
              Icon(
                a.isPostable
                    ? Icons.article_outlined
                    : Icons.folder_rounded,
                size: 17,
                color: dim
                    ? AppColors.border
                    : (a.isPostable
                        ? AppColors.mutedForeground
                        : AppColors.primary),
              ),
              const SizedBox(width: AppSpacing.sm),
              SizedBox(
                width: 76,
                child: Text(a.code,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color:
                          dim ? AppColors.border : AppColors.mutedForeground,
                    )),
              ),
              Expanded(
                child: Text(
                  a.name,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight:
                        a.isPostable ? FontWeight.w500 : FontWeight.w800,
                    color: dim ? AppColors.border : AppColors.foreground,
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              AccountingBadge(text: a.type.label),
              const SizedBox(width: AppSpacing.sm),
              if (a.isPostable)
                IconButton(
                  tooltip: 'Ver mayor',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.menu_book_rounded, size: 17),
                  onPressed: () => _showLedger(a),
                ),
              if (canManageCatalog)
                IconButton(
                  tooltip: 'Editar',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.edit_rounded, size: 17),
                  onPressed: () => _editAccount(a),
                ),
              Switch(
                value: a.isActive,
                onChanged: (_) async {
                  final msg = await widget.vm.toggleAccount(a);
                  if (!mounted || msg == null) return;
                  _toast(msg);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _costCenters() {
    final canManageCatalog = ref
        .watch(sessionProvider.notifier)
        .hasPermission('contabilidad.catalogo.gestionar');
    final vm = widget.vm;
    if (vm.costCenters.isEmpty) {
      return const AccountingEmpty(
        icon: Icons.account_tree_rounded,
        title: 'Sin centros de costo',
        subtitle: 'Crea centros de costo, departamentos, proyectos o '
            'sucursales para clasificar las líneas de los asientos.',
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.only(top: AppSpacing.sm),
      itemCount: vm.costCenters.length,
      separatorBuilder: (_, _) =>
          Divider(height: 1, color: AppColors.border.withValues(alpha: 0.55)),
      itemBuilder: (context, i) {
        final c = vm.costCenters[i];
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
          child: Row(
            children: [
              SizedBox(
                width: 84,
                child: Text(c.code,
                    style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: AppColors.mutedForeground)),
              ),
              Expanded(
                child: Text(c.name,
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w500)),
              ),
              AccountingBadge(text: c.kindLabel),
              const SizedBox(width: AppSpacing.sm),
              if (canManageCatalog)
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.edit_rounded, size: 17),
                  onPressed: () => _editCostCenter(c),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _mappings() {
    final vm = widget.vm;
    if (vm.mappings.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    return ListView.separated(
      padding: const EdgeInsets.only(top: AppSpacing.sm),
      itemCount: vm.mappings.length,
      separatorBuilder: (_, _) =>
          Divider(height: 1, color: AppColors.border.withValues(alpha: 0.55)),
      itemBuilder: (context, i) {
        final m = vm.mappings[i];
        final key = m['event_key'] as String;
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
          child: Row(
            children: [
              Expanded(
                flex: 3,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_mappingLabel(key),
                        style: const TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w600)),
                    Text(key,
                        style: const TextStyle(
                            fontSize: 11,
                            color: AppColors.mutedForeground)),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                flex: 4,
                child: DropdownButtonFormField<String>(
                  initialValue: m['account_id'] as String?,
                  isExpanded: true,
                  style: const TextStyle(
                      fontSize: 13, color: AppColors.foreground),
                  decoration: const InputDecoration(
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(
                        horizontal: AppSpacing.md, vertical: AppSpacing.sm),
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    for (final a in vm.postableAccounts)
                      DropdownMenuItem(
                        value: a.id,
                        child: Text('${a.code} · ${a.name}',
                            overflow: TextOverflow.ellipsis),
                      ),
                  ],
                  onChanged: (v) async {
                    if (v == null) return;
                    final msg = await vm.setMapping(key, v);
                    if (!mounted || msg == null) return;
                    _toast(msg);
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  static String _mappingLabel(String key) => switch (key) {
        'cash' => 'Caja general',
        'petty_cash' => 'Caja chica',
        'bank' => 'Bancos',
        'card_clearing' => 'Tarjetas por liquidar',
        'ar_customers' => 'Cuentas por cobrar clientes',
        'inventory' => 'Inventario',
        'itbis_credit' => 'ITBIS pagado en compras',
        'ap_suppliers' => 'Cuentas por pagar proveedores',
        'itbis_payable' => 'ITBIS por pagar',
        'itbis_withheld' => 'ITBIS retenido',
        'isr_withheld' => 'ISR retenido',
        'tips_payable' => 'Propinas por pagar',
        'service_fee_payable' => 'Cargo por servicio',
        'sales_revenue' => 'Ingresos por ventas',
        'delivery_revenue' => 'Ingresos por delivery',
        'sales_discounts' => 'Descuentos en ventas',
        'other_income' => 'Otros ingresos',
        'cogs' => 'Costo de ventas',
        'cash_expense' => 'Gastos de caja',
        'rounding' => 'Diferencias y redondeo',
        'retained_earnings' => 'Resultados acumulados',
        'current_earnings' => 'Resultado del ejercicio',
        _ when key.startsWith('payment_method:') =>
          'Cobro con ${key.split(':').last}',
        _ => key,
      };

  Future<void> _editAccount(AccountingAccount? account) async {
    final res = await showAccountFormDialog(
      context,
      account: account,
      accounts: widget.vm.accounts,
    );
    if (res == null || !mounted) return;
    final msg = await widget.vm.saveAccount(
      id: res.id,
      code: res.code,
      name: res.name,
      accountType: res.accountType,
      parentId: res.parentId,
      isPostable: res.isPostable,
    );
    if (!mounted || msg == null) return;
    _toast(msg);
  }

  Future<void> _editCostCenter(AccountingCostCenter? costCenter) async {
    final res = await showCostCenterDialog(context, costCenter: costCenter);
    if (res == null || !mounted) return;
    final msg = await widget.vm.saveCostCenter(
      id: res.id,
      code: res.code,
      name: res.name,
      kind: res.kind,
    );
    if (!mounted || msg == null) return;
    _toast(msg);
  }

  Future<void> _showLedger(AccountingAccount account) async {
    await widget.vm.loadLedger(account.id);
    if (!mounted) return;
    final currency = currentBusinessCurrencyOrFallback(ref);
    await showDialog<void>(
      context: context,
      builder: (_) => _LedgerDialog(
        account: account,
        rows: widget.vm.ledger,
        currency: currency,
        from: widget.vm.from,
        to: widget.vm.to,
      ),
    );
  }

  void _toast(String message) {
    if (widget.vm.error != null) {
      AppToast.error(context, message);
    } else {
      AppToast.success(context, message);
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Libro mayor de una cuenta
// ─────────────────────────────────────────────────────────────────────────────

class _LedgerDialog extends StatelessWidget {
  final AccountingAccount account;
  final List<Map<String, dynamic>> rows;
  final BusinessCurrency currency;
  final DateTime from;
  final DateTime to;

  const _LedgerDialog({
    required this.account,
    required this.rows,
    required this.currency,
    required this.from,
    required this.to,
  });

  @override
  Widget build(BuildContext context) {
    final df = DateFormat('dd/MM/yyyy');
    return Dialog(
      backgroundColor: Colors.transparent,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 940, maxHeight: 660),
        child: AccountingCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AccountingCardHeader(
                title: 'Mayor — ${account.code} · ${account.name}',
                subtitle: '${df.format(from)} — ${df.format(to)}',
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _ExportMenu(
                      filename: 'mayor_${account.code}',
                      title:
                          'Libro Mayor — ${account.code} ${account.name}',
                      subtitle: '${df.format(from)} — ${df.format(to)}',
                      headers: const [
                        'Fecha',
                        'Asiento',
                        'Descripción',
                        'Débito',
                        'Crédito',
                        'Saldo'
                      ],
                      rows: [
                        for (final r in rows)
                          [
                            r['entry_date']?.toString() ?? '',
                            (r['entry_number'] ?? '').toString(),
                            (r['description'] ?? '').toString(),
                            _num(r['debit']).toStringAsFixed(2),
                            _num(r['credit']).toStringAsFixed(2),
                            _num(r['balance']).toStringAsFixed(2),
                          ],
                      ],
                      numericColumns: const [3, 4, 5],
                    ),
                    IconButton(
                      icon: const Icon(Icons.close_rounded),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              Expanded(
                child: rows.isEmpty
                    ? const AccountingEmpty(
                        icon: Icons.menu_book_rounded,
                        title: 'Sin movimientos',
                        subtitle:
                            'La cuenta no tuvo movimientos en el rango.',
                      )
                    : AccountingTable(
                        minWidth: 720,
                        columns: const [
                          AcctColumn('Fecha', width: 104),
                          AcctColumn('Asiento', width: 80),
                          AcctColumn('Descripción', flex: 4),
                          AcctColumn('Debe', width: 120, numeric: true),
                          AcctColumn('Haber', width: 120, numeric: true),
                          AcctColumn('Saldo', width: 130, numeric: true),
                        ],
                        rows: [
                          for (final r in rows)
                            AcctRow(
                              [
                                Text(_fmtDate(r['entry_date'])),
                                Text((r['entry_number'] ?? 0) == 0
                                    ? '—'
                                    : '#${r['entry_number']}'),
                                Text((r['description'] ?? '').toString(),
                                    overflow: TextOverflow.ellipsis),
                                Text(_num(r['debit']) == 0
                                    ? ''
                                    : currency
                                        .formatAmount(_num(r['debit']))),
                                Text(_num(r['credit']) == 0
                                    ? ''
                                    : currency
                                        .formatAmount(_num(r['credit']))),
                                Text(
                                  currency.formatAmount(_num(r['balance'])),
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w700),
                                ),
                              ],
                              emphasized:
                                  (r['entry_number'] ?? 0) == 0,
                            ),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Pestaña: balanza de comprobación
// ─────────────────────────────────────────────────────────────────────────────

class _TrialBalanceTab extends StatelessWidget {
  final AccountingViewModel vm;
  final BusinessCurrency currency;

  const _TrialBalanceTab({required this.vm, required this.currency});

  @override
  Widget build(BuildContext context) {
    if (vm.isBusy && vm.trialBalance.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (vm.trialBalance.isEmpty) {
      return AccountingCard(
        child: AccountingEmpty(
          icon: Icons.balance_rounded,
          title: 'Balanza vacía',
          subtitle: 'No hay movimientos contables en el rango.',
          action: OutlinedButton(
            onPressed: () => vm.loadTrialBalance(),
            child: const Text('Recargar'),
          ),
        ),
      );
    }

    final totalDebit =
        vm.trialBalance.fold(0.0, (s, r) => s + _num(r['debit']));
    final totalCredit =
        vm.trialBalance.fold(0.0, (s, r) => s + _num(r['credit']));
    final diff = totalDebit - totalCredit;
    final df = DateFormat('dd/MM/yyyy');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: AppSpacing.md,
          runSpacing: AppSpacing.md,
          children: [
            AccountingKpiTile(
              label: 'Total débitos',
              value: currency.formatAmount(totalDebit),
              icon: Icons.south_west_rounded,
            ),
            AccountingKpiTile(
              label: 'Total créditos',
              value: currency.formatAmount(totalCredit),
              icon: Icons.north_east_rounded,
            ),
            AccountingKpiTile(
              label: 'Diferencia',
              value: currency.formatAmount(diff),
              icon: diff.abs() < 0.01
                  ? Icons.check_circle_rounded
                  : Icons.warning_amber_rounded,
              valueColor: diff.abs() < 0.01
                  ? AppColors.success
                  : AppColors.destructive,
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.lg),
        Expanded(
          child: AccountingCard(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, AppSpacing.sm),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AccountingCardHeader(
                  title: 'Balanza de comprobación',
                  subtitle: '${df.format(vm.from)} — ${df.format(vm.to)} · '
                      '${vm.trialBalance.length} cuentas con movimiento',
                  trailing: _ExportMenu(
                    filename: 'balanza_comprobacion',
                    title: 'Balanza de comprobación',
                    subtitle: '${df.format(vm.from)} — ${df.format(vm.to)}',
                    headers: const [
                      'Código',
                      'Cuenta',
                      'Saldo inicial',
                      'Débitos',
                      'Créditos',
                      'Saldo final'
                    ],
                    rows: [
                      for (final r in vm.trialBalance)
                        [
                          (r['code'] ?? '').toString(),
                          (r['name'] ?? '').toString(),
                          _num(r['opening_balance']).toStringAsFixed(2),
                          _num(r['debit']).toStringAsFixed(2),
                          _num(r['credit']).toStringAsFixed(2),
                          _num(r['ending_balance']).toStringAsFixed(2),
                        ],
                    ],
                    numericColumns: const [2, 3, 4, 5],
                    landscape: true,
                    summaryLines: [
                      'Total débitos: ${totalDebit.toStringAsFixed(2)}',
                      'Total créditos: ${totalCredit.toStringAsFixed(2)}',
                    ],
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                Expanded(
                  child: AccountingTable(
                    minWidth: 900,
                    columns: const [
                      AcctColumn('Código', width: 84),
                      AcctColumn('Cuenta', flex: 3),
                      AcctColumn('Saldo inicial',
                          width: 130, numeric: true),
                      AcctColumn('Débitos', width: 130, numeric: true),
                      AcctColumn('Créditos', width: 130, numeric: true),
                      AcctColumn('Saldo final', width: 140, numeric: true),
                    ],
                    rows: [
                      for (final r in vm.trialBalance)
                        AcctRow([
                          Text((r['code'] ?? '').toString(),
                              style: const TextStyle(
                                  fontSize: 12,
                                  color: AppColors.mutedForeground)),
                          Text((r['name'] ?? '').toString(),
                              overflow: TextOverflow.ellipsis),
                          Text(currency
                              .formatAmount(_num(r['opening_balance']))),
                          Text(currency.formatAmount(_num(r['debit']))),
                          Text(currency.formatAmount(_num(r['credit']))),
                          Text(
                            currency
                                .formatAmount(_num(r['ending_balance'])),
                            style: const TextStyle(
                                fontWeight: FontWeight.w700),
                          ),
                        ]),
                    ],
                    footer: AcctRow(
                      [
                        const Text(''),
                        const Text('TOTALES'),
                        const Text(''),
                        Text(currency.formatAmount(totalDebit)),
                        Text(currency.formatAmount(totalCredit)),
                        const Text(''),
                      ],
                      emphasized: true,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Pestaña: estado de resultados
// ─────────────────────────────────────────────────────────────────────────────

class _IncomeStatementTab extends StatelessWidget {
  final AccountingViewModel vm;
  final BusinessCurrency currency;

  const _IncomeStatementTab({required this.vm, required this.currency});

  @override
  Widget build(BuildContext context) {
    if (vm.isBusy && vm.incomeStatement.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (vm.incomeStatement.isEmpty) {
      return AccountingCard(
        child: AccountingEmpty(
          icon: Icons.trending_up_rounded,
          title: 'Sin resultados en el rango',
          subtitle:
              'Genera los asientos del período para ver ingresos y gastos.',
          action: OutlinedButton(
            onPressed: () => vm.loadIncomeStatement(),
            child: const Text('Recargar'),
          ),
        ),
      );
    }

    final income =
        vm.incomeStatement.where((r) => r['account_type'] == 'income').toList();
    final expense = vm.incomeStatement
        .where((r) => r['account_type'] == 'expense')
        .toList();
    final totalIncome = income.fold(0.0, (s, r) => s + _num(r['amount']));
    final totalExpense = expense.fold(0.0, (s, r) => s + _num(r['amount']));
    final result = totalIncome - totalExpense;
    final df = DateFormat('dd/MM/yyyy');

    return ListView(
      padding: EdgeInsets.zero,
      children: [
        Wrap(
          spacing: AppSpacing.md,
          runSpacing: AppSpacing.md,
          children: [
            AccountingKpiTile(
              label: 'Ingresos',
              value: currency.formatAmount(totalIncome),
              icon: Icons.trending_up_rounded,
              valueColor: AppColors.success,
            ),
            AccountingKpiTile(
              label: 'Gastos y costos',
              value: currency.formatAmount(totalExpense),
              icon: Icons.trending_down_rounded,
              valueColor: AppColors.destructive,
            ),
            AccountingKpiTile(
              label: result >= 0 ? 'Utilidad' : 'Pérdida',
              value: currency.formatAmount(result.abs()),
              icon: Icons.savings_rounded,
              valueColor:
                  result >= 0 ? AppColors.success : AppColors.destructive,
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.lg),
        _group(
          title: 'Ingresos',
          subtitle: '${df.format(vm.from)} — ${df.format(vm.to)}',
          rows: income,
          total: totalIncome,
          trailing: _ExportMenu(
            filename: 'estado_resultados',
            title: 'Estado de resultados',
            subtitle: '${df.format(vm.from)} — ${df.format(vm.to)}',
            headers: const ['Código', 'Cuenta', 'Naturaleza', 'Importe'],
            rows: [
              for (final r in vm.incomeStatement)
                [
                  (r['code'] ?? '').toString(),
                  (r['name'] ?? '').toString(),
                  r['account_type'] == 'income' ? 'Ingreso' : 'Gasto',
                  _num(r['amount']).toStringAsFixed(2),
                ],
            ],
            numericColumns: const [3],
            summaryLines: [
              'Ingresos: ${totalIncome.toStringAsFixed(2)}',
              'Gastos y costos: ${totalExpense.toStringAsFixed(2)}',
              '${result >= 0 ? 'Utilidad' : 'Pérdida'}: '
                  '${result.abs().toStringAsFixed(2)}',
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        _group(
          title: 'Gastos y costos',
          rows: expense,
          total: totalExpense,
        ),
        const SizedBox(height: AppSpacing.lg),
        AccountingCard(
          child: Row(
            children: [
              Icon(
                result >= 0
                    ? Icons.check_circle_rounded
                    : Icons.error_rounded,
                color:
                    result >= 0 ? AppColors.success : AppColors.destructive,
              ),
              const SizedBox(width: AppSpacing.md),
              Text(
                result >= 0 ? 'Utilidad del período' : 'Pérdida del período',
                style: const TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w800),
              ),
              const Spacer(),
              Text(
                currency.formatAmount(result.abs()),
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: result >= 0
                      ? AppColors.success
                      : AppColors.destructive,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _group({
    required String title,
    String? subtitle,
    required List<Map<String, dynamic>> rows,
    required double total,
    Widget? trailing,
  }) {
    return AccountingCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AccountingCardHeader(
              title: title, subtitle: subtitle, trailing: trailing),
          const SizedBox(height: AppSpacing.sm),
          const Divider(height: 1, color: AppColors.border),
          if (rows.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: AppSpacing.lg),
              child: Text('Sin movimientos en el período',
                  style: TextStyle(
                      fontSize: 13, color: AppColors.mutedForeground)),
            )
          else
            for (final r in rows)
              AccountingAmountRow(
                code: (r['code'] ?? '').toString(),
                name: (r['name'] ?? '').toString(),
                amount: currency.formatAmount(_num(r['amount'])),
              ),
          const Divider(height: 1, color: AppColors.border),
          AccountingAmountRow(
            code: '',
            name: 'Total $title',
            amount: currency.formatAmount(total),
            emphasized: true,
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Pestaña: balance general
// ─────────────────────────────────────────────────────────────────────────────

class _BalanceSheetTab extends StatelessWidget {
  final AccountingViewModel vm;
  final BusinessCurrency currency;

  const _BalanceSheetTab({required this.vm, required this.currency});

  @override
  Widget build(BuildContext context) {
    if (vm.isBusy && vm.balanceSheet.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (vm.balanceSheet.isEmpty) {
      return AccountingCard(
        child: AccountingEmpty(
          icon: Icons.account_balance_rounded,
          title: 'Balance vacío',
          subtitle: 'No hay saldos a la fecha de corte.',
          action: OutlinedButton(
            onPressed: () => vm.loadBalanceSheet(),
            child: const Text('Recargar'),
          ),
        ),
      );
    }

    final assets =
        vm.balanceSheet.where((r) => r['account_type'] == 'asset').toList();
    final liabilities =
        vm.balanceSheet.where((r) => r['account_type'] == 'liability').toList();
    final equity =
        vm.balanceSheet.where((r) => r['account_type'] == 'equity').toList();
    final totalAssets = assets.fold(0.0, (s, r) => s + _num(r['balance']));
    final totalLiab = liabilities.fold(0.0, (s, r) => s + _num(r['balance']));
    final totalEquity = equity.fold(0.0, (s, r) => s + _num(r['balance']));
    final cuadra = (totalAssets - totalLiab - totalEquity).abs() < 0.01;
    final df = DateFormat('dd/MM/yyyy');

    return ListView(
      padding: EdgeInsets.zero,
      children: [
        Wrap(
          spacing: AppSpacing.md,
          runSpacing: AppSpacing.md,
          children: [
            AccountingKpiTile(
              label: 'Activo',
              value: currency.formatAmount(totalAssets),
              icon: Icons.savings_rounded,
            ),
            AccountingKpiTile(
              label: 'Pasivo + Patrimonio',
              value: currency.formatAmount(totalLiab + totalEquity),
              icon: cuadra
                  ? Icons.check_circle_rounded
                  : Icons.warning_amber_rounded,
              valueColor:
                  cuadra ? AppColors.success : AppColors.destructive,
            ),
            AccountingKpiTile(
              label: 'Fecha de corte',
              value: df.format(vm.to),
              icon: Icons.event_rounded,
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.lg),
        _group(
          title: 'Activo',
          subtitle: 'Al ${df.format(vm.to)}',
          rows: assets,
          total: totalAssets,
          trailing: _ExportMenu(
            filename: 'balance_general',
            title: 'Balance general',
            subtitle: 'Al ${df.format(vm.to)}',
            headers: const ['Código', 'Cuenta', 'Grupo', 'Saldo'],
            rows: [
              for (final r in vm.balanceSheet)
                [
                  (r['code'] ?? '').toString(),
                  (r['name'] ?? '').toString(),
                  _groupLabel(r['account_type'] as String?),
                  _num(r['balance']).toStringAsFixed(2),
                ],
            ],
            numericColumns: const [3],
            summaryLines: [
              'Activo: ${totalAssets.toStringAsFixed(2)}',
              'Pasivo: ${totalLiab.toStringAsFixed(2)}',
              'Patrimonio: ${totalEquity.toStringAsFixed(2)}',
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        _group(title: 'Pasivo', rows: liabilities, total: totalLiab),
        const SizedBox(height: AppSpacing.lg),
        _group(title: 'Patrimonio', rows: equity, total: totalEquity),
      ],
    );
  }

  static String _groupLabel(String? type) => switch (type) {
        'asset' => 'Activo',
        'liability' => 'Pasivo',
        'equity' => 'Patrimonio',
        _ => '',
      };

  Widget _group({
    required String title,
    String? subtitle,
    required List<Map<String, dynamic>> rows,
    required double total,
    Widget? trailing,
  }) {
    return AccountingCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AccountingCardHeader(
              title: title, subtitle: subtitle, trailing: trailing),
          const SizedBox(height: AppSpacing.sm),
          const Divider(height: 1, color: AppColors.border),
          if (rows.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: AppSpacing.lg),
              child: Text('Sin saldos a la fecha',
                  style: TextStyle(
                      fontSize: 13, color: AppColors.mutedForeground)),
            )
          else
            for (final r in rows)
              AccountingAmountRow(
                code: (r['code'] ?? '').toString(),
                name: (r['name'] ?? '').toString(),
                amount: currency.formatAmount(_num(r['balance'])),
              ),
          const Divider(height: 1, color: AppColors.border),
          AccountingAmountRow(
            code: '',
            name: 'Total $title',
            amount: currency.formatAmount(total),
            emphasized: true,
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Pestaña: períodos
// ─────────────────────────────────────────────────────────────────────────────

class _PeriodsTab extends ConsumerWidget {
  final AccountingViewModel vm;
  const _PeriodsTab({required this.vm});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Cerrar o reabrir un mes contable es `contabilidad.periodos.cerrar`.
    final canClosePeriods = ref
        .watch(sessionProvider.notifier)
        .hasPermission('contabilidad.periodos.cerrar');
    if (vm.periods.isEmpty) {
      return const AccountingCard(
        child: AccountingEmpty(
          icon: Icons.calendar_month_rounded,
          title: 'Sin períodos',
          subtitle: 'Los períodos se crean solos al registrar el primer '
              'asiento de cada mes.',
        ),
      );
    }
    final months = DateFormat.MMMM('es');
    final closed = vm.periods.where((p) => p.isClosed).length;

    return AccountingCard(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AccountingCardHeader(
            title: 'Períodos contables',
            subtitle: '${vm.periods.length} meses · $closed cerrados. '
                'Un mes cerrado rechaza cualquier asiento con esa fecha.',
          ),
          const SizedBox(height: AppSpacing.md),
          const Divider(height: 1, color: AppColors.border),
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.only(top: AppSpacing.xs),
              itemCount: vm.periods.length,
              separatorBuilder: (_, _) => Divider(
                  height: 1,
                  color: AppColors.border.withValues(alpha: 0.55)),
              itemBuilder: (context, i) {
                final p = vm.periods[i];
                return Padding(
                  padding:
                      const EdgeInsets.symmetric(vertical: AppSpacing.sm),
                  child: Row(
                    children: [
                      Container(
                        width: 34,
                        height: 34,
                        decoration: BoxDecoration(
                          color: (p.isClosed
                                  ? AppColors.destructive
                                  : AppColors.success)
                              .withValues(alpha: 0.10),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Icon(
                          p.isClosed
                              ? Icons.lock_rounded
                              : Icons.lock_open_rounded,
                          size: 17,
                          color: p.isClosed
                              ? AppColors.destructive
                              : AppColors.success,
                        ),
                      ),
                      const SizedBox(width: AppSpacing.md),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${_capitalize(months.format(DateTime(p.year, p.month)))} '
                              '${p.year}',
                              style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700),
                            ),
                            Text(
                              p.isClosed
                                  ? 'Cerrado — no admite asientos'
                                  : 'Abierto — admite asientos',
                              style: const TextStyle(
                                  fontSize: 12,
                                  color: AppColors.mutedForeground),
                            ),
                          ],
                        ),
                      ),
                      if (canClosePeriods)
                        OutlinedButton(
                          onPressed: () async {
                            final msg = await vm.setPeriodStatus(p.year, p.month,
                                p.isClosed ? 'open' : 'closed');
                            if (!context.mounted || msg == null) return;
                            if (vm.error != null) {
                              AppToast.error(context, msg);
                            } else {
                              AppToast.success(context, msg);
                            }
                          },
                          child: Text(p.isClosed ? 'Reabrir' : 'Cerrar mes'),
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  static String _capitalize(String s) =>
      s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';
}

// ─────────────────────────────────────────────────────────────────────────────
// Compartidos
// ─────────────────────────────────────────────────────────────────────────────

double _num(Object? value) => (value as num?)?.toDouble() ?? 0;

String _fmtDate(Object? raw) {
  final parsed = DateTime.tryParse(raw?.toString() ?? '');
  return parsed == null
      ? (raw?.toString() ?? '')
      : DateFormat('dd/MM/yyyy').format(parsed);
}

/// Exportación del reporte visible en CSV, Excel o PDF (requisito del PDF del
/// cliente: "Exportación de reportes a Excel y PDF").
class _ExportMenu extends StatelessWidget {
  final String filename;
  final String title;
  final String subtitle;
  final ExportRow headers;
  final List<ExportRow> rows;
  final List<int> numericColumns;
  final List<String>? summaryLines;
  final bool landscape;

  const _ExportMenu({
    required this.filename,
    required this.title,
    required this.subtitle,
    required this.headers,
    required this.rows,
    this.numericColumns = const [],
    this.summaryLines,
    this.landscape = false,
  });

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: 'Exportar',
      icon: const Icon(Icons.download_rounded, size: 20),
      itemBuilder: (_) => const [
        PopupMenuItem(value: 'csv', child: Text('Exportar CSV')),
        PopupMenuItem(value: 'xlsx', child: Text('Exportar Excel')),
        PopupMenuItem(value: 'pdf', child: Text('Exportar PDF')),
      ],
      onSelected: (format) async {
        try {
          switch (format) {
            case 'csv':
              await ReportExporter.exportCsv(
                  filename: filename, headers: headers, rows: rows);
              break;
            case 'xlsx':
              await ReportExporter.exportExcel(
                  filename: filename,
                  sheetName: 'Reporte',
                  headers: headers,
                  rows: rows);
              break;
            case 'pdf':
              await ReportExporter.exportPdf(
                filename: filename,
                title: title,
                subtitle: subtitle,
                headers: headers,
                rows: rows,
                landscape: landscape,
                columnNumericIndices: numericColumns,
                summaryLines: summaryLines,
              );
              break;
          }
        } catch (e) {
          if (context.mounted) {
            AppToast.error(context, 'No se pudo exportar: $e');
          }
        }
      },
    );
  }
}
