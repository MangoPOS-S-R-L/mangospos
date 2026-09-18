import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/core/theme/app_colors.dart';
import 'package:mangopos/core/theme/app_shadows.dart';
import 'package:mangopos/core/theme/app_spacing.dart';
import 'package:mangopos/presentation/reports/model/report_column.dart';
import 'package:mangopos/presentation/reports/widgets/customizable_report_table.dart';
import 'package:mangopos/presentation/reports/widgets/report_widgets.dart';

/// Abre el panel de columnas (drawer derecho). Devuelve la lista de columnas
/// visibles en su orden al tocar "Aplicar", o null si se cierra sin aplicar.
Future<List<String>?> showColumnPickerPanel(
  BuildContext context, {
  required ReportDefinition definition,
  required List<String> visible,
}) {
  return showGeneralDialog<List<String>>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Cerrar panel de columnas',
    barrierColor: Colors.black.withValues(alpha: 0.25),
    transitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (context, _, _) => Align(
      alignment: Alignment.centerRight,
      child: ColumnPickerPanel(definition: definition, visible: visible),
    ),
    transitionBuilder: (context, animation, _, child) => SlideTransition(
      position: Tween(begin: const Offset(1, 0), end: Offset.zero).animate(
        CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
      ),
      child: child,
    ),
  );
}

class ColumnPickerPanel extends StatefulWidget {
  const ColumnPickerPanel({
    super.key,
    required this.definition,
    required this.visible,
  });

  final ReportDefinition definition;
  final List<String> visible;

  @override
  State<ColumnPickerPanel> createState() => _ColumnPickerPanelState();
}

class _ColumnPickerPanelState extends State<ColumnPickerPanel> {
  late List<String> _visible = [...widget.visible];

  ReportDefinition get _definition => widget.definition;

  void _move(int from, int to) {
    if (to < 0 || to >= _visible.length) return;
    setState(() {
      final id = _visible.removeAt(from);
      _visible.insert(to, id);
    });
  }

  void _remove(String id) {
    if (_definition.column(id)?.locked ?? true) return;
    setState(() => _visible.remove(id));
  }

  void _add(String id) {
    if (_visible.contains(id)) return;
    setState(() => _visible.add(id));
  }

  void _restore() {
    setState(() => _visible = [..._definition.defaultConfig.columns]);
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final width = math.min(430.0, size.width);
    final available = <ReportColumnOrigin, List<ReportColumn>>{};
    for (final column in _definition.columns) {
      if (_visible.contains(column.id)) continue;
      available.putIfAbsent(column.origin, () => []).add(column);
    }

    return Material(
      color: Colors.white,
      elevation: 0,
      child: Container(
        width: width,
        height: size.height,
        decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(left: BorderSide(color: AppColors.border)),
          boxShadow: AppShadows.cardInteractive,
        ),
        child: SafeArea(
          left: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                    AppSpacing.cardPadding, 20, 12, AppSpacing.tightGap),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Columnas',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w800,
                              color: AppColors.foreground,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '${_definition.title} · ${_visible.length} de '
                            '${_definition.columns.length} visibles',
                            style: const TextStyle(
                              fontSize: 13,
                              color: AppColors.mutedForeground,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Cerrar',
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1, color: AppColors.border),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(AppSpacing.lg,
                      AppSpacing.lg, AppSpacing.lg, AppSpacing.cardPadding),
                  children: [
                    const _SectionTitle('VISIBLES, EN ORDEN'),
                    ReorderableListView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      buildDefaultDragHandles: false,
                      itemCount: _visible.length,
                      onReorderItem: _move,
                      proxyDecorator: (child, _, _) => Material(
                        color: Colors.transparent,
                        elevation: 0,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            borderRadius:
                                BorderRadius.circular(reportRadius),
                            boxShadow: AppShadows.cardInteractive,
                          ),
                          child: child,
                        ),
                      ),
                      itemBuilder: (context, index) {
                        final column = _definition.column(_visible[index])!;
                        return _VisibleColumnTile(
                          key: ValueKey(column.id),
                          column: column,
                          index: index,
                          isFirst: index == 0,
                          isLast: index == _visible.length - 1,
                          onUp: () => _move(index, index - 1),
                          onDown: () => _move(index, index + 1),
                          onRemove: () => _remove(column.id),
                        );
                      },
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    const _SectionTitle('DISPONIBLES'),
                    if (available.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 8),
                        child: Text(
                          'Todas las columnas del catálogo están visibles.',
                          style: TextStyle(
                            fontSize: 13,
                            color: AppColors.mutedForeground,
                          ),
                        ),
                      ),
                    for (final origin in ReportColumnOrigin.values)
                      if (available[origin] != null) ...[
                        Padding(
                          padding: const EdgeInsets.only(top: 6, bottom: 6),
                          child: Text(
                            origin.label,
                            style: const TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w700,
                              color: AppColors.foreground,
                            ),
                          ),
                        ),
                        for (final column in available[origin]!)
                          _AvailableColumnTile(
                            column: column,
                            onAdd: () => _add(column.id),
                          ),
                      ],
                    const SizedBox(height: AppSpacing.lg),
                    Container(
                      padding: const EdgeInsets.all(AppSpacing.md),
                      decoration: BoxDecoration(
                        color: AppColors.secondary,
                        borderRadius: BorderRadius.circular(reportRadius),
                        border: Border.all(color: AppColors.border),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(Icons.info_outline_rounded,
                              size: 16, color: AppColors.mutedForeground),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _definition.catalogNote,
                              style: const TextStyle(
                                fontSize: 12,
                                height: 1.4,
                                color: AppColors.mutedForeground,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1, color: AppColors.border),
              Padding(
                padding: const EdgeInsets.all(AppSpacing.lg),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        style: reportOutlineButtonStyle(),
                        onPressed: _restore,
                        icon: const Icon(Icons.restart_alt_rounded, size: 18),
                        label: const Text('Restaurar'),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.tightGap),
                    Expanded(
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: MangoColors.primaryOrange,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(reportRadius),
                          ),
                          textStyle:
                              const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        onPressed: () =>
                            Navigator.of(context).pop([..._visible]),
                        icon: const Icon(Icons.check_rounded, size: 18),
                        label: const Text('Aplicar'),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.6,
          color: AppColors.mutedForeground,
        ),
      ),
    );
  }
}

class _SourceText extends StatelessWidget {
  const _SourceText(this.source);

  final String source;

  @override
  Widget build(BuildContext context) {
    return Text(
      source,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(
        fontFamily: reportNumberFontFamily,
        fontSize: 11,
        color: AppColors.mutedForeground,
      ),
    );
  }
}

class _VisibleColumnTile extends StatelessWidget {
  const _VisibleColumnTile({
    super.key,
    required this.column,
    required this.index,
    required this.isFirst,
    required this.isLast,
    required this.onUp,
    required this.onDown,
    required this.onRemove,
  });

  final ReportColumn column;
  final int index;
  final bool isFirst;
  final bool isLast;
  final VoidCallback onUp;
  final VoidCallback onDown;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    const iconConstraints = BoxConstraints.tightFor(width: 30, height: 30);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Container(
        padding: const EdgeInsets.fromLTRB(4, 6, 6, 6),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(reportRadius),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          children: [
            ReorderableDragStartListener(
              index: index,
              child: const MouseRegion(
                cursor: SystemMouseCursors.grab,
                child: Padding(
                  padding: EdgeInsets.all(6),
                  child: Icon(Icons.drag_indicator_rounded,
                      size: 18, color: AppColors.mutedForeground),
                ),
              ),
            ),
            const SizedBox(width: 2),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    column.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                      color: AppColors.foreground,
                    ),
                  ),
                  _SourceText(column.source),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Subir',
              constraints: iconConstraints,
              padding: EdgeInsets.zero,
              iconSize: 18,
              onPressed: isFirst ? null : onUp,
              icon: const Icon(Icons.arrow_upward_rounded),
            ),
            IconButton(
              tooltip: 'Bajar',
              constraints: iconConstraints,
              padding: EdgeInsets.zero,
              iconSize: 18,
              onPressed: isLast ? null : onDown,
              icon: const Icon(Icons.arrow_downward_rounded),
            ),
            if (column.locked)
              const Tooltip(
                message: 'Eje del reporte: siempre visible',
                child: SizedBox(
                  width: 30,
                  height: 30,
                  child: Icon(Icons.lock_outline_rounded,
                      size: 16, color: AppColors.mutedForeground),
                ),
              )
            else
              IconButton(
                tooltip: 'Quitar',
                constraints: iconConstraints,
                padding: EdgeInsets.zero,
                iconSize: 18,
                color: AppColors.destructive,
                onPressed: onRemove,
                icon: const Icon(Icons.close_rounded),
              ),
          ],
        ),
      ),
    );
  }
}

class _AvailableColumnTile extends StatelessWidget {
  const _AvailableColumnTile({required this.column, required this.onAdd});

  final ReportColumn column;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: AppColors.background,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(reportRadius),
          side: const BorderSide(color: AppColors.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onAdd,
          hoverColor: AppColors.primary.withValues(alpha: 0.06),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        column.label,
                        style: const TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w700,
                          color: AppColors.foreground,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        column.description,
                        style: const TextStyle(
                          fontSize: 12,
                          height: 1.3,
                          color: AppColors.mutedForeground,
                        ),
                      ),
                      const SizedBox(height: 2),
                      _SourceText(column.source),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                const Icon(Icons.add_circle_outline_rounded,
                    size: 20, color: AppColors.primary),
                const SizedBox(width: 6),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
