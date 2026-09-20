// Pantalla y exportación del reporte de comandas: que pinte sin desbordes en
// escritorio, tablet POS y teléfono; que el filtro por estación cambie lo que
// se ve; y que PDF/CSV se armen (el PDF lanza con caracteres fuera de
// Latin-1 si no se sanean).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/data/models/kitchen_comanda_report.dart';
import 'package:mangopos/data/models/kitchen_missing_report.dart';
import 'package:mangopos/data/repositories/reports_repository.dart';
import 'package:mangopos/presentation/reports/services/reports_csv_export_service.dart';
import 'package:mangopos/presentation/reports/services/reports_export_service.dart';
import 'package:mangopos/presentation/reports/view/kitchen_comandas_report_view.dart';
import 'package:mangopos/presentation/reports/viewmodel/reports_viewmodel.dart';
import 'package:mangopos/services/session/session_controller.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _FakeReportsViewModel extends ReportsViewModel {
  _FakeReportsViewModel(
    Ref ref,
    KitchenComandaReport report, {
    double? salesItemsSold,
    KitchenComandaReport? openNow,
    KitchenComandaReport? withoutComanda,
    KitchenMissingReport? missing,
  }) : super(
         ReportsRepository(
           // Sin auto-refresh: su timer periódico queda pendiente al terminar
           // el test. Nunca se llama: loadCategory no hace nada.
           SupabaseClient(
             'http://localhost',
             'anon',
             authOptions: const AuthClientOptions(autoRefreshToken: false),
           ),
         ),
         ref,
       ) {
    state = state.copyWith(
      comandasReport: report,
      comandasSalesItemsSold: salesItemsSold,
      comandasOpenReport: openNow ?? _openNow,
      comandasWithoutComandaReport: withoutComanda,
      comandasMissingReport: missing,
    );
  }

  @override
  Future<void> loadCategory(ReportCategory category) async {}

  // El selector de horas llama a load() al aplicar; en el test solo
  // interesa que el estado quede con el rango nuevo.
  @override
  Future<void> load() async {}
}

class _FakeSessionController extends SessionController {
  @override
  SessionState build() => const SessionState(activeBusinessId: 'biz-1');
}

var _seq = 0;

Map<String, dynamic> _row({
  String order = 'order-1',
  required String sent,
  required String name,
  num quantity = 1,
  String table = 'Mesa 5',
  List<String> codes = const ['cocina'],
  List<String> names = const ['Cocina'],
  List<Map<String, dynamic>> modifiers = const [],
  String? notes,
  String status = 'served',
  String orderStatus = 'open',
  String? closedAt,
}) => {
  'item_id': 'item-${_seq++}',
  'order_id': order,
  'kitchen_sent_at': sent,
  'product_id': 'p-$name',
  'product_name': name,
  'quantity': quantity,
  'notes': notes,
  'table_name': table,
  'item_author': 'Claudia Pérez 🎉',
  'area_codes': codes,
  'area_names': names,
  'modifiers': modifiers,
  'status': status,
  'order_status': orderStatus,
  'order_closed_at': closedAt,
  'session_closed_at': closedAt,
  'is_zero_value': false,
};

final _report = KitchenComandaReport.fromRows([
  _row(
    sent: '2026-09-19T14:05:00Z',
    name: 'Burrito',
    quantity: 2,
    modifiers: [
      {'name': 'Extra queso', 'qty': 2},
    ],
    notes: 'Sin picante ⚠',
  ),
  _row(
    sent: '2026-09-19T14:05:00Z',
    name: 'Mojito',
    codes: const ['bar'],
    names: const ['Bar'],
    status: 'paid',
  ),
  _row(
    order: 'order-2',
    sent: '2026-09-19T15:00:00Z',
    name: 'Filete de res a la parrilla con papas',
    table: 'Venta rápida',
    orderStatus: 'paid',
    closedAt: '2026-09-19T15:30:00Z',
  ),
  // Orden anulada desde la mesa, con su nota.
  {
    ..._row(
      order: 'order-4',
      sent: '2026-09-19T17:00:00Z',
      name: 'Johnnie Blue Label',
      table: 'MUEBLE08',
      status: 'pending',
      orderStatus: 'canceled',
      closedAt: '2026-09-19T17:20:00Z',
    ),
    'void_note': 'Juleisy: el cliente se fue',
  },
  // Una comanda cobrada completa: el filtro "no cobradas" la esconde.
  _row(
    order: 'order-3',
    sent: '2026-09-19T16:00:00Z',
    name: 'Agua',
    table: 'Mesa 2',
    status: 'paid',
    orderStatus: 'paid',
    closedAt: '2026-09-19T16:30:00Z',
  ),
]);

/// Foto de "aún sin cobrar": la mesa 5 abierta y una orden huérfana de
/// anoche (mesa cerrada con la orden viva).
final _openNow = KitchenComandaReport.fromRows([
  _row(sent: '2026-09-19T14:05:00Z', name: 'Burrito', quantity: 2),
  {
    ..._row(
      order: 'order-9',
      sent: '2026-09-18T23:40:00Z',
      name: 'Presidente',
      quantity: 6,
      table: 'Mesa 9',
      status: 'pending',
      orderStatus: 'sent',
    ),
    'session_closed_at': '2026-09-19T01:00:00Z',
  },
]);

Future<void> _pump(
  WidgetTester tester,
  Size size, {
  double? salesItemsSold,
  KitchenMissingReport? missing,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        reportsViewModelProvider.overrideWith(
          (ref) => _FakeReportsViewModel(
            ref,
            _report,
            salesItemsSold: salesItemsSold,
            missing: missing,
          ),
        ),
        sessionProvider.overrideWith(_FakeSessionController.new),
      ],
      child: const MaterialApp(home: KitchenComandasReportView()),
    ),
  );
  await tester.pump();
}

/// Desaparecidas: un Blue Label borrado con motivo en MUEBLE31 y una orden
/// huérfana en la mesa 9.
final _missing = KitchenMissingReport.fromRows([
  {
    ..._row(
      order: 'order-31',
      sent: '2026-09-19T18:00:00Z',
      name: 'Blue Label borrado',
      table: 'MUEBLE31',
      codes: const ['bar'],
      names: const ['Bar'],
      status: 'pending',
    ),
    'missing_kind': 'deleted',
    'removed_at': '2026-09-19T18:30:00Z',
    'removed_reason': 'Cliente no lo quiso',
    'removed_by': 'Avila Soto',
    'qty_before': 1,
    'qty_after': 0,
  },
  {
    ..._row(
      order: 'order-9',
      sent: '2026-09-19T13:00:00Z',
      name: 'Mofongo huérfano',
      quantity: 2,
      table: 'Mesa 9',
      status: 'pending',
      orderStatus: 'sent',
    ),
    'session_closed_at': '2026-09-19T14:00:00Z',
    'missing_kind': 'orphan',
  },
]);

void main() {
  testWidgets('escritorio: comandas y total por producto lado a lado', (
    tester,
  ) async {
    await _pump(tester, const Size(1400, 2400));
    expect(tester.takeException(), isNull);
    expect(find.text('Total por producto'), findsOneWidget);
    expect(find.text('2 × Burrito'), findsOneWidget);
    expect(find.text('+ Extra queso ×2'), findsOneWidget);
    expect(find.text('Imprimir resumen'), findsOneWidget);
  });

  testWidgets('tablet POS 1024 px sin desbordes', (tester) async {
    await _pump(tester, const Size(1024, 2400));
    expect(tester.takeException(), isNull);
  });

  testWidgets('teléfono: total arriba, comandas debajo, sin desbordes', (
    tester,
  ) async {
    // 470 px sigue siendo teléfono (< 480). Más angosto, el chip de rango del
    // ReportScaffold compartido desborda con la fuente de pruebas (cada
    // glifo mide 1 em) — no es de esta pantalla.
    await _pump(tester, const Size(470, 3200));
    expect(tester.takeException(), isNull);
    final totals = tester.getTopLeft(find.text('Total por producto'));
    final comandas = tester.getTopLeft(find.text('Comandas').last);
    expect(totals.dy, lessThan(comandas.dy));
  });

  testWidgets('cada comanda marca lo que no se cobró; filtro "no cobradas"', (
    tester,
  ) async {
    await _pump(tester, const Size(1400, 2400));
    expect(find.text('Pendiente: 2'), findsOneWidget);
    expect(find.text('Sin cobrar: 1'), findsOneWidget);
    expect(find.text('1 × Agua'), findsOneWidget);
    await tester.tap(find.text('Solo las no cobradas (2)'));
    await tester.pump();
    // La mesa 2 se cobró completa: sale de la lista.
    expect(find.text('1 × Agua'), findsNothing);
    expect(find.text('2 × Burrito'), findsOneWidget);
  });

  testWidgets('filtro por estación: Bar deja solo lo del bar', (tester) async {
    await _pump(tester, const Size(1400, 2400));
    expect(find.text('2 × Burrito'), findsOneWidget);
    await tester.tap(find.text('Bar').first);
    await tester.pump();
    expect(find.text('2 × Burrito'), findsNothing);
    expect(find.text('1 × Mojito'), findsOneWidget);
  });

  group('Enviado vs. cobrado', () {
    Future<void> openComparison(
      WidgetTester tester,
      Size size, {
      double? salesItemsSold,
    }) async {
      await _pump(tester, size, salesItemsSold: salesItemsSold);
      await tester.tap(find.text('Enviado vs. cobrado'));
      await tester.pump();
    }

    testWidgets('escritorio: resumen, tabla y detalle con motivo', (
      tester,
    ) async {
      await openComparison(tester, const Size(1400, 3000));
      expect(tester.takeException(), isNull);
      expect(find.text('Comandas no cobradas'), findsOneWidget);
      // Chips por estado con cuántas comandas hay en cada uno.
      expect(find.text('Sin cobrar (1)'), findsOneWidget);
      expect(find.text('Pendiente — mesa abierta (1)'), findsOneWidget);
      expect(find.text('La orden se cobró sin este producto'), findsOneWidget);
      expect(find.text('Sin cobrar: 1'), findsOneWidget);
      expect(find.text('Pendiente (mesa abierta): 2'), findsOneWidget);
      // Sin el número de Ventas no hay cuadre que mostrar.
      expect(find.textContaining('Según el reporte de Ventas'), findsNothing);
    });

    testWidgets('cuadre con Ventas: muestra el número y explica la brecha', (
      tester,
    ) async {
      await openComparison(tester, const Size(1400, 3000), salesItemsSold: 4);
      expect(tester.takeException(), isNull);
      expect(
        find.text(
          'Según el reporte de Ventas se cobraron 4 productos en el período.',
        ),
        findsOneWidget,
      );
      // Cobrado aquí: 2 (el mojito y el agua). Los otros 2 se enviaron a
      // cocina otro día.
      expect(
        find.textContaining('2 de los productos de Ventas se enviaron'),
        findsOneWidget,
      );
    });

    testWidgets('aún sin cobrar (ahora): mesa abierta y orden huérfana', (
      tester,
    ) async {
      await openComparison(tester, const Size(1400, 3000));
      expect(tester.takeException(), isNull);
      expect(find.text('Aún sin cobrar (ahora mismo)'), findsOneWidget);
      expect(find.text('Mesa cerrada con la orden abierta'), findsOneWidget);
      expect(find.text('Mesa abierta'), findsOneWidget);
      expect(find.text('6 × Presidente'), findsOneWidget);
    });

    testWidgets('aún sin cobrar en teléfono, sin desbordes', (tester) async {
      await openComparison(tester, const Size(470, 5000));
      expect(tester.takeException(), isNull);
      expect(find.text('Aún sin cobrar (ahora mismo)'), findsOneWidget);
    });

    testWidgets('comandas no cobradas: cambiar de estado cambia la lista', (
      tester,
    ) async {
      await openComparison(tester, const Size(1400, 3000));
      // Por defecto lo más grave: sin cobrar (el filete que la orden
      // cobró sin él).
      expect(find.text('La orden se cobró sin este producto'), findsOneWidget);
      // Cada tarjeta dice su estado, no solo el color.
      expect(find.text('Sin cobrar'), findsWidgets);
      await tester.tap(find.text('Pendiente — mesa abierta (1)'));
      await tester.pump();
      expect(find.text('Pendiente — mesa abierta'), findsOneWidget);
      expect(find.text('La orden se cobró sin este producto'), findsNothing);
      // La mesa 5 sale en la comanda pendiente Y en "aún sin cobrar (ahora)".
      expect(find.text('2 × Burrito'), findsNWidgets(2));
    });

    testWidgets('las anuladas muestran la nota que se les puso', (
      tester,
    ) async {
      await openComparison(tester, const Size(1400, 3000));
      await tester.tap(find.text('Anulado después de enviar a cocina (1)'));
      await tester.pump();
      expect(find.text('Orden anulada'), findsOneWidget);
      expect(find.text('Nota: Juleisy: el cliente se fue'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('cobrado sin comanda: sección y suma en el cuadre', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1400, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final withoutComanda = KitchenComandaReport.fromRows([
        {
          ..._row(
            order: 'order-7',
            sent: '2026-09-19T17:30:00Z',
            name: 'Agua',
            quantity: 2,
            table: 'MUEBLE20',
            status: 'paid',
          ),
          'sent_source': 'none',
        },
      ]);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            reportsViewModelProvider.overrideWith(
              (ref) => _FakeReportsViewModel(
                ref,
                _report,
                salesItemsSold: 4,
                withoutComanda: withoutComanda,
              ),
            ),
            sessionProvider.overrideWith(_FakeSessionController.new),
          ],
          child: const MaterialApp(home: KitchenComandasReportView()),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('Enviado vs. cobrado'));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('Cobrado sin comanda'), findsOneWidget);
      expect(find.text('Cobrado sin comanda (aparte): 2'), findsOneWidget);
      expect(find.text('2 × Agua'), findsOneWidget);
      // 2 en comandas + 2 sin comanda = 4 = Ventas.
      expect(find.textContaining('= 4. Cuadra con Ventas.'), findsOneWidget);
    });

    testWidgets('el cuadre no sale con filtro por estación', (tester) async {
      await openComparison(tester, const Size(1400, 3000), salesItemsSold: 3);
      await tester.tap(find.text('Bar').first);
      await tester.pump();
      expect(find.textContaining('Según el reporte de Ventas'), findsNothing);
    });

    testWidgets('tablet POS 1024 px: la tabla de 8 columnas cabe', (
      tester,
    ) async {
      await openComparison(tester, const Size(1024, 3000));
      expect(tester.takeException(), isNull);
    });

    testWidgets('teléfono: tarjetas sin desbordes', (tester) async {
      await openComparison(tester, const Size(470, 4000));
      expect(tester.takeException(), isNull);
      expect(find.text('La orden se cobró sin este producto'), findsOneWidget);
    });

    testWidgets('"Ver todos" muestra también lo cobrado completo', (
      tester,
    ) async {
      await openComparison(tester, const Size(1400, 3000));
      // El mojito se cobró: no sale hasta pedir todos los productos.
      expect(find.text('Mojito'), findsNothing);
      await tester.tap(find.textContaining('Ver todos los productos'));
      await tester.pump();
      expect(find.text('Mojito'), findsOneWidget);
    });

    testWidgets('imprimir ofrece las tres opciones', (tester) async {
      await _pump(tester, const Size(1400, 2400));
      await tester.tap(find.text('Imprimir resumen'));
      await tester.pumpAndSettle();
      expect(find.text('¿Qué quieres imprimir?'), findsOneWidget);
      expect(find.text('Todas las comandas'), findsOneWidget);
      expect(find.text('Solo total por producto'), findsOneWidget);
      expect(find.text('Enviado vs. cobrado'), findsWidgets);
      await tester.tap(find.text('Cancelar'));
      await tester.pumpAndSettle();
      expect(find.text('¿Qué quieres imprimir?'), findsNothing);
    });
  });

  group('Servidor con la versión vieja de la RPC', () {
    // Sin las columnas de cobro (orden, mesa, cortesía, a 0): una orden
    // ANULADA parecería abierta y saldría "pendiente".
    final oldServer = KitchenComandaReport.fromRows([
      for (final row in [
        _row(
          sent: '2026-09-18T23:50:00Z',
          name: 'Johnnie Blue Label 750Ml',
          table: 'MUEBLE08',
          status: 'pending',
        ),
      ])
        {
          for (final e in row.entries)
            if (!const {
              'order_status',
              'order_closed_at',
              'session_closed_at',
              'is_zero_value',
            }.contains(e.key))
              e.key: e.value,
        },
    ]);

    Future<void> pumpOld(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1400, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            reportsViewModelProvider.overrideWith(
              (ref) => _FakeReportsViewModel(ref, oldServer),
            ),
            sessionProvider.overrideWith(_FakeSessionController.new),
          ],
          child: const MaterialApp(home: KitchenComandasReportView()),
        ),
      );
      await tester.pump();
    }

    testWidgets('el comparador avisa en vez de mostrar estados falsos', (
      tester,
    ) async {
      await pumpOld(tester);
      await tester.tap(find.text('Enviado vs. cobrado'));
      await tester.pump();
      expect(
        find.textContaining('Falta volver a correr la migración 20260919_0001'),
        findsOneWidget,
      );
      expect(find.text('Comandas no cobradas'), findsNothing);
    });

    testWidgets('las comandas no llevan etiquetas de cobro', (tester) async {
      await pumpOld(tester);
      expect(find.text('1 × Johnnie Blue Label 750Ml'), findsOneWidget);
      expect(find.textContaining('Pendiente'), findsNothing);
      expect(find.textContaining('Solo las no cobradas'), findsNothing);
    });
  });

  group('Exportación', () {
    late ProviderContainer container;
    late ReportsViewModel viewModel;

    setUp(() {
      container = ProviderContainer(
        overrides: [
          reportsViewModelProvider.overrideWith(
            (ref) => _FakeReportsViewModel(ref, _report),
          ),
        ],
      );
      viewModel = container.read(reportsViewModelProvider.notifier);
    });

    tearDown(() => container.dispose());

    test('el PDF se arma aunque haya emoji en nombres y notas', () async {
      final bytes = await ReportsExportService.buildCurrentReportPdf(
        category: ReportCategory.comandas,
        state: container.read(reportsViewModelProvider),
        viewModel: viewModel,
      );
      expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    });

    test('el CSV trae cada producto de cada comanda y el total', () {
      final csv = ReportsCsvExportService.buildCsv(
        ReportCategory.comandas,
        container.read(reportsViewModelProvider),
        viewModel,
      );
      expect(csv, contains('Reporte de comandas'));
      expect(csv, contains('Filete de res a la parrilla con papas'));
      expect(csv, contains('Extra queso x2'));
      expect(csv, contains('Total por producto'));
    });

    test('el CSV trae el comparador con lo cobrado', () {
      final csv = ReportsCsvExportService.buildCsv(
        ReportCategory.comandas,
        container.read(reportsViewModelProvider),
        viewModel,
      );
      expect(csv, contains('Enviado a cocina vs. cobrado'));
      expect(csv, contains('Comandas no cobradas'));
      expect(csv, contains('Aún sin cobrar (ahora mismo)'));
      expect(csv, contains('Mesa cerrada con la orden abierta'));
      expect(csv, contains('La orden se cobró sin este producto'));
    });

    test('con filtro Bar, el CSV solo exporta lo del bar', () {
      viewModel.setComandasArea('bar');
      final csv = ReportsCsvExportService.buildCsv(
        ReportCategory.comandas,
        container.read(reportsViewModelProvider),
        viewModel,
      );
      expect(csv, contains('Mojito'));
      expect(csv, isNot(contains('Burrito')));
      expect(csv, contains('Bar'));
    });
  });

  group('Comandas desaparecidas', () {
    Future<void> openComparison(
      WidgetTester tester, {
      KitchenMissingReport? missing,
    }) async {
      await _pump(tester, const Size(1400, 3600), missing: missing);
      await tester.tap(find.text('Enviado vs. cobrado'));
      await tester.pump();
    }

    testWidgets('comparador: los dos grupos con quién, cuándo y el motivo', (
      tester,
    ) async {
      await openComparison(tester, missing: _missing);
      expect(tester.takeException(), isNull);
      expect(find.text('Comandas desaparecidas'), findsOneWidget);
      expect(
        find.text('Borrado o reducido después de enviar (1)'),
        findsOneWidget,
      );
      expect(find.text('Fuera de toda cuenta (2)'), findsOneWidget);
      expect(find.text('1 × Blue Label borrado'), findsOneWidget);
      expect(
        find.text(
          'Borrado 19/09 14:30 por Avila Soto · Motivo: Cliente no lo quiso',
        ),
        findsOneWidget,
      );
      expect(find.text('2 × Mofongo huérfano'), findsOneWidget);
      expect(
        find.text('Borrado o reducido después de enviar (aparte): 1'),
        findsOneWidget,
      );
    });

    testWidgets('sin la migración 0002 lo dice, no dice "ninguna"', (
      tester,
    ) async {
      await openComparison(tester);
      expect(
        find.textContaining('falta aplicar la migración 20260919_0002'),
        findsOneWidget,
      );
      expect(find.textContaining('Ninguna comanda desaparecida'), findsNothing);
    });

    testWidgets('vista Comandas: sale arriba solo si hay desaparecidas', (
      tester,
    ) async {
      await _pump(tester, const Size(1400, 3600), missing: _missing);
      expect(tester.takeException(), isNull);
      final missing = tester.getTopLeft(find.text('Comandas desaparecidas'));
      final totals = tester.getTopLeft(find.text('Total por producto'));
      expect(missing.dy, lessThan(totals.dy));
    });

    testWidgets('vista Comandas: vacía o sin dato, no ocupa espacio', (
      tester,
    ) async {
      await _pump(
        tester,
        const Size(1400, 2400),
        missing: KitchenMissingReport.empty,
      );
      expect(find.text('Comandas desaparecidas'), findsNothing);
    });

    testWidgets('teléfono: sin desbordes', (tester) async {
      await _pump(tester, const Size(470, 4000), missing: _missing);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Enviado vs. cobrado'));
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    test('PDF y CSV traen las desaparecidas', () async {
      final container = ProviderContainer(
        overrides: [
          reportsViewModelProvider.overrideWith(
            (ref) => _FakeReportsViewModel(ref, _report, missing: _missing),
          ),
        ],
      );
      addTearDown(container.dispose);
      final viewModel = container.read(reportsViewModelProvider.notifier);
      final state = container.read(reportsViewModelProvider);
      final bytes = await ReportsExportService.buildCurrentReportPdf(
        category: ReportCategory.comandas,
        state: state,
        viewModel: viewModel,
      );
      expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
      final csv = ReportsCsvExportService.buildCsv(
        ReportCategory.comandas,
        state,
        viewModel,
      );
      expect(csv, contains('Eliminaciones'));
      expect(csv, contains('Comandas desaparecidas'));
      expect(csv, contains('Blue Label borrado'));
      expect(csv, contains('Motivo: Cliente no lo quiso'));
      expect(csv, contains('Orden huérfana'));
    });
  });

  group('Eliminaciones y rango por horas', () {
    testWidgets('el encabezado cuenta las eliminaciones', (tester) async {
      await _pump(tester, const Size(1400, 2400), missing: _missing);
      expect(find.text('Eliminaciones'), findsOneWidget);
      // _missing trae un borrado y una huérfana: la huérfana no la quitó
      // nadie, así que no cuenta como eliminación.
      expect(find.text('1'), findsWidgets);
    });

    testWidgets('sin el registro no se inventa un 0', (tester) async {
      await _pump(tester, const Size(1400, 2400));
      expect(find.text('Eliminaciones'), findsNothing);
    });

    testWidgets('la barra dice el rango y el selector aplica el turno', (
      tester,
    ) async {
      await _pump(tester, const Size(1400, 2400));
      expect(find.textContaining('Días completos'), findsOneWidget);

      await tester.tap(find.text('Elegir horas'));
      await tester.pumpAndSettle();
      expect(find.text('¿Desde qué hora y hasta cuándo?'), findsOneWidget);
      expect(find.text('Desde'), findsOneWidget);
      expect(find.text('Hasta'), findsOneWidget);

      await tester.tap(find.text('Turno de anoche (6 p. m. → 6 a. m.)'));
      await tester.pump();
      await tester.tap(find.text('Aplicar'));
      await tester.pumpAndSettle();

      // Ya no es un día completo: la barra muestra el turno con horas.
      expect(find.textContaining('Días completos'), findsNothing);
      expect(find.textContaining('6:00 PM →'), findsOneWidget);
      // El encabezado del reporte también deja de decir un solo día.
      expect(find.textContaining('6:00 PM – '), findsOneWidget);
    });

    testWidgets('cancelar no cambia el rango', (tester) async {
      await _pump(tester, const Size(1400, 2400));
      await tester.tap(find.text('Elegir horas'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancelar'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Días completos'), findsOneWidget);
    });
  });
}
