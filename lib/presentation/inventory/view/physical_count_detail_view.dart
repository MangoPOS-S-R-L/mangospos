// Detalle de sesión de conteo físico: header + líneas + acciones.
//
// Workflow visible:
//   draft       → [Congelar inventario] [Cancelar]
//   in_progress → editor de conteo por línea + [Completar conteo] [Cancelar]
//   completed   → solo vista (sistema vs contado vs diferencia vs valor)
//   cancelled   → solo vista
//
// MODO A CIEGAS: si la sesión se creó con `is_blind`, las columnas "Sistema",
// "Diferencia" y "Valor" quedan ocultas mientras se cuenta, para que quien
// cuenta no sepa lo que "debería" haber. Quien tiene permiso de completar
// puede revelarlas para decidir recuentos; al completar se revelan siempre.
//
// EDITAR LA FICHA SIN SALIR: cada renglón lleva un botón al lado del nombre
// que abre el formulario del maestro (el mismo de Insumos). Nació de un caso
// concreto del piso: el insumo no tiene código de barras, la pistola no lo
// encuentra y hay que teclearlo entre cientos de líneas. Con el botón se
// escanea dentro de la ficha, se guarda, y de ahí en adelante la pistola
// resuelve ese código en esta misma pantalla. El botón se pinta en ámbar
// solo cuando el insumo no tiene NI código de barras NI SKU: con cualquiera
// de los dos ya es escaneable.
//
// AGREGAR LO QUE NO ESTÁ: el congelado arma las líneas con los insumos
// activos DE ESE MOMENTO, así que la mercancía que aparece en el anaquel sin
// ficha —o el insumo dado de alta después de congelar— no tenía dónde
// anotarse. Ahora se suma a la sesión en caliente (`fn_physical_count_add_item`,
// migración 20260902_0004), sea desde el botón "Agregar" o desde un escaneo
// que no resolvió.
//
// PRODUCTO O INSUMO — son dos altas distintas y las dos hacen falta:
//   · INSUMO  (`inventory_items`): se cuenta y se consume, no se vende.
//   · PRODUCTO (`menu_items`): se vende en la caja. Para poder contarlo tiene
//     que ser INVENTARIABLE, porque lo que se cuenta no es el producto sino
//     el insumo que el sistema le crea al activarle stock propio
//     (`menu_items.inventory_item_id`). Por eso el diálogo se abre con
//     "Inventariable" ya encendido y, si igual se apaga, el producto se crea
//     pero NO entra a la sesión — y se avisa.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/core/utils/app_toast.dart';
import 'package:mangopos/core/utils/export/report_exporter.dart';
import 'package:mangopos/data/repositories/physical_count_repository.dart';
import 'package:mangopos/services/session/session_controller.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/theme/app_colors.dart';
import '../../../data/utils/business_id_resolver.dart';
import '../../products/viewmodel/products_viewmodel.dart';
import '../../products/widgets/add_edit_product_dialog.dart';
import '../services/inventory_scan.dart';
import '../state/inventory_state.dart';
import '../viewmodel/inventory_viewmodel.dart';
import 'widgets/item_form_dialog.dart';
import 'package:mangopos/core/utils/friendly_error.dart';

class PhysicalCountDetailView extends ConsumerStatefulWidget {
  final String sessionId;
  const PhysicalCountDetailView({super.key, required this.sessionId});

  @override
  ConsumerState<PhysicalCountDetailView> createState() =>
      _PhysicalCountDetailViewState();
}

class _PhysicalCountDetailViewState
    extends ConsumerState<PhysicalCountDetailView> {
  bool _loading = true;
  bool _busy = false;
  String? _error;
  PhysicalCountDetail? _detail;
  bool _dirty = false;

  // Filtro: ocultar líneas ya contadas para enfocarse en las pendientes.
  bool _onlyPending = false;
  // Filtro: solo líneas con diferencia (para revisar antes de cerrar).
  bool _onlyDifferences = false;
  String _search = '';
  // El escaneo (y el alta de un insumo) filtran la lista por su nombre. Sin
  // controlador el campo quedaba vacío mientras la lista mostraba un solo
  // renglón: parecía que la pantalla se había vaciado.
  final TextEditingController _searchCtrl = TextEditingController();

  // El supervisor revela el stock del sistema en una sesión a ciegas para
  // poder decidir qué mandar a recuento.
  bool _revealed = false;

  // Selección para pedir 2ª vuelta.
  final Set<String> _selected = {};
  bool _selectionMode = false;

  // Con un diálogo encima, la pistola NO debe filtrar la lista de atrás: sus
  // caracteres van al campo de texto enfocado (el despachador observa sin
  // consumir). Se sigue escuchando —para que el escaneo no caiga en la
  // pantalla de ventas, que queda viva en el shell— pero se ignora.
  bool _dialogOpen = false;

  /// Fichas editadas SIN salir del conteo. Pisan al catálogo del módulo y
  /// además cubren al insumo que ese catálogo no trae (filtra por bodega;
  /// el conteo incluye todos los activos del negocio).
  final Map<String, InventoryItemSummary> _itemOverrides = {};

  // Índice memoizado del catálogo: se rehace solo cuando cambia la lista de
  // origen o se edita una ficha. Se recorre en cada build (buscar es teclear)
  // y el catálogo tiene miles de insumos.
  List<InventoryItemSummary>? _catalogoBase;
  List<InventoryItemSummary> _catalogoParaEscaneo = const [];
  Map<String, InventoryItemSummary> _catalogoPorId = const {};

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    Future.microtask(_load);
    // El catálogo del módulo es lo único que trae los CÓDIGOS DE BARRAS: las
    // líneas del conteo sólo tienen nombre y SKU. Sin esto, entrar directo a
    // una sesión —que es lo que se hace un día de inventario— dejaba la
    // pistola resolviendo únicamente por SKU.
    //
    // No bloquea la pantalla: el conteo se puede empezar mientras carga, y
    // si falla se sigue con el respaldo por SKU.
    Future.microtask(() => ref.read(inventoryViewModelProvider).init());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final detail = await ref
          .read(physicalCountRepositoryProvider)
          .getDetail(widget.sessionId);
      if (!mounted) return;
      setState(() {
        _detail = detail;
        _loading = false;
        _selected.removeWhere(
          (id) => !detail.lines.any((l) => l.itemId == id),
        );
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = FriendlyError.humanize('No se pudo cargar la sesión: $e');
        _loading = false;
      });
    }
  }

  /// Vuelve a bajar la sesión entera, a pedido.
  ///
  /// El conteo normal NO recarga (ver `_saveLine`): con mil líneas eso apaga
  /// la pantalla y pierde el scroll. Pero cuando las líneas cambian por fuera
  /// —otra terminal, o insumos nuevos metidos a la sesión— hace falta pedirlo
  /// explícitamente. Se avisa cuántos renglones aparecieron.
  Future<void> _recargar() async {
    final antes = _detail?.lines.length ?? 0;
    await _load();
    if (!mounted) return;
    final ahora = _detail?.lines.length ?? 0;
    final nuevos = ahora - antes;
    AppToast.info(
      context,
      nuevos > 0
          ? '$nuevos item(s) nuevos en la sesión. Ahora son $ahora.'
          : 'Sesión al día: $ahora item(s).',
    );
  }

  /// Oculta el stock del sistema: sesión a ciegas, en conteo y sin revelar.
  bool get _hideSystem {
    final h = _detail?.header;
    if (h == null) return false;
    return h.isBlind &&
        h.status == PhysicalCountStatus.inProgress &&
        !_revealed;
  }

  Future<void> _freeze() async {
    if (_busy) return;
    final isBlind = _detail?.header.isBlind ?? false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Congelar inventario'),
        content: Text(
          'Se tomará un snapshot del stock actual de la bodega, incluyendo '
          'todos los insumos activos.\n\n'
          '${isBlind ? 'La sesión es a ciegas: al contar no se mostrará el '
              'stock del sistema.\n\n' : ''}'
          'Puedes seguir vendiendo durante el conteo — al completar, el '
          'ajuste se calcula contra el stock de ese momento, así que el '
          'inventario queda exactamente en lo que contaste.',
          style: const TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: MangoColors.primaryOrange,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Congelar'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      await ref
          .read(physicalCountRepositoryProvider)
          .freeze(widget.sessionId);
      _dirty = true;
      await _load();
    } catch (e) {
      if (!mounted) return;
      AppToast.error(context, 'No se pudo congelar: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openComplete() async {
    final detail = _detail;
    if (detail == null) return;
    final pending = detail.lines.where((l) => l.countedQuantity == null).length;
    final pendingRecount =
        detail.lines.where((l) => l.recountRequested).length;
    final adjustments = detail.lines.where((l) {
      final v = l.variance;
      return v != null && v.abs() >= 0.0001;
    }).toList(growable: false);

    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _CompleteConfirmDialog(
        pending: pending,
        pendingRecount: pendingRecount,
        adjustments: adjustments,
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      final result = await ref
          .read(physicalCountRepositoryProvider)
          .complete(widget.sessionId);
      _dirty = true;
      _revealed = true;
      _selectionMode = false;
      _selected.clear();
      await _load();
      if (!mounted) return;
      // Cerrar el conteo es el momento en que el reporte tiene valor, así que
      // se ofrece de una vez en vez de esperar a que lo busquen en la barra.
      final wantsPdf = await showDialog<bool>(
        context: context,
        builder: (_) => _CompletedDialog(
          adjustments: (result['adjustments_count'] as num?)?.toInt() ?? 0,
          netValue:
              (result['variance_value_total'] as num?)?.toDouble() ?? 0,
        ),
      );
      if (wantsPdf == true && mounted) {
        await _exportComparison(onlyDifferences: true);
      }
    } catch (e) {
      if (!mounted) return;
      AppToast.error(context, 'No se pudo completar: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  int get _pendientesSinContar =>
      (_detail?.lines ?? const []).where((l) => l.countedQuantity == null).length;

  /// Pone en cero todas las líneas sin contar.
  ///
  /// Es lo que hace que un conteo REEMPLACE el inventario: al completar, sólo
  /// se ajustan las líneas con cantidad, así que lo que quede en blanco
  /// conserva su existencia vieja. En un catálogo de mil insumos eso es
  /// existencia fantasma garantizada.
  ///
  /// Va aparte del cierre a propósito: contar por partes es un caso legítimo
  /// y ahí las líneas en blanco NO se deben tocar. La decisión la toma quien
  /// cierra, no la función.
  Future<void> _ponerEnCeroPendientes() async {
    final cuantas = _pendientesSinContar;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Poner en cero lo no contado'),
        content: Text(
          'Vas a marcar $cuantas insumo(s) en CERO: los que nadie encontró '
          'físicamente.\n\n'
          'Hacelo solo si este conteo cubre TODO el almacén. Si estás '
          'contando por partes, cancelá: lo que dejes en blanco conserva su '
          'existencia actual, que es lo correcto en un conteo parcial.\n\n'
          'Todavía podés corregir cualquier línea antes de completar.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Poner $cuantas en cero'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    setState(() => _busy = true);
    try {
      final n = await ref
          .read(physicalCountRepositoryProvider)
          .zeroPending(widget.sessionId);
      _dirty = true;
      await _load();
      if (!mounted) return;
      AppToast.success(context, '$n insumo(s) quedaron en cero.');
    } catch (e) {
      if (!mounted) return;
      AppToast.error(context, 'No se pudo: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _requestRecount() async {
    if (_selected.isEmpty) return;
    setState(() => _busy = true);
    try {
      final n = await ref.read(physicalCountRepositoryProvider).requestRecount(
            sessionId: widget.sessionId,
            itemIds: _selected.toList(growable: false),
          );
      _dirty = true;
      setState(() {
        _selected.clear();
        _selectionMode = false;
      });
      await _load();
      if (!mounted) return;
      AppToast.success(context, '$n item(s) marcados para recuento.');
    } catch (e) {
      if (!mounted) return;
      AppToast.error(context, 'No se pudo marcar el recuento: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openCancel() async {
    final reasonCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cancelar sesión'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'La sesión se marcará como cancelada. No se generarán '
              'ajustes ni se moverá inventario.',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: reasonCtrl,
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: 'Razón (opcional)',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('No, mantener'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFDC2626),
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Sí, cancelar'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      await ref.read(physicalCountRepositoryProvider).cancel(
            sessionId: widget.sessionId,
            reason: reasonCtrl.text.trim().isEmpty
                ? null
                : reasonCtrl.text.trim(),
          );
      _dirty = true;
      await _load();
    } catch (e) {
      if (!mounted) return;
      AppToast.error(context, 'No se pudo cancelar: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveLine(PhysicalCountLine line, double value) async {
    final eraRecuento = line.recountRequested && line.countedQuantity != null;
    try {
      await ref.read(physicalCountRepositoryProvider).setCount(
            sessionId: widget.sessionId,
            itemId: line.itemId,
            countedQuantity: value,
          );
      _dirty = true;
      if (!mounted) return;
      // Se actualiza en memoria, NO se recarga la sesión.
      //
      // Recargar tras cada número tecleado volvía a bajar TODAS las líneas
      // —en un catálogo de mil insumos, mil veces— y además ponía la
      // pantalla en spinner: se perdía el foco y el scroll en cada renglón.
      // El servidor ya guardó; la pantalla solo tiene que reflejarlo.
      _aplicarConteoLocal(line, value, wasRecount: eraRecuento);
    } catch (e) {
      if (!mounted) return;
      // El conteo NO quedó guardado: hay que decirlo fuerte, porque el
      // número sigue escrito en el campo y parece que sí entró.
      AppToast.error(
        context,
        'NO se guardó el conteo de ${line.itemName}. Revisá la conexión y '
        'volvé a escribirlo.',
      );
    }
  }

  /// Refleja el conteo recién guardado sin ir a la red: reemplaza la línea y
  /// recalcula los contadores del encabezado.
  void _aplicarConteoLocal(
    PhysicalCountLine line,
    double value, {
    required bool wasRecount,
  }) {
    final actual = _detail;
    if (actual == null) return;
    final lineas = [
      for (final l in actual.lines)
        l.itemId == line.itemId ? l.withCount(value, wasRecount: wasRecount) : l,
    ];
    setState(() {
      _detail = PhysicalCountDetail(
        header: actual.header.withCounters(
          countedLines: lineas.where((l) => l.countedQuantity != null).length,
          pendingRecount: lineas.where((l) => l.recountRequested).length,
        ),
        lines: lineas,
      );
    });
  }

  /// Hoja de conteo para llenar a mano. Si la sesión es a ciegas sale sin
  /// las cantidades del sistema. Respeta los filtros de pantalla, porque su
  /// uso típico es imprimir una sección concreta para repartir el conteo.
  Future<void> _exportCountSheet() async {
    final d = _detail;
    if (d == null) return;
    final h = d.header;
    final lines = _visibleLines(d.lines);
    if (lines.isEmpty) {
      AppToast.info(context, 'No hay items que imprimir con estos filtros.');
      return;
    }
    final showSystem = !h.isBlind;

    final headers = showSystem
        ? const ['Item', 'SKU', 'Unidad', 'Sistema', 'Conteo físico']
        : const ['Item', 'SKU', 'Unidad', 'Conteo físico'];
    final rows = lines
        .map((l) => <String>[
              l.itemName,
              l.itemSku ?? '',
              l.unit,
              if (showSystem) _fmtQty(l.snapshotQuantity),
              '',
            ])
        .toList(growable: false);

    await _emitPdf(
      filename: 'hoja_conteo_${h.code}',
      title: 'Hoja de conteo ${h.code}',
      subtitle: _subtitleFor(h, lines.length),
      headers: headers,
      rows: rows,
      landscape: false,
      numeric: showSystem ? const [3] : const [],
      flex: showSystem
          ? const [4, 1.6, 1.2, 1.4, 2.4]
          : const [4.5, 1.8, 1.2, 2.5],
      summary: const [
        'Contado por: ______________________',
        'Revisado por: _____________________',
      ],
    );
  }

  /// Reporte final: comparación sistema vs conteo con el impacto en costo.
  /// Usa TODAS las líneas de la sesión, no las filtradas en pantalla — es un
  /// documento de cierre y no debe depender de lo que quedó tecleado en el
  /// buscador.
  Future<void> _exportComparison({required bool onlyDifferences}) async {
    final d = _detail;
    if (d == null) return;
    final h = d.header;

    var lines = d.lines;
    if (onlyDifferences) {
      lines = lines.where((l) {
        final v = l.displayVariance;
        return v != null && v.abs() >= 0.0001;
      }).toList(growable: false);
    }
    if (lines.isEmpty) {
      if (!mounted) return;
      AppToast.info(
        context,
        onlyDifferences
            ? 'No hubo diferencias en este conteo.'
            : 'La sesión no tiene items.',
      );
      return;
    }

    final rows = lines.map((l) {
      // Tras completar, la base del ajuste es el stock vivo de ese momento.
      final base = l.stockAtComplete ?? l.snapshotQuantity;
      final diff = l.displayVariance;
      final value = l.displayVarianceValue;
      return <String>[
        l.itemName,
        l.unit,
        _fmtQty(base),
        l.countedQuantity == null ? 'sin contar' : _fmtQty(l.countedQuantity!),
        diff == null ? '' : '${diff > 0 ? '+' : ''}${_fmtQty(diff)}',
        _fmtMoney(l.unitCost ?? l.unitCostCurrent),
        value == null ? '' : _fmtMoney(value),
      ];
    }).toList(growable: false);

    // Los totales se calculan sobre la sesión completa aunque el PDF liste
    // solo las diferencias: si no, el "impacto neto" cambiaría según el filtro.
    final all = d.lines;
    final counted = all.where((l) => l.countedQuantity != null).length;
    final withDiff = all.where((l) {
      final v = l.displayVariance;
      return v != null && v.abs() >= 0.0001;
    }).length;
    final missing = all.fold<double>(
      0,
      (sum, l) {
        final v = l.displayVarianceValue ?? 0;
        return v < 0 ? sum + v : sum;
      },
    );
    final over = all.fold<double>(
      0,
      (sum, l) {
        final v = l.displayVarianceValue ?? 0;
        return v > 0 ? sum + v : sum;
      },
    );

    await _emitPdf(
      filename: 'conteo_${h.code}',
      title: 'Conteo físico ${h.code} — Comparación',
      subtitle: _subtitleFor(h, lines.length),
      headers: const [
        'Item',
        'Unidad',
        'Sistema',
        'Contado',
        'Diferencia',
        'Costo unit.',
        'Valor dif.',
      ],
      rows: rows,
      landscape: true,
      numeric: const [2, 3, 4, 5, 6],
      flex: const [4, 1.2, 1.4, 1.4, 1.4, 1.4, 1.6],
      summary: [
        'Items en sesión: ${all.length}   ·   contados: $counted   ·   '
            'con diferencia: $withDiff',
        'Ajustes aplicados: ${h.adjustmentsCount}',
        'Faltantes: ${_fmtMoney(missing)}',
        'Sobrantes: ${_fmtMoney(over)}',
        'Impacto neto: ${_fmtMoney(missing + over)}',
        '',
        'Contado por: ______________   Revisado por: ______________',
      ],
    );
  }

  String _subtitleFor(PhysicalCountSummary h, int shown) {
    final dateFmt = DateFormat('dd/MM/yyyy HH:mm');
    return [
      h.warehouseName,
      if (h.isBlind) 'Conteo a ciegas',
      if (h.frozenAt != null) 'Congelado ${dateFmt.format(h.frozenAt!)}',
      if (h.completedAt != null) 'Cerrado ${dateFmt.format(h.completedAt!)}',
      '$shown items',
    ].join('  ·  ');
  }

  Future<void> _emitPdf({
    required String filename,
    required String title,
    required String subtitle,
    required List<String> headers,
    required List<ExportRow> rows,
    required bool landscape,
    required List<int> numeric,
    required List<double> flex,
    required List<String> summary,
  }) async {
    try {
      await ReportExporter.exportPdf(
        filename: filename,
        title: title,
        subtitle: subtitle,
        headers: headers,
        rows: rows,
        landscape: landscape,
        columnNumericIndices: numeric,
        columnFlex: flex,
        summaryLines: summary.isEmpty ? null : summary,
      );
    } catch (e) {
      if (!mounted) return;
      AppToast.error(context, 'No se pudo generar el PDF: $e');
    }
  }

  /// Punto de entrada del botón PDF: en sesión cerrada pregunta qué reporte.
  Future<void> _openExport() async {
    final h = _detail?.header;
    if (h == null) return;
    final completada = h.status == PhysicalCountStatus.completed;
    final elegido = await showDialog<_ExportKind>(
      context: context,
      builder: (_) => _ExportChoiceDialog(completada: completada),
    );
    if (elegido == null) return;
    switch (elegido) {
      case _ExportKind.hojaConteo:
        await _exportCountSheet();
      case _ExportKind.soloDiferencias:
        await _exportComparison(onlyDifferences: true);
      case _ExportKind.todos:
        await _exportComparison(onlyDifferences: false);
      case _ExportKind.excel:
        await _exportExcel();
    }
  }

  /// Deja un texto usable como nombre de archivo. La nota del área viene
  /// escrita a mano y trae barras y acentos ("Conteo Foodshop/Rosayra"), que
  /// en Windows rompen el guardado.
  static String _paraNombreDeArchivo(String texto) {
    final limpio = texto
        .replaceAll(RegExp(r'[^A-Za-z0-9áéíóúÁÉÍÓÚñÑ ]'), ' ')
        .replaceAll(RegExp(r'\s+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    if (limpio.isEmpty) return 'area';
    return limpio.length > 40 ? limpio.substring(0, 40) : limpio;
  }

  /// Detalle de la sesión a Excel.
  ///
  /// Es lo que pide un auditor: UNA hoja por sesión con lo que contó esa
  /// área, antes de combinar nada. El PDF sirve para firmar; el .xlsx sirve
  /// para que alguien sume, filtre y cruce por su cuenta.
  ///
  /// Sale la sesión COMPLETA, sin los filtros de pantalla: un respaldo con
  /// filtros aplicados a medias no es un respaldo. Las columnas del sistema
  /// se omiten si la sesión sigue a ciegas y sin revelar, igual que la
  /// pantalla.
  Future<void> _exportExcel() async {
    final d = _detail;
    if (d == null) return;
    final h = d.header;
    final mostrarSistema = !_hideSystem;

    // La identificación viaja en CADA fila, no en un encabezado suelto: con
    // una sesión por área son varios archivos, y sin esto no se distinguen
    // entre sí ni se pueden apilar en una sola hoja sin perder el origen.
    final area = (h.notes ?? '').trim().isEmpty
        ? '(sin nombre de área)'
        : h.notes!.trim();

    final headers = <String>[
      'Sesión',
      'Área',
      'Bodega',
      'Item',
      'SKU',
      'Unidad',
      if (mostrarSistema) 'Sistema',
      'Contado',
      'Estado',
      if (mostrarSistema) ...['Diferencia', 'Costo unit.', 'Valor dif.'],
      'Notas',
    ];

    final rows = <ExportRow>[];
    for (final l in d.lines) {
      final base = l.stockAtComplete ?? l.snapshotQuantity;
      final diff = l.displayVariance;
      final valor = l.displayVarianceValue;
      rows.add(<String>[
        h.code,
        area,
        h.warehouseName,
        l.itemName,
        l.itemSku ?? '',
        l.unit,
        if (mostrarSistema) _fmtQty(base),
        l.countedQuantity == null ? '' : _fmtQty(l.countedQuantity!),
        l.countedQuantity == null ? 'sin contar' : 'contado',
        if (mostrarSistema) ...[
          diff == null ? '' : _fmtQty(diff),
          _fmtQty(l.unitCost ?? l.unitCostCurrent),
          valor == null ? '' : _fmtQty(valor),
        ],
        l.counterNotes ?? '',
      ]);
    }

    // Índices de las columnas que tienen que llegar como NÚMERO. El SKU se
    // queda como texto a propósito: un código numérico pierde los ceros a la
    // izquierda en cuanto Excel lo toma por número.
    //
    // Con las 3 columnas de identificación al frente, el bloque de números
    // arranca en la 6 (Sistema) o en la 7 (Contado) según se muestre el
    // sistema o no.
    final numericas = mostrarSistema
        ? <int>[6, 7, 9]        // Sistema, Contado, Diferencia
        : <int>[6];             // Contado
    final montos = mostrarSistema
        ? <int>[10, 11]         // Costo unit., Valor dif.
        : const <int>[];

    setState(() => _busy = true);
    try {
      final ok = await ReportExporter.exportExcel(
        filename: 'conteo_${h.code}_${_paraNombreDeArchivo(area)}',
        sheetName: h.code,
        headers: headers,
        rows: rows,
        numericColumns: numericas,
        moneyColumns: montos,
      );
      if (!mounted) return;
      AppToast.success(
        context,
        ok
            ? 'Excel de ${h.code} generado (${rows.length} items).'
            : 'No se pudo descargar; el detalle quedó en el portapapeles.',
      );
    } catch (e) {
      if (!mounted) return;
      AppToast.error(context, 'No se pudo generar el Excel: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }


  /// Escanear en el conteo AÍSLA la línea: quien cuenta pasa la pistola por
  /// el anaquel y teclea la cantidad, sin buscar a mano entre cientos de
  /// renglones. No se escribe el número solo — el conteo es justamente el
  /// dato que aporta la persona.
  void _aislarLinea(String itemId, String nombre) {
    if (_dialogOpen) return;
    final lineas = _detail?.lines ?? const [];
    if (!lineas.any((l) => l.itemId == itemId)) {
      // Existe en el catálogo pero no en la sesión: se dio de alta DESPUÉS de
      // congelar. En vez de rebotar al operador, se ofrece sumarlo.
      final ficha = _fichaDe(itemId);
      if (ficha != null && _puedeAgregarALaSesion) {
        unawaited(_ofrecerAgregarExistente(ficha));
        return;
      }
      AppToast.warning(context, '$nombre no está en esta sesión de conteo.');
      return;
    }
    _filtrarPor(nombre);
  }

  /// Deja la lista en un solo renglón y lo dice en el buscador.
  void _filtrarPor(String texto) {
    _searchCtrl.text = texto;
    setState(() => _search = texto);
  }

  /// ¿Se puede sumar mercancía a esta sesión? Hace falta que esté en conteo y
  /// que la persona pueda dar de alta en ALGUNO de los dos catálogos: el
  /// maestro de insumos o el de productos. Son permisos distintos y hay
  /// gente que tiene uno solo.
  bool get _puedeAgregarALaSesion {
    if (_detail?.header.status != PhysicalCountStatus.inProgress) return false;
    final sesion = ref.read(sessionProvider.notifier);
    return sesion.hasPermission('inventario.productos.crear_editar') ||
        sesion.hasPermission('productos.crear');
  }

  /// Rehace el índice del catálogo si cambió la lista o alguna ficha.
  /// Se llama desde `build`: solo cachea datos derivados.
  void _reindexarCatalogo(List<InventoryItemSummary> base) {
    if (identical(base, _catalogoBase)) return;
    _catalogoBase = base;
    if (_itemOverrides.isEmpty) {
      _catalogoParaEscaneo = base;
      _catalogoPorId = {for (final i in base) i.id: i};
      return;
    }
    final porId = <String, InventoryItemSummary>{
      for (final i in base) i.id: _itemOverrides[i.id] ?? i,
    };
    // Las editadas acá que el listado no trae entran igual: son justo las que
    // acaban de recibir código y la pistola tiene que resolver.
    for (final entry in _itemOverrides.entries) {
      porId.putIfAbsent(entry.key, () => entry.value);
    }
    _catalogoPorId = porId;
    _catalogoParaEscaneo = porId.values.toList(growable: false);
  }

  /// La ficha del insumo de una línea, si se conoce. Null = el catálogo del
  /// módulo no la trae todavía (y no se ha editado acá).
  InventoryItemSummary? _fichaDe(String itemId) => _catalogoPorId[itemId];

  /// Editar la ficha del insumo SIN salir del conteo.
  ///
  /// El caso que lo pide: el renglón no tiene código de barras, así que la
  /// pistola no lo encuentra y hay que buscarlo tecleando entre cientos de
  /// líneas. Se abre el MISMO formulario del maestro (Insumos), con el campo
  /// del código enfocado cuando está vacío: se escanea, se guarda y se sigue
  /// contando.
  Future<void> _editarInsumo(PhysicalCountLine line) async {
    if (_dialogOpen || _busy) return;
    final repo = ref.read(inventoryRepositoryProvider);
    final vm = ref.read(inventoryViewModelProvider);

    var ficha = _fichaDe(line.itemId);
    if (ficha == null) {
      // El catálogo del módulo filtra por bodega; el conteo trae TODOS los
      // insumos activos. El que falte se busca por id.
      setState(() => _busy = true);
      try {
        ficha = await repo.getItemById(line.itemId);
      } catch (e) {
        ficha = null;
        if (mounted) {
          AppToast.error(context, 'No se pudo abrir "${line.itemName}": $e');
        }
      } finally {
        if (mounted) setState(() => _busy = false);
      }
      if (!mounted) return;
      if (ficha == null) return;
    }

    final businessId = vm.state.businessId ??
        await resolveBusinessIdOrNull(Supabase.instance.client, 'auto');
    if (!mounted) return;
    if (businessId == null) {
      AppToast.error(context, 'No se pudo resolver el negocio activo.');
      return;
    }

    final sinCodigo = ficha.barcode.trim().isEmpty;
    _dialogOpen = true;
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => ItemFormDialog(
        businessId: businessId,
        repo: repo,
        edit: ficha,
        focusBarcode: sinCodigo,
      ),
    );
    _dialogOpen = false;
    if (saved != true || !mounted) return;

    // Se relee SOLO esa ficha. Recargar el catálogo entero —o la sesión, con
    // sus mil líneas— por un renglón editado apaga la pantalla en medio del
    // conteo y hace perder el scroll.
    InventoryItemSummary? fresca;
    try {
      fresca = await repo.getItemById(line.itemId);
    } catch (_) {
      fresca = null; // Se guardó igual; solo se pierde el refresco en pantalla.
    }
    if (!mounted) return;
    setState(() {
      if (fresca != null) {
        _itemOverrides[line.itemId] = fresca;
        // El renglón muestra el nombre/SKU que la vista trae del maestro: si
        // se renombró el insumo, la lista no puede seguir diciendo lo viejo.
        final actual = _detail;
        if (actual != null &&
            (fresca.name != line.itemName ||
                (fresca.sku.isEmpty ? null : fresca.sku) != line.itemSku)) {
          _detail = PhysicalCountDetail(
            header: actual.header,
            lines: [
              for (final l in actual.lines)
                l.itemId == line.itemId
                    ? l.withItemInfo(
                        name: fresca.name,
                        sku: fresca.sku.isEmpty ? null : fresca.sku,
                      )
                    : l,
            ],
          );
        }
      }
      _catalogoBase = null; // fuerza reindexar con la ficha nueva
    });
    // La pistola resuelve por código de barras o por SKU: se avisa con el que
    // haya quedado cargado, para que quien cuenta sepa que ya puede escanear.
    final codigo = fresca?.barcode.trim() ?? '';
    final sku = fresca?.sku.trim() ?? '';
    final identificador = codigo.isNotEmpty ? codigo : sku;
    AppToast.success(
      context,
      identificador.isEmpty
          ? 'Ficha de "${line.itemName}" actualizada.'
          : '${codigo.isNotEmpty ? 'Código' : 'SKU'} $identificador '
              'guardado: la pistola ya encuentra "${line.itemName}".',
    );
  }

  /// Sin catálogo cargado (o con un insumo que no está en él), se intenta el
  /// SKU de las líneas antes de darse por vencido.
  void _escaneoSinCatalogo(String code) {
    if (_dialogOpen) return;
    final lower = code.toLowerCase();
    final lineas = _detail?.lines ?? const [];
    final hit = lineas
        .where((l) => (l.itemSku ?? '').trim().toLowerCase() == lower);
    if (hit.length == 1) {
      _filtrarPor(hit.first.itemName);
      return;
    }
    if (_puedeAgregarALaSesion) {
      unawaited(_ofrecerAlta(code));
      return;
    }
    AppToast.warning(context, 'Ningún insumo con el código "$code".');
  }

  /// Escaneó algo que no existe: se ofrece darlo de alta con ESE código y
  /// sumarlo al conteo. Es el caso del inventario de arranque, donde media
  /// bodega nunca se cargó al sistema.
  Future<void> _ofrecerAlta(String code) async {
    if (_dialogOpen) return;
    final sesion = ref.read(sessionProvider.notifier);
    final canCrearProducto = sesion.hasPermission('productos.crear');
    final canCrearInsumo =
        sesion.hasPermission('inventario.productos.crear_editar');
    _dialogOpen = true;
    final que = await showDialog<_AltaTipo>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('No encontrado'),
        content: Text(
          'Ningún artículo con el código "$code".\n\n'
          '¿Qué querés dar de alta con ese código y agregar al conteo?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, null),
            child: const Text('Cancelar'),
          ),
          if (canCrearInsumo)
            OutlinedButton(
              onPressed: () => Navigator.pop(ctx, _AltaTipo.insumo),
              child: const Text('Insumo'),
            ),
          if (canCrearProducto)
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: MangoColors.primaryOrange,
              ),
              onPressed: () => Navigator.pop(ctx, _AltaTipo.producto),
              child: const Text('Producto'),
            ),
        ],
      ),
    );
    _dialogOpen = false;
    if (que == null || !mounted) return;
    if (que == _AltaTipo.producto) {
      await _crearProductoNuevo(codigo: code);
    } else {
      await _crearInsumoNuevo(codigo: code);
    }
  }

  /// El insumo existe en el catálogo pero quedó fuera del congelado.
  Future<void> _ofrecerAgregarExistente(InventoryItemSummary item) async {
    if (_dialogOpen) return;
    _dialogOpen = true;
    final agregar = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('No está en esta sesión'),
        content: Text(
          '"${item.name}" existe en el catálogo pero no entró en este conteo '
          '(se dio de alta después de congelar).\n\n'
          '¿Agregarlo a la sesión para contarlo?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: MangoColors.primaryOrange,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Agregar al conteo'),
          ),
        ],
      ),
    );
    _dialogOpen = false;
    if (agregar != true || !mounted) return;
    await _agregarLineaSesion(item);
  }

  /// Da de alta un PRODUCTO de menú (se vende en la caja) y lo suma al
  /// conteo a través del insumo que le crea el tracking de inventario.
  ///
  /// Se abre el mismo diálogo de la pantalla de Productos: precio, categoría,
  /// menú, impuestos y áreas de impresión no se pueden inventar acá.
  Future<void> _crearProductoNuevo({String? codigo}) async {
    if (_dialogOpen || _busy) return;
    final productsVm = ref.read(productsViewModelProvider);
    // El diálogo necesita categorías y menús; el conteo no los carga. Se
    // traen recién ahora, no al abrir la pantalla.
    if (productsVm.categories.isEmpty || productsVm.menus.isEmpty) {
      setState(() => _busy = true);
      try {
        await productsVm.init();
      } catch (e) {
        if (mounted) {
          AppToast.error(context, 'No se pudo cargar el catálogo: $e');
        }
      } finally {
        if (mounted) setState(() => _busy = false);
      }
      if (!mounted) return;
      if (productsVm.categories.isEmpty) {
        AppToast.warning(
          context,
          'No hay categorías de producto todavía. Creá una en Productos.',
        );
        return;
      }
    }

    _dialogOpen = true;
    await showDialog<void>(
      context: context,
      builder: (_) => AddEditProductDialog(
        categories: productsVm.categories,
        menus: productsVm.menus,
        existingPresentations: productsVm.presentationOptions,
        onCreateCategory: (name) => productsVm.createCategory(name: name),
        initialBarcode: codigo,
        // Lo que se da de alta en un conteo es mercancía que hay que contar.
        initialInventoryTracked: true,
        onAdd: ({
          required name,
          required price,
          required categoryId,
          taxMode = 'exclusive',
          sku,
          description,
          menuId,
          cost,
          barcode,
          hasVariants = false,
          isActive = true,
          itemType = 'standard',
          printAreaCode,
          presentation,
          printAreaIds,
          imageFile,
          imageBytes,
          taxIds = const [],
          isInventoryTracked = false,
          initialStock = 0,
          initialStockByWarehouse,
          allowNegativeSale = false,
          baseUnit,
          purchaseUnit,
          packSize,
        }) async {
          // El diálogo NO espera esta llamada: se cierra apenas la dispara.
          // El alta y el alta-en-la-sesión siguen acá, con la pantalla del
          // conteo ya de vuelta al frente.
          try {
            final creado = await productsVm.addProduct(
              name: name,
              price: price,
              categoryId: categoryId,
              taxMode: taxMode,
              sku: sku,
              description: description,
              menuId: menuId,
              cost: cost,
              barcode: barcode,
              hasVariants: hasVariants,
              isActive: isActive,
              itemType: itemType,
              printAreaCode: printAreaCode,
              presentation: presentation,
              printAreaIds: printAreaIds,
              imageFile: imageFile,
              imageBytes: imageBytes,
              taxIds: taxIds,
              isInventoryTracked: isInventoryTracked,
              initialStock: initialStock,
              initialStockByWarehouse: initialStockByWarehouse,
              allowNegativeSale: allowNegativeSale,
              baseUnit: baseUnit,
              purchaseUnit: purchaseUnit,
              packSize: packSize,
            );
            await _sumarProductoAlConteo(creado, name);
          } catch (e) {
            if (mounted) {
              AppToast.error(context, 'No se pudo crear "$name": $e');
            }
          }
        },
        // Nunca se llama: acá siempre se CREA (product == null).
        onUpdate:
            ({
              required id,
              required name,
              required price,
              required categoryId,
              taxMode = 'exclusive',
              sku,
              required isActive,
              description,
              menuId,
              cost,
              barcode,
              hasVariants = false,
              itemType = 'standard',
              printAreaCode,
              presentation,
              printAreaIds,
              imageFile,
              imageBytes,
              taxIds = const [],
              isInventoryTracked,
              initialStock = 0,
              initialStockByWarehouse,
              allowNegativeSale,
            }) {},
      ),
    );
    _dialogOpen = false;
  }

  /// Puente producto → conteo: lo que se cuenta es el INSUMO ligado.
  Future<void> _sumarProductoAlConteo(
    Map<String, dynamic>? creado,
    String nombre,
  ) async {
    if (!mounted) return;
    final productId = creado?['id']?.toString();
    if (productId == null || productId.isEmpty) {
      AppToast.warning(
        context,
        '"$nombre" se creó, pero no se pudo agregar al conteo. Buscalo tras '
        'volver a abrir la sesión.',
      );
      return;
    }
    String? invId;
    try {
      invId = await ref
          .read(productsRepositoryProvider)
          .getLinkedInventoryItemId(productId);
    } catch (_) {
      invId = null;
    }
    if (!mounted) return;
    if (invId == null) {
      // Se creó sin stock propio: no hay insumo que contar.
      AppToast.warning(
        context,
        '"$nombre" se creó como producto, pero sin inventario propio: no '
        'entra en el conteo. Activale "Inventariable" en Productos.',
      );
      return;
    }
    InventoryItemSummary? item;
    try {
      item = await ref.read(inventoryRepositoryProvider).getItemById(invId);
    } catch (_) {
      item = null;
    }
    if (!mounted) return;
    if (item == null) {
      AppToast.warning(
        context,
        '"$nombre" se creó, pero no se pudo leer su insumo para agregarlo al '
        'conteo.',
      );
      return;
    }
    await _agregarLineaSesion(item);
  }

  /// Da de alta un insumo que no existía y lo suma al conteo.
  Future<void> _crearInsumoNuevo({String? codigo}) async {
    if (_dialogOpen || _busy) return;
    final repo = ref.read(inventoryRepositoryProvider);
    final businessId = ref.read(inventoryViewModelProvider).state.businessId ??
        await resolveBusinessIdOrNull(Supabase.instance.client, 'auto');
    if (!mounted) return;
    if (businessId == null) {
      AppToast.error(context, 'No se pudo resolver el negocio activo.');
      return;
    }
    Map<String, dynamic>? creado;
    _dialogOpen = true;
    await showDialog<bool>(
      context: context,
      builder: (_) => ItemFormDialog(
        businessId: businessId,
        repo: repo,
        // El código ya viene puesto; lo que falta escribir es el nombre.
        initialBarcode: codigo,
        onCreated: (row) => creado = row,
      ),
    );
    _dialogOpen = false;
    final row = creado;
    if (row == null || !mounted) return;
    final item = InventoryItemSummary.fromMap(row, stock: 0);
    await _agregarLineaSesion(item);
  }

  /// Suma la línea a la sesión congelada y la deja aislada, lista para
  /// teclear la cantidad.
  ///
  /// La línea se arma en memoria con lo que devuelve el RPC: recargar la
  /// sesión entera —mil renglones— por uno agregado apaga la pantalla en
  /// medio del conteo, igual que pasaba al guardar cada cantidad.
  Future<void> _agregarLineaSesion(InventoryItemSummary item) async {
    final d = _detail;
    if (d == null) return;
    if (d.header.status != PhysicalCountStatus.inProgress) {
      AppToast.info(context, 'La sesión no está en conteo.');
      return;
    }
    if (d.lines.any((l) => l.itemId == item.id)) {
      _filtrarPor(item.name);
      return;
    }
    setState(() => _busy = true);
    try {
      final res = await ref.read(physicalCountRepositoryProvider).addItem(
            sessionId: widget.sessionId,
            itemId: item.id,
          );
      if (!mounted) return;
      final nueva = PhysicalCountLine(
        id: res.lineId,
        itemId: item.id,
        itemName: item.name,
        unit: item.unit,
        snapshotQuantity: res.snapshotQuantity,
        itemSku: item.sku.trim().isEmpty ? null : item.sku.trim(),
        unitCostCurrent: item.cost,
      );
      // Mismo orden que trae la vista (por nombre), para que no aparezca al
      // final de la lista.
      final lineas = [...d.lines, nueva]
        ..sort((a, b) =>
            a.itemName.toLowerCase().compareTo(b.itemName.toLowerCase()));
      _dirty = true;
      setState(() {
        _detail = PhysicalCountDetail(
          header: d.header.withCounters(
            countedLines:
                lineas.where((l) => l.countedQuantity != null).length,
            pendingRecount: lineas.where((l) => l.recountRequested).length,
            linesCount: lineas.length,
          ),
          lines: lineas,
        );
        // La ficha nueva entra al catálogo del escaneo: el próximo disparo de
        // la pistola sobre ese código ya cae en su renglón.
        _itemOverrides[item.id] = item;
        _catalogoBase = null;
      });
      _filtrarPor(item.name);
      AppToast.success(
        context,
        res.alreadyExisted
            ? '"${item.name}" ya estaba en la sesión.'
            : '"${item.name}" agregado al conteo. Escribí la cantidad.',
      );
    } catch (e) {
      if (!mounted) return;
      final texto = e.toString();
      // Sin la migración aplicada el insumo QUEDA CREADO en el maestro: hay
      // que decirlo, o se intenta de nuevo y se duplica la ficha.
      final faltaMigracion = texto.contains('PGRST202') ||
          texto.contains('fn_physical_count_add_item');
      AppToast.error(
        context,
        faltaMigracion
            ? '"${item.name}" quedó creado en Insumos, pero falta aplicar la '
                'migración 20260902_0004 para sumarlo a este conteo.'
            : 'No se pudo agregar "${item.name}" a la sesión: $e',
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  List<PhysicalCountLine> _visibleLines(List<PhysicalCountLine> lines) {
    final counting = _detail?.header.status == PhysicalCountStatus.inProgress;
    var out = lines;
    if (_search.trim().isNotEmpty) {
      final q = _search.trim().toLowerCase();
      out = out
          .where((l) =>
              l.itemName.toLowerCase().contains(q) ||
              (l.itemSku ?? '').toLowerCase().contains(q))
          .toList(growable: false);
    }
    if (_onlyPending && counting) {
      out = out
          .where((l) => l.countedQuantity == null || l.recountRequested)
          .toList(growable: false);
    }
    if (_onlyDifferences) {
      out = out.where((l) {
        final v = l.displayVariance;
        return v != null && v.abs() >= 0.0001;
      }).toList(growable: false);
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final sessionCtrl = ref.read(sessionProvider.notifier);
    final canCreate = sessionCtrl.hasPermission('inventario.conteo.crear');
    final canComplete =
        sessionCtrl.hasPermission('inventario.conteo.completar');
    final canCancel = sessionCtrl.hasPermission('inventario.conteo.anular');
    // El maestro de insumos va bajo su propio permiso: quien cuenta en el
    // piso no necesariamente puede tocar la ficha.
    final canEditItems = sessionCtrl.hasPermission(
      'inventario.productos.crear_editar',
    );
    // Alta de producto de menú: es el permiso de Productos, no el de
    // inventario. Son dos catálogos distintos.
    final canCreateProducts = sessionCtrl.hasPermission('productos.crear');

    // El catálogo del módulo trae los códigos de barras; las líneas del
    // conteo no. Si todavía no está cargado, el escaneo cae al SKU de la
    // propia línea, que cubre al negocio que etiqueta por SKU.
    final catalogo = ref.watch(inventoryViewModelProvider).state.items;
    _reindexarCatalogo(catalogo);

    return InventoryScanListener(
      enabled: !_loading && !_busy,
      items: _catalogoParaEscaneo,
      onItem: (item) => _aislarLinea(item.id, item.name),
      onUnresolved: _escaneoSinCatalogo,
      child: PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        Navigator.of(context).pop(_dirty);
      },
      child: Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(
          title: Text(_detail?.header.code ?? 'Conteo físico'),
          backgroundColor: Colors.white,
          foregroundColor: MangoColors.darkGray,
          elevation: 0,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.of(context).pop(_dirty),
          ),
          actions: [
            // Las líneas pueden crecer POR FUERA de esta pantalla: otra
            // terminal contando, o insumos dados de alta durante el conteo
            // (activar "Inventariable" en Productos crea uno por producto).
            // Sin esto había que salir y volver a entrar para verlos.
            IconButton(
              tooltip: 'Recargar sesión',
              icon: const Icon(Icons.refresh_rounded),
              onPressed: _busy || _loading ? null : _recargar,
            ),
            if (_detail != null &&
                _detail!.header.status != PhysicalCountStatus.draft)
              IconButton(
                tooltip: 'Hoja de conteo (PDF)',
                icon: const Icon(Icons.picture_as_pdf_outlined),
                onPressed: _busy ? null : _openExport,
              ),
          ],
        ),
        body: _loading
            ? const Center(
                child: CircularProgressIndicator(
                  valueColor:
                      AlwaysStoppedAnimation(MangoColors.primaryOrange),
                ),
              )
            : _error != null
                ? Center(child: Text(_error!))
                : _buildContent(
                    canCreate,
                    canComplete,
                    canCancel,
                    canEditItems,
                    canCreateProducts,
                  ),
      ),
      ),
    );
  }

  Widget _buildContent(
    bool canCreate,
    bool canComplete,
    bool canCancel,
    bool canEditItems,
    bool canCreateProducts,
  ) {
    final d = _detail!;
    final h = d.header;
    final canActOnDraft = h.status == PhysicalCountStatus.draft;
    final canActOnInProgress = h.status == PhysicalCountStatus.inProgress;
    final visible = _visibleLines(d.lines);

    final showLines = !(canActOnDraft && d.lines.isEmpty);
    final editable = canActOnInProgress;

    // CustomScrollView y no SingleChildScrollView: una sesión incluye todos
    // los insumos activos del negocio, y cada fila lleva su propio TextField.
    // Con slivers las filas se construyen solo cuando entran en pantalla.
    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
          sliver: SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _HeaderCard(header: h, lines: d.lines),
                const SizedBox(height: 16),
                if (!showLines) const _EmptyDraftHint(),
              ],
            ),
          ),
        ),
        if (showLines) ...[
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            sliver: SliverToBoxAdapter(
              child: _LinesCardTop(
                header: h,
                editable: editable,
                hideSystem: _hideSystem,
                revealed: _revealed,
                canReveal: canComplete && h.isBlind && canActOnInProgress,
                onToggleReveal: () => setState(() => _revealed = !_revealed),
                onlyPending: _onlyPending,
                onTogglePending: (v) => setState(() => _onlyPending = v),
                onlyDifferences: _onlyDifferences,
                onToggleDifferences: (v) =>
                    setState(() => _onlyDifferences = v),
                searchCtrl: _searchCtrl,
                onSearch: (v) => setState(() => _search = v),
                onAddItem: canActOnInProgress && canEditItems
                    ? () => _crearInsumoNuevo()
                    : null,
                onAddProduct:
                    canActOnInProgress && canCreateProducts
                        ? () => _crearProductoNuevo()
                        : null,
                selectionMode: _selectionMode && canActOnInProgress,
              ),
            ),
          ),
          if (visible.isEmpty)
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              sliver: SliverToBoxAdapter(
                child: _CardSlice(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Center(
                      child: Text(
                        d.lines.isEmpty
                            ? 'Sin items en esta sesión'
                            : 'Ningún item coincide con los filtros',
                        style: const TextStyle(color: MangoColors.muted),
                      ),
                    ),
                  ),
                ),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              sliver: SliverList.builder(
                itemCount: visible.length,
                itemBuilder: (context, i) {
                  final l = visible[i];
                  return _CardSlice(
                    child: _LineRow(
                      key: ValueKey(l.id),
                      line: l,
                      item: _fichaDe(l.itemId),
                      onEdit: canEditItems
                          ? () => _editarInsumo(l)
                          : null,
                      editable: editable,
                      hideSystem: _hideSystem,
                      selectionMode: _selectionMode && canActOnInProgress,
                      isSelected: _selected.contains(l.itemId),
                      onToggleSelected: (itemId) => setState(() {
                        if (!_selected.remove(itemId)) _selected.add(itemId);
                      }),
                      onSave: canActOnInProgress ? _saveLine : null,
                    ),
                  );
                },
              ),
            ),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            sliver: const SliverToBoxAdapter(child: _LinesCardBottom()),
          ),
        ],
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
          sliver: SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_selectionMode && canActOnInProgress) ...[
                  _RecountBar(
                    count: _selected.length,
                    busy: _busy,
                    onCancel: () => setState(() {
                      _selectionMode = false;
                      _selected.clear();
                    }),
                    onConfirm: _selected.isEmpty ? null : _requestRecount,
                  ),
                  const SizedBox(height: 12),
                ],
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (canActOnDraft && canCreate)
                      FilledButton.icon(
                        onPressed: _busy ? null : _freeze,
                        style: FilledButton.styleFrom(
                          backgroundColor: MangoColors.primaryOrange,
                        ),
                        icon: const Icon(Icons.ac_unit_rounded),
                        label: const Text('Congelar inventario'),
                      ),
                    if (canActOnInProgress && canComplete) ...[
                      FilledButton.icon(
                        onPressed: _busy ? null : _openComplete,
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFF059669),
                        ),
                        icon: const Icon(Icons.check_circle_outline),
                        label: const Text('Completar conteo'),
                      ),
                      if (!_selectionMode)
                        OutlinedButton.icon(
                          onPressed: _busy
                              ? null
                              : () => setState(() => _selectionMode = true),
                          icon: const Icon(Icons.replay_rounded, size: 18),
                          label: const Text('Marcar recuento'),
                        ),
                      // Solo aparece si hay algo sin contar: es la pieza que
                      // convierte el conteo en un reemplazo del inventario.
                      if (!_selectionMode && _pendientesSinContar > 0)
                        OutlinedButton.icon(
                          onPressed: _busy ? null : _ponerEnCeroPendientes,
                          icon: const Icon(
                            Icons.exposure_zero_rounded,
                            size: 18,
                          ),
                          label: Text(
                            'Poner en cero lo no contado '
                            '($_pendientesSinContar)',
                          ),
                        ),
                    ],
                    if (h.status == PhysicalCountStatus.completed)
                      FilledButton.icon(
                        onPressed: _busy ? null : _openExport,
                        style: FilledButton.styleFrom(
                          backgroundColor: MangoColors.primaryOrange,
                        ),
                        icon: const Icon(Icons.picture_as_pdf_outlined),
                        label: const Text('Reporte de comparación'),
                      ),
                    if (canActOnInProgress)
                      OutlinedButton.icon(
                        onPressed: _busy ? null : _exportCountSheet,
                        icon: const Icon(Icons.print_outlined, size: 18),
                        label: const Text('Hoja de conteo'),
                      ),
                    if ((canActOnDraft || canActOnInProgress) && canCancel)
                      TextButton.icon(
                        onPressed: _busy ? null : _openCancel,
                        style: TextButton.styleFrom(
                          foregroundColor: const Color(0xFFDC2626),
                        ),
                        icon: const Icon(Icons.cancel_outlined),
                        label: const Text('Cancelar sesión'),
                      ),
                  ],
                ),
                if (visible.length != d.lines.length) ...[
                  const SizedBox(height: 12),
                  Text(
                    'Mostrando ${visible.length} de ${d.lines.length} items '
                    '(hay filtros activos).',
                    style: const TextStyle(
                        fontSize: 11, color: MangoColors.muted),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// =============================================================================
// Header
// =============================================================================

class _HeaderCard extends StatelessWidget {
  final PhysicalCountSummary header;
  final List<PhysicalCountLine> lines;
  const _HeaderCard({required this.header, required this.lines});

  @override
  Widget build(BuildContext context) {
    final dateFormat = DateFormat('dd MMM yyyy HH:mm');
    final progress = header.linesCount == 0
        ? 0.0
        : header.countedLines / header.linesCount;
    final completed = header.status == PhysicalCountStatus.completed;
    final movedDuringCount = lines.where((l) => l.movedDuringCount).length;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: _statusColor(header.status).withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  header.status.label,
                  style: TextStyle(
                    color: _statusColor(header.status),
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                ),
              ),
              if (header.isBlind) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1F2937).withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.visibility_off_outlined,
                          size: 13, color: Color(0xFF374151)),
                      SizedBox(width: 5),
                      Text(
                        'A ciegas',
                        style: TextStyle(
                          color: Color(0xFF374151),
                          fontWeight: FontWeight.w700,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const Spacer(),
              Text(
                header.code,
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 13,
                  letterSpacing: 0.3,
                  color: MangoColors.muted,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            header.warehouseName,
            style: const TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w800,
              color: MangoColors.darkGray,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 24,
            runSpacing: 8,
            children: [
              _Metric(
                label: 'Items en sesión',
                value: header.linesCount.toString(),
              ),
              _Metric(
                label: 'Items contados',
                value: '${header.countedLines} / ${header.linesCount}',
                highlight: header.status == PhysicalCountStatus.inProgress,
              ),
              if (header.pendingRecount > 0)
                _Metric(
                  label: 'Por recontar',
                  value: header.pendingRecount.toString(),
                  color: const Color(0xFFD97706),
                ),
              if (completed) ...[
                _Metric(
                  label: 'Ajustes aplicados',
                  value: header.adjustmentsCount.toString(),
                  highlight: true,
                ),
                _Metric(
                  label: 'Faltantes',
                  value: _fmtMoney(header.shrinkageValue),
                  color: const Color(0xFFDC2626),
                ),
                _Metric(
                  label: 'Impacto neto',
                  value: _fmtMoney(header.varianceValueTotal),
                  color: header.varianceValueTotal < 0
                      ? const Color(0xFFDC2626)
                      : const Color(0xFF059669),
                ),
              ],
            ],
          ),
          if (header.status == PhysicalCountStatus.inProgress &&
              header.linesCount > 0) ...[
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                minHeight: 6,
                value: progress.clamp(0.0, 1.0),
                backgroundColor: const Color(0xFFF1F5F9),
                valueColor: const AlwaysStoppedAnimation(
                  MangoColors.primaryOrange,
                ),
              ),
            ),
          ],
          if (completed && movedDuringCount > 0) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFFEFF6FF),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFFBFDBFE)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.info_outline,
                      size: 16, color: Color(0xFF1D4ED8)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '$movedDuringCount item(s) tuvieron movimientos '
                      '(ventas, transferencias) entre congelar y completar. '
                      'El ajuste se calculó contra el stock del momento del '
                      'cierre, así que el inventario quedó en lo contado.',
                      style: const TextStyle(
                          fontSize: 11, color: Color(0xFF1E3A8A)),
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 16),
          const Divider(height: 1),
          const SizedBox(height: 12),
          _TimestampRow(
            label: 'Creada',
            timestamp: dateFormat.format(header.startedAt),
          ),
          if (header.frozenAt != null)
            _TimestampRow(
              label: 'Congelada',
              timestamp: dateFormat.format(header.frozenAt!),
            ),
          if (header.completedAt != null)
            _TimestampRow(
              label: 'Completada',
              timestamp: dateFormat.format(header.completedAt!),
            ),
          if (header.cancelledAt != null)
            _TimestampRow(
              label: 'Cancelada',
              timestamp: dateFormat.format(header.cancelledAt!),
            ),
          if (header.notes != null && header.notes!.isNotEmpty) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFFF8FAFC),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                header.notes!,
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ],
          if (header.cancellationReason != null &&
              header.cancellationReason!.isNotEmpty) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFFFEF2F2),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFFFCA5A5)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.cancel_outlined,
                      size: 16, color: Color(0xFFDC2626)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Razón: ${header.cancellationReason!}',
                      style: const TextStyle(
                          fontSize: 12, color: Color(0xFF991B1B)),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  final String label;
  final String value;
  final bool highlight;
  final Color? color;
  const _Metric({
    required this.label,
    required this.value,
    this.highlight = false,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w700,
            color: MangoColors.muted,
            letterSpacing: 0.4,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            color: color ??
                (highlight
                    ? MangoColors.primaryOrange
                    : MangoColors.darkGray),
          ),
        ),
      ],
    );
  }
}

class _TimestampRow extends StatelessWidget {
  final String label;
  final String timestamp;
  const _TimestampRow({required this.label, required this.timestamp});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 100,
            child: Text(
              label,
              style: const TextStyle(
                  fontSize: 11, color: MangoColors.muted),
            ),
          ),
          Text(
            timestamp,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: MangoColors.darkGray,
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyDraftHint extends StatelessWidget {
  const _EmptyDraftHint();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF7ED),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFFED7AA)),
      ),
      child: const Row(
        children: [
          Icon(Icons.ac_unit_rounded,
              size: 28, color: MangoColors.primaryOrange),
          SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Sesión en borrador',
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    color: MangoColors.darkGray,
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  'Aún no has congelado el stock. Cuando estés listo, '
                  'congela el inventario para tomar el snapshot por '
                  'item y empezar el conteo.',
                  style: TextStyle(
                      fontSize: 12, color: MangoColors.darkGray),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Barra de recuento
// =============================================================================

class _RecountBar extends StatelessWidget {
  final int count;
  final bool busy;
  final VoidCallback onCancel;
  final VoidCallback? onConfirm;
  const _RecountBar({
    required this.count,
    required this.busy,
    required this.onCancel,
    required this.onConfirm,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFFFFFBEB),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFFDE68A)),
      ),
      child: Row(
        children: [
          const Icon(Icons.replay_rounded,
              size: 18, color: Color(0xFFD97706)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              count == 0
                  ? 'Selecciona los items que quieres recontar antes de '
                      'aplicar los ajustes.'
                  : '$count item(s) seleccionados para 2ª vuelta.',
              style: const TextStyle(
                  fontSize: 12, color: Color(0xFF92400E)),
            ),
          ),
          TextButton(
            onPressed: busy ? null : onCancel,
            child: const Text('Salir'),
          ),
          const SizedBox(width: 4),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFD97706),
            ),
            onPressed: busy ? null : onConfirm,
            child: const Text('Marcar para recuento'),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Líneas
// =============================================================================

/// Parte superior de la tarjeta de líneas: título, búsqueda, filtros,
/// aviso de modo ciego y encabezado de columnas.
class _LinesCardTop extends StatelessWidget {
  final PhysicalCountSummary header;
  final bool editable;
  final bool hideSystem;
  final bool revealed;
  final bool canReveal;
  final VoidCallback onToggleReveal;
  final bool onlyPending;
  final ValueChanged<bool> onTogglePending;
  final bool onlyDifferences;
  final ValueChanged<bool> onToggleDifferences;
  final ValueChanged<String> onSearch;

  /// El texto lo maneja el padre: al escanear (o al dar de alta un insumo) la
  /// lista se filtra sola y el campo tiene que mostrarlo.
  final TextEditingController searchCtrl;

  /// Da de alta un insumo que no está en el conteo. Null = sesión cerrada o
  /// sin permiso sobre el maestro.
  final VoidCallback? onAddItem;

  /// Da de alta un producto de menú inventariable. Null = sesión cerrada o
  /// sin permiso de Productos.
  final VoidCallback? onAddProduct;
  final bool selectionMode;

  const _LinesCardTop({
    required this.header,
    required this.editable,
    required this.hideSystem,
    required this.revealed,
    required this.canReveal,
    required this.onToggleReveal,
    required this.onlyPending,
    required this.onTogglePending,
    required this.onlyDifferences,
    required this.onToggleDifferences,
    required this.onSearch,
    required this.searchCtrl,
    required this.onAddItem,
    required this.onAddProduct,
    required this.selectionMode,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(14)),
        border: Border(
          top: BorderSide(color: Color(0xFFE5E7EB)),
          left: BorderSide(color: Color(0xFFE5E7EB)),
          right: BorderSide(color: Color(0xFFE5E7EB)),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Text(
                      'Items a contar',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                        color: MangoColors.darkGray,
                      ),
                    ),
                    const Spacer(),
                    if (onAddItem != null || onAddProduct != null)
                      _AddMenuButton(
                        onAddProduct: onAddProduct,
                        onAddItem: onAddItem,
                      ),
                    if (canReveal)
                      TextButton.icon(
                        onPressed: onToggleReveal,
                        icon: Icon(
                          revealed
                              ? Icons.visibility_off_outlined
                              : Icons.visibility_outlined,
                          size: 16,
                        ),
                        label: Text(
                          revealed ? 'Ocultar sistema' : 'Ver diferencias',
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: searchCtrl,
                  onChanged: onSearch,
                  decoration: const InputDecoration(
                    isDense: true,
                    hintText: 'Buscar item o SKU…',
                    prefixIcon: Icon(Icons.search, size: 18),
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (editable)
                      FilterChip(
                        selected: onlyPending,
                        onSelected: onTogglePending,
                        label: const Text('Solo pendientes'),
                        labelStyle: const TextStyle(fontSize: 12),
                        selectedColor:
                            MangoColors.primaryOrange.withValues(alpha: 0.18),
                        checkmarkColor: MangoColors.primaryOrange,
                      ),
                    if (!hideSystem)
                      FilterChip(
                        selected: onlyDifferences,
                        onSelected: onToggleDifferences,
                        label: const Text('Solo diferencias'),
                        labelStyle: const TextStyle(fontSize: 12),
                        selectedColor:
                            const Color(0xFFDC2626).withValues(alpha: 0.14),
                        checkmarkColor: const Color(0xFFDC2626),
                      ),
                  ],
                ),
              ],
            ),
          ),
          if (hideSystem)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(
                horizontal: 20,
                vertical: 10,
              ),
              color: const Color(0xFFF3F4F6),
              child: const Row(
                children: [
                  Icon(Icons.visibility_off_outlined,
                      size: 15, color: Color(0xFF4B5563)),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Conteo a ciegas: el stock del sistema y las '
                      'diferencias están ocultos. Se revelan al completar.',
                      style: TextStyle(
                          fontSize: 11, color: Color(0xFF4B5563)),
                    ),
                  ),
                ],
              ),
            ),
          _LinesHeaderRow(
            hideSystem: hideSystem,
            selectionMode: selectionMode,
          ),
        ],
      ),
    );
  }
}

/// Cada fila de la lista va envuelta aquí para que los bordes laterales de
/// la tarjeta sigan siendo continuos aunque las filas vivan en un SliverList.
class _CardSlice extends StatelessWidget {
  final Widget child;
  const _CardSlice({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(
          left: BorderSide(color: Color(0xFFE5E7EB)),
          right: BorderSide(color: Color(0xFFE5E7EB)),
        ),
      ),
      child: child,
    );
  }
}

/// Cierre inferior de la tarjeta de líneas.
class _LinesCardBottom extends StatelessWidget {
  const _LinesCardBottom();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 12,
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(bottom: Radius.circular(14)),
        border: Border(
          left: BorderSide(color: Color(0xFFE5E7EB)),
          right: BorderSide(color: Color(0xFFE5E7EB)),
          bottom: BorderSide(color: Color(0xFFE5E7EB)),
        ),
      ),
    );
  }
}



class _LinesHeaderRow extends StatelessWidget {
  final bool hideSystem;
  final bool selectionMode;
  const _LinesHeaderRow({
    required this.hideSystem,
    required this.selectionMode,
  });

  @override
  Widget build(BuildContext context) {
    const style = TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w700,
      color: MangoColors.muted,
    );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      decoration: const BoxDecoration(
        color: Color(0xFFF8FAFC),
        border: Border(
          top: BorderSide(color: Color(0xFFE5E7EB)),
          bottom: BorderSide(color: Color(0xFFE5E7EB)),
        ),
      ),
      child: Row(
        children: [
          if (selectionMode) const SizedBox(width: 40),
          const Expanded(flex: 5, child: Text('Item', style: style)),
          if (!hideSystem)
            const Expanded(
              flex: 2,
              child: Text('Sistema', textAlign: TextAlign.end, style: style),
            ),
          const Expanded(
            flex: 3,
            child: Text('Contado', textAlign: TextAlign.end, style: style),
          ),
          if (!hideSystem) ...[
            const Expanded(
              flex: 2,
              child:
                  Text('Diferencia', textAlign: TextAlign.end, style: style),
            ),
            const Expanded(
              flex: 2,
              child: Text('Valor', textAlign: TextAlign.end, style: style),
            ),
          ],
        ],
      ),
    );
  }
}

class _LineRow extends StatefulWidget {
  final PhysicalCountLine line;

  /// Ficha del insumo, cuando se conoce. Solo se usa para saber si ya tiene
  /// código de barras: la línea del conteo no lo trae.
  final InventoryItemSummary? item;

  /// Abre la ficha del insumo. Null = sin permiso para editar el maestro.
  final VoidCallback? onEdit;
  final bool editable;
  final bool hideSystem;
  final bool selectionMode;
  final bool isSelected;
  final ValueChanged<String> onToggleSelected;
  final Future<void> Function(PhysicalCountLine, double)? onSave;
  const _LineRow({
    super.key,
    required this.line,
    required this.item,
    required this.onEdit,
    required this.editable,
    required this.hideSystem,
    required this.selectionMode,
    required this.isSelected,
    required this.onToggleSelected,
    required this.onSave,
  });

  @override
  State<_LineRow> createState() => _LineRowState();
}

class _LineRowState extends State<_LineRow> {
  late TextEditingController _ctrl;
  late FocusNode _focus;
  bool _saving = false;

  /// Una línea marcada para recuento se presenta vacía: quien recuenta no
  /// debe anclarse en su primer número.
  String _initialText() {
    if (widget.line.recountRequested) return '';
    return widget.line.countedQuantity == null
        ? ''
        : _fmtQty(widget.line.countedQuantity!);
  }

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: _initialText());
    _focus = FocusNode();
    _focus.addListener(_onFocusChange);
  }

  @override
  void didUpdateWidget(covariant _LineRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Si llega un valor nuevo desde backend y no estamos editando, sincronizar.
    if (!_focus.hasFocus &&
        (oldWidget.line.countedQuantity != widget.line.countedQuantity ||
            oldWidget.line.recountRequested !=
                widget.line.recountRequested)) {
      _ctrl.text = _initialText();
    }
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocusChange);
    _focus.dispose();
    _ctrl.dispose();
    super.dispose();
  }

  void _onFocusChange() {
    if (!_focus.hasFocus) {
      _maybeSave();
    }
  }

  Future<void> _maybeSave() async {
    final raw = _ctrl.text.replaceAll(',', '.').trim();
    if (raw.isEmpty) return;
    final v = double.tryParse(raw);
    if (v == null || v < 0) {
      AppToast.info(
        context,
        'Cantidad inválida en "${widget.line.itemName}".',
      );
      return;
    }
    // Un recuento se guarda aunque repita el mismo número: así se limpia
    // la marca de 2ª vuelta.
    if (!widget.line.recountRequested &&
        widget.line.countedQuantity != null &&
        (widget.line.countedQuantity! - v).abs() < 0.0001) {
      return;
    }
    setState(() => _saving = true);
    try {
      await widget.onSave?.call(widget.line, v);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final line = widget.line;
    final variance = line.displayVariance;
    final value = line.displayVarianceValue;
    final flagged = line.recountRequested;

    return Container(
      color: flagged ? const Color(0xFFFFFBEB) : null,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      child: Row(
        children: [
          if (widget.selectionMode)
            SizedBox(
              width: 40,
              child: Checkbox(
                value: widget.isSelected,
                activeColor: const Color(0xFFD97706),
                onChanged: line.countedQuantity == null
                    ? null
                    : (_) => widget.onToggleSelected(line.itemId),
              ),
            ),
          Expanded(
            flex: 5,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        line.itemName,
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          color: MangoColors.darkGray,
                        ),
                      ),
                    ),
                    if (flagged) ...[
                      const SizedBox(width: 6),
                      const _Pill(
                        text: 'Recontar',
                        color: Color(0xFFD97706),
                      ),
                    ] else if (line.wasRecounted) ...[
                      const SizedBox(width: 6),
                      const _Pill(
                        text: '2ª vuelta',
                        color: Color(0xFF6B7280),
                      ),
                    ],
                    if (widget.onEdit != null) ...[
                      const SizedBox(width: 2),
                      _EditItemButton(
                        // Sin ficha cargada no se puede afirmar que falte el
                        // código: se muestra el botón neutro.
                        missingCode: widget.item != null &&
                            widget.item!.barcode.trim().isEmpty &&
                            widget.item!.sku.trim().isEmpty,
                        onPressed: widget.onEdit!,
                      ),
                    ],
                  ],
                ),
                if (line.wasRecounted && !widget.hideSystem)
                  Text(
                    '1er conteo: ${_fmtQty(line.firstCountQuantity!)} '
                    '${line.unit}',
                    style: const TextStyle(
                      fontSize: 11,
                      color: MangoColors.muted,
                    ),
                  ),
                if (line.counterNotes != null &&
                    line.counterNotes!.isNotEmpty)
                  Text(
                    line.counterNotes!,
                    style: const TextStyle(
                      fontSize: 11,
                      color: MangoColors.muted,
                    ),
                  ),
              ],
            ),
          ),
          if (!widget.hideSystem)
            Expanded(
              flex: 2,
              child: Text(
                '${_fmtQty(line.stockAtComplete ?? line.snapshotQuantity)} '
                '${line.unit}',
                textAlign: TextAlign.end,
                style: const TextStyle(color: MangoColors.muted),
              ),
            ),
          Expanded(
            flex: 3,
            child: widget.editable
                ? Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: TextField(
                      controller: _ctrl,
                      focusNode: _focus,
                      textAlign: TextAlign.end,
                      enabled: !_saving,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      onSubmitted: (_) => _maybeSave(),
                      decoration: InputDecoration(
                        isDense: true,
                        border: const OutlineInputBorder(),
                        suffixText: line.unit,
                        hintText: flagged ? 'recontar' : '—',
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 8,
                        ),
                        suffixIcon: _saving
                            ? const Padding(
                                padding: EdgeInsets.all(8),
                                child: SizedBox(
                                  width: 12,
                                  height: 12,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                ),
                              )
                            : null,
                      ),
                    ),
                  )
                : Text(
                    line.countedQuantity == null
                        ? '—'
                        : '${_fmtQty(line.countedQuantity!)} ${line.unit}',
                    textAlign: TextAlign.end,
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: line.countedQuantity == null
                          ? MangoColors.muted
                          : MangoColors.darkGray,
                    ),
                  ),
          ),
          if (!widget.hideSystem) ...[
            Expanded(
              flex: 2,
              child: Text(
                variance == null
                    ? '—'
                    : '${variance > 0 ? '+' : ''}${_fmtQty(variance)} '
                        '${line.unit}',
                textAlign: TextAlign.end,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: _varianceColor(variance),
                ),
              ),
            ),
            Expanded(
              flex: 2,
              child: Text(
                value == null || value.abs() < 0.005
                    ? '—'
                    : _fmtMoney(value),
                textAlign: TextAlign.end,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                  color: _varianceColor(value),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Qué se da de alta cuando el código escaneado no existe.
enum _AltaTipo { producto, insumo }

/// Menú «Agregar» de la barra de líneas. Un solo botón con las dos altas:
/// producto (se vende y se cuenta) e insumo (solo inventario). Van juntas
/// porque quien está contando no siempre sabe cuál de las dos es, y en la
/// barra no hay lugar para dos botones más.
class _AddMenuButton extends StatelessWidget {
  final VoidCallback? onAddProduct;
  final VoidCallback? onAddItem;
  const _AddMenuButton({
    required this.onAddProduct,
    required this.onAddItem,
  });

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<_AltaTipo>(
      tooltip: 'Agregar algo que no está en el conteo',
      position: PopupMenuPosition.under,
      onSelected: (tipo) {
        if (tipo == _AltaTipo.producto) {
          onAddProduct?.call();
        } else {
          onAddItem?.call();
        }
      },
      itemBuilder: (context) => [
        if (onAddProduct != null)
          const PopupMenuItem(
            value: _AltaTipo.producto,
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.sell_outlined, size: 18),
              title: Text('Agregar producto'),
              subtitle: Text(
                'Se vende en la caja y se cuenta',
                style: TextStyle(fontSize: 11),
              ),
            ),
          ),
        if (onAddItem != null)
          const PopupMenuItem(
            value: _AltaTipo.insumo,
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.inventory_2_outlined, size: 18),
              title: Text('Agregar insumo'),
              subtitle: Text(
                'Solo inventario, no se vende',
                style: TextStyle(fontSize: 11),
              ),
            ),
          ),
      ],
      child: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.add_rounded, size: 18, color: MangoColors.primaryOrange),
            SizedBox(width: 4),
            Text(
              'Agregar',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: MangoColors.primaryOrange,
              ),
            ),
            Icon(Icons.arrow_drop_down, size: 18,
                color: MangoColors.primaryOrange),
          ],
        ),
      ),
    );
  }
}

/// Botón «Modificar» del renglón: abre la ficha del insumo sin salir del
/// conteo. Cambia de cara cuando el insumo NO TIENE con qué ser escaneado —es
/// el motivo por el que se entra: agregarle el código y que la pistola lo
/// encuentre en el próximo renglón.
///
/// El aviso mira código de barras Y SKU: `resolveScannedItem` resuelve por
/// cualquiera de los dos (código exacto primero, SKU exacto después), así que
/// un insumo etiquetado por SKU ya es escaneable y no hay nada que corregir.
class _EditItemButton extends StatelessWidget {
  final bool missingCode;
  final VoidCallback onPressed;
  const _EditItemButton({
    required this.missingCode,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: onPressed,
      icon: Icon(
        missingCode ? Icons.qr_code_scanner_rounded : Icons.edit_outlined,
        size: 18,
        color: missingCode
            ? const Color(0xFFD97706)
            : MangoColors.muted,
      ),
      tooltip: missingCode
          ? 'Sin código de barras ni SKU — editar ficha para agregarlo'
          : 'Editar ficha del insumo',
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
      // Blanco de toque usable con el dedo en tablet, sin engordar la fila.
      constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
      splashRadius: 18,
    );
  }
}

class _Pill extends StatelessWidget {
  final String text;
  final Color color;
  const _Pill({required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }
}

// =============================================================================
// Diálogo de completar conteo
// =============================================================================

class _CompleteConfirmDialog extends StatelessWidget {
  final int pending;
  final int pendingRecount;
  final List<PhysicalCountLine> adjustments;
  const _CompleteConfirmDialog({
    required this.pending,
    required this.pendingRecount,
    required this.adjustments,
  });

  @override
  Widget build(BuildContext context) {
    final netValue = adjustments.fold<double>(
      0,
      (sum, l) => sum + (l.displayVarianceValue ?? 0),
    );

    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 600),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Completar conteo físico',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                'El inventario quedará exactamente en las cantidades que '
                'contaste: el ajuste se calcula contra el stock del momento '
                'de cerrar, así que las ventas ocurridas durante el conteo '
                'no lo desfasan. Los items sin contar no se tocan.',
                style: TextStyle(fontSize: 12, color: MangoColors.muted),
              ),
              if (pendingRecount > 0) ...[
                const SizedBox(height: 12),
                _Warning(
                  color: const Color(0xFFD97706),
                  background: const Color(0xFFFFFBEB),
                  border: const Color(0xFFFDE68A),
                  text: 'Hay $pendingRecount item(s) marcados para recuento '
                      'que todavía no se han vuelto a contar. Si continúas, '
                      'se usará el conteo original.',
                ),
              ],
              if (pending > 0) ...[
                const SizedBox(height: 12),
                _Warning(
                  color: const Color(0xFFD97706),
                  background: const Color(0xFFFFFBEB),
                  border: const Color(0xFFFDE68A),
                  text: 'Hay $pending item(s) sin contar. Si continúas, esos '
                      'items no generarán ajustes y se quedarán con el '
                      'stock actual.',
                ),
              ],
              const SizedBox(height: 16),
              Row(
                children: [
                  Text(
                    adjustments.isEmpty
                        ? 'Sin diferencias — no se generarán ajustes.'
                        : 'Diferencias detectadas (${adjustments.length})',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: MangoColors.muted,
                    ),
                  ),
                  const Spacer(),
                  if (adjustments.isNotEmpty)
                    Text(
                      'Impacto ${_fmtMoney(netValue)}',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        color: _varianceColor(netValue),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              if (adjustments.isNotEmpty)
                Flexible(
                  child: Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFFF8FAFC),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFFE5E7EB)),
                    ),
                    child: SingleChildScrollView(
                      child: Column(
                        children: adjustments.map((l) {
                          final v = l.variance!;
                          final value = l.displayVarianceValue;
                          final sign = v > 0 ? '+' : '';
                          return Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    l.itemName,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 13),
                                  ),
                                ),
                                Text(
                                  '$sign${_fmtQty(v)} ${l.unit}',
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
                                    color: _varianceColor(v),
                                  ),
                                ),
                                SizedBox(
                                  width: 110,
                                  child: Text(
                                    value == null || value.abs() < 0.005
                                        ? ''
                                        : _fmtMoney(value),
                                    textAlign: TextAlign.end,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: _varianceColor(value),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          );
                        }).toList(growable: false),
                      ),
                    ),
                  ),
                ),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    child: const Text('Volver'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF059669),
                    ),
                    onPressed: () => Navigator.of(context).pop(true),
                    child: const Text('Aplicar ajustes y cerrar'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Warning extends StatelessWidget {
  final String text;
  final Color color;
  final Color background;
  final Color border;
  const _Warning({
    required this.text,
    required this.color,
    required this.background,
    required this.border,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: border),
      ),
      child: Row(
        children: [
          Icon(Icons.warning_amber_rounded, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                  fontSize: 12, color: Color(0xFF92400E)),
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Diálogos de reporte
// =============================================================================

/// Se muestra al cerrar el conteo: resume el impacto y ofrece el PDF.
class _CompletedDialog extends StatelessWidget {
  final int adjustments;
  final double netValue;
  const _CompletedDialog({
    required this.adjustments,
    required this.netValue,
  });

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.check_circle, color: Color(0xFF059669)),
          SizedBox(width: 10),
          Text('Conteo completado'),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            adjustments == 0
                ? 'El inventario ya coincidía con lo contado: no hizo falta '
                    'ningún ajuste.'
                : 'Se aplicaron $adjustments ajuste(s). El stock quedó '
                    'exactamente en las cantidades contadas.',
            style: const TextStyle(fontSize: 13),
          ),
          if (adjustments > 0) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                const Text(
                  'Impacto en costo',
                  style: TextStyle(fontSize: 12, color: MangoColors.muted),
                ),
                const Spacer(),
                Text(
                  _fmtMoney(netValue),
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    color: _varianceColor(netValue),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cerrar'),
        ),
        FilledButton.icon(
          style: FilledButton.styleFrom(
            backgroundColor: MangoColors.primaryOrange,
          ),
          onPressed: () => Navigator.of(context).pop(true),
          icon: const Icon(Icons.picture_as_pdf_outlined, size: 18),
          label: const Text('Generar PDF'),
        ),
      ],
    );
  }
}

/// Elige el alcance del reporte de comparación. Devuelve `true` para
/// "solo diferencias", `false` para el listado completo.
/// Qué se exporta desde el botón de la barra.
enum _ExportKind { hojaConteo, soloDiferencias, todos, excel }

class _ExportChoiceDialog extends StatelessWidget {
  /// La comparación solo tiene sentido con la sesión cerrada: antes de
  /// completar no hay ajustes aplicados y el "impacto" sería provisorio.
  final bool completada;
  const _ExportChoiceDialog({required this.completada});

  @override
  Widget build(BuildContext context) {
    return SimpleDialog(
      title: const Text('Exportar'),
      children: [
        SimpleDialogOption(
          onPressed: () => Navigator.of(context).pop(_ExportKind.excel),
          child: const ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.table_view_outlined,
                color: Color(0xFF059669)),
            title: Text('Detalle en Excel (.xlsx)'),
            subtitle: Text(
              'La sesión completa, para auditoría. Se puede sumar y filtrar.',
              style: TextStyle(fontSize: 12),
            ),
          ),
        ),
        SimpleDialogOption(
          onPressed: () => Navigator.of(context).pop(_ExportKind.hojaConteo),
          child: const ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.print_outlined, color: MangoColors.muted),
            title: Text('Hoja de conteo (PDF)'),
            subtitle: Text(
              'Para llenar a mano. Respeta los filtros de la pantalla.',
              style: TextStyle(fontSize: 12),
            ),
          ),
        ),
        if (completada) ...[
          const Divider(height: 1),
          const Padding(
            padding: EdgeInsets.fromLTRB(24, 12, 24, 8),
            child: Text(
              'Reporte de comparación — los totales del pie son siempre los '
              'de la sesión completa.',
              style: TextStyle(fontSize: 12, color: MangoColors.muted),
            ),
          ),
          SimpleDialogOption(
            onPressed: () =>
                Navigator.of(context).pop(_ExportKind.soloDiferencias),
            child: const ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.filter_alt_outlined,
                  color: MangoColors.primaryOrange),
              title: Text('Solo diferencias (PDF)'),
              subtitle: Text(
                'Los items que no cuadraron. Es el documento de cierre.',
                style: TextStyle(fontSize: 12),
              ),
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop(_ExportKind.todos),
            child: const ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.list_alt_outlined, color: MangoColors.muted),
              title: Text('Todos los items (PDF)'),
              subtitle: Text(
                'La sesión completa, cuadre o no. Sirve de respaldo.',
                style: TextStyle(fontSize: 12),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

Color _statusColor(PhysicalCountStatus s) {
  switch (s) {
    case PhysicalCountStatus.draft:
      return const Color(0xFF6B7280);
    case PhysicalCountStatus.inProgress:
      return MangoColors.primaryOrange;
    case PhysicalCountStatus.completed:
      return const Color(0xFF059669);
    case PhysicalCountStatus.cancelled:
      return const Color(0xFFDC2626);
  }
}

Color _varianceColor(double? v) {
  if (v == null) return MangoColors.muted;
  if (v.abs() < 0.0001) return const Color(0xFF059669);
  return v > 0 ? const Color(0xFF059669) : const Color(0xFFDC2626);
}

// Igual que el resto del módulo de inventario, la moneda va fija en RD$.
final _currency = NumberFormat.currency(
  locale: 'en_US',
  symbol: 'RD\$ ',
  decimalDigits: 2,
);

String _fmtMoney(double v) => _currency.format(v);

String _fmtQty(double v) {
  if (v == v.truncate()) return v.truncate().toString();
  return v.toStringAsFixed(2);
}
