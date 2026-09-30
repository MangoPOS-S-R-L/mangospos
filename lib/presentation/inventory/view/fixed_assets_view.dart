// Activos fijos: el equipo y el mobiliario del negocio, uno por uno.
//
// Hornos, neveras, freidoras, TV, equipos de caja, aires, mesas y sillas, el
// motor de delivery. Cada uno con su código (AF-00001), dónde está, quién
// responde por él, su estado y su historia. NO es inventario: no se consume
// ni entra en la valuación ni en el costo de venta (20260930_0052). Sin
// depreciación (decisión del dueño).
//
// Ver: `inventario.activos.acceso` (lo gatea la ruta). Escribir:
// `inventario.activos.gestionar` (acá se esconden los botones; el servidor
// lo vuelve a exigir en cada RPC).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/currency/business_currency.dart';
import '../../../core/currency/business_currency_provider.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_radius.dart';
import '../../../core/theme/app_shadows.dart';
import '../../../core/utils/app_toast.dart';
import '../../../core/utils/friendly_error.dart';
import '../../../data/repositories/fixed_assets_repository.dart';
import '../../../services/session/session_controller.dart';
import '../services/fixed_assets_pdf.dart';
import '../state/fixed_assets_state.dart';
import 'fixed_asset_detail_dialog.dart';
import 'fixed_asset_form_dialog.dart';
import 'widgets/inventory_back_button.dart';

/// Permiso para dar de alta, editar, mover y dar de baja.
const kFixedAssetsManagePermission = 'inventario.activos.gestionar';

/// Permiso para entrar a la pantalla (la ruta lo exige).
const kFixedAssetsAccessPermission = 'inventario.activos.acceso';

class FixedAssetsView extends ConsumerStatefulWidget {
  const FixedAssetsView({super.key});

  @override
  ConsumerState<FixedAssetsView> createState() => _FixedAssetsViewState();
}

class _FixedAssetsViewState extends ConsumerState<FixedAssetsView> {
  static const _pageSize = 100;

  bool _loading = true;
  bool _migrationMissing = false;
  String? _error;
  String? _businessId;
  List<FixedAsset> _assets = const [];
  List<FixedAssetOption> _warehouses = const [];
  List<FixedAssetOption> _employees = const [];
  FixedAssetsFilter _filter = const FixedAssetsFilter();
  int _visible = _pageSize;
  bool _printing = false;
  final _searchCtrl = TextEditingController();

  FixedAssetsRepository get _repo => ref.read(fixedAssetsRepositoryProvider);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final businessId = await _repo.resolveBusinessId();
      if (businessId == null) {
        if (!mounted) return;
        setState(() {
          _loading = false;
          _error = 'No se pudo resolver el negocio activo.';
        });
        return;
      }
      _businessId = businessId;
      // Bodegas y empleados son accesorios: si fallan, la lista igual sale
      // (solo los selectores quedan vacíos).
      final extras = await Future.wait([
        _repo.listWarehouses(businessId).catchError(
              (_) => const <FixedAssetOption>[],
            ),
        _repo.listEmployees(businessId).catchError(
              (_) => const <FixedAssetOption>[],
            ),
      ]);
      _warehouses = extras[0];
      _employees = extras[1];
      await _load();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = FriendlyError.from(e);
      });
    }
  }

  Future<void> _load() async {
    final businessId = _businessId;
    if (businessId == null) return;
    setState(() => _loading = true);
    try {
      final rows = await _repo.listAssets(businessId);
      if (!mounted) return;
      setState(() {
        _assets = rows;
        _loading = false;
        _migrationMissing = false;
        _error = null;
      });
    } on FixedAssetsMigrationMissing {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _migrationMissing = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = FriendlyError.from(e);
      });
    }
  }

  void _setFilter(FixedAssetsFilter next) {
    setState(() {
      _filter = next;
      _visible = _pageSize;
    });
  }

  /// Reemplaza la ficha en la lista sin volver a pedir todo.
  void _replace(FixedAsset updated) {
    setState(() {
      _assets = sortFixedAssetsByCode([
        for (final a in _assets)
          if (a.id != updated.id) a,
        updated,
      ]);
    });
  }

  /// Bodegas para el filtro: las activas + las que todavía tienen activos
  /// aunque se hayan desactivado.
  List<FixedAssetOption> get _locationOptions {
    final result = [..._warehouses];
    for (final a in _assets) {
      final id = a.warehouseId;
      if (id != null && !result.any((o) => o.id == id)) {
        result.add(FixedAssetOption(
          id,
          a.warehouseName.isEmpty ? 'Bodega' : a.warehouseName,
        ));
      }
    }
    return result;
  }

  Future<void> _new() async {
    final businessId = _businessId;
    if (businessId == null) return;
    final saved = await showFixedAssetFormDialog(
      context,
      repo: _repo,
      businessId: businessId,
      warehouses: _warehouses,
      employees: _employees,
      knownCategories: fixedAssetCategoriesIn(_assets),
    );
    if (saved != null && mounted) _replace(saved);
  }

  void _open(FixedAsset asset, BusinessCurrency money, bool canManage) {
    final businessId = _businessId;
    if (businessId == null) return;
    showFixedAssetDetailDialog(
      context,
      asset: asset,
      repo: _repo,
      businessId: businessId,
      warehouses: _warehouses,
      employees: _employees,
      knownCategories: fixedAssetCategoriesIn(_assets),
      canManage: canManage,
      money: money,
      onChanged: _replace,
      onPrintAct: (a) => _printAct(a, money),
    );
  }

  String get _printedBy => ref.read(sessionProvider).userName ?? '';

  /// Qué se imprime, en palabras, para el encabezado del documento.
  String _scopeLabel() {
    final f = _filter;
    final parts = <String>[];
    final wh = f.warehouseId;
    if (wh != null) {
      final name = wh == kFixedAssetNoWarehouse
          ? 'Sin ubicación'
          : _locationOptions
              .firstWhere(
                (o) => o.id == wh,
                orElse: () => const FixedAssetOption('', 'Bodega'),
              )
              .name;
      parts.add('Ubicación: $name');
    }
    if (f.category != null) parts.add('Categoría: ${f.category}');
    if (f.status != null) parts.add('Estado: ${f.status!.label}');
    if (f.query.trim().isNotEmpty) parts.add('Búsqueda: "${f.query.trim()}"');
    if (!f.showRetired && f.status != FixedAssetStatus.retired) {
      parts.add('Sin dados de baja');
    }
    return parts.join(' · ');
  }

  Future<void> _printInventory(
    List<FixedAsset> shown,
    BusinessCurrency money,
  ) async {
    final businessId = _businessId;
    if (businessId == null) return;
    if (shown.isEmpty) {
      AppToast.info(context, 'No hay activos en pantalla para imprimir.');
      return;
    }
    setState(() => _printing = true);
    try {
      final businessName = await _repo.getBusinessName(businessId);
      await FixedAssetsPdf.printInventory(
        assets: shown,
        businessName: businessName,
        scopeLabel: _scopeLabel(),
        printedBy: _printedBy,
        currency: money,
      );
    } catch (e) {
      if (!mounted) return;
      AppToast.error(context, 'No se pudo generar el documento: $e');
    } finally {
      if (mounted) setState(() => _printing = false);
    }
  }

  Future<void> _printAct(FixedAsset asset, BusinessCurrency money) async {
    final businessId = _businessId;
    if (businessId == null) return;
    try {
      final businessName = await _repo.getBusinessName(businessId);
      await FixedAssetsPdf.printAssignmentAct(
        asset: asset,
        businessName: businessName,
        deliveredBy: _printedBy,
        currency: money,
      );
    } catch (e) {
      if (!mounted) return;
      AppToast.error(context, 'No se pudo generar el acta: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider.notifier);
    ref.watch(sessionProvider);
    final canManage = session.hasPermission(kFixedAssetsManagePermission);
    final money = currentBusinessCurrencyOrFallback(ref);
    final filtered = _filter.apply(_assets);

    return Scaffold(
      backgroundColor: AppColors.background,
      body: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final pad = width >= 700 ? 24.0 : 14.0;
          final wide = width >= 900;
          return RefreshIndicator(
            onRefresh: _load,
            child: SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: EdgeInsets.all(pad),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _header(
                    width - pad * 2,
                    canManage: canManage,
                    onPrint: () => _printInventory(filtered, money),
                  ),
                  const SizedBox(height: 18),
                  ..._body(filtered, money, canManage, wide, width - pad * 2),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _header(
    double width, {
    required bool canManage,
    required VoidCallback onPrint,
  }) {
    final ready = !_loading && !_migrationMissing && _error == null;
    final actions = Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        IconButton.filledTonal(
          tooltip: 'Actualizar',
          onPressed: _loading ? null : _bootstrap,
          icon: _loading
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.refresh),
        ),
        OutlinedButton.icon(
          key: const Key('fixed-assets-print'),
          onPressed: ready && !_printing ? onPrint : null,
          icon: const Icon(Icons.print_outlined, size: 18),
          label: const Text('Imprimir'),
        ),
        if (canManage)
          FilledButton.icon(
            key: const Key('fixed-assets-new'),
            onPressed: ready ? _new : null,
            icon: const Icon(Icons.add_rounded, size: 18),
            label: const Text('Nuevo activo'),
          ),
      ],
    );
    final title = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(top: 2),
          child: InventoryBackButton(),
        ),
        const SizedBox(width: 4),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Activos fijos',
                style: TextStyle(
                  fontSize: width >= 600 ? 28 : 24,
                  fontWeight: FontWeight.w800,
                  color: AppColors.foreground,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Equipos y mobiliario, uno por uno: dónde está cada cosa y '
                'quién responde por ella.',
                style: TextStyle(
                  fontSize: 14,
                  color: AppColors.mutedForeground,
                ),
              ),
            ],
          ),
        ),
      ],
    );
    if (width < 760) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [title, const SizedBox(height: 12), actions],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: title),
        const SizedBox(width: 12),
        actions,
      ],
    );
  }

  List<Widget> _body(
    List<FixedAsset> filtered,
    BusinessCurrency money,
    bool canManage,
    bool wide,
    double width,
  ) {
    if (_migrationMissing) {
      return const [
        _Notice(
          key: Key('fixed-assets-migration-missing'),
          icon: Icons.construction_rounded,
          color: AppColors.warning,
          title: 'Falta habilitarlo en el servidor',
          text:
              'Falta aplicar la migración 20260930_0052_fixed_assets.sql en '
              'Supabase. Aplícala y vuelve a abrir esta pantalla.',
        ),
      ];
    }
    if (_error != null && _assets.isEmpty) {
      return [
        _Notice(
          icon: Icons.error_outline,
          color: AppColors.destructive,
          title: 'No se pudo cargar',
          text: _error!,
          action: TextButton.icon(
            onPressed: _bootstrap,
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('Reintentar'),
          ),
        ),
      ];
    }
    if (_loading && _assets.isEmpty) {
      return const [
        Padding(
          padding: EdgeInsets.symmetric(vertical: 80),
          child: Center(child: CircularProgressIndicator()),
        ),
      ];
    }
    if (_assets.isEmpty) {
      return [
        _Notice(
          icon: Icons.chair_alt_outlined,
          color: AppColors.mutedForeground,
          title: 'Todavía no hay activos registrados',
          text:
              'Registra hornos, neveras, freidoras, mesas, equipos de caja… '
              'uno por uno, con su código, dónde está y quién responde por '
              'él.',
          action: canManage
              ? FilledButton.icon(
                  onPressed: _new,
                  icon: const Icon(Icons.add_rounded, size: 18),
                  label: const Text('Registrar el primero'),
                )
              : null,
        ),
      ];
    }

    return [
      _KpiRow(kpis: FixedAssetsKpis.from(_assets), money: money),
      const SizedBox(height: 18),
      _filters(width),
      const SizedBox(height: 14),
      _list(filtered, money, canManage, wide),
    ];
  }

  Widget _filters(double width) {
    final narrow = width < 600;
    final fieldWidth = narrow ? width : 230.0;
    final categories = fixedAssetCategoriesIn(_assets);
    final locations = _locationOptions;
    final hasNoWarehouse = _assets.any((a) => a.warehouseId == null);
    final retiredCount = _assets.where((a) => a.status.isRetired).length;
    final f = _filter;

    InputDecoration deco(String label) => InputDecoration(
          labelText: label,
          isDense: true,
          filled: true,
          fillColor: AppColors.card,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppRadius.card),
          ),
        );

    return Wrap(
      spacing: 12,
      runSpacing: 12,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        SizedBox(
          width: narrow ? width : 300,
          child: TextField(
            key: const Key('fixed-assets-search'),
            controller: _searchCtrl,
            onChanged: (v) => _setFilter(f.copyWith(query: v)),
            decoration: deco('Buscar').copyWith(
              hintText: 'Nombre, código, serie, marca o modelo',
              prefixIcon: const Icon(Icons.search),
            ),
          ),
        ),
        SizedBox(
          width: fieldWidth,
          child: DropdownButtonFormField<String?>(
            key: ValueKey('fixed-assets-category-${f.category}'),
            initialValue: categories.contains(f.category) ? f.category : null,
            isExpanded: true,
            decoration: deco('Categoría'),
            items: [
              const DropdownMenuItem<String?>(
                value: null,
                child: Text('Todas las categorías'),
              ),
              for (final c in categories)
                DropdownMenuItem<String?>(
                  value: c,
                  child: Text(c, overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: (v) => _setFilter(
              v == null
                  ? f.copyWith(clearCategory: true)
                  : f.copyWith(category: v),
            ),
          ),
        ),
        SizedBox(
          width: fieldWidth,
          child: DropdownButtonFormField<String?>(
            key: ValueKey('fixed-assets-location-${f.warehouseId}'),
            initialValue: f.warehouseId == kFixedAssetNoWarehouse ||
                    locations.any((o) => o.id == f.warehouseId)
                ? f.warehouseId
                : null,
            isExpanded: true,
            decoration: deco('Ubicación'),
            items: [
              const DropdownMenuItem<String?>(
                value: null,
                child: Text('Todas las ubicaciones'),
              ),
              for (final w in locations)
                DropdownMenuItem<String?>(
                  value: w.id,
                  child: Text(w.name, overflow: TextOverflow.ellipsis),
                ),
              if (hasNoWarehouse)
                const DropdownMenuItem<String?>(
                  value: kFixedAssetNoWarehouse,
                  child: Text('Sin ubicación'),
                ),
            ],
            onChanged: (v) => _setFilter(
              v == null
                  ? f.copyWith(clearWarehouse: true)
                  : f.copyWith(warehouseId: v),
            ),
          ),
        ),
        SizedBox(
          width: fieldWidth,
          child: DropdownButtonFormField<FixedAssetStatus?>(
            key: ValueKey('fixed-assets-status-${f.status?.wire}'),
            initialValue: f.status,
            isExpanded: true,
            decoration: deco('Estado'),
            items: [
              const DropdownMenuItem<FixedAssetStatus?>(
                value: null,
                child: Text('Todos los estados'),
              ),
              for (final s in FixedAssetStatus.values)
                DropdownMenuItem<FixedAssetStatus?>(
                  value: s,
                  child: Text(s.label, overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: (v) => _setFilter(
              v == null ? f.copyWith(clearStatus: true) : f.copyWith(status: v),
            ),
          ),
        ),
        FilterChip(
          key: const Key('fixed-assets-show-retired'),
          label: Text('Mostrar dados de baja ($retiredCount)'),
          selected: f.showRetired,
          onSelected: (v) => _setFilter(f.copyWith(showRetired: v)),
        ),
      ],
    );
  }

  Widget _list(
    List<FixedAsset> filtered,
    BusinessCurrency money,
    bool canManage,
    bool wide,
  ) {
    final shown = filtered.take(_visible).toList(growable: false);
    return _Card(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Text(
              '${filtered.length} '
              '${filtered.length == 1 ? 'activo' : 'activos'}'
              '${_filter.isFiltering ? ' con estos filtros' : ''}',
              key: const Key('fixed-assets-count'),
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: AppColors.mutedForeground,
              ),
            ),
          ),
          const Divider(height: 1),
          if (filtered.isEmpty)
            Padding(
              padding: const EdgeInsets.all(28),
              child: Column(
                children: [
                  Text(
                    'Ningún activo coincide con los filtros.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: AppColors.mutedForeground),
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: () {
                      _searchCtrl.clear();
                      _setFilter(const FixedAssetsFilter());
                    },
                    child: const Text('Limpiar filtros'),
                  ),
                ],
              ),
            )
          else ...[
            if (wide) const _TableHeader(),
            for (final a in shown)
              wide
                  ? _AssetRow(
                      asset: a,
                      money: money,
                      onTap: () => _open(a, money, canManage),
                    )
                  : _AssetCard(
                      asset: a,
                      money: money,
                      onTap: () => _open(a, money, canManage),
                    ),
            if (filtered.length > shown.length)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Center(
                  child: TextButton.icon(
                    onPressed: () => setState(() => _visible += _pageSize),
                    icon: const Icon(Icons.expand_more),
                    label: Text(
                      'Ver más (${filtered.length - shown.length} restantes)',
                    ),
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

// ── Piezas ─────────────────────────────────────────────────────────────────

class _Card extends StatelessWidget {
  const _Card({required this.child, this.padding});

  final Widget child;
  final EdgeInsets? padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: padding ?? const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.border),
        boxShadow: AppShadows.cardElevated,
      ),
      child: child,
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({
    super.key,
    required this.icon,
    required this.color,
    required this.title,
    required this.text,
    this.action,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return _Card(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 28),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: AppColors.foreground,
                  ),
                ),
                const SizedBox(height: 4),
                Text(text, style: TextStyle(color: AppColors.mutedForeground)),
                if (action != null) ...[const SizedBox(height: 10), action!],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _KpiRow extends StatelessWidget {
  const _KpiRow({required this.kpis, required this.money});

  final FixedAssetsKpis kpis;
  final BusinessCurrency money;

  @override
  Widget build(BuildContext context) {
    final bajaCaption = [
      if (kpis.damaged > 0)
        '${kpis.damaged} ${kpis.damaged == 1 ? 'dañado' : 'dañados'}',
      if (kpis.lost > 0)
        '${kpis.lost} ${kpis.lost == 1 ? 'perdido' : 'perdidos'}',
    ];
    final tiles = <Widget>[
      _KpiTile(
        key: const Key('fixed-assets-kpi-in-use'),
        label: 'Activos en uso',
        value: '${kpis.inUse}',
        caption: 'de ${kpis.registered} registrados (sin contar bajas)',
        icon: Icons.check_circle_outline_rounded,
        color: AppColors.success,
      ),
      _KpiTile(
        key: const Key('fixed-assets-kpi-value'),
        label: 'Valor de compra',
        value: money.formatAmount(kpis.purchaseValue),
        caption: kpis.withoutCost > 0
            ? 'Sin depreciación · ${kpis.withoutCost} sin costo cargado'
            : 'Costo histórico, sin depreciación',
        icon: Icons.payments_outlined,
        color: AppColors.info,
      ),
      _KpiTile(
        key: const Key('fixed-assets-kpi-repair'),
        label: 'Reparación',
        value: '${kpis.repairTotal}',
        caption: '${kpis.needsRepair} la necesitan · '
            '${kpis.inRepair} en el taller',
        icon: Icons.build_outlined,
        color: AppColors.warning,
      ),
      _KpiTile(
        key: const Key('fixed-assets-kpi-retired'),
        label: 'Dados de baja',
        value: '${kpis.retired}',
        caption: bajaCaption.isEmpty
            ? 'Fuera de la operación, con su historia'
            : 'Además: ${bajaCaption.join(' · ')}',
        icon: Icons.do_not_disturb_on_outlined,
        color: AppColors.mutedForeground,
      ),
    ];

    return LayoutBuilder(
      builder: (context, c) {
        const gap = 12.0;
        if (c.maxWidth >= 900) {
          return IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < tiles.length; i++) ...[
                  if (i > 0) const SizedBox(width: gap),
                  Expanded(child: tiles[i]),
                ],
              ],
            ),
          );
        }
        final w = (c.maxWidth - gap) / 2;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [for (final t in tiles) SizedBox(width: w, child: t)],
        );
      },
    );
  }
}

class _KpiTile extends StatelessWidget {
  const _KpiTile({
    super.key,
    required this.label,
    required this.value,
    required this.caption,
    required this.icon,
    required this.color,
  });

  final String label;
  final String value;
  final String caption;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 118),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.border),
        boxShadow: AppShadows.cardElevated,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: color),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: AppColors.mutedForeground,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w800,
                color: AppColors.foreground,
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            caption,
            style: TextStyle(fontSize: 11.5, color: AppColors.mutedForeground),
          ),
        ],
      ),
    );
  }
}

// Columnas de la tabla ancha (flex).
const _colCode = 2;
const _colName = 5;
const _colCategory = 3;
const _colLocation = 4;
const _colResponsible = 3;
const _colStatus = 3;
const _colCost = 3;

class _TableHeader extends StatelessWidget {
  const _TableHeader();

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w800,
      color: AppColors.mutedForeground,
    );
    Widget cell(String text, int flex, {bool right = false}) => Expanded(
          flex: flex,
          child: Text(
            text,
            style: style,
            textAlign: right ? TextAlign.right : TextAlign.left,
          ),
        );
    return Container(
      color: AppColors.accent,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          cell('Código', _colCode),
          cell('Activo', _colName),
          cell('Categoría', _colCategory),
          cell('Ubicación', _colLocation),
          cell('Responsable', _colResponsible),
          cell('Estado', _colStatus),
          cell('Costo', _colCost, right: true),
        ],
      ),
    );
  }
}

class _AssetRow extends StatelessWidget {
  const _AssetRow({
    required this.asset,
    required this.money,
    required this.onTap,
  });

  final FixedAsset asset;
  final BusinessCurrency money;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final a = asset;
    final muted = TextStyle(fontSize: 12, color: AppColors.mutedForeground);
    final body = TextStyle(fontSize: 13.5, color: AppColors.foreground);
    final detail = [
      if (a.brandModel.isNotEmpty) a.brandModel,
      if ((a.serialNumber ?? '').isNotEmpty) 'Serie ${a.serialNumber}',
    ].join(' · ');
    return InkWell(
      key: ValueKey('fixed-asset-row-${a.id}'),
      onTap: onTap,
      child: Opacity(
        opacity: a.status.isRetired ? 0.6 : 1,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: AppColors.cardDivider)),
          ),
          child: Row(
            children: [
              Expanded(
                flex: _colCode,
                child: Text(
                  a.code,
                  style: body.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              Expanded(
                flex: _colName,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      a.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: body.copyWith(fontWeight: FontWeight.w700),
                    ),
                    if (detail.isNotEmpty)
                      Text(
                        detail,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: muted,
                      ),
                  ],
                ),
              ),
              Expanded(
                flex: _colCategory,
                child: Text(
                  a.category ?? '—',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: body,
                ),
              ),
              Expanded(
                flex: _colLocation,
                child: Text(
                  a.locationLabel,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: a.hasLocation ? body : muted,
                ),
              ),
              Expanded(
                flex: _colResponsible,
                child: Text(
                  a.responsibleLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: a.employeeName.isEmpty ? muted : body,
                ),
              ),
              Expanded(
                flex: _colStatus,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: FixedAssetStatusBadge(a.status, dense: true),
                ),
              ),
              Expanded(
                flex: _colCost,
                child: Text(
                  a.purchaseCost == null
                      ? '—'
                      : money.formatAmount(a.purchaseCost!),
                  textAlign: TextAlign.right,
                  style: body,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AssetCard extends StatelessWidget {
  const _AssetCard({
    required this.asset,
    required this.money,
    required this.onTap,
  });

  final FixedAsset asset;
  final BusinessCurrency money;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final a = asset;
    final muted = TextStyle(fontSize: 12.5, color: AppColors.mutedForeground);
    Widget line(IconData icon, String text) => Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Row(
            children: [
              Icon(icon, size: 14, color: AppColors.mutedForeground),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: muted,
                ),
              ),
            ],
          ),
        );
    return InkWell(
      key: ValueKey('fixed-asset-row-${a.id}'),
      onTap: onTap,
      child: Opacity(
        opacity: a.status.isRetired ? 0.6 : 1,
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: AppColors.cardDivider)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    a.code,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w800,
                      color: AppColors.mutedForeground,
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Todo el espacio que sobra es de la pastilla. El costo va
                  // en su propia línea: al lado de la pastilla, con letra
                  // grande o un monto largo, en 360 px no cabían los dos.
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: FixedAssetStatusBadge(a.status, dense: true),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                a.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                  color: AppColors.foreground,
                ),
              ),
              if (a.brandModel.isNotEmpty)
                Text(
                  a.brandModel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: muted,
                ),
              line(Icons.place_outlined, a.locationLabel),
              line(Icons.person_outline, a.responsibleLabel),
              if (a.purchaseCost != null)
                line(
                  Icons.payments_outlined,
                  money.formatAmount(a.purchaseCost!),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
