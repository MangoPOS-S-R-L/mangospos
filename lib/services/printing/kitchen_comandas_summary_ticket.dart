import 'package:intl/intl.dart';

import '../../core/utils/app_time.dart';
import '../../data/models/kitchen_comanda_report.dart';
import '../../data/models/kitchen_missing_report.dart';
import '../../data/models/printing_models.dart';
import 'esc_pos_generator.dart';

/// Resumen impreso de las comandas del rango (58/80mm).
///
/// Arriba cuántas comandas y órdenes se enviaron; después cada comanda (hora,
/// mesa, orden, mesero y sus productos); y AL FINAL cuánto salió de cada
/// producto. Con [includeComandas] en false sale solo el conteo y el total
/// por producto: en un día de 300 comandas el detalle son metros de papel.
class KitchenComandasSummaryTicket {
  const KitchenComandasSummaryTicket._();

  static PrintTicket generate({
    required KitchenComandaReport report,
    required String businessName,
    required DateTime from,
    required DateTime to,
    String stationLabel = 'Todas',
    bool includeComandas = true,
    int paperWidth = 80,
    DateTime? printedAt,

    /// Comandas desaparecidas. Null = no se pudo cargar: no se imprime ni
    /// el conteo ni la sección.
    KitchenMissingReport? missing,

    /// false = solo el conteo de eliminaciones, sin el detalle de cada una
    /// (modo "solo total por producto").
    bool includeMissingDetail = true,
  }) {
    final gen = EscPosGenerator(paperWidth: paperWidth);
    final qty = NumberFormat('#,##0.##', 'en_US');
    // Con un solo día basta la hora; con varios, la hora sola no dice cuál.
    // El último instante incluido: con un turno que cruza la medianoche hay
    // que imprimir el día junto a la hora (ver _rangeLabel).
    final multiDay = _spansDays(from, to);
    String when(DateTime d) =>
        multiDay ? '${_two(d.day)}/${_two(d.month)} ${_time(d)}' : _time(d);

    _header(
      gen,
      businessName: businessName,
      title: 'RESUMEN DE COMANDAS',
      from: from,
      to: to,
      stationLabel: stationLabel,
      printedAt: printedAt,
    );

    gen.setBold(true);
    gen.textRow('Comandas enviadas:', '${report.comandasCount}');
    gen.textRow('Órdenes:', '${report.ordersCount}');
    gen.setBold(false);
    gen.textRow('Productos:', qty.format(report.units));
    if (missing != null) {
      // Lo que alguien quitó de la cuenta después de mandarlo a cocina.
      gen.textRow('Eliminaciones:', '${missing.removals.length}');
      gen.textRow('  Productos eliminados:', qty.format(missing.removedUnits));
    }
    gen.doubleSeparator();

    if (includeComandas) {
      gen.setBold(true);
      gen.text('COMANDAS');
      gen.setBold(false);
      gen.separator();
      if (report.isEmpty) {
        gen.text('No se enviaron comandas.');
        gen.separator();
      }
      for (final c in report.comandas) {
        gen.setBold(true);
        gen.textRow(
          '${when(c.sentAt)} ${c.tableName.toUpperCase()}',
          '#${c.orderNumber}',
        );
        gen.setBold(false);
        final waiter = c.waiterName;
        if (waiter != null) gen.textWrapped('Mesero: ${waiter.toUpperCase()}');
        for (final i in c.displayItems) {
          gen.textWrapped(' ${qty.format(i.quantity)} x ${i.productName}');
          for (final m in i.modifiers) {
            gen.textWrapped(
              '     + ${m.name}${m.qty > 1 ? ' x${qty.format(m.qty)}' : ''}',
            );
          }
          if (i.notes != null) gen.textWrapped('     Nota: ${i.notes}');
        }
        gen.separator();
      }
      gen.lineFeed();

      // Las anuladas no cuentan en las comandas ni en el total, pero se
      // imprimen con la nota que se les puso al anular.
      final voided = report.comandasIn(KitchenChargeState.voided);
      if (voided.isNotEmpty) {
        gen.setBold(true);
        gen.textWrapped('COMANDAS ANULADAS (${voided.length})');
        gen.setBold(false);
        gen.separator();
        for (final c in voided) {
          gen.setBold(true);
          gen.textRow(
            '${when(c.sentAt)} ${c.tableName.toUpperCase()}',
            '#${c.orderNumber}',
          );
          gen.setBold(false);
          final reason = c.items.first.stateReason;
          if (reason != null) gen.textWrapped(reason);
          gen.textWrapped(report.voidNoteLabel(c));
          for (final i in c.displayItems) {
            gen.textWrapped(' ${qty.format(i.quantity)} x ${i.productName}');
          }
          gen.separator();
        }
        gen.lineFeed();
      }

      if (includeMissingDetail && missing != null && !missing.isEmpty) {
        _missingSection(gen, missing, when: when, qty: qty);
      }
    }

    gen.setBold(true);
    gen.text('TOTAL POR PRODUCTO');
    gen.setBold(false);
    gen.separator();
    final totals = report.productTotals;
    if (totals.isEmpty) gen.text('Sin productos.');
    for (final t in totals) {
      _nameAndQty(gen, t.productName, qty.format(t.quantity));
    }
    gen.separator();
    gen.setBold(true);
    gen.setTextSize(height: 2);
    gen.textRow('TOTAL:', qty.format(report.units));
    gen.setTextSize();
    gen.setBold(false);

    gen.lineFeed(2);
    gen.cut();

    return PrintTicket(
      type: 'kitchen_comandas_summary',
      escPosCommands: gen.getCommands(),
      rawText: gen.getPlainText(),
    );
  }

  /// Comparador "enviado a cocina vs. cobrado", de principio a fin:
  /// las comandas cobradas, las que no (sin cobrar, pendientes, cortesía,
  /// anuladas con su nota), lo cobrado sin comanda, lo que sigue sin cobrar
  /// ahora, los productos con diferencia y, AL FINAL, el resumen que cuadra
  /// todo (y contra Ventas).
  static PrintTicket generateComparison({
    required KitchenComandaReport report,
    required String businessName,
    required DateTime from,
    required DateTime to,
    String stationLabel = 'Todas',
    int paperWidth = 80,
    DateTime? printedAt,

    /// Productos cobrados del período según el reporte de Ventas, para
    /// cuadrar. Null = no aplica (filtro por estación) o no se pudo leer.
    double? salesItemsSold,

    /// Lo que sigue sin cobrar AHORA (modo "aún sin cobrar" de la RPC).
    /// Null = no se imprime esa sección.
    KitchenComandaReport? openNow,

    /// Lo cobrado en el rango que nunca pasó por cocina (modo "cobrado sin
    /// comanda" de la RPC). Null = no se imprime esa sección ni esa línea.
    KitchenComandaReport? withoutComanda,

    /// Comandas desaparecidas: borradas/reducidas después de enviarse o
    /// fuera de toda cuenta. Null = no se pudo cargar: no se imprime.
    KitchenMissingReport? missing,
  }) {
    final gen = EscPosGenerator(paperWidth: paperWidth);
    final qty = NumberFormat('#,##0.##', 'en_US');
    // El último instante incluido: con un turno que cruza la medianoche hay
    // que imprimir el día junto a la hora (ver _rangeLabel).
    final multiDay = _spansDays(from, to);
    String when(DateTime d) =>
        multiDay ? '${_two(d.day)}/${_two(d.month)} ${_time(d)}' : _time(d);
    final c = report.comparison;

    _header(
      gen,
      businessName: businessName,
      title: 'COMANDAS VS. COBRADO',
      from: from,
      to: to,
      stationLabel: stationLabel,
      printedAt: printedAt,
    );

    void comandaBlock(
      KitchenComanda comanda, {
      String? reason,
      bool withNote = false,
    }) {
      gen.setBold(true);
      gen.textRow(
        '${when(comanda.sentAt)} ${comanda.tableName.toUpperCase()}',
        '#${comanda.orderNumber}',
      );
      gen.setBold(false);
      final waiter = comanda.waiterName;
      if (waiter != null) gen.textWrapped('Mesero: ${waiter.toUpperCase()}');
      if (reason != null) gen.textWrapped(reason);
      if (withNote) gen.textWrapped(report.voidNoteLabel(comanda));
      for (final i in comanda.displayItems) {
        gen.textWrapped(' ${qty.format(i.quantity)} x ${i.productName}');
      }
      gen.separator();
    }

    void title(String text) {
      gen.setBold(true);
      gen.textWrapped(text);
      gen.setBold(false);
      gen.separator();
    }

    // 1. Las comandas cobradas (en dinero o a 0): para que el resto tenga
    //    contra qué leerse.
    final paid = report.comandasInAny(const {
      KitchenChargeState.charged,
      KitchenChargeState.zeroCharge,
    });
    if (paid.isNotEmpty) {
      title('COMANDAS COBRADAS (${paid.length})');
      for (final comanda in paid) {
        comandaBlock(comanda);
      }
      gen.lineFeed();
    }

    // 2. Las que no se cobraron normal, por estado, POR COMANDA.
    const titles = {
      KitchenChargeState.unpaid: 'COMANDAS SIN COBRAR',
      KitchenChargeState.pending: 'COMANDAS PENDIENTES - MESA ABIERTA',
      KitchenChargeState.courtesy: 'COMANDAS CON CORTESÍA',
      KitchenChargeState.voided: 'COMANDAS CON ANULADOS',
    };
    for (final state in titles.keys) {
      final groups = c.byComanda.where((g) => g.state == state).toList();
      if (groups.isEmpty) continue;
      title('${titles[state]} (${groups.length})');
      for (final g in groups) {
        comandaBlock(
          g.comanda,
          reason: g.reason,
          withNote: g.state == KitchenChargeState.voided,
        );
      }
      gen.lineFeed();
    }

    // 2b. Lo que salió a cocina y hoy no está en ninguna cuenta.
    if (missing != null && !missing.isEmpty) {
      _missingSection(gen, missing, when: when, qty: qty);
    }

    // 3. La dirección contraria: se cobró y nunca pasó por cocina.
    final noComanda = withoutComanda?.accounts;
    final noComandaUnits = noComanda?.fold(0.0, (s, a) => s + a.units);
    if (noComanda != null && noComanda.isNotEmpty) {
      title('COBRADO SIN COMANDA (${noComanda.length})');
      for (final a in noComanda) {
        gen.setBold(true);
        gen.textRow(a.tableName.toUpperCase(), '#${a.orderNumber}');
        gen.setBold(false);
        gen.textWrapped('Cobrado ${_date(a.since)} ${_time(a.since)}');
        for (final i in a.displayItems) {
          gen.textWrapped(' ${qty.format(i.quantity)} x ${i.productName}');
        }
        gen.separator();
      }
      gen.lineFeed();
    }

    // 4. Lo que sigue sin cobrar AHORA, sin importar el rango.
    if (openNow != null) {
      final accounts = openNow.openAccounts;
      final units = accounts.fold(0.0, (s, a) => s + a.units);
      title('AÚN SIN COBRAR (AHORA)');
      gen.textWrapped(
        accounts.isEmpty
            ? 'Nada enviado a cocina pendiente de cobrar.'
            : '${qty.format(units)} productos en ${accounts.length} '
                  '${accounts.length == 1 ? 'cuenta' : 'cuentas'}',
      );
      gen.separator();
      for (final a in accounts) {
        gen.setBold(true);
        gen.textRow(a.tableName.toUpperCase(), '#${a.orderNumber}');
        gen.setBold(false);
        gen.textWrapped(
          a.isOrphan ? 'Mesa cerrada con la orden abierta' : 'Mesa abierta',
        );
        gen.textWrapped('Desde ${_date(a.since)} ${_time(a.since)}');
        for (final i in a.displayItems) {
          gen.textWrapped(' ${qty.format(i.quantity)} x ${i.productName}');
        }
        gen.separator();
      }
      gen.lineFeed();
    }

    // 5. Productos con algo que revisar.
    final toReview = c.products.where((p) => p.needsReview).toList();
    if (toReview.isNotEmpty) {
      title('POR PRODUCTO');
      for (final p in toReview) {
        gen.setBold(true);
        gen.textWrapped(p.productName);
        gen.setBold(false);
        gen.textWrapped(
          '  Enviado ${qty.format(p.sent)} | Cobrado ${qty.format(p.charged)} '
          '| Dif. ${qty.format(p.difference)}',
        );
        final parts = [
          for (final (state, value) in [
            (KitchenChargeState.pending, p.pending),
            (KitchenChargeState.unpaid, p.unpaid),
            (KitchenChargeState.courtesy, p.courtesy),
            (KitchenChargeState.voided, p.voided),
          ])
            if (value > 0.005) '${state.label} ${qty.format(value)}',
        ];
        if (parts.isNotEmpty) gen.textWrapped('  ${parts.join(' - ')}');
      }
      gen.lineFeed();
    }

    // 6. RESUMEN al final: todo lo de arriba en números.
    gen.doubleSeparator();
    gen.setTextSize(height: 2);
    gen.setBold(true);
    gen.textCentered('RESUMEN');
    gen.setBold(false);
    gen.setTextSize();
    gen.doubleSeparator();
    gen.textRow('Comandas cobradas:', '${paid.length}');
    gen.textRow('Enviado a cocina:', qty.format(c.sent));
    gen.textRow('  Cobrado:', qty.format(c.charged));
    if (c.courtesy > 0.005) {
      gen.textRow('    de eso, cortesía:', qty.format(c.courtesy));
    }
    if (c.zeroCharge > 0.005) {
      gen.textRow('    de eso, a 0:', qty.format(c.zeroCharge));
    }
    gen.textRow('  Pendiente (abiertas):', qty.format(c.pending));
    gen.textRow('  Sin cobrar:', qty.format(c.unpaid));
    gen.setBold(true);
    gen.textRow('DIFERENCIA:', qty.format(c.difference));
    gen.setBold(false);
    gen.textRow('Anulado (aparte):', qty.format(c.voided));
    if (missing != null) {
      gen.textRow('Eliminaciones:', '${missing.removals.length}');
      gen.textRow(
        'Borrado/reducido (aparte):',
        qty.format(missing.removedUnits),
      );
      gen.textRow('Fuera de toda cuenta:', qty.format(missing.outsideUnits));
    }
    if (noComandaUnits != null) {
      gen.textRow('Cobrado sin comanda:', qty.format(noComandaUnits));
    }
    gen.separator();
    gen.setBold(true);
    gen.textRow(
      'TOTAL COBRADO:',
      qty.format(c.charged + (noComandaUnits ?? 0)),
    );
    gen.setBold(false);
    if (salesItemsSold != null) {
      gen.textRow('Según Ventas:', qty.format(salesItemsSold));
    }
    if (c.allCharged) {
      gen.textCenteredWrapped('Todo lo enviado a cocina está cobrado.');
    }

    gen.lineFeed(2);
    gen.cut();
    return PrintTicket(
      type: 'kitchen_comandas_comparison',
      escPosCommands: gen.getCommands(),
      rawText: gen.getPlainText(),
    );
  }

  /// "COMANDAS DESAPARECIDAS": primero lo que alguien borró o redujo (con
  /// quién, cuándo y el motivo), después lo que quedó fuera de toda cuenta.
  static void _missingSection(
    EscPosGenerator gen,
    KitchenMissingReport missing, {
    required String Function(DateTime) when,
    required NumberFormat qty,
  }) {
    gen.setBold(true);
    gen.textWrapped('COMANDAS DESAPARECIDAS');
    gen.setBold(false);
    gen.textWrapped('Salieron a cocina y no están en ninguna cuenta.');
    gen.separator();
    for (final removals in const [true, false]) {
      final groups = missing.groups(removals: removals);
      if (groups.isEmpty) continue;
      gen.setBold(true);
      gen.textWrapped(
        removals
            ? 'BORRADO O REDUCIDO DESPUÉS DE ENVIAR: '
                  '${qty.format(missing.removedUnits)}'
            : 'FUERA DE TODA CUENTA: ${qty.format(missing.outsideUnits)}',
      );
      gen.setBold(false);
      gen.separator();
      for (final g in groups) {
        final c = g.comanda;
        gen.setBold(true);
        gen.textRow(
          '${when(c.sentAt)} ${c.tableName.toUpperCase()}',
          '#${c.orderNumber}',
        );
        gen.setBold(false);
        final waiter = c.waiterName;
        if (waiter != null) gen.textWrapped('Mesero: ${waiter.toUpperCase()}');
        gen.textWrapped(g.kind.explanation ?? g.kind.label.toUpperCase());
        for (final e in g.entries) {
          gen.textWrapped(' ${qty.format(e.quantity)} x ${e.item.productName}');
          // "Borrado 18/09 21:14 por Ana" y "Motivo: …", cada uno en su
          // línea.
          if (e.kind.isRemoval) {
            for (final part in e.detail.split(' · ')) {
              gen.textWrapped('     $part');
            }
          }
        }
        gen.separator();
      }
    }
    gen.lineFeed();
  }

  static void _header(
    EscPosGenerator gen, {
    required String businessName,
    required String title,
    required DateTime from,
    required DateTime to,
    required String stationLabel,
    DateTime? printedAt,
  }) {
    gen.initialize();
    gen.lineFeed();
    gen.setTextSize(width: gen.paperWidth <= 58 ? 1 : 2, height: 2);
    gen.setBold(true);
    gen.textCenteredWrapped(businessName);
    gen.setBold(false);
    gen.setTextSize();
    gen.doubleSeparator();

    gen.setTextSize(height: 2);
    gen.setBold(true);
    gen.textCenteredWrapped(title);
    gen.setBold(false);
    gen.setTextSize();
    gen.textCentered('Rango: ${_rangeLabel(from, to)}');
    gen.textCentered('Estación: $stationLabel');
    gen.textCentered(
      'Impreso: ${_dateTime(AppTime.astFromInstant(printedAt ?? DateTime.now()))}',
    );
    gen.separator();
  }

  /// Nombre a la izquierda y cantidad a la derecha. Si el nombre no cabe en
  /// la línea (58mm, platos con nombre largo) se envuelve y la cantidad va
  /// sola a la derecha: truncarlo dejaría dos platos con el mismo nombre.
  static void _nameAndQty(EscPosGenerator gen, String name, String qty) {
    if (name.length + qty.length + 1 <= gen.maxChars) {
      gen.textRow(name, qty);
      return;
    }
    gen.textWrapped(name);
    gen.textRight(qty);
  }

  /// [to] es exclusivo. Con días completos se muestra el último día
  /// incluido (igual que el encabezado de Reportes); con horas —el turno que
  /// cruza la medianoche— se muestran las dos horas tal cual, porque el
  /// límite superior ya no es medianoche.
  static String _rangeLabel(DateTime from, DateTime to) {
    if (_hasTimeOfDay(from) || _hasTimeOfDay(to)) {
      return '${_dateTime(from)} - ${_dateTime(to)}';
    }
    final last = to.subtract(const Duration(days: 1));
    final a = _date(from);
    final b = _date(last);
    return a == b ? a : '$a - $b';
  }

  static bool _hasTimeOfDay(DateTime d) => d.hour != 0 || d.minute != 0;

  /// ¿El rango toca más de un día? [to] es exclusivo, así que se mira el
  /// último instante incluido.
  static bool _spansDays(DateTime from, DateTime to) {
    final last = to.subtract(const Duration(microseconds: 1));
    return _date(from) != _date(last);
  }

  static String _date(DateTime d) =>
      '${_two(d.day)}/${_two(d.month)}/${d.year}';

  static String _time(DateTime d) => '${_two(d.hour)}:${_two(d.minute)}';

  static String _dateTime(DateTime d) => '${_date(d)} ${_time(d)}';

  static String _two(int v) => v.toString().padLeft(2, '0');
}
