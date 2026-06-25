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

const _weekdaysShort = ['Lun', 'Mar', 'Mié', 'Jue', 'Vie', 'Sáb', 'Dom'];
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
    ScaffoldMessenger.of(context).showSnackBar(
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

    return Scaffold(
      backgroundColor: AppColors.background,
      floatingActionButton: _canManage
          ? _PrimaryFab(label: 'Nueva reserva', onTap: _new)
          : null,
      body: SafeArea(
        child: Column(
          children: [
            _Header(
              state: state,
              onPrev: () => vm.shiftDay(-1),
              onNext: () => vm.shiftDay(1),
              onToday: () => vm.setDay(DateTime.now()),
              onPickDate: _pickDate,
              onRefresh: vm.refresh,
              onSelectDay: vm.setDay,
              onFilter: vm.setStatusFilter,
              onSetViewMode: vm.setViewMode,
            ),
            Expanded(child: _body(state)),
          ],
        ),
      ),
    );
  }

  Widget _body(ReservationsState state) {
    if (state.viewMode == ReservationViewMode.floorPlan) {
      return _floorPlan(state);
    }

    if (state.loading && state.reservations.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.error != null) {
      return _ErrorState(
        message: state.error!,
        onRetry: () => ref.read(reservationsVmProvider.notifier).refresh(),
      );
    }
    final groups = state.groupedByZone;
    if (groups.isEmpty) {
      return _EmptyState(
        filtered: state.statusFilter != null,
        canManage: _canManage,
        onNew: _new,
      );
    }

    return RefreshIndicator(
      color: AppColors.primary,
      onRefresh: () => ref.read(reservationsVmProvider.notifier).refresh(),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final twoCol = constraints.maxWidth >= 980;
          final contentWidth =
              constraints.maxWidth > 1180 ? 1180.0 : constraints.maxWidth;
          final pad = constraints.maxWidth < 600 ? 16.0 : 24.0;
          final inner = contentWidth - pad * 2;
          final itemWidth = twoCol ? (inner - 16) / 2 : inner;

          return SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            child: Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: contentWidth),
                child: Padding(
                  padding: EdgeInsets.fromLTRB(pad, 8, pad, 96),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final g in groups) ...[
                        _ZoneSectionHeader(
                          zone: g.zone,
                          count: g.items.length,
                        ),
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 16,
                          runSpacing: 0,
                          children: [
                            for (final r in g.items)
                              SizedBox(
                                width: itemWidth,
                                child: ReservationCard(
                                  reservation: r,
                                  onAction: (a) => _handleAction(r, a),
                                  onTap: _canManage
                                      ? () => _handleAction(
                                          r, ReservationAction.edit)
                                      : null,
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 22),
                      ],
                    ],
                  ),
                ),
              ),
            ),
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
  final VoidCallback onPrev;
  final VoidCallback onNext;
  final VoidCallback onToday;
  final VoidCallback onPickDate;
  final VoidCallback onRefresh;
  final void Function(DateTime) onSelectDay;
  final void Function(ReservationStatus?) onFilter;
  final void Function(ReservationViewMode) onSetViewMode;

  const _Header({
    required this.state,
    required this.onPrev,
    required this.onNext,
    required this.onToday,
    required this.onPickDate,
    required this.onRefresh,
    required this.onSelectDay,
    required this.onFilter,
    required this.onSetViewMode,
  });

  @override
  Widget build(BuildContext context) {
    final day = state.selectedDay;
    final narrow = MediaQuery.of(context).size.width < 600;
    final pad = narrow ? 16.0 : 24.0;
    final longDate =
        '${_weekdaysLong[day.weekday - 1]}, ${day.day} de ${_monthsLong[day.month - 1]}';

    final all = state.reservations;
    final active = all.where((r) => r.status.isActive).toList();
    final covers = active.fold<int>(0, (s, r) => s + r.partySize);
    final seated =
        all.where((r) => r.status == ReservationStatus.seated).length;
    final upcoming = all
        .where((r) =>
            r.status == ReservationStatus.confirmed ||
            r.status == ReservationStatus.pending)
        .length;

    return Container(
      decoration: const BoxDecoration(
        color: AppColors.background,
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      padding: EdgeInsets.fromLTRB(pad, narrow ? 12 : 18, pad, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Título + controles
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Reservas',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w800,
                        color: AppColors.foreground,
                        letterSpacing: -0.5,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      longDate,
                      style: const TextStyle(
                        fontSize: 13,
                        color: AppColors.mutedForeground,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
              _RoundIconButton(
                icon: Icons.today_outlined,
                tooltip: 'Elegir fecha',
                onTap: onPickDate,
              ),
              const SizedBox(width: 8),
              _RoundIconButton(
                icon: Icons.refresh,
                tooltip: 'Refrescar',
                onTap: onRefresh,
              ),
            ],
          ),
          const SizedBox(height: 14),
          _ViewModeSwitch(current: state.viewMode, onSelect: onSetViewMode),
          const SizedBox(height: 16),
          // KPIs
          SizedBox(
            height: 74,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                _StatCard(
                  icon: Icons.event_available_outlined,
                  value: '${active.length}',
                  label: 'Reservas',
                  color: AppColors.primary,
                ),
                _StatCard(
                  icon: Icons.groups_outlined,
                  value: '$covers',
                  label: 'Comensales',
                  color: AppColors.info,
                ),
                _StatCard(
                  icon: Icons.event_seat_outlined,
                  value: '$seated',
                  label: 'Sentadas',
                  color: AppColors.success,
                ),
                _StatCard(
                  icon: Icons.schedule_outlined,
                  value: '$upcoming',
                  label: 'Por llegar',
                  color: AppColors.warning,
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          // Tira de días
          _WeekStrip(
            selectedDay: day,
            onPrev: onPrev,
            onNext: onNext,
            onToday: onToday,
            onSelect: onSelectDay,
          ),
          // Filtros con contador (solo en la vista de lista)
          if (state.viewMode == ReservationViewMode.list) ...[
            const SizedBox(height: 12),
            _FilterBar(
              current: state.statusFilter,
              reservations: all,
              onFilter: onFilter,
            ),
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
  final IconData icon;
  final String value;
  final String label;
  final Color color;

  const _StatCard({
    required this.icon,
    required this.value,
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 156,
      margin: const EdgeInsets.only(right: 12),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
        boxShadow: AppShadows.soft,
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(AppRadius.iconBox),
            ),
            child: Icon(icon, color: color, size: 21),
          ),
          const SizedBox(width: 12),
          Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                value,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  color: AppColors.foreground,
                  height: 1,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                label,
                style: const TextStyle(
                  fontSize: 12,
                  color: AppColors.mutedForeground,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// Week strip
// ============================================================================

class _WeekStrip extends StatelessWidget {
  final DateTime selectedDay;
  final VoidCallback onPrev;
  final VoidCallback onNext;
  final VoidCallback onToday;
  final void Function(DateTime) onSelect;

  const _WeekStrip({
    required this.selectedDay,
    required this.onPrev,
    required this.onNext,
    required this.onToday,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    // Ancla en hoy; si el día elegido es anterior, arranca ahí para que sea
    // visible. 14 días de ventana; fechas lejanas vía el date picker.
    final start = selectedDay.isBefore(today) ? selectedDay : today;
    final days = List.generate(14, (i) => start.add(Duration(days: i)));

    return Row(
      children: [
        _RoundIconButton(
          icon: Icons.chevron_left,
          tooltip: 'Día anterior',
          onTap: onPrev,
          small: true,
        ),
        const SizedBox(width: 6),
        Expanded(
          child: SizedBox(
            height: 62,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: days.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (_, i) {
                final d = days[i];
                final selected = d.year == selectedDay.year &&
                    d.month == selectedDay.month &&
                    d.day == selectedDay.day;
                final isToday = d.year == today.year &&
                    d.month == today.month &&
                    d.day == today.day;
                return _DayPill(
                  day: d,
                  selected: selected,
                  isToday: isToday,
                  onTap: () => onSelect(d),
                );
              },
            ),
          ),
        ),
        const SizedBox(width: 6),
        _RoundIconButton(
          icon: Icons.chevron_right,
          tooltip: 'Día siguiente',
          onTap: onNext,
          small: true,
        ),
      ],
    );
  }
}

class _DayPill extends StatelessWidget {
  final DateTime day;
  final bool selected;
  final bool isToday;
  final VoidCallback onTap;

  const _DayPill({
    required this.day,
    required this.selected,
    required this.isToday,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final fg = selected
        ? Colors.white
        : (isToday ? AppColors.primary : AppColors.foreground);

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        width: 52,
        decoration: BoxDecoration(
          color: selected ? AppColors.primary : AppColors.card,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected
                ? AppColors.primary
                : (isToday ? AppColors.primary : AppColors.border),
            width: isToday && !selected ? 1.4 : 1,
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              _weekdaysShort[day.weekday - 1],
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: selected
                    ? Colors.white.withValues(alpha: 0.9)
                    : AppColors.mutedForeground,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              '${day.day}',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: fg,
                height: 1,
              ),
            ),
          ],
        ),
      ),
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
  final bool small;

  const _RoundIconButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.small = false,
  });

  @override
  Widget build(BuildContext context) {
    final size = small ? 36.0 : 42.0;
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
            child: Icon(icon, size: small ? 20 : 22, color: AppColors.foreground),
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
            'Plano del salón',
            Icons.grid_view_outlined,
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
// Cabecera de sección por zona (vista de lista)
// ============================================================================

class _ZoneSectionHeader extends StatelessWidget {
  final String zone;
  final int count;

  const _ZoneSectionHeader({required this.zone, required this.count});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 4,
          height: 18,
          decoration: BoxDecoration(
            color: AppColors.primary,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 10),
        Text(
          zone,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w800,
            color: AppColors.foreground,
          ),
        ),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: AppColors.primary.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            '$count',
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: AppColors.primary,
            ),
          ),
        ),
      ],
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
