import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:intl/intl.dart';

import '../../../data/models/kitchen_comanda_report.dart';
import '../../../data/models/kitchen_missing_report.dart';
import '../../../data/models/table_deposit_report.dart';
import '../model/report_column.dart';
import '../model/report_table_data.dart';
import '../viewmodel/reports_viewmodel.dart';

class ReportsCsvExportService {
  /// CSV de la tabla personalizable: columnas visibles en su orden, filas en
  /// el orden de la pantalla (con subtotales si está agrupada) y fila de
  /// total. Sin formato: números planos, sin símbolo ni separador de miles.
  static Future<void> exportTable(ReportTableExport export) async {
    final csv = buildTableCsv(export);
    // BOM: Excel en Windows abre el CSV como UTF-8 (acentos y ñ intactos).
    await FilePicker.saveFile(
      dialogTitle: 'Guardar reporte CSV',
      fileName: '${export.fileStem}.csv',
      bytes: utf8.encode('﻿$csv'),
    );
  }

  static String buildTableCsv(ReportTableExport export) {
    final table = export.table;
    final width = table.columns.length;
    final rows = <List<String>>[
      [for (final column in table.columns) column.label],
    ];
    List<String> plainRow(List<ReportCell> cells) => [
          for (var c = 0; c < width; c++)
            plainValue(table.columns[c], cells[c],
                decimals: export.currencyDecimals),
        ];
    for (final row in table.rows) {
      if (row.type == ReportTableRowType.groupHeader) {
        rows.add([
          row.groupLabel ?? '',
          for (var c = 1; c < width; c++) '',
        ]);
      } else {
        rows.add(plainRow(row.cells));
      }
    }
    rows.add(plainRow(table.totals));
    return rows.map(_toCsvLine).join('\n');
  }

  /// Valor sin formato de una celda. Vacío cuando no hay dato o el total va
  /// en blanco; el rótulo de total viaja tal cual.
  static String plainValue(
    ReportColumn column,
    ReportCell cell, {
    int decimals = 2,
  }) {
    final raw = cell.raw;
    if (raw == null) return '';
    if (raw is String) return raw;
    if (raw is DateTime) return DateFormat('yyyy-MM-dd HH:mm').format(raw);
    if (raw is! num) return raw.toString();
    switch (column.kind) {
      case ReportColumnKind.money:
        return raw.toStringAsFixed(decimals);
      case ReportColumnKind.percent:
        return raw.toStringAsFixed(2);
      case ReportColumnKind.integer:
        return raw.round().toString();
      case ReportColumnKind.decimal:
        final fixed = raw.toStringAsFixed(4);
        return fixed.contains('.')
            ? fixed.replaceFirst(RegExp(r'\.?0+$'), '')
            : fixed;
      case ReportColumnKind.text:
      case ReportColumnKind.status:
      case ReportColumnKind.date:
        return raw.toString();
    }
  }

  static Future<void> exportCurrentReport({
    required ReportCategory category,
    required ReportsState state,
    required ReportsViewModel viewModel,
  }) async {
    final csv = buildCsv(category, state, viewModel);
    final filename =
        'reporte_${category.name}_${DateTime.now().millisecondsSinceEpoch}.csv';

    // BOM igual que en `exportTable`: sin él, Excel en Windows abre el CSV
    // como ANSI y los nombres con acento salen rotos ("PÃ©rez").
    await FilePicker.saveFile(
      dialogTitle: 'Guardar reporte CSV',
      fileName: filename,
      bytes: utf8.encode('\uFEFF$csv'),
    );
  }

  /// Contenido del CSV por categoría (sin BOM). Público para pruebas.
  static String buildCsv(
    ReportCategory category,
    ReportsState state,
    ReportsViewModel viewModel,
  ) {
    final rows = <List<String>>[];
    rows.add([viewModel.getCategoryTitle(category)]);
    rows.add([
      'Desde',
      state.salesFrom.toIso8601String(),
      'Hasta',
      state.salesTo.subtract(const Duration(days: 1)).toIso8601String(),
    ]);
    rows.add([]);

    void addMetricSection(List<SalesMetricCardData> metrics) {
      rows.add(['Métrica', 'Valor', 'Detalle']);
      for (final metric in metrics) {
        rows.add([metric.title, metric.value, metric.subtitle]);
      }
      rows.add([]);
    }

    void addBreakdownSection(String title, List<SalesBreakdownRow> breakdown) {
      rows.add([title]);
      rows.add(['Concepto', 'Monto', 'Cantidad', 'Conteo']);
      for (final row in breakdown) {
        rows.add([
          row.label,
          row.amount.toStringAsFixed(2),
          row.quantity.toStringAsFixed(2),
          row.count.toString(),
        ]);
      }
      rows.add([]);
    }

    // Label del service fee derivado de la configuración del comercio
    // (`service_fee_label`). Antes era "Propina de ley" hardcoded — rompía
    // multi-país y multi-configuración.
    final serviceFeeLabel =
        (state.fiscalSummary?['service_fee_label'] as String?)?.trim();
    final effectiveServiceFeeLabel =
        (serviceFeeLabel?.isNotEmpty ?? false)
            ? serviceFeeLabel!
            : 'Cargo de servicio';

    void addFiscalDocumentsDetail(List<Map<String, dynamic>> fiscalDocs) {
      if (fiscalDocs.isEmpty) return;
      final taxLabels =
          _collectTaxLabels(fiscalDocs, effectiveServiceFeeLabel);
      rows.add(['Detalle de comprobantes']);
      rows.add([
        'NCF',
        'Tipo',
        'Cliente',
        'RNC/Cédula',
        'Subtotal',
        ...taxLabels,
        'Total',
        'Estado',
        'Fecha',
      ]);
      for (final doc in fiscalDocs) {
        final issuedAt =
            DateTime.tryParse(doc['issued_at']?.toString() ?? '') ??
                DateTime.now();
        rows.add([
          doc['ncf_number']?.toString() ?? '',
          doc['ncf_type']?.toString() ?? '',
          doc['customer_name']?.toString() ?? 'CONSUMIDOR FINAL',
          doc['customer_rnc']?.toString() ?? '-',
          ((doc['subtotal'] as num?)?.toDouble() ?? 0).toStringAsFixed(2),
          ...taxLabels.map((label) {
            final amount = _taxAmountForLabel(
              doc,
              label,
              effectiveServiceFeeLabel,
            );
            return amount > 0 ? amount.toStringAsFixed(2) : '0.00';
          }),
          ((doc['total'] as num?)?.toDouble() ?? 0).toStringAsFixed(2),
          (doc['status']?.toString() ?? 'active') == 'active'
              ? 'Activo'
              : 'Anulado',
          issuedAt.toLocal().toIso8601String(),
        ]);
      }
      rows.add([]);
    }

    void addProductSalesSection(List<ProductSalesReportRow> productRows) {
      rows.add(['Ventas por producto']);
      rows.add([
        'Producto',
        'Categoría',
        'Cantidad vendida',
        'Ventas brutas',
        'Descuentos',
        'Cortesías',
        'Ventas netas',
        'Costo',
        'Ganancia bruta',
        'Margen %',
        'Tickets',
      ]);
      for (final row in productRows) {
        rows.add([
          row.product,
          row.category,
          row.quantitySold.toStringAsFixed(2),
          row.grossSales.toStringAsFixed(2),
          row.discounts.toStringAsFixed(2),
          row.courtesies.toStringAsFixed(2),
          row.netSales.toStringAsFixed(2),
          row.cost.toStringAsFixed(2),
          row.grossProfit.toStringAsFixed(2),
          row.marginPct == null ? '' : row.marginPct!.toStringAsFixed(1),
          row.tickets.toString(),
        ]);
      }
      rows.add([]);
    }

    switch (category) {
      case ReportCategory.sales:
        addMetricSection(viewModel.getSalesMetricCards());
        // Sub-reporte "Por comprobante" sale enfocado: solo métricas
        // + tabla de comprobantes. Mismo formato limpio que el reporte
        // de impuestos.
        if (state.salesSubReport == SalesSubReport.byReceipt) {
          addBreakdownSection(
            'Ventas por recibo / comprobante',
            viewModel.getReceiptRows(),
          );
          // Sin anulados salvo que el usuario los haya mostrado en la vista.
          addFiscalDocumentsDetail(viewModel.getVisibleFiscalDocuments());
          break;
        }
        addBreakdownSection(
          'Ventas por tipo de pago',
          viewModel.getPaymentMethodRows(),
        );
        addBreakdownSection(
          'Ventas por categoría',
          viewModel.getCategoryRows(),
        );
        addBreakdownSection('Ventas por empleado', viewModel.getEmployeeRows());
        addBreakdownSection(
          'Ventas por recibo / comprobante',
          viewModel.getReceiptRows(),
        );
        addBreakdownSection(
          'Ventas por modificadores',
          viewModel.getModifierRows(),
        );
        addBreakdownSection(
          'Descuentos y cortesías',
          viewModel.getDiscountRows(),
        );
        addProductSalesSection(viewModel.getFilteredProductSalesRows());
        addBreakdownSection('Top productos', viewModel.getTopProductRows());
        addBreakdownSection('Ventas por zona', viewModel.getZoneRows());
        addBreakdownSection('Ventas por hora', viewModel.getHourlyRows());
        break;
      case ReportCategory.delivery:
        final deliveryDate = DateFormat('dd/MM/yyyy HH:mm:ss');
        rows.add(['Fees de delivery cobrados']);
        rows.add([
          'Fecha de cobro',
          'Cliente',
          'Total de la orden',
          'Fee de delivery',
        ]);
        for (final row in viewModel.getDeliveryFeeRows()) {
          rows.add([
            row.paidAt != null ? deliveryDate.format(row.paidAt!) : '',
            row.customerName,
            row.orderTotal.toStringAsFixed(2),
            row.deliveryFee.toStringAsFixed(2),
          ]);
        }
        rows.add([
          'Total',
          '${viewModel.deliveryOrdersCount} órdenes',
          viewModel.deliveryTotalOrdersAmount.toStringAsFixed(2),
          viewModel.deliveryTotalFees.toStringAsFixed(2),
        ]);
        rows.add([]);
        break;
      case ReportCategory.comandas:
        final report = viewModel.comandasView;
        final qty = NumberFormat('#,##0.##', 'en_US');
        final missingForHeader = viewModel.comandasMissingView;
        rows.add([
          'Estación',
          viewModel.comandasStationLabel,
          'Comandas',
          '${report.comandasCount}',
          'Órdenes',
          '${report.ordersCount}',
          if (missingForHeader != null) ...[
            'Eliminaciones',
            '${missingForHeader.removals.length}',
          ],
        ]);
        rows.add([]);
        // Una fila por producto de cada comanda: así se puede filtrar y
        // sumar en Excel.
        rows.add(['Comandas enviadas']);
        rows.add([
          'Fecha',
          'Mesa',
          'Orden',
          'Mesero',
          'Estación',
          'Producto',
          'Cantidad',
          'Modificadores',
          'Nota',
        ]);
        final sentFormat = DateFormat('dd/MM/yyyy HH:mm:ss');
        for (final c in report.comandas) {
          for (final i in c.displayItems) {
            rows.add([
              sentFormat.format(c.sentAt),
              c.tableName,
              c.orderNumber,
              c.waiterName ?? '',
              i.areaNames.join(' / '),
              i.productName,
              qty.format(i.quantity),
              i.modifiers
                  .map((m) => m.qty > 1 ? '${m.name} x${qty.format(m.qty)}' : m.name)
                  .join(', '),
              i.notes ?? '',
            ]);
          }
        }
        rows.add([]);
        rows.add(['Total por producto']);
        rows.add(['Producto', 'Cantidad', 'En comandas']);
        for (final t in report.productTotals) {
          rows.add([t.productName, qty.format(t.quantity), '${t.comandas}']);
        }
        rows.add(['Total', qty.format(report.units), '${report.comandasCount}']);
        rows.add([]);
        // Comparador: enviado a cocina vs. cobrado.
        final cmp = report.comparison;
        rows.add(['Enviado a cocina vs. cobrado']);
        rows.add([
          'Producto',
          'Enviado',
          'Cobrado (incluye cortesía y a 0)',
          'Cortesía',
          'Cobrado a 0',
          'Pendiente',
          'Sin cobrar',
          'Diferencia',
          'Anulado (aparte)',
        ]);
        for (final p in cmp.products) {
          rows.add([
            p.productName,
            qty.format(p.sent),
            qty.format(p.charged),
            qty.format(p.courtesy),
            qty.format(p.zeroCharge),
            qty.format(p.pending),
            qty.format(p.unpaid),
            qty.format(p.difference),
            qty.format(p.voided),
          ]);
        }
        rows.add([
          'Total',
          qty.format(cmp.sent),
          qty.format(cmp.charged),
          qty.format(cmp.courtesy),
          qty.format(cmp.zeroCharge),
          qty.format(cmp.pending),
          qty.format(cmp.unpaid),
          qty.format(cmp.difference),
          qty.format(cmp.voided),
        ]);
        final sold = state.comandasSalesItemsSold;
        if (viewModel.effectiveComandasArea == null &&
            sold != null &&
            sold >= 0) {
          rows.add(['Cobrado según el reporte de Ventas', qty.format(sold)]);
        }
        rows.add([]);
        // Una fila por producto de cada comanda no cobrada (se puede filtrar
        // por orden en Excel para ver la comanda completa).
        rows.add(['Comandas no cobradas']);
        rows.add([
          'Estado',
          'Fecha',
          'Mesa',
          'Orden',
          'Mesero',
          'Producto',
          'Cantidad',
          'Motivo',
          'Nota de anulación',
          'Anulada el',
        ]);
        for (final g in cmp.byComanda) {
          for (final i in g.comanda.displayItems) {
            rows.add([
              g.state.label,
              sentFormat.format(g.comanda.sentAt),
              g.comanda.tableName,
              g.comanda.orderNumber,
              g.comanda.waiterName ?? '',
              i.productName,
              qty.format(i.quantity),
              g.reason ?? '',
              g.state != KitchenChargeState.voided
                  ? ''
                  : report.hasVoidNotes
                  ? (g.note ?? '')
                  : 'No disponible (falta actualizar la migración)',
              g.state == KitchenChargeState.voided && g.comanda.voidAt != null
                  ? sentFormat.format(g.comanda.voidAt!)
                  : '',
            ]);
          }
        }
        rows.add([]);
        final missing = viewModel.comandasMissingView;
        if (missing != null) {
          // Una fila por producto: salió a cocina y hoy no está en ninguna
          // cuenta.
          rows.add(['Comandas desaparecidas']);
          rows.add([
            'Qué pasó',
            'Fecha',
            'Mesa',
            'Orden',
            'Mesero',
            'Producto',
            'Cantidad',
            'Detalle',
          ]);
          for (final removals in const [true, false]) {
            for (final g in missing.groups(removals: removals)) {
              for (final KitchenMissingItem e in g.entries) {
                rows.add([
                  e.kind.label,
                  sentFormat.format(e.item.sentAt),
                  g.comanda.tableName,
                  g.comanda.orderNumber,
                  g.comanda.waiterName ?? '',
                  e.item.productName,
                  qty.format(e.quantity),
                  e.detail,
                ]);
              }
            }
          }
          rows.add([
            'Total borrado o reducido después de enviar',
            qty.format(missing.removedUnits),
          ]);
          rows.add([
            'Total fuera de toda cuenta',
            qty.format(missing.outsideUnits),
          ]);
          rows.add([]);
        }
        if (state.comandasWithoutComandaReport != null) {
          final withoutComanda = viewModel.comandasWithoutComandaView;
          final units = withoutComanda.accounts.fold(
            0.0,
            (s, a) => s + a.units,
          );
          rows.add(['Cobrado sin comanda']);
          rows.add(['Mesa', 'Cobrado', 'Orden', 'Producto', 'Cantidad']);
          for (final a in withoutComanda.accounts) {
            for (final i in a.displayItems) {
              rows.add([
                a.tableName,
                sentFormat.format(a.since),
                a.orderNumber,
                i.productName,
                qty.format(i.quantity),
              ]);
            }
          }
          rows.add(['Total cobrado sin comanda', qty.format(units)]);
          rows.add([
            'Total cobrado (comandas + sin comanda)',
            qty.format(cmp.charged + units),
          ]);
          rows.add([]);
        }
        if (state.comandasOpenReport != null) {
          final openNow = viewModel.comandasOpenView;
          rows.add(['Aún sin cobrar (ahora mismo)']);
          rows.add([
            'Mesa',
            'Estado',
            'Desde',
            'Orden',
            'Mesero',
            'Producto',
            'Cantidad',
          ]);
          for (final a in openNow.openAccounts) {
            for (final i in a.displayItems) {
              rows.add([
                a.tableName,
                a.isOrphan
                    ? 'Mesa cerrada con la orden abierta'
                    : 'Mesa abierta',
                sentFormat.format(a.since),
                a.orderNumber,
                a.waiterName ?? '',
                i.productName,
                qty.format(i.quantity),
              ]);
            }
          }
          rows.add([]);
        }
        break;
      case ReportCategory.deposits:
        final report = state.depositsReport ?? TableDepositReport.empty;
        final depositDate = DateFormat('dd/MM/yyyy HH:mm:ss');
        rows.add(['Saldos por mesa (balance al momento de exportar)']);
        rows.add([
          'Mesa',
          'A nombre de',
          'Referencia',
          'Abonado',
          'Consumido',
          'Devuelto',
          'Balance',
        ]);
        for (final a in report.accounts) {
          rows.add([
            a.tableLabel,
            a.holderName ?? '',
            a.referenceLabel,
            a.deposited.toStringAsFixed(2),
            a.consumed.toStringAsFixed(2),
            a.returned.toStringAsFixed(2),
            a.balance.toStringAsFixed(2),
          ]);
        }
        rows.add([
          'Total',
          '',
          '',
          '',
          '',
          '',
          report.outstandingBalance.toStringAsFixed(2),
        ]);
        rows.add([]);
        rows.add(['Movimientos del rango']);
        rows.add([
          'Fecha',
          'Mesa',
          'A nombre de',
          'Tipo',
          'Referencia',
          'Nota',
          'Método',
          'Monto',
          'Balance',
          'Registrado por',
        ]);
        for (final m in report.movements) {
          rows.add([
            depositDate.format(m.createdAt),
            m.tableLabel,
            m.holderName ?? '',
            m.typeLabel,
            m.reference ?? '',
            m.note ?? '',
            m.methodName ?? '',
            m.amount.toStringAsFixed(2),
            m.balanceAfter.toStringAsFixed(2),
            m.createdByName ?? '',
          ]);
        }
        rows.add([]);
        break;
      case ReportCategory.offers:
        final offerDate = DateFormat('dd/MM/yyyy HH:mm:ss');
        // Pivote: cantidad por producto.
        rows.add(['Productos en oferta']);
        rows.add(['Producto', 'Cantidad']);
        for (final row in viewModel.getOfferProductTotals()) {
          rows.add([row.productName, row.quantity.toStringAsFixed(2)]);
        }
        rows.add([
          'Suma total',
          viewModel.offersTotalQuantity.toStringAsFixed(2),
        ]);
        rows.add([]);
        // Detalle: una fila por cada vez que se aplicó una oferta.
        rows.add(['Detalle de ofertas']);
        rows.add([
          'Fecha',
          'Oferta',
          'Producto',
          'Cantidad',
          'Valor a precio de menú',
          'Descuento otorgado',
        ]);
        for (final row in viewModel.getOfferDetailRows()) {
          rows.add([
            row.dateTime != null ? offerDate.format(row.dateTime!) : '',
            row.offerName,
            row.productName,
            row.quantity.toStringAsFixed(2),
            row.valorMenu.toStringAsFixed(2),
            row.descuento.toStringAsFixed(2),
          ]);
        }
        rows.add([
          'Total',
          '',
          '',
          viewModel.offersTotalQuantity.toStringAsFixed(2),
          viewModel.offersTotalValorMenu.toStringAsFixed(2),
          viewModel.offersTotalDescuento.toStringAsFixed(2),
        ]);
        rows.add([]);
        break;
      case ReportCategory.finances:
        addMetricSection(viewModel.getFinanceMetricCards());
        addBreakdownSection(
          'Movimientos por tipo',
          viewModel.getFinanceTypeRows(),
        );
        addBreakdownSection('Sesiones', viewModel.getFinanceSessionRows());
        break;
      case ReportCategory.inventory:
        addMetricSection(viewModel.getInventoryMetricCards());
        addBreakdownSection('Top stock', viewModel.getInventoryTopStockRows());
        addBreakdownSection('Alertas', viewModel.getInventoryAlertRows());
        addBreakdownSection(
          'Movimientos',
          viewModel.getInventoryMovementRows(),
        );
        break;
      case ReportCategory.purchases:
        addMetricSection(viewModel.getPurchaseMetricCards());
        addBreakdownSection('Estados', viewModel.getPurchaseStatusRows());
        addBreakdownSection(
          'Top proveedores',
          viewModel.getPurchaseSupplierRows(),
        );
        break;
      case ReportCategory.taxes:
        // Misma fuente que el view (fiscalSummary). Ver comentario en
        // reports_export_service.dart sobre por qué cambiamos de
        // getTaxMetricCards a getTaxReportMetricCards.
        addMetricSection(viewModel.getTaxReportMetricCards());
        addBreakdownSection(
          'Total facturado por tipo de comprobante',
          viewModel.getTaxReportTypeRows(),
        );
        break;
      case ReportCategory.fiscal:
        addMetricSection(viewModel.getFiscalMetricCards());
        addBreakdownSection(
          'Comprobantes por tipo de NCF',
          viewModel.getFiscalTypeRows(),
        );
        addBreakdownSection(
          'Desglose por tipo de impuesto',
          viewModel.getFiscalTaxBreakdownRows(),
        );
        addFiscalDocumentsDetail(viewModel.getVisibleFiscalDocuments());
        break;
    }

    return rows.map(_toCsvLine).join('\n');
  }

  static String _toCsvLine(List<String> cells) {
    return cells.map((cell) => '"${cell.replaceAll('"', '""')}"').join(',');
  }

  // Skip "Impuesto X%" entries — fallback de tax_rate combinado que no
  // pudo desdoblarse contra impuestos configurados (ej. 28% = ITBIS+Ley).
  static final RegExp _kUnmappedTaxLabelRe = RegExp(r'^Impuesto\s');

  static List<String> _collectTaxLabels(
    List<Map<String, dynamic>> documents,
    String serviceFeeLabel,
  ) {
    final labels = <String>{};
    for (final doc in documents) {
      final breakdown = doc['tax_breakdown'];
      if (breakdown is List) {
        for (final item in breakdown) {
          final m = item is Map<String, dynamic>
              ? item
              : Map<String, dynamic>.from(item as Map);
          final label = m['label']?.toString() ?? '';
          if (_kUnmappedTaxLabelRe.hasMatch(label)) continue;
          final rate = (m['rate'] as num?)?.toDouble() ?? 0;
          final display = rate > 0
              ? '$label (${rate.toStringAsFixed(rate.truncateToDouble() == rate ? 0 : 2)}%)'
              : label;
          if (display.isNotEmpty) labels.add(display);
        }
      }
      final sf = (doc['service_fee'] as num?)?.toDouble() ?? 0;
      if (sf > 0) labels.add(serviceFeeLabel);
    }
    return labels.toList(growable: false);
  }

  static double _taxAmountForLabel(
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
}
