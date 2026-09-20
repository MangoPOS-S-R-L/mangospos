import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:mangopos/core/theme/app_colors.dart';
import 'package:mangopos/core/theme/app_spacing.dart';
import 'package:mangopos/data/models/kitchen_missing_report.dart';
import 'package:mangopos/presentation/reports/widgets/kitchen_charge_comparison_view.dart';
import 'package:mangopos/presentation/reports/widgets/report_widgets.dart';

final _qty = NumberFormat('#,##0.##', 'en_US');

/// Color de lo borrado/reducido (alguien lo quitó) y de lo que quedó fuera de
/// toda cuenta (se perdió solo).
const Color _removedColor = AppColors.destructive;
const Color _outsideColor = AppColors.warning;

/// "Comandas desaparecidas": salieron a cocina y hoy no están en ninguna
/// cuenta. Dos grupos: lo que se borró o se redujo después de enviarse, y lo
/// que sigue en la base pero ninguna cuenta viva muestra.
class KitchenMissingSection extends StatelessWidget {
  const KitchenMissingSection({
    super.key,
    required this.missing,
    required this.multiDay,
  });

  /// Null = no se pudo cargar (falta la migración 20260919_0002).
  final KitchenMissingReport? missing;
  final bool multiDay;

  @override
  Widget build(BuildContext context) {
    final m = missing;
    final time = DateFormat(multiDay ? 'dd/MM HH:mm' : 'HH:mm');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ReportSectionLabel(
          title: 'Comandas desaparecidas',
          subtitle: m == null || m.isEmpty
              ? 'Lo que salió a cocina y hoy no está en ninguna cuenta.'
              : 'Salieron a cocina y hoy no están en ninguna cuenta: '
                    '${_qty.format(m.removedUnits)} borrado o reducido, '
                    '${_qty.format(m.outsideUnits)} fuera de toda cuenta.',
        ),
        const SizedBox(height: AppSpacing.itemGap),
        if (m == null)
          const ReportSurfaceCard(
            child: ReportEmptyPlaceholder(
              icon: Icons.system_update_alt,
              message:
                  'Para ver lo que se borra de las cuentas después de enviarse '
                  'a cocina falta aplicar la migración 20260919_0002.',
            ),
          )
        else if (m.isEmpty)
          const ReportSurfaceCard(
            child: ReportEmptyPlaceholder(
              icon: Icons.verified_outlined,
              message:
                  'Ninguna comanda desaparecida en el rango: todo lo que salió '
                  'a cocina está en una cuenta.',
            ),
          )
        else ...[
          for (final removals in const [true, false])
            if (m.groups(removals: removals).isNotEmpty) ...[
              _GroupTitle(
                removals: removals,
                units: removals ? m.removedUnits : m.outsideUnits,
              ),
              const SizedBox(height: AppSpacing.sm),
              for (final g in m.groups(removals: removals))
                _MissingCard(group: g, time: time),
              const SizedBox(height: AppSpacing.sm),
            ],
        ],
        if (m != null)
          const Text(
            'Lo borrado se registra desde que se aplicó la migración '
            '20260919_0002; lo borrado antes no dejó rastro.',
            style: TextStyle(fontSize: 11.5, color: AppColors.mutedForeground),
          ),
      ],
    );
  }
}

class _GroupTitle extends StatelessWidget {
  const _GroupTitle({required this.removals, required this.units});

  final bool removals;
  final double units;

  @override
  Widget build(BuildContext context) {
    final color = removals ? _removedColor : _outsideColor;
    return Row(
      children: [
        Icon(
          removals ? Icons.delete_outline : Icons.help_outline,
          size: 18,
          color: color,
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            removals
                ? 'Borrado o reducido después de enviar '
                      '(${_qty.format(units)})'
                : 'Fuera de toda cuenta (${_qty.format(units)})',
            style: TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w800,
              color: color,
            ),
          ),
        ),
      ],
    );
  }
}

class _MissingCard extends StatelessWidget {
  const _MissingCard({required this.group, required this.time});

  final KitchenMissingGroup group;
  final DateFormat time;

  @override
  Widget build(BuildContext context) {
    final c = group.comanda;
    final waiter = c.waiterName;
    final color = group.kind.isRemoval ? _removedColor : _outsideColor;
    final explanation = group.kind.explanation;
    return KitchenStripeCard(
      color: color,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: 2,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                '${time.format(c.sentAt)} · ${c.tableName} · #${c.orderNumber}',
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 13.5,
                  color: AppColors.foreground,
                ),
              ),
              if (waiter != null)
                Text(
                  'Mesero: $waiter',
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.mutedForeground,
                  ),
                ),
              for (final area in c.areaNames)
                ReportStatusTag(label: area, tone: AppColors.info),
              ReportStatusTag(label: group.kind.label, tone: color),
            ],
          ),
          if (explanation != null) ...[
            const SizedBox(height: 2),
            Text(
              explanation,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.sm),
          for (final e in group.entries) ...[
            Text(
              '${_qty.format(e.quantity)} × ${e.item.productName}',
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppColors.foreground,
              ),
            ),
            // Quién, cuándo y por qué (solo lo que alguien quitó).
            if (e.kind.isRemoval)
              Padding(
                padding: const EdgeInsets.only(left: 16, bottom: 2),
                child: Text(
                  e.detail,
                  style: TextStyle(
                    fontSize: 12,
                    fontStyle: FontStyle.italic,
                    color: e.reason == null
                        ? AppColors.mutedForeground
                        : AppColors.foreground,
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }
}
