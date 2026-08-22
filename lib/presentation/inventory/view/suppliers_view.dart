// Fase 3 Proveedores — la lista: cuánto le compro, cuánto le debo, cómo
// cumple.
//
// Antes esto era una agenda de contactos: nombre, RNC, un texto de
// condiciones y un lápiz. Cubría bien los 9 campos del schema `suppliers`, y
// ese era exactamente el problema — para decidir a quién comprarle hay que
// saber lo que la ficha NO guarda. De ahí las cuatro decisiones de esta
// pantalla:
//
//   1. La fila es la puerta. «Abrir» es la acción primaria y el lápiz baja
//      al menú ⋮ — al revés de como estaba.
//   2. Cada fila dice algo comercial: qué provee, en qué condiciones, cuánto
//      se le compró en 12 meses, cuánto se le debe y si entrega completo.
//   3. Las condiciones se ven como lo que son. Un plazo configurado y un
//      «30 dias» escrito a mano se pintan distinto: sólo el primero puede
//      calcular un vencimiento.
//   4. Lo que falta se ve: sin RNC, sin condiciones y sin insumos vinculados
//      son filtros, no letra chica.
//
// El interior de cada proveedor vive en `supplier_detail_view.dart`.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../app/router/routes.dart';
import '../../../app/widgets/skeleton_loading.dart';
import '../../../core/currency/business_currency.dart';
import '../../../core/currency/business_currency_provider.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_radius.dart';
import '../../../core/theme/app_shadows.dart';
import '../../../core/utils/app_toast.dart';
import '../../../data/repositories/suppliers_repository.dart';
import '../../../data/utils/business_id_resolver.dart';
import '../../../services/session/session_controller.dart';
import '../state/supplier_overview_state.dart';
import '../viewmodel/inventory_viewmodel.dart';
import 'widgets/inventory_back_button.dart';
import 'widgets/supplier_form_dialog.dart';
import 'widgets/supplier_visuals.dart';

/// Debajo de este ancho la tabla se vuelve tarjetas. Siete columnas en una
/// tablet de 1024 quedan ilegibles mucho antes de desbordar.
const double _kTableBreakpoint = 1000;

const double _kColSupplies = 168;
const double _kColTerms = 152;
const double _kColSpend = 138;
const double _kColDue = 150;
const double _kColFulfillment = 132;
const double _kColActions = 128;

/// Qué proveedores se muestran.
enum _StateFilter { active, all, inactive }

class SuppliersView extends ConsumerStatefulWidget {
  const SuppliersView({super.key});

  @override
  ConsumerState<SuppliersView> createState() => _SuppliersViewState();
}

class _SuppliersViewState extends ConsumerState<SuppliersView> {
  bool _loading = true;
  bool _refreshing = false;
  String? _error;
  String? _businessId;
  SuppliersOverview _overview = SuppliersOverview.empty;

  final _searchCtrl = TextEditingController();
  String _query = '';
  bool _onlyOwing = false;
  bool _onlyMissingRnc = false;
  bool _onlyMissingTerms = false;
  _StateFilter _stateFilter = _StateFilter.active;

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

  SuppliersRepository get _repo => ref.read(suppliersRepositoryProvider);

  Future<void> _bootstrap() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final businessId = await resolveBusinessIdOrNull(
        Supabase.instance.client,
        'auto',
      );
      if (businessId == null) {
        if (!mounted) return;
        setState(() {
          _loading = false;
          _error = 'No se pudo resolver el negocio activo.';
        });
        return;
      }
      _businessId = businessId;
      await _load();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _load() async {
    final businessId = _businessId;
    if (businessId == null) {
      setState(() => _loading = false);
      return;
    }
    try {
      final overview = await _repo.getSuppliersOverview(businessId);
      if (!mounted) return;
      setState(() {
        _overview = overview;
        _loading = false;
        _refreshing = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _refreshing = false;
        // Con algo pintado, un fallo de red no borra la pantalla.
        _error = _overview.suppliers.isEmpty ? e.toString() : null;
      });
      if (_overview.suppliers.isNotEmpty && mounted) {
        AppToast.warning(context, 'No se pudo actualizar: ${_short(e)}');
      }
    }
  }

  static String _short(Object e) {
    final text = e.toString();
    return text.length > 90 ? '${text.substring(0, 90)}…' : text;
  }

  Future<void> _refresh() async {
    setState(() => _refreshing = true);
    await _load();
  }

  // ── Acciones ────────────────────────────────────────────────────────────

  Future<void> _openForm({SupplierOverview? edit}) async {
    final businessId = _businessId;
    if (businessId == null) return;
    final saved = await showSupplierFormDialog(
      context,
      businessId: businessId,
      repo: _repo,
      edit: edit?.supplier,
    );
    if (saved) await _refresh();
  }

  void _openSupplier(SupplierOverview s, {String? tab}) {
    final query = tab == null ? '' : '?tab=$tab';
    context.push('${AppRoutes.inventorySuppliers}/${s.id}$query');
  }

  /// Desactivar no borra: la ficha sigue en la lista, atenuada, para que el
  /// historial de compras siga teniendo dónde apoyarse.
  Future<void> _toggleActive(SupplierOverview s) async {
    final businessId = _businessId;
    if (businessId == null) return;
    final activate = !s.isActive;
    if (!activate && s.owesMoney) {
      final ok = await _confirmDeactivate(s);
      if (ok != true) return;
    }
    try {
      final d = s.supplier;
      await _repo.saveSupplier(
        businessId: businessId,
        supplierId: d.id,
        name: d.name,
        rnc: d.rnc.isEmpty ? null : d.rnc,
        contactName: d.contactName.isEmpty ? null : d.contactName,
        phone: d.phone.isEmpty ? null : d.phone,
        email: d.email.isEmpty ? null : d.email,
        address: d.address.isEmpty ? null : d.address,
        paymentTerms: d.paymentTerms.isEmpty ? null : d.paymentTerms,
        notes: d.notes.isEmpty ? null : d.notes,
        isActive: activate,
        termsType: d.paymentTermsType.isEmpty ? null : d.paymentTermsType,
        termsDays: d.paymentTermsDays,
        termsFrom: d.paymentTermsFrom.isEmpty ? null : d.paymentTermsFrom,
        minOrderAmount: d.minOrderAmount,
        leadTimeDays: d.leadTimeDays,
      );
      if (!mounted) return;
      AppToast.success(
        context,
        activate
            ? '${s.name} vuelve a estar disponible para comprar.'
            : '${s.name} quedó inactivo.',
      );
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      AppToast.error(context, 'No se pudo cambiar el estado: ${_short(e)}');
    }
  }

  Future<bool?> _confirmDeactivate(SupplierOverview s) {
    final currency = currentBusinessCurrencyOrFallback(ref);
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Desactivar ${s.name}'),
        content: Text(
          'Todavía se le deben ${currency.formatAmount(s.payable)} en '
          '${s.payableCount} documento(s). La deuda no se cancela: el '
          'proveedor deja de aparecer para crear órdenes nuevas y su cuenta '
          'corriente queda abierta.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.destructive,
            ),
            child: const Text('Desactivar'),
          ),
        ],
      ),
    );
  }

  // ── Filtrado ────────────────────────────────────────────────────────────

  List<SupplierOverview> get _visible {
    final q = _query.trim().toLowerCase();
    return _overview.suppliers.where((s) {
      switch (_stateFilter) {
        case _StateFilter.active:
          if (!s.isActive) return false;
        case _StateFilter.inactive:
          if (s.isActive) return false;
        case _StateFilter.all:
          break;
      }
      if (_onlyOwing && !s.owesMoney) return false;
      if (_onlyMissingRnc && s.hasRnc) return false;
      if (_onlyMissingTerms && s.terms.type != null) return false;
      if (q.isEmpty) return true;
      final d = s.supplier;
      return d.name.toLowerCase().contains(q) ||
          d.rnc.toLowerCase().contains(q) ||
          d.contactName.toLowerCase().contains(q) ||
          d.phone.toLowerCase().contains(q) ||
          d.email.toLowerCase().contains(q) ||
          s.supplies.any((name) => name.toLowerCase().contains(q));
    }).toList(growable: false);
  }

  // ── Build ───────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final currency = currentBusinessCurrencyOrFallback(ref);
    final canEdit = ref
        .watch(sessionProvider.notifier)
        .hasPermission('compras.proveedores.crear_editar');

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= _kTableBreakpoint;
            if (_error != null && _overview.suppliers.isEmpty) {
              return _errorState();
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _header(currency: currency, wide: wide, canEdit: canEdit),
                if (_refreshing)
                  LinearProgressIndicator(
                    minHeight: 2,
                    backgroundColor: AppColors.muted,
                    color: AppColors.primary,
                  ),
                Expanded(
                  child: _loading
                      ? _skeleton(wide)
                      : _body(currency: currency, wide: wide, canEdit: canEdit),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _errorState() => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error_outline, size: 40, color: AppColors.destructive),
          const SizedBox(height: 12),
          Text(
            _error!,
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.foreground),
          ),
          const SizedBox(height: 12),
          FilledButton(onPressed: _bootstrap, child: const Text('Reintentar')),
        ],
      ),
    ),
  );

  Widget _header({
    required BusinessCurrency currency,
    required bool wide,
    required bool canEdit,
  }) {
    final title = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Proveedores',
          style: TextStyle(
            fontSize: wide ? 28 : 20,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.4,
            color: AppColors.foreground,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          _subtitle(currency),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: wide ? 14 : 12,
            color: AppColors.mutedForeground,
          ),
        ),
      ],
    );

    return Container(
      padding: EdgeInsets.fromLTRB(wide ? 20 : 12, 14, wide ? 24 : 12, 14),
      decoration: BoxDecoration(
        color: AppColors.card,
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const InventoryBackButton(),
          const SizedBox(width: 4),
          Expanded(child: title),
          if (wide) ...[
            OutlinedButton.icon(
              onPressed: () => context.push(AppRoutes.purchasesRegister),
              icon: const Icon(Icons.shopping_cart_outlined, size: 17),
              label: const Text('Nueva orden'),
            ),
            const SizedBox(width: 10),
          ],
          if (canEdit)
            wide
                ? FilledButton.icon(
                    onPressed: _loading ? null : () => _openForm(),
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('Nuevo proveedor'),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 16,
                      ),
                    ),
                  )
                : IconButton(
                    tooltip: 'Nuevo proveedor',
                    onPressed: _loading ? null : () => _openForm(),
                    icon: Icon(Icons.add_circle, color: AppColors.primary),
                  ),
        ],
      ),
    );
  }

  /// El subtítulo dice lo urgente, no lo obvio. «5 proveedores» ya está en el
  /// pie de la tabla; lo que hace falta arriba es qué vence.
  String _subtitle(BusinessCurrency currency) {
    if (_loading) return 'Catálogo de proveedores y condiciones';
    final parts = <String>[
      '${_overview.activeCount} '
          '${_overview.activeCount == 1 ? 'activo' : 'activos'}',
    ];
    if (_overview.totalPayable > 0) {
      parts.add('${currency.formatAmount(_overview.totalPayable)} por pagar');
    }
    final next = _overview.nextDueDate;
    if (next != null) {
      final days = DateTime(next.year, next.month, next.day)
          .difference(DateTime.now())
          .inDays;
      if (days < 0) {
        parts.add('1 factura vencida hace ${-days} d');
      } else if (days == 0) {
        parts.add('1 factura vence hoy');
      } else {
        parts.add('1 factura vence en $days ${days == 1 ? 'día' : 'días'}');
      }
    }
    return parts.join(' · ');
  }

  Widget _body({
    required BusinessCurrency currency,
    required bool wide,
    required bool canEdit,
  }) {
    final items = _visible;
    final padding = EdgeInsets.symmetric(horizontal: wide ? 24 : 12);

    return RefreshIndicator(
      onRefresh: _refresh,
      color: AppColors.primary,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverPadding(
            padding: padding.copyWith(top: 16, bottom: 14),
            sliver: SliverToBoxAdapter(child: _toolbar(wide)),
          ),
          if (!_overview.linksSupported)
            SliverPadding(
              padding: padding.copyWith(bottom: 14),
              sliver: SliverToBoxAdapter(child: _schemaNotice()),
            ),
          if (items.isEmpty)
            SliverPadding(
              padding: padding,
              sliver: SliverToBoxAdapter(child: _empty()),
            )
          else ...[
            if (wide)
              SliverPadding(
                padding: padding,
                sliver: SliverToBoxAdapter(child: _headerRow()),
              ),
            SliverPadding(
              padding: padding,
              sliver: SliverList.builder(
                itemCount: items.length,
                itemBuilder: (context, i) {
                  final s = items[i];
                  final accent = supplierAccent(
                    index: _overview.suppliers.indexOf(s),
                    isPreferred: s.isPreferred,
                    isActive: s.isActive,
                  );
                  return wide
                      ? _SupplierRow(
                          supplier: s,
                          accent: accent,
                          currency: currency,
                          canEdit: canEdit,
                          onOpen: () => _openSupplier(s),
                          onEdit: () => _openForm(edit: s),
                          onToggleActive: () => _toggleActive(s),
                          onOrders: () => _openSupplier(s, tab: 'ordenes'),
                          onAccount: () => _openSupplier(s, tab: 'cuenta'),
                        )
                      : _SupplierCard(
                          supplier: s,
                          accent: accent,
                          currency: currency,
                          onOpen: () => _openSupplier(s),
                        );
                },
              ),
            ),
            SliverPadding(
              padding: padding.copyWith(top: wide ? 0 : 4, bottom: 28),
              sliver: SliverToBoxAdapter(child: _footer(currency, items, wide)),
            ),
          ],
          const SliverToBoxAdapter(child: SizedBox(height: 28)),
        ],
      ),
    );
  }

  Widget _toolbar(bool wide) {
    final search = TextField(
      controller: _searchCtrl,
      onChanged: (v) => setState(() => _query = v),
      textInputAction: TextInputAction.search,
      decoration: InputDecoration(
        isDense: true,
        hintText: 'Buscar por nombre, RNC, contacto o insumo que provee',
        prefixIcon: Icon(Icons.search, color: AppColors.mutedForeground),
        suffixIcon: _query.isEmpty
            ? null
            : IconButton(
                tooltip: 'Limpiar',
                icon: const Icon(Icons.close, size: 18),
                onPressed: () {
                  _searchCtrl.clear();
                  setState(() => _query = '');
                },
              ),
        filled: true,
        fillColor: AppColors.card,
        contentPadding: const EdgeInsets.symmetric(vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          borderSide: BorderSide(color: AppColors.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          borderSide: BorderSide(color: AppColors.border),
        ),
      ),
    );

    final pills = <Widget>[
      _FilterPill(
        label: 'Por pagar',
        count: _overview.owingCount,
        selected: _onlyOwing,
        color: AppColors.primary,
        onTap: () => setState(() => _onlyOwing = !_onlyOwing),
      ),
      _FilterPill(
        label: 'Sin RNC',
        count: _overview.withoutRncCount,
        selected: _onlyMissingRnc,
        color: AppColors.warning,
        onTap: () => setState(() => _onlyMissingRnc = !_onlyMissingRnc),
      ),
      _FilterPill(
        label: 'Sin condiciones',
        count: _overview.withoutTermsCount,
        selected: _onlyMissingTerms,
        color: AppColors.warning,
        onTap: () => setState(() => _onlyMissingTerms = !_onlyMissingTerms),
      ),
      PopupMenuButton<_StateFilter>(
        tooltip: 'Estado',
        onSelected: (v) => setState(() => _stateFilter = v),
        itemBuilder: (_) => const [
          PopupMenuItem(value: _StateFilter.active, child: Text('Activos')),
          PopupMenuItem(value: _StateFilter.all, child: Text('Todos')),
          PopupMenuItem(value: _StateFilter.inactive, child: Text('Inactivos')),
        ],
        child: _FilterPill(
          label: switch (_stateFilter) {
            _StateFilter.active => 'Activos',
            _StateFilter.all => 'Todos',
            _StateFilter.inactive => 'Inactivos',
          },
          selected: _stateFilter != _StateFilter.active,
          color: AppColors.info,
          trailingIcon: Icons.expand_more,
        ),
      ),
    ];

    if (!wide) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          search,
          const SizedBox(height: 10),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final pill in pills) ...[pill, const SizedBox(width: 8)],
              ],
            ),
          ),
        ],
      );
    }

    return Row(
      children: [
        Expanded(child: search),
        for (final pill in pills) ...[const SizedBox(width: 10), pill],
      ],
    );
  }

  /// Aviso de esquema. No es una alerta de error: la pantalla funciona, sólo
  /// que sin la parte que necesita la migración.
  Widget _schemaNotice() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.infoSurface,
        border: Border.all(color: AppColors.info.withValues(alpha: 0.30)),
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.link_off, size: 18, color: AppColors.info),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Este negocio todavía no tiene el vínculo proveedor↔insumo. La '
              'columna «Provee» se arma con el suplidor preferido de cada '
              'insumo. Con la migración 20260819_0003 aplicada se pueden '
              'declarar los insumos de cada proveedor, con su código y su '
              'precio de lista.',
              style: TextStyle(
                fontSize: 12,
                height: 1.45,
                color: AppColors.foreground,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _headerRow() {
    Widget head(String text, {TextAlign align = TextAlign.left}) => Text(
      text.toUpperCase(),
      textAlign: align,
      style: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w800,
        letterSpacing: 0.5,
        color: AppColors.mutedForeground,
      ),
    );

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.background,
        border: Border.all(color: AppColors.border),
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(AppRadius.lg),
        ),
      ),
      child: Row(
        children: [
          Expanded(child: head('Proveedor')),
          SizedBox(width: _kColSupplies, child: head('Provee')),
          const SizedBox(width: 12),
          SizedBox(width: _kColTerms, child: head('Términos')),
          const SizedBox(width: 12),
          SizedBox(
            width: _kColSpend,
            child: head('Compras 12 m', align: TextAlign.right),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: _kColDue,
            child: head('Por pagar', align: TextAlign.right),
          ),
          const SizedBox(width: 12),
          SizedBox(width: _kColFulfillment, child: head('Cumplimiento')),
          const SizedBox(width: 12),
          const SizedBox(width: _kColActions),
        ],
      ),
    );
  }

  Widget _footer(
    BusinessCurrency currency,
    List<SupplierOverview> shown,
    bool wide,
  ) {
    final total = _overview.suppliers.length;
    final hidden = total - shown.length;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
      decoration: BoxDecoration(
        color: AppColors.background,
        border: Border.all(color: AppColors.border),
        borderRadius: wide
            ? const BorderRadius.vertical(bottom: Radius.circular(AppRadius.lg))
            : BorderRadius.circular(AppRadius.lg),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '$total ${total == 1 ? 'proveedor' : 'proveedores'} · '
              '${_overview.activeCount} activos · '
              '${_overview.inactiveCount} inactivos'
              '${hidden > 0 ? ' · $hidden fuera del filtro' : ''}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: AppColors.mutedForeground),
            ),
          ),
          Text(
            'Compras 12 meses  ',
            style: TextStyle(fontSize: 12, color: AppColors.mutedForeground),
          ),
          Text(
            currency.formatAmount(_overview.totalSpend),
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w800,
              color: AppColors.foreground,
            ),
          ),
        ],
      ),
    );
  }

  Widget _empty() {
    final filtering =
        _query.isNotEmpty ||
        _onlyOwing ||
        _onlyMissingRnc ||
        _onlyMissingTerms ||
        _stateFilter != _StateFilter.active;
    return Container(
      padding: const EdgeInsets.all(40),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        children: [
          Icon(
            filtering ? Icons.filter_alt_off_outlined : Icons.local_shipping_outlined,
            size: 38,
            color: AppColors.mutedForeground,
          ),
          const SizedBox(height: 12),
          Text(
            filtering
                ? 'Ningún proveedor cumple ese filtro.'
                : 'Todavía no hay proveedores.',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: AppColors.foreground,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            filtering
                ? 'Probá quitando alguno o buscando otra cosa.'
                : 'Cargá a quién le comprás para que las órdenes de compra, '
                      'las cuentas por pagar y el reorden sepan a quién '
                      'apuntar.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: AppColors.mutedForeground),
          ),
          if (!filtering) ...[
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () => _openForm(),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Nuevo proveedor'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _skeleton(bool wide) => SingleChildScrollView(
    padding: EdgeInsets.fromLTRB(wide ? 24 : 12, 16, wide ? 24 : 12, 24),
    child: Column(
      children: [
        const SkeletonBox(height: 44, borderRadius: AppRadius.md),
        const SizedBox(height: 16),
        for (var i = 0; i < 6; i++) ...[
          Container(
            height: 72,
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
            decoration: BoxDecoration(
              color: AppColors.card,
              border: Border.all(color: AppColors.border),
            ),
            child: Row(
              children: const [
                SkeletonBox(width: 36, height: 36, borderRadius: 10),
                SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      SkeletonBox(width: 170, height: 13, borderRadius: 6),
                      SizedBox(height: 8),
                      SkeletonBox(width: 120, height: 10, borderRadius: 6),
                    ],
                  ),
                ),
                SizedBox(width: 12),
                SkeletonBox(width: 110, height: 22, borderRadius: 8),
                SizedBox(width: 12),
                SkeletonBox(width: 90, height: 22, borderRadius: 8),
              ],
            ),
          ),
        ],
      ],
    ),
  );
}

// ── Fila ancha ─────────────────────────────────────────────────────────────

/// Fila de la tabla. La novedad respecto del CRUD anterior es que TODA la
/// fila abre el proveedor: el botón «Abrir» es el refuerzo visual, no el
/// único blanco.
class _SupplierRow extends StatelessWidget {
  final SupplierOverview supplier;
  final Color accent;
  final BusinessCurrency currency;
  final bool canEdit;
  final VoidCallback onOpen;
  final VoidCallback onEdit;
  final VoidCallback onToggleActive;
  final VoidCallback onOrders;
  final VoidCallback onAccount;

  const _SupplierRow({
    required this.supplier,
    required this.accent,
    required this.currency,
    required this.canEdit,
    required this.onOpen,
    required this.onEdit,
    required this.onToggleActive,
    required this.onOrders,
    required this.onAccount,
  });

  @override
  Widget build(BuildContext context) {
    final s = supplier;
    final inactive = !s.isActive;

    return Material(
      color: inactive ? AppColors.background : AppColors.card,
      child: InkWell(
        onTap: onOpen,
        child: Ink(
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(color: AppColors.border),
              right: BorderSide(color: AppColors.border),
              bottom: BorderSide(color: AppColors.border),
            ),
          ),
          child: Opacity(
            opacity: inactive ? 0.62 : 1,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: 18,
                vertical: 12,
              ),
              child: Row(
                children: [
                  Expanded(child: _identity()),
                  SizedBox(width: _kColSupplies, child: _supplies()),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: _kColTerms,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: SupplierTermsChip(terms: s.terms),
                    ),
                  ),
                  const SizedBox(width: 12),
                  SizedBox(width: _kColSpend, child: _spend()),
                  const SizedBox(width: 12),
                  SizedBox(width: _kColDue, child: _due()),
                  const SizedBox(width: 12),
                  SizedBox(width: _kColFulfillment, child: _fulfillment()),
                  const SizedBox(width: 12),
                  SizedBox(width: _kColActions, child: _actions()),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _identity() {
    final s = supplier;
    final tags = <Widget>[
      if (s.isPreferred)
        SupplierTag(label: 'PRINCIPAL', color: AppColors.primary),
      if (!s.hasRnc && s.isActive)
        SupplierTag(label: 'FALTA RNC', color: AppColors.warning),
      if (!s.isActive)
        SupplierTag(label: 'INACTIVO', color: AppColors.mutedForeground),
    ];

    final meta = <String>[
      s.hasRnc ? 'RNC ${s.supplier.rnc}' : 'Sin RNC',
      if (s.supplier.contactName.isNotEmpty)
        s.supplier.contactName
      else if (s.supplier.phone.isNotEmpty)
        s.supplier.phone
      else
        'sin contacto',
    ];

    return Row(
      children: [
        SupplierAvatar(initials: s.initials, color: accent),
        const SizedBox(width: 11),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      s.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: AppColors.foreground,
                      ),
                    ),
                  ),
                  for (final tag in tags) ...[
                    const SizedBox(width: 7),
                    Flexible(child: tag),
                  ],
                ],
              ),
              const SizedBox(height: 2),
              Text(
                meta.join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  color: AppColors.mutedForeground,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _supplies() {
    final s = supplier;
    if (s.suppliesCount == 0) {
      return Text(
        'Sin insumos vinculados',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 11.5, color: AppColors.mutedForeground),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          s.supplies.take(3).join(', '),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            color: AppColors.foreground,
          ),
        ),
        Text(
          '${s.suppliesCount} ${s.suppliesCount == 1 ? 'insumo' : 'insumos'}',
          style: TextStyle(fontSize: 11, color: AppColors.mutedForeground),
        ),
      ],
    );
  }

  Widget _spend() {
    final s = supplier;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          s.orders == 0 ? '—' : currency.formatAmount(s.spend),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            color: s.orders == 0
                ? AppColors.mutedForeground
                : AppColors.foreground,
          ),
        ),
        Text(
          s.orders == 0
              ? 'sin compras 12 m'
              : '${s.orders} ${s.orders == 1 ? 'orden' : 'órdenes'}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 10.5, color: AppColors.mutedForeground),
        ),
      ],
    );
  }

  /// La columna que decide a quién se le paga primero. El vencimiento en
  /// ámbar (o rojo si ya pasó) es lo único que se lee de un vistazo.
  Widget _due() {
    final s = supplier;
    if (!s.owesMoney) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '—',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w800,
              color: AppColors.mutedForeground,
            ),
          ),
          Text(
            'al día',
            style: TextStyle(fontSize: 10.5, color: AppColors.mutedForeground),
          ),
        ],
      );
    }

    final days = s.daysToNextDue();
    final overdue = s.overdueCount > 0 || (days != null && days < 0);
    final color = overdue ? AppColors.destructive : AppColors.warning;
    final sub = () {
      if (overdue) {
        return s.overdueCount > 1
            ? '${s.overdueCount} vencidas'
            : 'vencida hace ${-(days ?? 0)} d';
      }
      if (days == null) return '${s.payableCount} sin fecha';
      if (days == 0) return 'vence hoy';
      return 'vence en $days ${days == 1 ? 'día' : 'días'}';
    }();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          currency.formatAmount(s.payable),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w800,
            color: color,
          ),
        ),
        Text(
          sub,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 10.5,
            fontWeight: FontWeight.w800,
            color: color,
          ),
        ),
      ],
    );
  }

  Widget _fulfillment() {
    final s = supplier;
    final pct = s.fulfillmentPct;
    final lead = s.avgLeadDays;
    final label = pct == null
        ? 'sin órdenes cerradas'
        : '${pct.round()}%'
              '${lead == null ? '' : ' · ${lead.round()} d promedio'}';
    return SupplierFulfillmentBar(pct: pct, label: label);
  }

  Widget _actions() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        OutlinedButton(
          onPressed: onOpen,
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            minimumSize: const Size(0, 40),
            visualDensity: VisualDensity.compact,
          ),
          child: const Text('Abrir'),
        ),
        PopupMenuButton<String>(
          tooltip: 'Más',
          icon: Icon(Icons.more_vert, size: 19, color: AppColors.mutedForeground),
          onSelected: (value) => switch (value) {
            'edit' => onEdit(),
            'orders' => onOrders(),
            'account' => onAccount(),
            'toggle' => onToggleActive(),
            _ => null,
          },
          itemBuilder: (_) => [
            if (canEdit)
              const PopupMenuItem(value: 'edit', child: Text('Editar ficha')),
            const PopupMenuItem(
              value: 'orders',
              child: Text('Ver órdenes de compra'),
            ),
            const PopupMenuItem(
              value: 'account',
              child: Text('Ver cuenta corriente'),
            ),
            if (canEdit)
              PopupMenuItem(
                value: 'toggle',
                child: Text(supplier.isActive ? 'Desactivar' : 'Reactivar'),
              ),
          ],
        ),
      ],
    );
  }
}

// ── Tarjeta compacta ───────────────────────────────────────────────────────

class _SupplierCard extends StatelessWidget {
  final SupplierOverview supplier;
  final Color accent;
  final BusinessCurrency currency;
  final VoidCallback onOpen;

  const _SupplierCard({
    required this.supplier,
    required this.accent,
    required this.currency,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final s = supplier;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        child: InkWell(
          onTap: onOpen,
          borderRadius: BorderRadius.circular(AppRadius.lg),
          child: Ink(
            decoration: BoxDecoration(
              color: AppColors.card,
              borderRadius: BorderRadius.circular(AppRadius.lg),
              border: Border.all(color: AppColors.border),
              boxShadow: AppShadows.soft,
            ),
            padding: const EdgeInsets.all(14),
            child: Opacity(
              opacity: s.isActive ? 1 : 0.62,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      SupplierAvatar(initials: s.initials, color: accent),
                      const SizedBox(width: 11),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              s.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                                color: AppColors.foreground,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              s.hasRnc
                                  ? 'RNC ${s.supplier.rnc}'
                                  : 'Sin RNC registrado',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 11.5,
                                color: AppColors.mutedForeground,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Icon(
                        Icons.chevron_right,
                        color: AppColors.mutedForeground,
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      SupplierTermsChip(terms: s.terms),
                      if (s.owesMoney)
                        SupplierTag(
                          label:
                              '${currency.formatAmount(s.payable)} por pagar',
                          color: s.overdueCount > 0
                              ? AppColors.destructive
                              : AppColors.warning,
                        ),
                      if (s.suppliesCount > 0)
                        SupplierTag(
                          label: '${s.suppliesCount} insumos',
                          color: AppColors.info,
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          s.orders == 0
                              ? 'Sin compras en 12 meses'
                              : '${currency.formatAmount(s.spend)} · '
                                    '${s.orders} órdenes',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12.5,
                            color: AppColors.mutedForeground,
                          ),
                        ),
                      ),
                      if (s.fulfillmentPct != null)
                        Text(
                          '${s.fulfillmentPct!.round()}% completas',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: SupplierFulfillmentBar.colorFor(
                              s.fulfillmentPct,
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ── Píldora de filtro ──────────────────────────────────────────────────────

class _FilterPill extends StatelessWidget {
  final String label;
  final int? count;
  final bool selected;
  final Color color;
  final IconData? trailingIcon;
  final VoidCallback? onTap;

  const _FilterPill({
    required this.label,
    required this.selected,
    required this.color,
    this.count,
    this.trailingIcon,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: Container(
        constraints: const BoxConstraints(minHeight: 44),
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? color.withValues(alpha: 0.08) : AppColors.card,
          border: Border.all(
            color: selected ? color.withValues(alpha: 0.45) : AppColors.border,
          ),
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                color: selected ? color : AppColors.foreground,
              ),
            ),
            if (count != null && count! > 0) ...[
              const SizedBox(width: 6),
              Container(
                constraints: const BoxConstraints(minWidth: 18, minHeight: 18),
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(horizontal: 5),
                decoration: BoxDecoration(
                  color: selected ? color : AppColors.muted,
                  borderRadius: BorderRadius.circular(AppRadius.md),
                ),
                child: Text(
                  '$count',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    color: selected ? Colors.white : AppColors.foreground,
                  ),
                ),
              ),
            ],
            if (trailingIcon != null) ...[
              const SizedBox(width: 4),
              Icon(trailingIcon, size: 18, color: AppColors.mutedForeground),
            ],
          ],
        ),
      ),
    );
  }
}
