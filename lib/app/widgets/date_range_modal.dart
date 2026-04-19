import 'package:flutter/material.dart';
import 'package:mangopos/app/theme/mango_colors.dart';

/// Compact Spanish date range picker modal.
/// Use inside a [Dialog] widget.
class DateRangeModal extends StatefulWidget {
  final DateTime? initialFrom;
  final DateTime? initialTo;
  final void Function(DateTime from, DateTime to) onApply;
  final VoidCallback onClear;

  const DateRangeModal({
    super.key,
    required this.onApply,
    required this.onClear,
    this.initialFrom,
    this.initialTo,
  });

  @override
  State<DateRangeModal> createState() => _DateRangeModalState();
}

class _DateRangeModalState extends State<DateRangeModal> {
  DateTime? _from;
  DateTime? _to;
  late DateTime _month;
  bool _selectingFrom = true;

  static const _dayLabels = ['Do', 'Lu', 'Ma', 'Mi', 'Ju', 'Vi', 'Sa'];
  static const _monthNames = [
    'enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio',
    'julio', 'agosto', 'septiembre', 'octubre', 'noviembre', 'diciembre',
  ];

  @override
  void initState() {
    super.initState();
    _from = widget.initialFrom;
    _to = widget.initialTo;
    final base = _from ?? DateTime.now();
    _month = DateTime(base.year, base.month, 1);
    _selectingFrom = _from == null || _to != null;
  }

  bool _isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  bool _isInRange(DateTime day) {
    if (_from == null || _to == null) return false;
    final d = DateTime(day.year, day.month, day.day);
    final f = DateTime(_from!.year, _from!.month, _from!.day);
    final t = DateTime(_to!.year, _to!.month, _to!.day);
    return d.isAfter(f) && d.isBefore(t);
  }

  void _onDayTapped(DateTime day) {
    setState(() {
      if (_selectingFrom) {
        _from = day;
        _to = null;
        _selectingFrom = false;
      } else {
        if (_from != null && day.isBefore(_from!)) {
          _to = _from;
          _from = day;
        } else {
          _to = day;
        }
      }
    });
  }

  void _applyPreset(DateTime from, DateTime to) {
    Navigator.pop(context);
    widget.onApply(from, to);
  }

  String _formatDate(DateTime? d) {
    if (d == null) return 'Seleccionar';
    return '${d.day} ${_monthNames[d.month - 1]}. ${d.year}';
  }

  String _capitalizedMonth(int monthIndex) {
    final name = _monthNames[monthIndex];
    return '${name[0].toUpperCase()}${name.substring(1)}';
  }

  @override
  Widget build(BuildContext context) {
    final today = DateTime.now();
    final daysInMonth = DateTime(_month.year, _month.month + 1, 0).day;
    final firstOffset = DateTime(_month.year, _month.month, 1).weekday % 7;

    final totalCells = firstOffset + daysInMonth;
    final rows = ((totalCells + 6) ~/ 7);

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                'Filtrar por fecha',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.close, size: 20),
                onPressed: () => Navigator.pop(context),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
            ],
          ),
          const SizedBox(height: 14),

          Row(
            children: [
              DatePresetChip(
                label: 'Hoy',
                onTap: () => _applyPreset(
                  DateTime(today.year, today.month, today.day),
                  DateTime(today.year, today.month, today.day, 23, 59, 59),
                ),
              ),
              const SizedBox(width: 8),
              DatePresetChip(
                label: 'Esta semana',
                onTap: () {
                  final monday =
                      today.subtract(Duration(days: today.weekday - 1));
                  _applyPreset(
                    DateTime(monday.year, monday.month, monday.day),
                    DateTime(today.year, today.month, today.day, 23, 59, 59),
                  );
                },
              ),
              const SizedBox(width: 8),
              DatePresetChip(
                label: 'Este mes',
                onTap: () => _applyPreset(
                  DateTime(today.year, today.month, 1),
                  DateTime(today.year, today.month, today.day, 23, 59, 59),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          Container(
            decoration: BoxDecoration(
              border: Border.all(color: MangoColors.cardBorder),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                Expanded(
                    child: DatePickerTab(
                  label: 'Desde',
                  value: _formatDate(_from),
                  active: _selectingFrom,
                  onTap: () => setState(() => _selectingFrom = true),
                  isLeft: true,
                )),
                Container(
                    width: 1, height: 48, color: MangoColors.cardBorder),
                Expanded(
                    child: DatePickerTab(
                  label: 'Hasta',
                  value: _formatDate(_to),
                  active: !_selectingFrom,
                  onTap: () => setState(() => _selectingFrom = false),
                  isLeft: false,
                )),
              ],
            ),
          ),
          const SizedBox(height: 16),

          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              IconButton(
                icon: const Icon(Icons.chevron_left, size: 20),
                onPressed: () => setState(() {
                  _month = DateTime(_month.year, _month.month - 1, 1);
                }),
                padding: EdgeInsets.zero,
                constraints:
                    const BoxConstraints(minWidth: 32, minHeight: 32),
              ),
              Text(
                '${_capitalizedMonth(_month.month - 1)} ${_month.year}',
                style:
                    const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
              ),
              IconButton(
                icon: const Icon(Icons.chevron_right, size: 20),
                onPressed: () => setState(() {
                  _month = DateTime(_month.year, _month.month + 1, 1);
                }),
                padding: EdgeInsets.zero,
                constraints:
                    const BoxConstraints(minWidth: 32, minHeight: 32),
              ),
            ],
          ),
          const SizedBox(height: 4),

          Row(
            children: _dayLabels
                .map((d) => Expanded(
                      child: Center(
                        child: Text(
                          d,
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: MangoColors.muted,
                          ),
                        ),
                      ),
                    ))
                .toList(),
          ),
          const SizedBox(height: 4),

          for (int r = 0; r < rows; r++)
            Row(
              children: List.generate(7, (c) {
                final cellIndex = r * 7 + c;
                if (cellIndex < firstOffset ||
                    cellIndex >= firstOffset + daysInMonth) {
                  return const Expanded(child: SizedBox(height: 36));
                }
                final day = cellIndex - firstOffset + 1;
                final date = DateTime(_month.year, _month.month, day);
                final isFrom = _from != null && _isSameDay(date, _from!);
                final isTo = _to != null && _isSameDay(date, _to!);
                final inRange = _isInRange(date);
                final isToday = _isSameDay(date, today);
                final isFuture = date.isAfter(today);

                return Expanded(
                  child: GestureDetector(
                    onTap: isFuture ? null : () => _onDayTapped(date),
                    child: Container(
                      height: 36,
                      margin: const EdgeInsets.all(1),
                      decoration: BoxDecoration(
                        color: isFrom || isTo
                            ? MangoColors.primaryOrange
                            : inRange
                                ? MangoColors.primaryOrange
                                    .withValues(alpha: 0.12)
                                : null,
                        shape: isFrom || isTo
                            ? BoxShape.circle
                            : BoxShape.rectangle,
                        borderRadius:
                            !isFrom && !isTo ? BorderRadius.circular(6) : null,
                        border: isToday && !isFrom && !isTo
                            ? Border.all(
                                color: MangoColors.primaryOrange, width: 1.5)
                            : null,
                      ),
                      child: Center(
                        child: Text(
                          '$day',
                          style: TextStyle(
                            fontSize: 13,
                            color: isFrom || isTo
                                ? Colors.white
                                : isFuture
                                    ? MangoColors.muted.withValues(alpha: 0.4)
                                    : null,
                            fontWeight: isFrom || isTo || isToday
                                ? FontWeight.bold
                                : null,
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              }),
            ),
          const SizedBox(height: 16),

          Row(
            children: [
              TextButton(
                onPressed: () {
                  Navigator.pop(context);
                  widget.onClear();
                },
                child: const Text(
                  'Limpiar',
                  style: TextStyle(color: MangoColors.muted),
                ),
              ),
              const Spacer(),
              FilledButton(
                onPressed: _from != null && _to != null
                    ? () {
                        Navigator.pop(context);
                        widget.onApply(_from!, _to!);
                      }
                    : null,
                style: FilledButton.styleFrom(
                  backgroundColor: MangoColors.primaryOrange,
                  disabledBackgroundColor:
                      MangoColors.primaryOrange.withValues(alpha: 0.4),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 28, vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                child: const Text('Aplicar',
                    style: TextStyle(color: Colors.white)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class DatePickerTab extends StatelessWidget {
  final String label;
  final String value;
  final bool active;
  final VoidCallback onTap;
  final bool isLeft;

  const DatePickerTab({
    super.key,
    required this.label,
    required this.value,
    required this.active,
    required this.onTap,
    required this.isLeft,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding:
            const EdgeInsets.symmetric(vertical: 10, horizontal: 14),
        decoration: BoxDecoration(
          color: active
              ? MangoColors.primaryOrange.withValues(alpha: 0.07)
              : null,
          borderRadius: isLeft
              ? const BorderRadius.horizontal(left: Radius.circular(9))
              : const BorderRadius.horizontal(right: Radius.circular(9)),
          border: active
              ? Border.all(color: MangoColors.primaryOrange)
              : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color:
                    active ? MangoColors.primaryOrange : MangoColors.muted,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              value,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: value == 'Seleccionar'
                    ? MangoColors.muted
                    : MangoColors.darkGray,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class DatePresetChip extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const DatePresetChip({super.key, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: const Color(0xFFF5F5F5),
          border: Border.all(color: MangoColors.cardBorder),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          label,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}
