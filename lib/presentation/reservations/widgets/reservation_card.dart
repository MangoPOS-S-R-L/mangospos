import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_radius.dart';
import '../../../core/theme/app_shadows.dart';
import '../../../data/models/reservation.dart';

/// Acciones disponibles sobre una reserva desde la agenda.
enum ReservationAction { seat, edit, cancel, noShow, call }

/// Color base del estado (acento de la tarjeta, pill y KPIs).
Color reservationStatusColor(ReservationStatus s) {
  switch (s) {
    case ReservationStatus.confirmed:
    case ReservationStatus.pending:
      return AppColors.info;
    case ReservationStatus.seated:
      return AppColors.success;
    case ReservationStatus.completed:
      return AppColors.mutedForeground;
    case ReservationStatus.cancelled:
      return AppColors.destructive;
    case ReservationStatus.noShow:
      return AppColors.warning;
  }
}

const _avatarPalette = <Color>[
  Color(0xFF6366F1), // indigo
  Color(0xFF0EA5E9), // sky
  Color(0xFF14B8A6), // teal
  Color(0xFFEC4899), // pink
  Color(0xFF8B5CF6), // violet
  Color(0xFFF97316), // mango
  Color(0xFF10B981), // emerald
  Color(0xFFF43F5E), // rose
];

Color _avatarColor(String name) =>
    _avatarPalette[name.hashCode.abs() % _avatarPalette.length];

String _initials(String name) {
  final parts = name
      .trim()
      .split(RegExp(r'\s+'))
      .where((p) => p.isNotEmpty)
      .toList();
  if (parts.isEmpty) return '?';
  String f(String s) => s.substring(0, 1).toUpperCase();
  if (parts.length == 1) {
    return parts[0].length >= 2
        ? parts[0].substring(0, 2).toUpperCase()
        : f(parts[0]);
  }
  return f(parts[0]) + f(parts[1]);
}

String _hhmm(DateTime d) =>
    '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

class ReservationCard extends StatefulWidget {
  final Reservation reservation;
  final void Function(ReservationAction action) onAction;

  /// Abrir detalles al tocar el cuerpo de la tarjeta. `null` = no clickeable.
  final VoidCallback? onTap;

  const ReservationCard({
    super.key,
    required this.reservation,
    required this.onAction,
    this.onTap,
  });

  @override
  State<ReservationCard> createState() => _ReservationCardState();
}

class _ReservationCardState extends State<ReservationCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final r = widget.reservation;
    final color = reservationStatusColor(r.status);
    final dimmed = r.status == ReservationStatus.cancelled ||
        r.status == ReservationStatus.noShow ||
        r.status == ReservationStatus.completed;

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: _hover ? color.withValues(alpha: 0.45) : AppColors.border,
          ),
          boxShadow: _hover ? AppShadows.cardElevated : AppShadows.soft,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: widget.onTap,
              child: IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(width: 5, color: color),
                    Expanded(
                      child: Opacity(
                        opacity: dimmed ? 0.62 : 1,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
                          child: _content(r, color),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _content(Reservation r, Color color) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _timeBlock(r),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  _avatar(r.customerName),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          r.customerName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 15.5,
                            fontWeight: FontWeight.w700,
                            color: AppColors.foreground,
                            height: 1.1,
                          ),
                        ),
                        if (r.customerPhone != null &&
                            r.customerPhone!.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              r.customerPhone!,
                              style: const TextStyle(
                                fontSize: 12,
                                color: AppColors.mutedForeground,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  _metaChip(Icons.groups_outlined, '${r.partySize} pers.'),
                  _metaChip(
                    Icons.table_restaurant_outlined,
                    _tableLabel(r),
                  ),
                ],
              ),
              if (r.notes != null && r.notes!.isNotEmpty) ...[
                const SizedBox(height: 8),
                _noteRow(r.notes!),
              ],
            ],
          ),
        ),
        const SizedBox(width: 10),
        _trailing(r, color),
      ],
    );
  }

  String _tableLabel(Reservation r) {
    final table = (r.tableCode != null && r.tableCode!.isNotEmpty)
        ? r.tableCode!
        : 'Mesa';
    return r.zoneName != null ? '${r.zoneName} · $table' : table;
  }

  Widget _timeBlock(Reservation r) {
    return SizedBox(
      width: 56,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _hhmm(r.reservedForLocal),
            style: const TextStyle(
              fontSize: 19,
              fontWeight: FontWeight.w800,
              color: AppColors.foreground,
              letterSpacing: -0.5,
              height: 1,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            '→ ${_hhmm(r.endsAtLocal)}',
            style: const TextStyle(
              fontSize: 11.5,
              color: AppColors.mutedForeground,
              height: 1,
            ),
          ),
        ],
      ),
    );
  }

  Widget _avatar(String name) {
    final c = _avatarColor(name);
    return Container(
      width: 38,
      height: 38,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: c,
        borderRadius: BorderRadius.circular(AppRadius.full),
      ),
      child: Text(
        _initials(name),
        style: const TextStyle(
          color: Colors.white,
          fontSize: 13,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _statusPill(Reservation r, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.full),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 5),
          Text(
            r.status.label,
            style: TextStyle(
              color: color,
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _metaChip(IconData icon, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: AppColors.secondary,
        borderRadius: BorderRadius.circular(AppRadius.full),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: AppColors.mutedForeground),
          const SizedBox(width: 5),
          Text(
            label,
            style: const TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: AppColors.foreground,
            ),
          ),
        ],
      ),
    );
  }

  Widget _noteRow(String notes) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.sticky_note_2_outlined,
              size: 14, color: AppColors.primary),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              notes,
              style: const TextStyle(
                fontSize: 12.5,
                color: AppColors.foreground,
                fontStyle: FontStyle.italic,
                height: 1.25,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _trailing(Reservation r, Color color) {
    final canSeat = r.status == ReservationStatus.confirmed ||
        r.status == ReservationStatus.pending;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        _statusPill(r, color),
        const SizedBox(height: 10),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (canSeat) ...[
              _SeatButton(onTap: () => widget.onAction(ReservationAction.seat)),
              const SizedBox(width: 6),
            ],
            _moreMenu(r),
          ],
        ),
      ],
    );
  }

  Widget _moreMenu(Reservation r) {
    final canEdit = r.status.isEditable;
    final canCancel = r.status.isActive;
    final hasPhone = r.customerPhone != null && r.customerPhone!.isNotEmpty;

    return Container(
      decoration: BoxDecoration(
        color: AppColors.secondary,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: AppColors.border),
      ),
      child: PopupMenuButton<ReservationAction>(
        tooltip: 'Más acciones',
        padding: EdgeInsets.zero,
        position: PopupMenuPosition.under,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.lg),
        ),
        icon: const Icon(Icons.more_horiz,
            size: 20, color: AppColors.mutedForeground),
        onSelected: widget.onAction,
        itemBuilder: (context) => [
          if (canEdit)
            _menuItem(ReservationAction.edit, Icons.edit_outlined, 'Editar'),
          if (hasPhone)
            _menuItem(ReservationAction.call, Icons.call_outlined, 'Llamar'),
          if (canCancel)
            _menuItem(
                ReservationAction.noShow, Icons.person_off_outlined, 'No llegó'),
          if (canCancel)
            _menuItem(ReservationAction.cancel, Icons.cancel_outlined,
                'Cancelar',
                danger: true),
        ],
      ),
    );
  }

  PopupMenuItem<ReservationAction> _menuItem(
    ReservationAction value,
    IconData icon,
    String label, {
    bool danger = false,
  }) {
    final color = danger ? AppColors.destructive : AppColors.foreground;
    return PopupMenuItem(
      value: value,
      height: 44,
      child: Row(
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 10),
          Text(label, style: TextStyle(color: color, fontSize: 14)),
        ],
      ),
    );
  }
}

/// Botón "Sentar" con gradiente Mango.
class _SeatButton extends StatelessWidget {
  final VoidCallback onTap;
  const _SeatButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: AppColors.primary,
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.event_seat, size: 16, color: Colors.white),
              SizedBox(width: 6),
              Text(
                'Sentar',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 13,
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
