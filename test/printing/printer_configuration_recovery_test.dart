import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/data/models/printing.dart';
import 'package:mangopos/data/repositories/printing_repository.dart';
import 'package:mangopos/presentation/settings/more settings/printing/printers/viewmodel/printers_viewmodel.dart';
import 'package:mangopos/presentation/settings/more settings/printing/widgets/printer_configuration_dialog.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

PrinterDevice _printer({String? mac = 'a0:b1:c2:d3:e4:f5'}) => PrinterDevice(
  id: 'p1',
  businessId: 'b1',
  name: 'Cocina',
  ip: '192.168.1.20',
  mac: mac,
  type: PrinterType.network,
  online: true,
  createdAt: DateTime.utc(2026),
);

class _ViewModel extends PrintingPrintersViewModel {
  _ViewModel(this.printer);
  final PrinterDevice printer;
  @override
  PrintingPrintersState build() => PrintingPrintersState(items: [printer]);
  void recover(PrinterDevice current) {
    state = state.copyWith(items: [current]);
  }
}

class _Repository extends PrintingRepository {
  _Repository()
    : super(
        SupabaseClient(
          'https://example.invalid',
          'key',
          authOptions: const AuthClientOptions(autoRefreshToken: false),
        ),
      );
  PrinterConfig? printed;
  @override
  Future<PrintOutcome> printEscPos({
    required PrinterConfig printer,
    required List<int> data,
    Duration timeout = const Duration(seconds: 5),
    String? idempotencyKey,
    String kind = 'other',
    String? areaCode,
    bool preferRaster = false,
    bool refreshOnFailure = true,
  }) async {
    printed = printer;
    return PrintOutcome.directSuccess;
  }
}

void main() {
  test(
    'test de red pasa identidad y configuración al mismo camino de recovery',
    () async {
      final printer = _printer().copyWith(
        port: 9101,
        connectionConfig: {
          'ip': '192.168.1.25',
          'mac': 'a0:b1:c2:d3:e4:f5',
          'port': 9101,
          'emulation': 'star_graphic',
        },
      );
      final repo = _Repository();
      final container = ProviderContainer(
        overrides: [
          printingPrintersRepositoryProvider.overrideWithValue(repo),
          printingPrintersViewModelProvider.overrideWith(
            () => _ViewModel(printer),
          ),
        ],
      );
      final vm = container.read(printingPrintersViewModelProvider.notifier);
      expect(await vm.testPrint('p1'), isTrue);
      expect(repo.printed!.effectiveIp, '192.168.1.25');
      expect(repo.printed!.effectiveMac, 'a0:b1:c2:d3:e4:f5');
      expect(repo.printed!.effectivePort, 9101);
      expect(repo.printed!.connectionConfig['emulation'], 'star_graphic');
      container.dispose();
    },
  );

  Future<_ViewModel> open(WidgetTester tester, PrinterDevice printer) async {
    await tester.binding.setSurfaceSize(const Size(1600, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final vm = _ViewModel(printer);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [printingPrintersViewModelProvider.overrideWith(() => vm)],
        child: MaterialApp(
          home: Consumer(
            builder: (context, ref, _) {
              ref.watch(printingPrintersViewModelProvider);
              return Scaffold(
                body: ElevatedButton(
                  onPressed: () => showPrinterConfigurationDialog(
                    context,
                    printer: printer,
                    vmCtrl: vm,
                  ),
                  child: const Text('Configurar'),
                ),
              );
            },
          ),
        ),
      ),
    );
    await tester.tap(find.text('Configurar'));
    await tester.pumpAndSettle();
    return vm;
  }

  Finder fieldWithText(String text) => find.byWidgetPredicate(
    (widget) => widget is TextField && widget.controller?.text == text,
  );

  testWidgets('el diálogo abierto refleja IP y MAC recuperadas', (
    tester,
  ) async {
    final printer = _printer(mac: null);
    final vm = await open(tester, printer);
    vm.recover(printer.copyWith(ip: '192.168.1.25', mac: 'a0:b1:c2:d3:e4:f5'));
    await tester.pump();
    expect(fieldWithText('192.168.1.25'), findsOneWidget);
    expect(fieldWithText('a0:b1:c2:d3:e4:f5'), findsOneWidget);
    expect(fieldWithText('192.168.1.20'), findsNothing);
  });

  testWidgets('recuperación conserva IP y MAC editadas por el usuario', (
    tester,
  ) async {
    final printer = _printer();
    final vm = await open(tester, printer);
    await tester.enterText(fieldWithText('192.168.1.20'), '192.168.1.30');
    await tester.enterText(
      fieldWithText('a0:b1:c2:d3:e4:f5'),
      'b0:b1:c2:d3:e4:f5',
    );
    vm.recover(printer.copyWith(ip: '192.168.1.25', mac: 'c0:b1:c2:d3:e4:f5'));
    await tester.pump();
    expect(fieldWithText('192.168.1.30'), findsOneWidget);
    expect(fieldWithText('b0:b1:c2:d3:e4:f5'), findsOneWidget);
    expect(fieldWithText('192.168.1.25'), findsNothing);
  });

  testWidgets('MAC vaciada intencionalmente no se repone por recuperación', (
    tester,
  ) async {
    final printer = _printer();
    final vm = await open(tester, printer);
    final macFinder = fieldWithText('a0:b1:c2:d3:e4:f5');
    final macController = tester.widget<TextField>(macFinder).controller!;
    await tester.enterText(macFinder, '');
    vm.recover(printer.copyWith(ip: '192.168.1.25', mac: 'c0:b1:c2:d3:e4:f5'));
    await tester.pump();
    expect(macController.text, isEmpty);
    expect(fieldWithText('192.168.1.25'), findsOneWidget);
  });
}
