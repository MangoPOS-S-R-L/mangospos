import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:mangopos/data/models/table_status.dart';
import 'package:mangopos/presentation/sales/view/theme/sales_theme.dart';

class TableCard extends StatefulWidget {
  final TableStatus status;
  final bool isOpening;
  final VoidCallback onTap;

  const TableCard({
    super.key,
    required this.status,
    required this.isOpening,
    required this.onTap,
  });

  @override
  State<TableCard> createState() => _TableCardState();
}

class _TableCardState extends State<TableCard> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final ts = widget.status;
    final isOccupied = ts.sessionId != null;
    final statusRaw = (ts.status ?? '').toString().toLowerCase();
    final isPaying =
        statusRaw == 'paying' || statusRaw == 'checkout' || statusRaw == 'payment';
    final statusColor =
        SalesTheme.statusColor(isOccupied: isOccupied, isPaying: isPaying);
    final statusLabel =
        SalesTheme.statusLabel(isOccupied: isOccupied, isPaying: isPaying);

    final total = ts.total;
    final showTotal = (isOccupied || isPaying) && total > 0;
    final formattedTotal =
        'RD\$ ${NumberFormat('#,##0', 'en_US').format(total)}';

    final waiterName = ts.waiterName?.trim().isNotEmpty == true
        ? ts.waiterName!.trim()
        : 'Sin asignar';

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: GestureDetector(
        onTap: widget.isOpening ? null : widget.onTap,
        child: AnimatedScale(
          scale: _isHovered ? 1.02 : 1.0,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeInOut,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeInOut,
            constraints: const BoxConstraints(
              minHeight: SalesTheme.tableCardHeight,
              maxHeight: SalesTheme.tableCardHeight,
            ),
            decoration: BoxDecoration(
              color: SalesTheme.cardBackground,
              borderRadius: BorderRadius.circular(SalesTheme.cardBorderRadius),
              border: Border.all(color: SalesTheme.border, width: 1),
              boxShadow: _isHovered
                  ? [SalesTheme.shadowMd]
                  : [SalesTheme.shadowSm],
            ),
            clipBehavior: Clip.antiAlias,
            child: Stack(
              children: [
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  child: Container(
                    width: SalesTheme.statusBorderWidth,
                    decoration: BoxDecoration(
                      color: statusColor,
                      borderRadius: BorderRadius.only(
                        topLeft: Radius.circular(SalesTheme.cardBorderRadius),
                        bottomLeft:
                            Radius.circular(SalesTheme.cardBorderRadius),
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                ts.code,
                                style: const TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.w700,
                                  color: SalesTheme.foreground,
                                  letterSpacing: -0.3,
                                  fontFamily: 'PlusJakartaSans',
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                statusLabel,
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: statusColor,
                                  fontFamily: 'PlusJakartaSans',
                                ),
                              ),
                            ],
                          ),
                          if (showTotal)
                            Text(
                              formattedTotal,
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                                color: SalesTheme.foreground,
                                fontFamily: 'PlusJakartaSans',
                              ),
                            ),
                        ],
                      ),
                      Container(
                        height: 1,
                        color: SalesTheme.border.withOpacity(0.4),
                      ),
                      if (widget.isOpening)
                        Row(
                          children: [
                            SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: statusColor,
                              ),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              'Abriendo...',
                              style: TextStyle(
                                fontSize: 12,
                                color: statusColor,
                                fontWeight: FontWeight.w500,
                                fontFamily: 'PlusJakartaSans',
                              ),
                            ),
                          ],
                        )
                      else if (!isOccupied && !isPaying)
                        Text(
                          'Toca para asignar',
                          style: TextStyle(
                            fontSize: 14,
                            color: SalesTheme.mutedForeground.withOpacity(0.6),
                            fontWeight: FontWeight.w500,
                            fontFamily: 'PlusJakartaSans',
                          ),
                        )
                      else
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Icon(
                                  Icons.people_outline,
                                  size: 16,
                                  color: SalesTheme.mutedForeground,
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  '${ts.peopleCount}',
                                  style: const TextStyle(
                                    fontSize: 14,
                                    color: SalesTheme.mutedForeground,
                                    fontWeight: FontWeight.w500,
                                    fontFamily: 'PlusJakartaSans',
                                  ),
                                ),
                                const SizedBox(width: 16),
                                const Icon(
                                  Icons.access_time,
                                  size: 16,
                                  color: SalesTheme.mutedForeground,
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  _formatTime(ts.minutesOpen ?? 0),
                                  style: const TextStyle(
                                    fontSize: 14,
                                    color: SalesTheme.mutedForeground,
                                    fontWeight: FontWeight.w500,
                                    fontFamily: 'PlusJakartaSans',
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Row(
                              children: [
                                const Icon(
                                  Icons.person_outline,
                                  size: 14,
                                  color: SalesTheme.mutedForeground,
                                ),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    waiterName,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: SalesTheme.mutedForeground,
                                      fontWeight: FontWeight.w500,
                                      fontFamily: 'PlusJakartaSans',
                                    ),
                                  ),
                                ),
                                if (ts.isOwn)
                                  Container(
                                    margin: const EdgeInsets.only(left: 8),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      color: SalesTheme.success.withOpacity(0.1),
                                      borderRadius: BorderRadius.circular(999),
                                    ),
                                    child: const Text(
                                      'Tu mesa',
                                      style: TextStyle(
                                        fontSize: 10,
                                        color: SalesTheme.success,
                                        fontWeight: FontWeight.w500,
                                        fontFamily: 'PlusJakartaSans',
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _formatTime(int minutes) {
    final hours = minutes ~/ 60;
    final mins = minutes % 60;
    return '${hours.toString().padLeft(2, '0')}:${mins.toString().padLeft(2, '0')}';
  }
}
