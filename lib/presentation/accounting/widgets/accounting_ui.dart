// Bloques visuales del módulo contable.
//
// Mismos tokens que el resto de la app (card blanca + borde suave +
// AppShadows.soft + radio 10), para que Contabilidad se lea igual que
// Reportes y no como una pantalla aparte. Todo lo tabular pasa por
// `AccountingTable`, que es responsive: si no entra a lo ancho, la tabla
// scrollea horizontal en vez de desbordar.

import 'package:flutter/material.dart';

import 'package:mangopos/core/theme/app_colors.dart';
import 'package:mangopos/core/theme/app_shadows.dart';
import 'package:mangopos/core/theme/app_spacing.dart';

const double kAcctRadius = 10.0;

/// Superficie blanca estándar del módulo.
class AccountingCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;

  const AccountingCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(AppSpacing.lg),
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(kAcctRadius),
        border: Border.all(color: AppColors.border),
        boxShadow: AppShadows.soft,
      ),
      child: child,
    );
  }
}

/// Encabezado de card: título, subtítulo opcional y acciones a la derecha.
class AccountingCardHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget? trailing;

  const AccountingCardHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                  color: AppColors.foreground,
                ),
              ),
              if (subtitle != null) ...[
                const SizedBox(height: 2),
                Text(
                  subtitle!,
                  style: const TextStyle(
                    fontSize: 12,
                    height: 1.35,
                    color: AppColors.mutedForeground,
                  ),
                ),
              ],
            ],
          ),
        ),
        ?trailing,
      ],
    );
  }
}

/// Definición de columna para [AccountingTable].
class AcctColumn {
  final String label;

  /// Ancho fijo en px. Si es null, la columna reparte el espacio con [flex].
  final double? width;
  final int flex;
  final bool numeric;

  const AcctColumn(
    this.label, {
    this.width,
    this.flex = 1,
    this.numeric = false,
  });
}

/// Fila de [AccountingTable]. `expanded` la vuelve desplegable.
class AcctRow {
  final List<Widget> cells;
  final Widget? expanded;
  final bool emphasized;

  const AcctRow(this.cells, {this.expanded, this.emphasized = false});
}

/// Tabla con encabezado fijo, filas separadas por divisor y fila de totales
/// opcional. Sustituye a `DataTable`, que no permite controlar anchos ni
/// desplegar filas.
///
/// REQUIERE altura acotada (dentro de un `Expanded` o `SizedBox`): la lista
/// no usa `shrinkWrap`, así solo construye las filas visibles aunque el
/// catálogo tenga cientos de cuentas.
class AccountingTable extends StatelessWidget {
  final List<AcctColumn> columns;
  final List<AcctRow> rows;
  final AcctRow? footer;

  /// Ancho mínimo antes de scrollear horizontal.
  final double minWidth;

  const AccountingTable({
    super.key,
    required this.columns,
    required this.rows,
    this.footer,
    this.minWidth = 760,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth < minWidth
            ? minWidth
            : constraints.maxWidth;
        final table = SizedBox(
          width: width,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _header(),
              const Divider(height: 1, color: AppColors.border),
              Expanded(
                child: ListView.separated(
                  padding: EdgeInsets.zero,
                  itemCount: rows.length,
                  separatorBuilder: (_, _) => Divider(
                    height: 1,
                    color: AppColors.border.withValues(alpha: 0.55),
                  ),
                  itemBuilder: (_, i) =>
                      _AccountingTableRow(columns: columns, row: rows[i]),
                ),
              ),
              if (footer != null) ...[
                const Divider(height: 1, color: AppColors.border),
                Container(
                  color: AppColors.muted.withValues(alpha: 0.45),
                  child: _AccountingTableRow(
                    columns: columns,
                    row: footer!,
                  ),
                ),
              ],
            ],
          ),
        );

        if (constraints.maxWidth >= minWidth) return table;
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: table,
        );
      },
    );
  }

  Widget _header() {
    return Padding(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md, vertical: AppSpacing.sm),
      child: Row(
        children: [
          for (final c in columns)
            _cellBox(
              c,
              Text(
                c.label.toUpperCase(),
                textAlign: c.numeric ? TextAlign.right : TextAlign.left,
                style: const TextStyle(
                  fontSize: 11,
                  letterSpacing: 0.4,
                  fontWeight: FontWeight.w700,
                  color: AppColors.mutedForeground,
                ),
              ),
            ),
        ],
      ),
    );
  }

  static Widget _cellBox(AcctColumn c, Widget child) {
    final padded = Padding(
      padding: const EdgeInsets.only(right: AppSpacing.md),
      child: Align(
        alignment:
            c.numeric ? Alignment.centerRight : Alignment.centerLeft,
        child: child,
      ),
    );
    if (c.width != null) return SizedBox(width: c.width, child: padded);
    return Expanded(flex: c.flex, child: padded);
  }
}

class _AccountingTableRow extends StatefulWidget {
  final List<AcctColumn> columns;
  final AcctRow row;

  const _AccountingTableRow({required this.columns, required this.row});

  @override
  State<_AccountingTableRow> createState() => _AccountingTableRowState();
}

class _AccountingTableRowState extends State<_AccountingTableRow> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final expandable = widget.row.expanded != null;
    final content = Padding(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md, vertical: AppSpacing.md),
      child: Row(
        children: [
          for (var i = 0; i < widget.columns.length; i++)
            AccountingTable._cellBox(
              widget.columns[i],
              DefaultTextStyle.merge(
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: widget.row.emphasized
                      ? FontWeight.w700
                      : FontWeight.normal,
                  color: AppColors.foreground,
                ),
                child: i < widget.row.cells.length
                    ? widget.row.cells[i]
                    : const SizedBox.shrink(),
              ),
            ),
        ],
      ),
    );

    if (!expandable) return content;

    return Column(
      children: [
        InkWell(
          onTap: () => setState(() => _open = !_open),
          child: Row(
            children: [
              Expanded(child: content),
              Padding(
                padding: const EdgeInsets.only(right: AppSpacing.sm),
                child: Icon(
                  _open
                      ? Icons.keyboard_arrow_up_rounded
                      : Icons.keyboard_arrow_down_rounded,
                  size: 18,
                  color: AppColors.mutedForeground,
                ),
              ),
            ],
          ),
        ),
        if (_open)
          Container(
            width: double.infinity,
            color: AppColors.accent.withValues(alpha: 0.5),
            padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.sm,
                AppSpacing.md, AppSpacing.md),
            child: widget.row.expanded!,
          ),
      ],
    );
  }
}

/// Tile de indicador (débitos, créditos, utilidad…).
class AccountingKpiTile extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;
  final IconData? icon;

  const AccountingKpiTile({
    super.key,
    required this.label,
    required this.value,
    this.valueColor,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return AccountingCard(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg, vertical: AppSpacing.md),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: (valueColor ?? AppColors.primary)
                    .withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(icon,
                  size: 18, color: valueColor ?? AppColors.primary),
            ),
            const SizedBox(width: AppSpacing.md),
          ],
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label,
                  style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: AppColors.mutedForeground)),
              const SizedBox(height: 2),
              Text(value,
                  style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                      color: valueColor ?? AppColors.foreground)),
            ],
          ),
        ],
      ),
    );
  }
}

class AccountingBadge extends StatelessWidget {
  final String text;
  final Color? color;

  const AccountingBadge({super.key, required this.text, this.color});

  @override
  Widget build(BuildContext context) {
    final c = color ?? AppColors.mutedForeground;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: c.withValues(alpha: 0.22)),
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
            fontSize: 11, color: c, fontWeight: FontWeight.w700),
      ),
    );
  }
}

/// Fila cuenta ↔ importe para estado de resultados y balance general.
class AccountingAmountRow extends StatelessWidget {
  final String code;
  final String name;
  final String amount;
  final bool emphasized;

  const AccountingAmountRow({
    super.key,
    required this.code,
    required this.name,
    required this.amount,
    this.emphasized = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      child: Row(
        children: [
          SizedBox(
            width: 78,
            child: Text(code,
                style: const TextStyle(
                    fontSize: 12,
                    fontFeatures: [FontFeature.tabularFigures()],
                    color: AppColors.mutedForeground)),
          ),
          Expanded(
            child: Text(name,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 13,
                    fontWeight:
                        emphasized ? FontWeight.w700 : FontWeight.w500)),
          ),
          const SizedBox(width: AppSpacing.md),
          Text(amount,
              style: TextStyle(
                fontSize: 13,
                fontWeight: emphasized ? FontWeight.w800 : FontWeight.w600,
                fontFeatures: const [FontFeature.tabularFigures()],
              )),
        ],
      ),
    );
  }
}

class AccountingEmpty extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Widget? action;

  const AccountingEmpty({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xxl),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: AppColors.muted,
                  borderRadius: BorderRadius.circular(16),
                ),
                child:
                    Icon(icon, size: 26, color: AppColors.mutedForeground),
              ),
              const SizedBox(height: AppSpacing.lg),
              Text(title,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w800)),
              const SizedBox(height: AppSpacing.xs),
              Text(subtitle,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: 13,
                      height: 1.4,
                      color: AppColors.mutedForeground)),
              if (action != null) ...[
                const SizedBox(height: AppSpacing.lg),
                action!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}
