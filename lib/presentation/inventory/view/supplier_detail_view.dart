// Fase 3 Proveedores — el interior: la pantalla que hoy no existe.
//
// Hasta ahora un proveedor era una fila que se editaba. Para saber cuánto se
// le compró, a qué precio o cuánto se le debe había que salir a Compras y
// cruzarlo a mano. Esta pantalla es el otro lado de la puerta:
//
//   · Encabezado — quién es, en qué condiciones y las dos acciones reales:
//     editar la ficha y crearle una orden.
//   · KPIs — volumen, deuda, cumplimiento y tiempo de entrega. Los cuatro
//     salen de datos que YA existían pero que nadie había cruzado.
//   · Insumos que provee — el vínculo que faltaba, con la historia de precio
//     de cada uno. Un insumo que se le compra pero nadie declaró aparece
//     marcado: es exactamente el que el reorden no puede encontrar.
//   · Órdenes y cuenta corriente — el historial y la deuda, sin salir.
//
// Nada acá inventa datos. Cuando una señal no está (sin `supplier_items`, sin
// `supplier_credits`, sin órdenes) el bloque lo dice y sigue.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
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
import 'widgets/link_supplier_item_dialog.dart';
import 'widgets/supplier_form_dialog.dart';
import 'widgets/supplier_visuals.dart';
import 'package:mangopos/core/utils/friendly_error.dart';

enum SupplierTab { items, orders, account }

const double _kTableBreakpoint = 900;

const double _kColCode = 158;
const double _kColPrice = 140;
const double _kColTrend = 140;
const double _kColLast = 130;
const double _kColItemActions = 156;

final DateFormat _fmtDate = DateFormat('dd/MM/yy');

class SupplierDetailView extends ConsumerStatefulWidget {
  final String supplierId;
  final SupplierTab initialTab;

  const SupplierDetailView({
    super.key,
    required this.supplierId,
    this.initialTab = SupplierTab.items,
  });

  @override
  ConsumerState<SupplierDetailView> createState() => _SupplierDetailViewState();
}

class _SupplierDetailViewState extends ConsumerState<SupplierDetailView> {
  bool _loading = true;
  bool _refreshing = false;
  String? _error;
  String? _businessId;
  SupplierDetail? _detail;
  late SupplierTab _tab;

  @override
  void initState() {
    super.initState();
    _tab = widget.initialTab;
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
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
        _error = FriendlyError.from(e);
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
      final detail = await _repo.getSupplierDetail(
        businessId: businessId,
        supplierId: widget.supplierId,
      );
      if (!mounted) return;
      setState(() {
        _detail = detail;
        _loading = false;
        _refreshing = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _refreshing = false;
        _error = _detail == null ? FriendlyError.from(e) : null;
      });
      if (_detail != null && mounted) {
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

  Future<void> _openEdit() async {
    final businessId = _businessId;
    final detail = _detail;
    if (businessId == null || detail == null) return;
    final saved = await showSupplierFormDialog(
      context,
      businessId: businessId,
      repo: _repo,
      edit: detail.overview.supplier,
    );
    if (saved) await _refresh();
  }

  Future<void> _linkItem() async {
    final businessId = _businessId;
    final detail = _detail;
    if (businessId == null || detail == null) return;
    final saved = await showLinkSupplierItemDialog(
      context,
      businessId: businessId,
      supplierId: widget.supplierId,
      supplierName: detail.overview.name,
      repo: _repo,
      alreadyLinked: {
        for (final item in detail.items)
          if (item.linked) item.itemId,
      },
    );
    if (saved) await _refresh();
  }

  /// Declarar formalmente un insumo que ya se le compra. Es el atajo del caso
  /// más común: la relación existe hace meses en las órdenes y sólo falta
  /// escribirla donde el reorden la pueda leer.
  Future<void> _declare(SupplierItemLink item) async {
    final businessId = _businessId;
    if (businessId == null) return;
    try {
      final ok = await _repo.linkItem(
        businessId: businessId,
        supplierId: widget.supplierId,
        itemId: item.itemId,
        purchaseUnit: item.purchaseUnit.isEmpty ? null : item.purchaseUnit,
        listPrice: item.price,
      );
      if (!mounted) return;
      if (!ok) {
        AppToast.warning(
          context,
          'Falta la migración 20260819_0003: todavía no hay dónde guardar el '
          'vínculo.',
        );
        return;
      }
      AppToast.success(context, '${item.itemName} quedó vinculado.');
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      AppToast.error(context, 'No se pudo vincular: ${_short(e)}');
    }
  }

  Future<void> _unlink(SupplierItemLink item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Quitar ${item.itemName}'),
        content: const Text(
          'Deja de declarar que este proveedor lo provee. No borra el insumo '
          'ni las compras ya hechas: sólo el reorden deja de proponerlo.',
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
            child: const Text('Quitar'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _repo.unlinkItem(
        supplierId: widget.supplierId,
        itemId: item.itemId,
      );
      if (mounted) await _refresh();
    } catch (e) {
      if (!mounted) return;
      AppToast.error(context, 'No se pudo quitar: ${_short(e)}');
    }
  }

  Future<void> _togglePreferred(SupplierItemLink item) async {
    try {
      final ok = await _repo.setPreferredSupplier(
        itemId: item.itemId,
        supplierId: item.preferred ? null : widget.supplierId,
      );
      if (!mounted) return;
      if (!ok) {
        AppToast.warning(
          context,
          'Falta la migración 20260813_0001: el insumo todavía no tiene '
          'suplidor preferido.',
        );
        return;
      }
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      AppToast.error(context, 'No se pudo cambiar: ${_short(e)}');
    }
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
            if (_error != null && _detail == null) return _errorState();
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _header(wide: wide, canEdit: canEdit),
                if (_refreshing)
                  LinearProgressIndicator(
                    minHeight: 2,
                    backgroundColor: AppColors.muted,
                    color: AppColors.primary,
                  ),
                Expanded(
                  child: _loading || _detail == null
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

  Widget _header({required bool wide, required bool canEdit}) {
    final s = _detail?.overview;
    final name = s?.name ?? 'Proveedor';
    final accent = supplierAccent(
      index: 0,
      isPreferred: s?.isPreferred ?? false,
      isActive: s?.isActive ?? true,
    );

    final meta = <String>[
      if (s != null && s.hasRnc) 'RNC ${s.supplier.rnc}' else 'Sin RNC',
      if (s != null && s.supplier.contactName.isNotEmpty) s.supplier.contactName,
      if (s != null && s.supplier.phone.isNotEmpty) s.supplier.phone,
      if (s != null && s.supplier.email.isNotEmpty) s.supplier.email,
    ];

    final actions = <Widget>[
      if (canEdit)
        OutlinedButton.icon(
          onPressed: _loading ? null : _openEdit,
          icon: const Icon(Icons.edit_outlined, size: 17),
          label: const Text('Editar'),
        ),
      FilledButton.icon(
        onPressed: _loading
            ? null
            : () => context.push(AppRoutes.purchasesRegister),
        icon: const Icon(Icons.shopping_cart_outlined, size: 17),
        label: const Text('Nueva orden'),
      ),
    ];

    return Container(
      padding: EdgeInsets.fromLTRB(wide ? 20 : 12, 14, wide ? 24 : 12, 14),
      decoration: BoxDecoration(
        color: AppColors.card,
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconButton(
                tooltip: 'Volver a Proveedores',
                onPressed: () => context.canPop()
                    ? context.pop()
                    : context.go(AppRoutes.inventorySuppliers),
                icon: const Icon(Icons.arrow_back),
              ),
              const SizedBox(width: 4),
              SupplierAvatar(
                initials: s?.initials ?? '··',
                color: accent,
                size: 46,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: wide ? 26 : 20,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -0.4,
                              color: AppColors.foreground,
                            ),
                          ),
                        ),
                        if (s != null) ...[
                          const SizedBox(width: 9),
                          SupplierTag(
                            label: s.isActive ? 'ACTIVO' : 'INACTIVO',
                            color: s.isActive
                                ? AppColors.success
                                : AppColors.mutedForeground,
                          ),
                          if (s.isPreferred) ...[
                            const SizedBox(width: 6),
                            Flexible(
                              child: SupplierTag(
                                label:
                                    'PRINCIPAL EN ${s.preferredCount} '
                                    '${s.preferredCount == 1 ? 'INSUMO' : 'INSUMOS'}',
                                color: AppColors.primary,
                              ),
                            ),
                          ],
                        ],
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      meta.join('  ·  '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        color: AppColors.mutedForeground,
                      ),
                    ),
                  ],
                ),
              ),
              if (wide)
                for (final action in actions) ...[
                  const SizedBox(width: 10),
                  action,
                ],
            ],
          ),
          if (!wide) ...[
            const SizedBox(height: 10),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final action in actions) ...[
                    action,
                    const SizedBox(width: 8),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _body({
    required BusinessCurrency currency,
    required bool wide,
    required bool canEdit,
  }) {
    final padding = EdgeInsets.symmetric(horizontal: wide ? 24 : 12);
    return RefreshIndicator(
      onRefresh: _refresh,
      color: AppColors.primary,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverPadding(
            padding: padding.copyWith(top: 16),
            sliver: SliverToBoxAdapter(child: _kpis(currency, wide)),
          ),
          SliverPadding(
            padding: padding.copyWith(top: 16),
            sliver: SliverToBoxAdapter(child: _tabs()),
          ),
          ...switch (_tab) {
            SupplierTab.items => _itemsSlivers(currency, wide, canEdit),
            SupplierTab.orders => _ordersSlivers(currency, wide),
            SupplierTab.account => _accountSlivers(currency, wide),
          },
          const SliverToBoxAdapter(child: SizedBox(height: 32)),
        ],
      ),
    );
  }

  // ── KPIs ────────────────────────────────────────────────────────────────

  Widget _kpis(BusinessCurrency currency, bool wide) {
    final s = _detail!.overview;
    final pct = s.fulfillmentPct;
    final lead = s.avgLeadDays;
    final promised = s.supplier.leadTimeDays;
    final days = s.daysToNextDue();

    String dueSub() {
      if (!s.owesMoney) return 'Nada pendiente con este proveedor';
      if (s.overdueCount > 0) {
        return '${s.overdueCount} '
            '${s.overdueCount == 1 ? 'factura vencida' : 'facturas vencidas'}';
      }
      if (days == null) return '${s.payableCount} documento(s) sin fecha';
      if (days == 0) return '1 factura vence hoy';
      return '1 factura vence en $days ${days == 1 ? 'día' : 'días'}';
    }

    String leadSub() {
      if (lead == null) return 'Sin órdenes recibidas con fecha';
      if (promised == null) return 'promedio de las últimas recibidas';
      final diff = lead - promised;
      if (diff.abs() < 0.5) return 'cumple los $promised d prometidos';
      return diff > 0
          ? '${diff.round()} d más de los $promised prometidos'
          : '${(-diff).round()} d antes de lo prometido';
    }

    final cards = <Widget>[
      _KpiCard(
        icon: Icons.shopping_bag_outlined,
        iconColor: AppColors.success,
        label: 'Compras 12 meses',
        value: s.orders == 0 ? '—' : currency.formatAmount(s.spend),
        sub: s.orders == 0
            ? 'Sin compras en el último año'
            : '${s.orders} ${s.orders == 1 ? 'orden' : 'órdenes'}',
      ),
      _KpiCard(
        icon: Icons.event_outlined,
        iconColor: s.overdueCount > 0 ? AppColors.destructive : AppColors.warning,
        label: 'Por pagar',
        value: s.owesMoney ? currency.formatAmount(s.payable) : '—',
        valueColor: s.owesMoney
            ? (s.overdueCount > 0 ? AppColors.destructive : AppColors.warning)
            : null,
        sub: dueSub(),
      ),
      _KpiCard(
        icon: Icons.local_shipping_outlined,
        iconColor: SupplierFulfillmentBar.colorFor(pct),
        label: 'Cumplimiento',
        value: pct == null ? '—' : '${pct.round()}%',
        sub: pct == null
            ? 'Todavía no hay órdenes cerradas'
            : '${s.ordersReceived} de ${s.ordersClosed} completas',
      ),
      _KpiCard(
        icon: Icons.schedule,
        iconColor: AppColors.info,
        label: 'Tiempo de entrega',
        value: lead == null
            ? '—'
            : '${lead.round()} ${lead.round() == 1 ? 'día' : 'días'}',
        sub: leadSub(),
      ),
    ];

    if (!wide) {
      return Column(
        children: [
          for (var i = 0; i < cards.length; i++) ...[
            if (i > 0) const SizedBox(height: 10),
            cards[i],
          ],
        ],
      );
    }
    return Row(
      children: [
        for (var i = 0; i < cards.length; i++) ...[
          if (i > 0) const SizedBox(width: 14),
          Expanded(child: cards[i]),
        ],
      ],
    );
  }

  Widget _tabs() {
    final d = _detail!;
    Widget tab(SupplierTab value, String label, int count, Color? badge) {
      final selected = _tab == value;
      return InkWell(
        onTap: () => setState(() => _tab = value),
        child: Padding(
          padding: const EdgeInsets.only(right: 20),
          child: Container(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 11),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: selected ? AppColors.primary : Colors.transparent,
                  width: 2,
                ),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                    color: selected
                        ? AppColors.foreground
                        : AppColors.mutedForeground,
                  ),
                ),
                if (count > 0) ...[
                  const SizedBox(width: 7),
                  Container(
                    constraints: const BoxConstraints(
                      minWidth: 18,
                      minHeight: 18,
                    ),
                    alignment: Alignment.center,
                    padding: const EdgeInsets.symmetric(horizontal: 5),
                    decoration: BoxDecoration(
                      color: selected
                          ? AppColors.foreground
                          : (badge ?? AppColors.muted),
                      borderRadius: BorderRadius.circular(AppRadius.md),
                    ),
                    child: Text(
                      '$count',
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w800,
                        color: selected ? Colors.white : AppColors.foreground,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            tab(SupplierTab.items, 'Insumos que provee', d.items.length, null),
            tab(SupplierTab.orders, 'Órdenes de compra', d.orders.length, null),
            tab(
              SupplierTab.account,
              'Cuenta corriente',
              d.payables.length,
              AppColors.warning.withValues(alpha: 0.16),
            ),
          ],
        ),
      ),
    );
  }

  // ── Pestaña: insumos que provee ─────────────────────────────────────────

  List<Widget> _itemsSlivers(
    BusinessCurrency currency,
    bool wide,
    bool canEdit,
  ) {
    final d = _detail!;
    final padding = EdgeInsets.symmetric(horizontal: wide ? 24 : 12);

    return [
      SliverPadding(
        padding: padding.copyWith(top: 18, bottom: 12),
        sliver: SliverToBoxAdapter(child: _itemsToolbar(wide, canEdit)),
      ),
      if (d.items.isEmpty)
        SliverPadding(
          padding: padding,
          sliver: SliverToBoxAdapter(
            child: _emptyBlock(
              icon: Icons.link_off,
              title: 'Nada vinculado todavía',
              body:
                  'Sin este vínculo, «Sugerencias de reorden» puede decir que '
                  'falta un insumo pero no a quién comprarlo. Se puede '
                  'declarar a mano, o aparece solo en cuanto se le registre '
                  'una compra.',
            ),
          ),
        )
      else ...[
        if (wide)
          SliverPadding(
            padding: padding,
            sliver: SliverToBoxAdapter(child: _itemsHeaderRow()),
          ),
        SliverPadding(
          padding: padding,
          sliver: SliverList.builder(
            itemCount: d.items.length,
            itemBuilder: (context, i) => _ItemRow(
              item: d.items[i],
              currency: currency,
              wide: wide,
              canEdit: canEdit,
              linksSupported: d.linksSupported,
              onDeclare: () => _declare(d.items[i]),
              onUnlink: () => _unlink(d.items[i]),
              onTogglePreferred: () => _togglePreferred(d.items[i]),
            ),
          ),
        ),
      ],
      SliverPadding(
        padding: padding.copyWith(top: 18),
        sliver: SliverToBoxAdapter(child: _commercialPanels(currency, wide)),
      ),
    ];
  }

  Widget _itemsToolbar(bool wide, bool canEdit) {
    final d = _detail!;
    final implicit = d.implicitItemsCount;

    final caption = implicit > 0
        ? '$implicit ${implicit == 1 ? 'insumo se le compra' : 'insumos se le compran'} '
              'sin estar declarados — el reorden todavía no los ve'
        : 'El vínculo que le falta a Sugerencias de reorden para generar la '
              'orden sola';

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Insumos que provee',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  color: AppColors.foreground,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                caption,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  color: implicit > 0
                      ? AppColors.warning
                      : AppColors.mutedForeground,
                  fontWeight: implicit > 0 ? FontWeight.w700 : FontWeight.w400,
                ),
              ),
            ],
          ),
        ),
        if (canEdit) ...[
          const SizedBox(width: 12),
          OutlinedButton.icon(
            onPressed: _linkItem,
            icon: const Icon(Icons.add, size: 16),
            label: const Text('Vincular insumo'),
          ),
        ],
      ],
    );
  }

  Widget _itemsHeaderRow() {
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
          Expanded(child: head('Insumo')),
          SizedBox(width: _kColCode, child: head('Código del proveedor')),
          const SizedBox(width: 12),
          SizedBox(
            width: _kColPrice,
            child: head('Último precio', align: TextAlign.right),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: _kColTrend,
            child: head('Variación', align: TextAlign.right),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: _kColLast,
            child: head('Última compra', align: TextAlign.right),
          ),
          const SizedBox(width: 12),
          const SizedBox(width: _kColItemActions),
        ],
      ),
    );
  }

  /// Las dos cajas de abajo: las condiciones comerciales estructuradas y la
  /// cuenta por pagar. Juntas responden «¿en qué términos le compro y cuánto
  /// le debo?», que es lo que la ficha anterior contestaba con una cadena.
  Widget _commercialPanels(BusinessCurrency currency, bool wide) {
    final terms = _termsPanel(currency);
    final payables = _payablesPanel(currency, compact: true);
    if (!wide) {
      return Column(
        children: [terms, const SizedBox(height: 14), payables],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: terms),
        const SizedBox(width: 14),
        SizedBox(width: 420, child: payables),
      ],
    );
  }

  Widget _termsPanel(BusinessCurrency currency) {
    final s = _detail!.overview;
    final t = s.terms;
    final structured = _repo.termsSupported;

    final cells = <({String label, String value})>[
      (
        label: 'Tipo',
        value: switch (t.type) {
          SupplierTermsType.contado => 'Contado',
          SupplierTermsType.credito => 'Crédito',
          SupplierTermsType.anticipo => 'Anticipo',
          null => 'Sin definir',
        },
      ),
      (
        label: 'Plazo',
        value: t.type == SupplierTermsType.credito && (t.days ?? 0) > 0
            ? '${t.days} días'
            : (t.type == SupplierTermsType.contado ? 'Inmediato' : '—'),
      ),
      (
        label: 'Desde',
        value: t.type != SupplierTermsType.credito
            ? '—'
            : (t.base == SupplierTermsBase.receipt
                  ? 'Fecha de recepción'
                  : 'Fecha de factura'),
      ),
      (label: 'Moneda', value: currency.code),
      (
        label: 'Mínimo de orden',
        value: s.supplier.minOrderAmount == null
            ? '—'
            : currency.formatAmount(s.supplier.minOrderAmount!),
      ),
      (
        label: 'Entrega prometida',
        value: s.supplier.leadTimeDays == null
            ? '—'
            : '${s.supplier.leadTimeDays} días hábiles',
      ),
    ];

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: AppColors.border),
        boxShadow: AppShadows.soft,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.handshake_outlined,
                size: 18,
                color: AppColors.primary,
              ),
              const SizedBox(width: 8),
              Text(
                'Condiciones comerciales',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  color: AppColors.foreground,
                ),
              ),
              const SizedBox(width: 8),
              if (!structured)
                SupplierTag(
                  label: 'HOY ES TEXTO LIBRE',
                  color: AppColors.destructive,
                )
              else if (t.type != null && !t.structured)
                SupplierTag(label: 'SIN CONFIRMAR', color: AppColors.warning),
            ],
          ),
          const SizedBox(height: 14),
          LayoutBuilder(
            builder: (context, constraints) {
              final columns = constraints.maxWidth >= 420 ? 2 : 1;
              final cellWidth =
                  (constraints.maxWidth - 12 * (columns - 1)) / columns;
              return Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  for (final cell in cells)
                    SizedBox(
                      width: cellWidth,
                      child: _TermCell(label: cell.label, value: cell.value),
                    ),
                ],
              );
            },
          ),
          if (t.freeText.trim().isNotEmpty) ...[
            const SizedBox(height: 12),
            _TermCell(label: 'Nota del negocio', value: t.freeText.trim()),
          ],
          const SizedBox(height: 14),
          _termsExplainer(structured, t),
        ],
      ),
    );
  }

  /// El bloque de abajo cambia según lo que la base pueda soportar. No es
  /// decoración: es la diferencia entre poder calcular un vencimiento y no.
  Widget _termsExplainer(bool structured, SupplierTerms t) {
    if (!structured) {
      return _Callout(
        color: AppColors.destructive,
        text:
            'Hoy payment_terms es un TEXT donde se escribe «30 días» o '
            '«contado» a mano. Nada puede calcular un vencimiento, avisar de '
            'un atraso ni ordenar por deuda. Con la migración '
            '20260819_0003 aplicada eso sale gratis.',
      );
    }
    if (t.type == null) {
      return _Callout(
        color: AppColors.warning,
        text: t.freeText.trim().isEmpty
            ? 'Sin condiciones definidas, cada compra a crédito pide la fecha '
                  'de vencimiento a mano. Editá la ficha para configurarlas.'
            : '«${t.freeText.trim()}» no es un plazo simple, así que no se '
                  'convierte en fecha. Se muestra literal y el vencimiento se '
                  'elige en cada compra.',
      );
    }
    if (!t.structured) {
      return _Callout(
        color: AppColors.warning,
        text:
            'Este plazo se dedujo del texto que escribió el negocio, no está '
            'configurado. Abrí «Editar» y confirmalo: recién ahí alimenta los '
            'vencimientos de la cuenta por pagar.',
      );
    }
    if (t.hasDueDate) {
      final due = t.dueDateFrom(DateTime.now());
      return _Callout(
        color: AppColors.success,
        text:
            'Una compra facturada hoy vence el ${_fmtDate.format(due!)}. '
            'La cuenta por pagar lo calcula sola.',
      );
    }
    return _Callout(
      color: AppColors.info,
      text:
          'Contado: cada compra se salda al recibir y no genera cuenta por '
          'pagar.',
    );
  }

  // ── Pestaña: órdenes ────────────────────────────────────────────────────

  List<Widget> _ordersSlivers(BusinessCurrency currency, bool wide) {
    final orders = _detail!.orders;
    final padding = EdgeInsets.symmetric(horizontal: wide ? 24 : 12);
    if (orders.isEmpty) {
      return [
        SliverPadding(
          padding: padding.copyWith(top: 18),
          sliver: SliverToBoxAdapter(
            child: _emptyBlock(
              icon: Icons.receipt_long_outlined,
              title: 'Sin órdenes en 12 meses',
              body:
                  'No hay compras registradas a este proveedor en el último '
                  'año. Con la primera orden aparecen acá su volumen, su '
                  'cumplimiento y su tiempo de entrega.',
            ),
          ),
        ),
      ];
    }
    return [
      SliverPadding(
        padding: padding.copyWith(top: 18),
        sliver: SliverList.builder(
          itemCount: orders.length,
          itemBuilder: (context, i) =>
              _OrderRow(order: orders[i], currency: currency),
        ),
      ),
    ];
  }

  // ── Pestaña: cuenta corriente ───────────────────────────────────────────

  List<Widget> _accountSlivers(BusinessCurrency currency, bool wide) {
    final padding = EdgeInsets.symmetric(horizontal: wide ? 24 : 12);
    return [
      SliverPadding(
        padding: padding.copyWith(top: 18),
        sliver: SliverToBoxAdapter(
          child: _payablesPanel(currency, compact: false),
        ),
      ),
    ];
  }

  Widget _payablesPanel(BusinessCurrency currency, {required bool compact}) {
    final d = _detail!;
    final payables = d.payables;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: AppColors.border),
        boxShadow: AppShadows.soft,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.event_outlined, size: 18, color: AppColors.warning),
              const SizedBox(width: 8),
              Text(
                'Cuenta por pagar',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  color: AppColors.foreground,
                ),
              ),
            ],
          ),
          const SizedBox(height: 13),
          if (payables.isEmpty)
            Text(
              'Nada pendiente con este proveedor.',
              style: TextStyle(fontSize: 12.5, color: AppColors.mutedForeground),
            )
          else ...[
            for (final p in (compact ? payables.take(4) : payables)) ...[
              _PayableRow(payable: p, currency: currency),
              const SizedBox(height: 10),
            ],
            if (compact && payables.length > 4)
              TextButton(
                onPressed: () => setState(() => _tab = SupplierTab.account),
                child: Text('Ver los ${payables.length}'),
              ),
            Divider(color: AppColors.muted, height: 20),
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  'Total por pagar',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppColors.mutedForeground,
                  ),
                ),
                const Spacer(),
                Text(
                  currency.formatAmount(d.overview.payable),
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                    color: AppColors.foreground,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  // ── Auxiliares ──────────────────────────────────────────────────────────

  Widget _emptyBlock({
    required IconData icon,
    required String title,
    required String body,
  }) {
    return Container(
      padding: const EdgeInsets.all(36),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        children: [
          Icon(icon, size: 34, color: AppColors.mutedForeground),
          const SizedBox(height: 12),
          Text(
            title,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: AppColors.foreground,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            body,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              height: 1.5,
              color: AppColors.mutedForeground,
            ),
          ),
        ],
      ),
    );
  }

  Widget _skeleton(bool wide) => SingleChildScrollView(
    padding: EdgeInsets.fromLTRB(wide ? 24 : 12, 16, wide ? 24 : 12, 24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            for (var i = 0; i < 4; i++) ...[
              if (i > 0) const SizedBox(width: 14),
              const Expanded(
                child: SkeletonBox(height: 96, borderRadius: AppRadius.lg),
              ),
            ],
          ],
        ),
        const SizedBox(height: 20),
        const SkeletonBox(height: 34, borderRadius: 8),
        const SizedBox(height: 16),
        for (var i = 0; i < 4; i++) ...[
          const SkeletonBox(height: 66, borderRadius: AppRadius.lg),
          const SizedBox(height: 10),
        ],
      ],
    ),
  );
}

// ── Widgets de apoyo ───────────────────────────────────────────────────────

class _KpiCard extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String label;
  final String value;
  final String sub;
  final Color? valueColor;

  const _KpiCard({
    required this.icon,
    required this.iconColor,
    required this.label,
    required this.value,
    required this.sub,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(17, 15, 17, 15),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: AppColors.border),
        boxShadow: AppShadows.soft,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: iconColor),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  label.toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.5,
                    color: AppColors.mutedForeground,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w800,
              color: valueColor ?? AppColors.foreground,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            sub,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11.5, color: AppColors.mutedForeground),
          ),
        ],
      ),
    );
  }
}

class _TermCell extends StatelessWidget {
  final String label;
  final String value;

  const _TermCell({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label.toUpperCase(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.4,
              color: AppColors.mutedForeground,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            value,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: AppColors.foreground,
            ),
          ),
        ],
      ),
    );
  }
}

class _Callout extends StatelessWidget {
  final Color color;
  final String text;

  const _Callout({required this.color, required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.07),
        border: Border.all(color: color.withValues(alpha: 0.30)),
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          height: 1.5,
          color: AppColors.foreground,
        ),
      ),
    );
  }
}

/// Fila de un insumo provisto. La columna de variación es la novedad: sin
/// ella, el alza del aceite se descubre cuando ya se comió el margen.
class _ItemRow extends StatelessWidget {
  final SupplierItemLink item;
  final BusinessCurrency currency;
  final bool wide;
  final bool canEdit;
  final bool linksSupported;
  final VoidCallback onDeclare;
  final VoidCallback onUnlink;
  final VoidCallback onTogglePreferred;

  const _ItemRow({
    required this.item,
    required this.currency,
    required this.wide,
    required this.canEdit,
    required this.linksSupported,
    required this.onDeclare,
    required this.onUnlink,
    required this.onTogglePreferred,
  });

  @override
  Widget build(BuildContext context) {
    if (!wide) return _card();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
      decoration: BoxDecoration(
        color: item.isSharpRise ? AppColors.warningSurface : AppColors.card,
        border: Border(
          left: BorderSide(color: AppColors.border),
          right: BorderSide(color: AppColors.border),
          bottom: BorderSide(color: AppColors.border),
        ),
      ),
      child: Row(
        children: [
          Expanded(child: _name()),
          SizedBox(width: _kColCode, child: _code()),
          const SizedBox(width: 12),
          SizedBox(width: _kColPrice, child: _price()),
          const SizedBox(width: 12),
          SizedBox(width: _kColTrend, child: _trend()),
          const SizedBox(width: 12),
          SizedBox(width: _kColLast, child: _last()),
          const SizedBox(width: 12),
          SizedBox(width: _kColItemActions, child: _actions()),
        ],
      ),
    );
  }

  Widget _name() {
    final meta = <String>[
      if (item.sku.isNotEmpty) item.sku,
      if (item.purchaseUnit.isNotEmpty)
        item.purchaseUnit
      else if (item.unit.isNotEmpty)
        item.unit,
      if (item.purchases > 0)
        '${item.purchases} ${item.purchases == 1 ? 'compra' : 'compras'}',
    ];

    return Row(
      children: [
        Container(
          width: 3,
          height: 34,
          decoration: BoxDecoration(
            color: item.isSharpRise ? AppColors.warning : Colors.transparent,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      item.itemName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: AppColors.foreground,
                      ),
                    ),
                  ),
                  if (item.preferred) ...[
                    const SizedBox(width: 7),
                    SupplierTag(label: 'PREFERIDO', color: AppColors.primary),
                  ],
                  if (item.isImplicitOnly) ...[
                    const SizedBox(width: 7),
                    Flexible(
                      child: SupplierTag(
                        label: 'SIN VINCULAR',
                        color: AppColors.warning,
                      ),
                    ),
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

  Widget _code() => Text(
    item.supplierCode.isEmpty ? '—' : item.supplierCode,
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    style: TextStyle(
      fontSize: 12.5,
      color: item.supplierCode.isEmpty
          ? AppColors.mutedForeground
          : AppColors.foreground,
    ),
  );

  Widget _price() {
    final price = item.price;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          price == null ? '—' : currency.formatAmount(price),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            color: price == null
                ? AppColors.mutedForeground
                : AppColors.foreground,
          ),
        ),
        Text(
          price == null
              ? 'sin precio'
              : (item.lastPaidPrice != null
                    ? 'último pagado'
                    : 'precio de lista'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 10.5, color: AppColors.mutedForeground),
        ),
      ],
    );
  }

  Widget _trend() {
    final pct = item.variationPct;
    if (pct == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '—',
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w800,
              color: AppColors.mutedForeground,
            ),
          ),
          Text(
            'una sola compra',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 10.5, color: AppColors.mutedForeground),
          ),
        ],
      );
    }

    // Una baja de precio es buena noticia: verde. Una subida por encima del
    // umbral es lo único que hay que mirar hoy: ámbar.
    final rising = pct > 0;
    final color = !rising
        ? AppColors.success
        : (item.isSharpRise ? AppColors.warning : AppColors.mutedForeground);
    final icon = pct.abs() < 0.05
        ? Icons.remove
        : (rising ? Icons.trending_up : Icons.trending_down);
    final prev = item.previousPaidPrice;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 3),
            Flexible(
              child: Text(
                '${rising ? '+' : ''}${pct.toStringAsFixed(1)}%',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w800,
                  color: color,
                ),
              ),
            ),
          ],
        ),
        Text(
          prev == null ? '' : 'desde ${currency.formatAmount(prev)}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 10.5, color: AppColors.mutedForeground),
        ),
      ],
    );
  }

  Widget _last() {
    final at = item.lastPurchaseAt;
    return Text(
      at == null ? 'nunca' : _relative(at),
      textAlign: TextAlign.right,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(fontSize: 12.5, color: AppColors.foreground),
    );
  }

  Widget _actions() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        if (item.isImplicitOnly && canEdit && linksSupported)
          OutlinedButton(
            onPressed: onDeclare,
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              minimumSize: const Size(0, 38),
              visualDensity: VisualDensity.compact,
              foregroundColor: AppColors.primary,
              side: BorderSide(
                color: AppColors.primary.withValues(alpha: 0.45),
              ),
            ),
            child: const Text('Vincular'),
          ),
        if (canEdit)
          PopupMenuButton<String>(
            tooltip: 'Más',
            icon: Icon(
              Icons.more_vert,
              size: 19,
              color: AppColors.mutedForeground,
            ),
            onSelected: (value) => switch (value) {
              'preferred' => onTogglePreferred(),
              'unlink' => onUnlink(),
              _ => null,
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'preferred',
                child: Text(
                  item.preferred
                      ? 'Quitar como preferido'
                      : 'Marcar como preferido',
                ),
              ),
              if (item.linked)
                const PopupMenuItem(
                  value: 'unlink',
                  child: Text('Quitar vínculo'),
                ),
            ],
          ),
      ],
    );
  }

  Widget _card() {
    final pct = item.variationPct;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: item.isSharpRise ? AppColors.warningSurface : AppColors.card,
          borderRadius: BorderRadius.circular(AppRadius.lg),
          border: Border.all(color: AppColors.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    item.itemName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w700,
                      color: AppColors.foreground,
                    ),
                  ),
                ),
                if (item.price != null)
                  Text(
                    currency.formatAmount(item.price!),
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      color: AppColors.foreground,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (item.supplierCode.isNotEmpty)
                  SupplierTag(label: item.supplierCode, color: AppColors.info),
                if (item.preferred)
                  SupplierTag(label: 'PREFERIDO', color: AppColors.primary),
                if (item.isImplicitOnly)
                  SupplierTag(
                    label: 'SIN VINCULAR',
                    color: AppColors.warning,
                  ),
                if (pct != null)
                  SupplierTag(
                    label:
                        '${pct > 0 ? '+' : ''}${pct.toStringAsFixed(1)}% vs '
                        'compra anterior',
                    color: pct > 0
                        ? (item.isSharpRise
                              ? AppColors.warning
                              : AppColors.mutedForeground)
                        : AppColors.success,
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _OrderRow extends StatelessWidget {
  final SupplierOrderRow order;
  final BusinessCurrency currency;

  const _OrderRow({required this.order, required this.currency});

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (order.status) {
      'received' => ('Recibida', AppColors.success),
      'partial' => ('Parcial', AppColors.warning),
      'cancelled' => ('Cancelada', AppColors.mutedForeground),
      'sent' => ('Enviada', AppColors.info),
      _ => ('Borrador', AppColors.mutedForeground),
    };

    final created = order.createdAt;
    final received = order.receivedDate;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(AppRadius.lg),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          children: [
            SupplierTag(label: label.toUpperCase(), color: color),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    created == null
                        ? 'Sin fecha'
                        : 'Creada el ${_fmtDate.format(created)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppColors.foreground,
                    ),
                  ),
                  Text(
                    received == null
                        ? (order.expectedDate == null
                              ? 'sin recepción registrada'
                              : 'esperada el '
                                    '${_fmtDate.format(order.expectedDate!)}')
                        : 'recibida el ${_fmtDate.format(received)}'
                              '${created == null ? '' : ' · '
                                  '${received.difference(created).inDays} d'}',
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
            Text(
              currency.formatAmount(order.total),
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w800,
                color: AppColors.foreground,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PayableRow extends StatelessWidget {
  final SupplierPayableRow payable;
  final BusinessCurrency currency;

  const _PayableRow({required this.payable, required this.currency});

  @override
  Widget build(BuildContext context) {
    final days = payable.daysToDue();
    final overdue = payable.isOverdue();
    // Sólo lo que apremia se pinta: lo que vence en tres semanas no necesita
    // color, y si todo grita nada grita.
    final urgent = overdue || (days != null && days <= 10);
    final color = overdue ? AppColors.destructive : AppColors.warning;

    final due = () {
      if (payable.dueDate == null) return 'SIN FECHA DE VENCIMIENTO';
      if (overdue) return 'VENCIDA HACE ${-days!} D';
      if (days == 0) return 'VENCE HOY';
      return 'VENCE ${_fmtDate.format(payable.dueDate!).toUpperCase()}';
    }();

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: urgent ? color.withValues(alpha: 0.06) : AppColors.card,
        border: Border.all(
          color: urgent ? color.withValues(alpha: 0.35) : AppColors.border,
        ),
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  payable.reference.isEmpty
                      ? 'Sin comprobante'
                      : payable.reference,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: AppColors.foreground,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  [
                    if (payable.createdAt != null)
                      'Registrada ${_fmtDate.format(payable.createdAt!)}',
                    if (payable.originalAmount > payable.balance)
                      'abonado '
                          '${currency.formatAmount(payable.originalAmount - payable.balance)}'
                      else if (payable.status == 'partial')
                        'pago parcial',
                  ].join(' · '),
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
          const SizedBox(width: 10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                currency.formatAmount(payable.balance),
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                  color: AppColors.foreground,
                ),
              ),
              Text(
                due,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w800,
                  color: urgent ? color : AppColors.mutedForeground,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

String _relative(DateTime when) {
  final diff = DateTime.now().difference(when);
  if (diff.inDays < 1) return 'hoy';
  if (diff.inDays == 1) return 'ayer';
  if (diff.inDays < 30) return 'hace ${diff.inDays} días';
  if (diff.inDays < 365) return 'hace ${(diff.inDays / 30).round()} meses';
  return _fmtDate.format(when);
}
