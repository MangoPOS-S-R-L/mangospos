import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/core/fiscal/ncf_types.dart';
import 'package:mangopos/core/theme/app_colors.dart';
import 'package:mangopos/core/theme/app_spacing.dart';

import 'report_widgets.dart';

/// Tabla "Detalle de comprobantes" con cada documento listado, sus
/// impuestos por tipo y un tag de estado (Activo / Anulado).
///
/// Diseñada para ser reusable entre el reporte de Comprobantes
/// Fiscales y el sub-reporte "Por comprobante" del Informe de ventas.
class FiscalDocumentsDetailCard extends StatelessWidget {
  const FiscalDocumentsDetailCard({
    super.key,
    required this.documents,
    required this.currency,
    required this.serviceFeeLabel,
    this.title = 'Detalle de comprobantes',
    this.subtitle =
        'Cada comprobante por separado, con su estado (Activo o Anulado).',
    this.emptyMessage = 'No hay comprobantes en el rango seleccionado.',
    this.showVoided = false,
    this.voidedCount = 0,
    this.onToggleVoided,
  });

  /// Documentos YA filtrados por el caller (tipo de NCF + anulados según
  /// [showVoided]). El widget no filtra: solo pinta y ofrece el toggle.
  final List<Map<String, dynamic>> documents;

  /// Inyectado por el caller (típico: `state.currency.formatter` desde una
  /// pantalla de reportes). Centraliza el símbolo en `business_settings`.
  final NumberFormat currency;

  /// Label del cargo de servicio configurado por el comercio (viene de
  /// `fiscalSummary.service_fee_label`). Se usa como header de columna y
  /// como sentinel para mapear el monto del service_fee al label correcto.
  /// Antes era "Propina de ley" hardcoded — rompía multi-config.
  final String serviceFeeLabel;
  final String title;
  final String subtitle;
  final String emptyMessage;

  /// Si los anulados están incluidos en [documents]. Por defecto NO: las
  /// ventas anuladas quedaban mezcladas al final de la tabla y no se
  /// distinguían de las válidas (y los totales del reporte nunca las
  /// contaron).
  final bool showVoided;

  /// Cuántos anulados hay en el rango (ocultos o no). Se muestra en el botón
  /// para que quede claro que existen aunque no se listen.
  final int voidedCount;

  /// Callback del toggle. Si es null no se dibuja el botón (el caller no
  /// maneja el estado).
  final ValueChanged<bool>? onToggleVoided;

  // ncfTypeName eliminado: ahora se usa el global de core/fiscal/ncf_types.dart
  // (catálogo único, evita drift entre archivos).

  /// Filtra labels "Impuesto X%" — son el fallback que produce el
  /// repositorio cuando un order_item tiene tax_rate combinado (ej. 28%
  /// = ITBIS+Propina) que no se pudo desdoblar contra los impuestos
  /// configurados. Mostrarlos crea una columna extra en la tabla con
  /// header largo ("Impuesto 28.00% (28%)") que fuerza wrap a dos
  /// líneas en headers cortos como NCF/Cliente. Las cantidades reales
  /// se siguen contando en ITBIS + Propina, este filtro solo afecta
  /// la presentación.
  static bool _isUnmappedTaxLabel(String label) {
    return RegExp(r'^Impuesto\s').hasMatch(label);
  }

  static List<String> collectTaxLabels(
    List<Map<String, dynamic>> documents,
    String serviceFeeLabel,
  ) {
    final labels = <String>{};
    for (final doc in documents) {
      final breakdown = doc['tax_breakdown'];
      if (breakdown is List) {
        for (final item in breakdown) {
          final row = item is Map<String, dynamic>
              ? item
              : Map<String, dynamic>.from(item as Map);
          final label = row['label']?.toString() ?? '';
          if (_isUnmappedTaxLabel(label)) continue;
          final rate = (row['rate'] as num?)?.toDouble() ?? 0;
          final display = rate > 0
              ? '$label (${rate.toStringAsFixed(rate.truncateToDouble() == rate ? 0 : 2)}%)'
              : label;
          if (display.isNotEmpty) labels.add(display);
        }
      }
      if (((doc['service_fee'] as num?)?.toDouble() ?? 0) > 0) {
        labels.add(serviceFeeLabel);
      }
    }
    return labels.toList(growable: false);
  }

  static double taxAmountForLabel(
    Map<String, dynamic> doc,
    String label,
    String serviceFeeLabel,
  ) {
    if (label == serviceFeeLabel) {
      return (doc['service_fee'] as num?)?.toDouble() ?? 0;
    }
    final breakdown = doc['tax_breakdown'];
    if (breakdown is! List) return 0;
    for (final item in breakdown) {
      final m = item is Map<String, dynamic>
          ? item
          : Map<String, dynamic>.from(item as Map);
      final itemLabel = m['label']?.toString() ?? '';
      final rate = (m['rate'] as num?)?.toDouble() ?? 0;
      final display = rate > 0
          ? '$itemLabel (${rate.toStringAsFixed(rate.truncateToDouble() == rate ? 0 : 2)}%)'
          : itemLabel;
      if (display == label) {
        return (m['tax_amount'] as num?)?.toDouble() ?? 0;
      }
    }
    return 0;
  }

  @override
  Widget build(BuildContext context) {
    final dateFormat = DateFormat('dd/MM/yyyy hh:mm a');
    final taxLabels = collectTaxLabels(documents, serviceFeeLabel);

    return ReportSurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final label = ReportSectionLabel(
                title: title,
                subtitle: showVoided || voidedCount == 0
                    ? subtitle
                    : voidedCount == 1
                        ? '$subtitle Hay 1 anulado oculto en el rango '
                            '(no suma a los totales).'
                        : '$subtitle Hay $voidedCount anulados ocultos en el '
                            'rango (no suman a los totales).',
              );
              if (onToggleVoided == null || voidedCount == 0) return label;
              final toggle = _VoidedToggleButton(
                showVoided: showVoided,
                voidedCount: voidedCount,
                onToggleVoided: onToggleVoided,
              );
              // En pantallas angostas el botón baja debajo del título.
              if (constraints.maxWidth < 520) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    label,
                    const SizedBox(height: AppSpacing.tightGap),
                    toggle,
                  ],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: label),
                  const SizedBox(width: AppSpacing.itemGap),
                  toggle,
                ],
              );
            },
          ),
          const SizedBox(height: AppSpacing.lg),
          if (documents.isEmpty)
            ReportEmptyPlaceholder(
              icon: Icons.description_outlined,
              message: emptyMessage,
            )
          else
            // LayoutBuilder + ConstrainedBox(minWidth) hace que la tabla se
            // estire a todo el ancho de la tarjeta cuando hay pocas columnas
            // (header, divisores y color de fila Anulado cubren toda la fila),
            // y siga haciendo scroll horizontal cuando hay muchas columnas de
            // impuestos y el contenido excede el ancho disponible.
            LayoutBuilder(
              builder: (context, constraints) => SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: ConstrainedBox(
                  constraints: BoxConstraints(minWidth: constraints.maxWidth),
                  child: DataTable(
                    headingRowColor: WidgetStateProperty.all(
                      MangoColors.bgLight,
                    ),
                    headingTextStyle: const TextStyle(
                      fontWeight: FontWeight.w700,
                      color: AppColors.foreground,
                      fontSize: 12,
                    ),
                    dataRowMinHeight: 44,
                    dataRowMaxHeight: 58,
                    columnSpacing: 20,
                    horizontalMargin: 12,
                    columns: [
                      const DataColumn(label: Text('NCF')),
                      const DataColumn(label: Text('Tipo')),
                      const DataColumn(label: Text('Cliente')),
                      const DataColumn(label: Text('RNC/Cédula')),
                      const DataColumn(label: Text('Subtotal'), numeric: true),
                      ...taxLabels.map(
                        (label) =>
                            DataColumn(label: Text(label), numeric: true),
                      ),
                      const DataColumn(label: Text('Total'), numeric: true),
                      const DataColumn(label: Text('Estado')),
                      const DataColumn(label: Text('Fecha')),
                    ],
                    rows: documents.map((doc) {
                      final ncfNumber = doc['ncf_number']?.toString() ?? '';
                      final ncfType = doc['ncf_type']?.toString() ?? '';
                      final customerName =
                          doc['customer_name']?.toString() ??
                          'CONSUMIDOR FINAL';
                      final customerRnc =
                          doc['customer_rnc']?.toString() ?? '-';
                      final subtotal =
                          (doc['subtotal'] as num?)?.toDouble() ?? 0;
                      final total = (doc['total'] as num?)?.toDouble() ?? 0;
                      final status = doc['status']?.toString() ?? 'active';
                      final issuedAt =
                          DateTime.tryParse(
                            doc['issued_at']?.toString() ?? '',
                          ) ??
                          DateTime.now();
                      final isVoid = status != 'active';

                      return DataRow(
                        // Anulado bien marcado: fondo rojo tenue + NCF y total
                        // tachados. Con el tinte al 4% las filas anuladas se
                        // confundían con las válidas al final de la tabla.
                        color: isVoid
                            ? WidgetStateProperty.all(
                                AppColors.destructive.withValues(alpha: 0.10),
                              )
                            : null,
                        cells: [
                          DataCell(
                            Text(
                              ncfNumber,
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                decoration: isVoid
                                    ? TextDecoration.lineThrough
                                    : null,
                                color: isVoid ? AppColors.destructive : null,
                              ),
                            ),
                          ),
                          DataCell(Text(ncfTypeName(ncfType))),
                          DataCell(
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 180),
                              child: Text(
                                customerName,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                          DataCell(
                            Text(customerRnc.isEmpty ? '-' : customerRnc),
                          ),
                          DataCell(Text(currency.format(subtotal))),
                          ...taxLabels.map((label) {
                            final amount = taxAmountForLabel(
                              doc,
                              label,
                              serviceFeeLabel,
                            );
                            return DataCell(
                              Text(amount > 0 ? currency.format(amount) : '-'),
                            );
                          }),
                          DataCell(
                            Text(
                              currency.format(total),
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                decoration: isVoid
                                    ? TextDecoration.lineThrough
                                    : null,
                                color: isVoid ? AppColors.destructive : null,
                              ),
                            ),
                          ),
                          DataCell(
                            ReportStatusTag(
                              label: isVoid ? 'Anulado' : 'Activo',
                              tone: isVoid
                                  ? AppColors.destructive
                                  : MangoColors.successGreen,
                            ),
                          ),
                          DataCell(Text(dateFormat.format(issuedAt.toLocal()))),
                        ],
                      );
                    }).toList(),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Botón "Ver / Ocultar anulados (N)". Solo aparece cuando el rango tiene
/// comprobantes anulados y el caller maneja el estado.
class _VoidedToggleButton extends StatelessWidget {
  const _VoidedToggleButton({
    required this.showVoided,
    required this.voidedCount,
    required this.onToggleVoided,
  });

  final bool showVoided;
  final int voidedCount;
  final ValueChanged<bool>? onToggleVoided;

  @override
  Widget build(BuildContext context) {
    final toggle = onToggleVoided;
    if (toggle == null || voidedCount == 0) return const SizedBox.shrink();
    return OutlinedButton.icon(
      onPressed: () => toggle(!showVoided),
      icon: Icon(
        showVoided ? Icons.visibility_off_outlined : Icons.visibility_outlined,
        size: 18,
      ),
      label: Text(
        showVoided
            ? 'Ocultar anulados ($voidedCount)'
            : 'Ver anulados ($voidedCount)',
      ),
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.destructive,
        side: BorderSide(color: AppColors.destructive.withValues(alpha: 0.35)),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      ),
    );
  }
}
