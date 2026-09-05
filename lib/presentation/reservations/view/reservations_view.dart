import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../app/router/routes.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_radius.dart';
import '../../../core/theme/app_shadows.dart';
import '../../../data/models/dining_table.dart';
import '../../../data/models/reservation.dart';
import '../../../data/models/zone.dart';
import '../../../services/session/session_controller.dart';
import '../state/reservations_state.dart';
import '../viewmodel/reservations_viewmodel.dart';
import '../widgets/reservation_card.dart';
import '../widgets/reservation_floor_map.dart';
import 'reservation_form.dart';
import 'package:mangopos/core/utils/app_snackbar.dart';

const _weekdaysLong = [
  'lunes', 'martes', 'miércoles', 'jueves', 'viernes', 'sábado', 'domingo',
];
const _monthsLong = [
  'enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio',
  'julio', 'agosto', 'septiembre', 'octubre', 'noviembre', 'diciembre',
];

class ReservationsView extends ConsumerStatefulWidget {
  const ReservationsView({super.key});

  @override
  ConsumerState<ReservationsView> createState() => _ReservationsViewState();
}

class _ReservationsViewState extends ConsumerState<ReservationsView> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(reservationsVmProvider.notifier).load('auto');
    });
  }

  bool get _canManage =>
      ref.read(sessionProvider.notifier).hasPermission('reservas.gestionar');

  Future<void> _new() async {
    final businessId = ref.read(reservationsVmProvider).businessId;
    if (businessId == null) return;
    await showReservationForm(
      context,
      businessId: businessId,
      initialDay: ref.read(reservationsVmProvider).selectedDay,
    );
  }

  Future<void> _pickDate() async {
    final state = ref.read(reservationsVmProvider);
    final picked = await showDatePicker(
      context: context,
      initialDate: state.selectedDay,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (picked != null) {
      ref.read(reservationsVmProvider.notifier).setDay(picked);
    }
  }

  Future<void> _handleAction(Reservation r, ReservationAction action) async {
    final vm = ref.read(reservationsVmProvider.notifier);
    final businessId = ref.read(reservationsVmProvider).businessId;

    switch (action) {
      case ReservationAction.call:
        final phone = r.customerPhone;
        if (phone == null || phone.isEmpty) return;
        final uri = Uri(scheme: 'tel', path: phone);
        if (await canLaunchUrl(uri)) await launchUrl(uri);
        return;

      case ReservationAction.edit:
        if (!_canManage || businessId == null) {
          _toast('No tienes permiso para gestionar reservas.');
          return;
        }
        await showReservationForm(context, businessId: businessId, existing: r);
        return;

      case ReservationAction.seat:
        if (!_canManage) {
          _toast('No tienes permiso para gestionar reservas.');
          return;
        }
        final result = await vm.seat(r.id);
        if (!mounted) return;
        if (result.error != null) {
          _toast(result.error!);
        } else {
          _toast('Reserva sentada — mesa abierta.');
          if (mounted) context.go(AppRoutes.salesByZone);
        }
        return;

      case ReservationAction.cancel:
        if (!_canManage) {
          _toast('No tienes permiso para gestionar reservas.');
          return;
        }
        final ok = await _confirm('¿Cancelar la reserva de ${r.customerName}?');
        if (ok != true) return;
        final err = await vm.cancel(r.id);
        if (err != null && mounted) _toast(err);
        return;

      case ReservationAction.noShow:
        if (!_canManage) {
          _toast('No tienes permiso para gestionar reservas.');
          return;
        }
        final err = await vm.markNoShow(r.id);
        if (err != null && mounted) _toast(err);
        return;
    }
  }

  Future<bool?> _confirm(String message) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.lg),
        ),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('No'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Sí'),
          ),
        ],
      ),
    );
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showAppSnackBar(
      SnackBar(
        content: Text(msg),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(reservationsVmProvider);
    final vm = ref.read(reservationsVmProvider.notifier);

    final outerPad = MediaQuery.of(context).size.width < 600 ? 10.0 : 18.0;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Padding(
          padding: EdgeInsets.all(outerPad),
          child: Container(
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: AppColors.card,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: AppColors.border),
              boxShadow: AppShadows.soft,
            ),
            child: Column(
              children: [
                _Header(
                  state: state,
                  canManage: _canManage,
                  onNew: _new,
                  onSearch: vm.setSearch,
                  onPrev: () => vm.shiftDay(-1),
                  onNext: () => vm.shiftDay(1),
                  onToday: () => vm.setDay(DateTime.now()),
                  onPickDate: _pickDate,
                  onRefresh: vm.refresh,
                  onFilter: vm.setStatusFilter,
                  onSetViewMode: vm.setViewMode,
                ),
                Expanded(child: _body(state)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _body(ReservationsState state) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 1000;
        if (wide) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(width: 384, child: _listView(state)),
              const VerticalDivider(
                width: 1,
                thickness: 1,
                color: AppColors.border,
              ),
              Expanded(child: _floorPlan(state)),
            ],
          );
        }
        return state.viewMode == ReservationViewMode.floorPlan
            ? _floorPlan(state)
            : _listView(state);
      },
    );
  }

  Widget _listView(ReservationsState state) {
    if (state.loading && state.reservations.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.error != null) {
      return _ErrorState(
        message: state.error!,
        onRetry: () => ref.read(reservationsVmProvider.notifier).refresh(),
      );
    }
    final items = state.visible;
    if (items.isEmpty) {
      return _EmptyState(
        filtered:
            state.statusFilter != null || state.searchQuery.trim().isNotEmpty,
        canManage: _canManage,
        onNew: _new,
      );
    }
    return RefreshIndicator(
      color: AppColors.primary,
      onRefresh: () => ref.read(reservationsVmProvider.notifier).refresh(),
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 24),
        itemCount: items.length,
        itemBuilder: (context, i) {
          final r = items[i];
          return _ReservationListCard(
            reservation: r,
            canManage: _canManage,
            onTap: _canManage
                ? () => _handleAction(r, ReservationAction.edit)
                : null,
            onAction: (a) => _handleAction(r, a),
          );
        },
      ),
    );
  }

  // --- Plano del salón -------------------------------------------------------

  Widget _floorPlan(ReservationsState state) {
    if (state.floorLoading && state.zones.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.error != null && state.zones.isEmpty) {
      return _ErrorState(
        message: state.error!,
        onRetry: () => ref
            .read(reservationsVmProvider.notifier)
            .setViewMode(ReservationViewMode.floorPlan),
      );
    }
    if (state.zones.isEmpty) {
      return const _FloorEmptyState();
    }

    final vm = ref.read(reservationsVmProvider.notifier);
    final zoneId = state.selectedZoneId ?? state.zones.first.id;
    final tables = state.tablesByZone[zoneId] ?? const <DiningTable>[];
    final byTable = state.activeByTableId;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _ZoneChips(
          zones: state.zones,
          selectedId: zoneId,
          onSelect: vm.selectZone,
        ),
        const _FloorLegend(),
        Expanded(
          child: ReservationFloorMap(
            key: ValueKey('floor_$zoneId'),
            tables: tables,
            reservationsByTableId: byTable,
            onTapTable: _openTableSheet,
          ),
        ),
      ],
    );
  }

  Future<void> _openTableSheet(DiningTable table) async {
    final state = ref.read(reservationsVmProvider);
    final businessId = state.businessId;
    if (businessId == null) return;
    final reservations =
        state.activeByTableId[table.id] ?? const <Reservation>[];

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => _TableSheet(
        table: table,
        reservations: reservations,
        canManage: _canManage,
        onAction: (r, a) {
          Navigator.of(ctx).pop();
          _handleAction(r, a);
        },
        onNew: () async {
          Navigator.of(ctx).pop();
          await showReservationForm(
            context,
            businessId: businessId,
            initialDay: state.selectedDay,
            initialTableId: table.id,
          );
        },
      ),
    );
  }
}

// ============================================================================
// Header
// ============================================================================

class _Header extends StatelessWidget {
  final ReservationsState state;
  final bool canManage;
  final VoidCallback onNew;
  final void Function(String) onSearch;
  final VoidCallback onPrev;
  final VoidCallback onNext;
  final VoidCallback onToday;
  final VoidCallback onPickDate;
  final VoidCallback onRefresh;
  final void Function(ReservationStatus?) onFilter;
  final void Function(ReservationViewMode) onSetViewMode;

  const _Header({
    required this.state,
    required this.canManage,
    required this.onNew,
    required this.onSearch,
    required this.onPrev,
    required this.onNext,
    required this.onToday,
    required this.onPickDate,
    required this.onRefresh,
    required this.onFilter,
    required this.onSetViewMode,
  });

  @override
  Widget build(BuildContext context) {
    final day = state.selectedDay;
    final width = MediaQuery.of(context).size.width;
    final narrow = width < 900;
    final wide = width >= 1000;
    final pad = width < 600 ? 16.0 : 24.0;
    final longDate =
        '${_weekdaysLong[day.weekday - 1]}, ${day.day} ${_monthsLong[day.month - 1]}';

    final all = state.reservations;
    final active = all.where((r) => r.status.isActive).toList();
    final covers = active.fold<int>(0, (s, r) => s + r.partySize);
    final seated =
        all.where((r) => r.status == ReservationStatus.seated).length;

    final title = const Text(
      'Reservas',
      style: TextStyle(
        fontSize: 22,
        fontWeight: FontWeight.w800,
        color: AppColors.foreground,
        letterSpacing: -0.5,
      ),
    );
    final search = _SearchField(onChanged: onSearch);
    final refreshBtn = _RoundIconButton(
      icon: Icons.refresh,
      tooltip: 'Refrescar',
      onTap: onRefresh,
    );
    final newBtn = canManage
        ? _PrimaryFab(label: 'Nueva reserva', onTap: onNew)
        : null;
    final tabs = _ViewModeSwitch(
      current: state.viewMode,
      onSelect: onSetViewMode,
    );
    final stats = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _StatCard(
          value: '${active.length}',
          label: 'Reservas',
          color: AppColors.primary,
        ),
        const SizedBox(width: 10),
        _StatCard(
          value: '$covers',
          label: 'Comensales',
          color: AppColors.info,
        ),
        const SizedBox(width: 10),
        _StatCard(
          value: '$seated',
          label: 'Sentadas',
          color: AppColors.success,
        ),
      ],
    );
    final dateNav = _DateNav(
      longDate: longDate,
      onPrev: onPrev,
      onNext: onNext,
      onToday: onToday,
      onPick: onPickDate,
    );
    final filterBar = _FilterBar(
      current: state.statusFilter,
      reservations: all,
      onFilter: onFilter,
    );

    return Container(
      padding: EdgeInsets.fromLTRB(pad, width < 600 ? 14 : 18, pad, 14),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Fila 1 — título + búsqueda + acciones
          if (narrow) ...[
            Row(children: [Expanded(child: title), refreshBtn]),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(child: search),
                if (newBtn != null) ...[const SizedBox(width: 10), newBtn],
              ],
            ),
          ] else
            Row(
              children: [
                title,
                const SizedBox(width: 24),
                Expanded(child: search),
                const SizedBox(width: 12),
                refreshBtn,
                if (newBtn != null) ...[const SizedBox(width: 10), newBtn],
              ],
            ),
          const SizedBox(height: 16),
          // Fila 2 — pestañas de vista + tarjetas de stats
          if (narrow) ...[
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: tabs,
            ),
            const SizedBox(height: 12),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: stats,
            ),
          ] else if (wide)
            Align(alignment: Alignment.centerRight, child: stats)
          else
            Row(children: [tabs, const Spacer(), stats]),
          // Fila 3 — filtros de estado + navegación de fecha
          if (wide || state.viewMode != ReservationViewMode.floorPlan) ...[
            const SizedBox(height: 14),
            if (narrow) ...[
              dateNav,
              const SizedBox(height: 10),
              filterBar,
            ] else
              Row(
                children: [
                  Expanded(child: filterBar),
                  const SizedBox(width: 12),
                  dateNav,
                ],
              ),
          ] else ...[
            const SizedBox(height: 14),
            Align(alignment: Alignment.centerLeft, child: dateNav),
          ],
        ],
      ),
    );
  }
}

// ============================================================================
// Stat card
// ============================================================================

class _StatCard extends StatelessWidget {
  final String value;
  final String label;
  final Color color;

  const _StatCard({
    required this.value,
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minWidth: 104),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 12,
              color: AppColors.mutedForeground,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w800,
              color: color,
              height: 1,
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// Campo de búsqueda
// ============================================================================

class _SearchField extends StatefulWidget {
  final void Function(String) onChanged;

  const _SearchField({required this.onChanged});

  @override
  State<_SearchField> createState() => _SearchFieldState();
}

class _SearchFieldState extends State<_SearchField> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _ctrl,
      onChanged: widget.onChanged,
      textInputAction: TextInputAction.search,
      style: const TextStyle(fontSize: 14, color: AppColors.foreground),
      decoration: InputDecoration(
        isDense: true,
        hintText: 'Buscar por cliente o teléfono…',
        hintStyle: const TextStyle(
          fontSize: 14,
          color: AppColors.mutedForeground,
        ),
        prefixIcon: const Icon(
          Icons.search,
          size: 20,
          color: AppColors.mutedForeground,
        ),
        suffixIcon: _ctrl.text.isEmpty
            ? null
            : IconButton(
                tooltip: 'Limpiar',
                icon: const Icon(Icons.close, size: 18),
                color: AppColors.mutedForeground,
                onPressed: () {
                  _ctrl.clear();
                  widget.onChanged('');
                  setState(() {});
                },
              ),
        filled: true,
        fillColor: AppColors.muted,
        contentPadding: const EdgeInsets.symmetric(vertical: 11),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.full),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.full),
          borderSide: const BorderSide(color: AppColors.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.full),
          borderSide: const BorderSide(color: AppColors.primary, width: 1.4),
        ),
      ),
    );
  }
}

// ============================================================================
// Navegación de fecha compacta (‹ fecha · Hoy ›)
// ============================================================================

class _DateNav extends StatelessWidget {
  final String longDate;
  final VoidCallback onPrev;
  final VoidCallback onNext;
  final VoidCallback onToday;
  final VoidCallback onPick;

  const _DateNav({
    required this.longDate,
    required this.onPrev,
    required this.onNext,
    required this.onToday,
    required this.onPick,
  });

  String get _capitalized =>
      longDate.isEmpty ? longDate : longDate[0].toUpperCase() + longDate.substring(1);

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(AppRadius.full),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _NavArrow(icon: Icons.chevron_left, tooltip: 'Día anterior', onTap: onPrev),
          InkWell(
            onTap: onPick,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.calendar_today_outlined,
                    size: 15,
                    color: AppColors.mutedForeground,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _capitalized,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: AppColors.foreground,
                    ),
                  ),
                ],
              ),
            ),
          ),
          Container(width: 1, height: 22, color: AppColors.border),
          InkWell(
            onTap: onToday,
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              child: Text(
                'Hoy',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: AppColors.primary,
                ),
              ),
            ),
          ),
          _NavArrow(icon: Icons.chevron_right, tooltip: 'Día siguiente', onTap: onNext),
        ],
      ),
    );
  }
}

class _NavArrow extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  const _NavArrow({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onTap,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 38, minHeight: 38),
      icon: Icon(icon, size: 20, color: AppColors.foreground),
    );
  }
}

// ============================================================================
// Filter bar
// ============================================================================

class _FilterBar extends StatelessWidget {
  final ReservationStatus? current;
  final List<Reservation> reservations;
  final void Function(ReservationStatus?) onFilter;

  const _FilterBar({
    required this.current,
    required this.reservations,
    required this.onFilter,
  });

  int _count(ReservationStatus? s) => s == null
      ? reservations.length
      : reservations.where((r) => r.status == s).length;

  @override
  Widget build(BuildContext context) {
    final filters = <(String, ReservationStatus?)>[
      ('Todas', null),
      ('Confirmadas', ReservationStatus.confirmed),
      ('Sentadas', ReservationStatus.seated),
      ('Canceladas', ReservationStatus.cancelled),
      ('No llegó', ReservationStatus.noShow),
    ];
    return SizedBox(
      height: 36,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: filters.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (_, i) {
          final f = filters[i];
          return _FilterPill(
            label: f.$1,
            count: _count(f.$2),
            selected: current == f.$2,
            accent: f.$2 == null
                ? AppColors.primary
                : reservationStatusColor(f.$2!),
            onTap: () => onFilter(f.$2),
          );
        },
      ),
    );
  }
}

class _FilterPill extends StatelessWidget {
  final String label;
  final int count;
  final bool selected;
  final Color accent;
  final VoidCallback onTap;

  const _FilterPill({
    required this.label,
    required this.count,
    required this.selected,
    required this.accent,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? accent.withValues(alpha: 0.12) : AppColors.card,
          borderRadius: BorderRadius.circular(AppRadius.full),
          border: Border.all(
            color: selected ? accent.withValues(alpha: 0.5) : AppColors.border,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: selected ? accent : AppColors.foreground,
              ),
            ),
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: selected
                    ? accent.withValues(alpha: 0.18)
                    : AppColors.muted,
                borderRadius: BorderRadius.circular(AppRadius.full),
              ),
              child: Text(
                '$count',
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                  color: selected ? accent : AppColors.mutedForeground,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// Botones / estados
// ============================================================================

class _RoundIconButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  const _RoundIconButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    const size = 42.0;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppRadius.md),
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppRadius.md),
              border: Border.all(color: AppColors.border),
            ),
            child: Icon(icon, size: 22, color: AppColors.foreground),
          ),
        ),
      ),
    );
  }
}

class _PrimaryFab extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _PrimaryFab({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.full),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          decoration: BoxDecoration(
            color: AppColors.primary,
            borderRadius: BorderRadius.circular(AppRadius.full),
            boxShadow: AppShadows.mango,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.add, color: Colors.white, size: 20),
              const SizedBox(width: 8),
              Text(
                label,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final bool filtered;
  final bool canManage;
  final VoidCallback onNew;

  const _EmptyState({
    required this.filtered,
    required this.canManage,
    required this.onNew,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(AppRadius.full),
              ),
              child: const Icon(
                Icons.event_seat_outlined,
                size: 44,
                color: AppColors.primary,
              ),
            ),
            const SizedBox(height: 20),
            Text(
              filtered
                  ? 'Sin reservas con este filtro'
                  : 'No hay reservas para este día',
              style: const TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: AppColors.foreground,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              filtered
                  ? 'Prueba con otro estado o cambia de día.'
                  : 'Crea la primera reserva para esta fecha.',
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 13.5,
                color: AppColors.mutedForeground,
              ),
            ),
            if (!filtered && canManage) ...[
              const SizedBox(height: 20),
              _PrimaryFab(label: 'Nueva reserva', onTap: onNew),
            ],
          ],
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _ErrorState({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_outlined,
                size: 44, color: AppColors.mutedForeground),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 14,
                color: AppColors.mutedForeground,
              ),
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Reintentar'),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// Conmutador de vistas (Lista / Plano del salón)
// ============================================================================

class _ViewModeSwitch extends StatelessWidget {
  final ReservationViewMode current;
  final void Function(ReservationViewMode) onSelect;

  const _ViewModeSwitch({required this.current, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _seg('Lista', Icons.view_agenda_outlined, ReservationViewMode.list),
          const SizedBox(width: 4),
          _seg(
            'Plano',
            Icons.table_restaurant_outlined,
            ReservationViewMode.floorPlan,
          ),
        ],
      ),
    );
  }

  Widget _seg(String label, IconData icon, ReservationViewMode mode) {
    final selected = current == mode;
    return GestureDetector(
      onTap: () => onSelect(mode),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
        decoration: BoxDecoration(
          color: selected ? AppColors.primary : Colors.transparent,
          borderRadius: BorderRadius.circular(9),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 16,
              color: selected ? Colors.white : AppColors.mutedForeground,
            ),
            const SizedBox(width: 7),
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: selected ? Colors.white : AppColors.mutedForeground,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// Tarjeta de reserva (panel de lista): bloque de hora + info + acciones
// ============================================================================

class _ReservationListCard extends StatefulWidget {
  final Reservation reservation;
  final bool canManage;
  final VoidCallback? onTap;
  final void Function(ReservationAction) onAction;

  const _ReservationListCard({
    required this.reservation,
    required this.canManage,
    required this.onTap,
    required this.onAction,
  });

  @override
  State<_ReservationListCard> createState() => _ReservationListCardState();
}

class _ReservationListCardState extends State<_ReservationListCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final r = widget.reservation;
    final color = reservationStatusColor(r.status);
    final dimmed = r.status == ReservationStatus.cancelled ||
        r.status == ReservationStatus.noShow ||
        r.status == ReservationStatus.completed;
    final table =
        (r.tableCode?.trim().isNotEmpty ?? false) ? r.tableCode!.trim() : '—';
    final t = r.reservedForLocal;
    final mm = t.minute.toString().padLeft(2, '0');
    final ampm = t.hour >= 12 ? 'PM' : 'AM';
    final h12 = t.hour % 12 == 0 ? 12 : t.hour % 12;

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: _hover ? color.withValues(alpha: 0.45) : AppColors.border,
          ),
          boxShadow: _hover ? AppShadows.cardElevated : AppShadows.soft,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: widget.onTap,
              child: Opacity(
                opacity: dimmed ? 0.64 : 1,
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 60,
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        decoration: BoxDecoration(
                          color: color.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              '$h12:$mm',
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w800,
                                color: color,
                                height: 1,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              ampm,
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: color,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    r.customerName,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 14.5,
                                      fontWeight: FontWeight.w700,
                                      color: AppColors.foreground,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                _StatusPill(status: r.status),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Wrap(
                              spacing: 12,
                              runSpacing: 4,
                              children: [
                                _MiniMeta(
                                  icon: Icons.table_restaurant_outlined,
                                  text: 'Mesa $table',
                                ),
                                _MiniMeta(
                                  icon: Icons.groups_outlined,
                                  text: '${r.partySize} pax',
                                ),
                              ],
                            ),
                            if (r.customerPhone != null &&
                                r.customerPhone!.trim().isNotEmpty) ...[
                              const SizedBox(height: 4),
                              _MiniMeta(
                                icon: Icons.call_outlined,
                                text: r.customerPhone!.trim(),
                              ),
                            ],
                            if (widget.canManage) ...[
                              const SizedBox(height: 8),
                              Align(
                                alignment: Alignment.centerRight,
                                child: _RowActions(
                                  reservation: r,
                                  onAction: widget.onAction,
                                  compact: false,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MiniMeta extends StatelessWidget {
  final IconData icon;
  final String text;

  const _MiniMeta({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: AppColors.mutedForeground),
        const SizedBox(width: 5),
        Text(
          text,
          style: const TextStyle(
            fontSize: 12.5,
            color: AppColors.mutedForeground,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}

class _StatusPill extends StatelessWidget {
  final ReservationStatus status;

  const _StatusPill({required this.status});

  @override
  Widget build(BuildContext context) {
    final color = reservationStatusColor(status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.full),
      ),
      child: Text(
        status.label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }
}

// ============================================================================
// Chips de zona (vista plano)
// ============================================================================

class _ZoneChips extends StatelessWidget {
  final List<Zone> zones;
  final String selectedId;
  final void Function(String) onSelect;

  const _ZoneChips({
    required this.zones,
    required this.selectedId,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 46,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 7),
        itemCount: zones.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final z = zones[i];
          final selected = z.id == selectedId;
          return GestureDetector(
            onTap: () => onSelect(z.id),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: selected ? AppColors.primary : AppColors.card,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: selected ? AppColors.primary : AppColors.border,
                ),
              ),
              child: Text(
                z.name,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: selected ? Colors.white : AppColors.foreground,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

// ============================================================================
// Leyenda del plano
// ============================================================================

class _FloorLegend extends StatelessWidget {
  const _FloorLegend();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
      child: Wrap(
        spacing: 16,
        runSpacing: 4,
        children: const [
          _LegendDot(color: AppColors.success, label: 'Libre'),
          _LegendDot(color: AppColors.primary, label: 'Reservada'),
          _LegendDot(color: AppColors.warning, label: 'Ocupada'),
          _LegendDot(color: AppColors.mutedForeground, label: 'Bloqueada'),
        ],
      ),
    );
  }
}

class _LegendDot extends StatelessWidget {
  final Color color;
  final String label;

  const _LegendDot({required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: const TextStyle(
            fontSize: 12,
            color: AppColors.mutedForeground,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}

// ============================================================================
// Estado vacío del plano (sin zonas/mesas)
// ============================================================================

class _FloorEmptyState extends StatelessWidget {
  const _FloorEmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: const [
            Icon(
              Icons.grid_view_outlined,
              size: 48,
              color: AppColors.mutedForeground,
            ),
            SizedBox(height: 12),
            Text(
              'No hay zonas ni mesas configuradas',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: AppColors.foreground,
              ),
            ),
            SizedBox(height: 6),
            Text(
              'Configura el salón en Ajustes → Zonas y mesas para usar el plano.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: AppColors.mutedForeground),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// Hoja de mesa (al tocar una mesa en el plano)
// ============================================================================

class _TableSheet extends StatelessWidget {
  final DiningTable table;
  final List<Reservation> reservations;
  final bool canManage;
  final void Function(Reservation, ReservationAction) onAction;
  final VoidCallback onNew;

  const _TableSheet({
    required this.table,
    required this.reservations,
    required this.canManage,
    required this.onAction,
    required this.onNew,
  });

  @override
  Widget build(BuildContext context) {
    final maxH = MediaQuery.of(context).size.height * 0.72;
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxH),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 10),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 12, 8),
              child: Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: AppColors.primary.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(
                      Icons.table_restaurant_outlined,
                      color: AppColors.primary,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Mesa ${table.code}',
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                            color: AppColors.foreground,
                          ),
                        ),
                        Text(
                          '${table.capacity} personas · '
                          '${reservations.length} reserva(s)',
                          style: const TextStyle(
                            fontSize: 13,
                            color: AppColors.mutedForeground,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close, color: AppColors.mutedForeground),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: reservations.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(28),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.event_available_outlined,
                            size: 36,
                            color: AppColors.mutedForeground,
                          ),
                          SizedBox(height: 8),
                          Text(
                            'Sin reservas para este día',
                            style: TextStyle(
                              fontSize: 14,
                              color: AppColors.mutedForeground,
                            ),
                          ),
                        ],
                      ),
                    )
                  : ListView.separated(
                      shrinkWrap: true,
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                      itemCount: reservations.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 10),
                      itemBuilder: (context, i) {
                        final r = reservations[i];
                        return ReservationCard(
                          reservation: r,
                          onAction: (a) => onAction(r, a),
                          onTap: canManage
                              ? () => onAction(r, ReservationAction.edit)
                              : null,
                        );
                      },
                    ),
            ),
            if (canManage)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: onNew,
                    icon: const Icon(Icons.add),
                    label: const Text('Reservar esta mesa'),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// Acciones de una reserva: botón Sentar + menú (Editar/Llamar/No llegó/Cancelar)
// ============================================================================

class _RowActions extends StatelessWidget {
  final Reservation reservation;
  final void Function(ReservationAction) onAction;
  final bool compact;

  const _RowActions({
    required this.reservation,
    required this.onAction,
    required this.compact,
  });

  PopupMenuItem<ReservationAction> _menuItem(
    ReservationAction action,
    IconData icon,
    String label, {
    bool danger = false,
  }) {
    final color = danger ? AppColors.destructive : AppColors.foreground;
    return PopupMenuItem<ReservationAction>(
      value: action,
      height: 44,
      child: Row(
        children: [
          Icon(
            icon,
            size: 18,
            color: danger ? AppColors.destructive : AppColors.mutedForeground,
          ),
          const SizedBox(width: 10),
          Text(
            label,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final r = reservation;
    final canSeat = r.status == ReservationStatus.confirmed ||
        r.status == ReservationStatus.pending;
    final canEdit = r.status.isEditable;
    final canCancel = r.status.isActive;
    final hasPhone =
        r.customerPhone != null && r.customerPhone!.trim().isNotEmpty;

    final menuItems = <PopupMenuEntry<ReservationAction>>[
      if (canEdit)
        _menuItem(ReservationAction.edit, Icons.edit_outlined, 'Editar'),
      if (hasPhone)
        _menuItem(ReservationAction.call, Icons.call_outlined, 'Llamar'),
      if (canCancel)
        _menuItem(
          ReservationAction.noShow,
          Icons.person_off_outlined,
          'No llegó',
        ),
      if (canCancel)
        _menuItem(
          ReservationAction.cancel,
          Icons.cancel_outlined,
          'Cancelar',
          danger: true,
        ),
    ];

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (canSeat) ...[
          _SeatPill(
            compact: compact,
            onTap: () => onAction(ReservationAction.seat),
          ),
          const SizedBox(width: 4),
        ],
        if (menuItems.isNotEmpty)
          SizedBox(
            width: 34,
            height: 34,
            child: PopupMenuButton<ReservationAction>(
              tooltip: 'Más acciones',
              padding: EdgeInsets.zero,
              position: PopupMenuPosition.under,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppRadius.lg),
              ),
              icon: const Icon(
                Icons.more_vert,
                size: 19,
                color: AppColors.mutedForeground,
              ),
              onSelected: onAction,
              itemBuilder: (_) => menuItems,
            ),
          ),
      ],
    );
  }
}

class _SeatPill extends StatelessWidget {
  final bool compact;
  final VoidCallback onTap;

  const _SeatPill({required this.compact, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.primary,
      borderRadius: BorderRadius.circular(AppRadius.full),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.full),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 9 : 12,
            vertical: 7,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.event_seat_outlined,
                size: 16,
                color: Colors.white,
              ),
              if (!compact) ...[
                const SizedBox(width: 6),
                const Text(
                  'Sentar',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
