import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:mangopos/core/network/connectivity_service.dart';
import 'package:mangopos/core/printing/printerless_mode.dart';
import 'package:mangopos/data/models/order_edit.dart';
import 'package:mangopos/data/models/printing.dart';
import 'package:mangopos/data/models/sales_models.dart';
import 'package:mangopos/data/repositories/printing_repository.dart';
import 'package:mangopos/data/repositories/sales_repository.dart';
import 'package:mangopos/data/utils/order_pricing_utils.dart';
import 'package:mangopos/data/utils/issued_receipt_order.dart';
import 'package:mangopos/presentation/cashier/utils/invoice_reprint.dart';
import 'package:mangopos/presentation/sales/viewmodel/sales_viewmodel.dart';
import 'package:mangopos/presentation/settings/more settings/printing/printers/viewmodel/printers_viewmodel.dart';
import 'package:mangopos/presentation/split_bill/viewmodel/split_bill_viewmodel.dart';
import 'package:mangopos/services/printing/print_ticket_service.dart';
import 'package:mangopos/services/session/session_controller.dart';

const biz = 'b0000000-0000-0000-0000-000000000001';
final snapshots =
    (jsonDecode(
              File(
                'test/fixtures/offer_split_receipts_legacy.json',
              ).readAsStringSync(),
            )
            as List)
        .cast<Map<String, dynamic>>();
Map<String, dynamic> snap(String scenario, String stage) => snapshots
    .firstWhere((s) => s['scenario'] == scenario && s['stage'] == stage);
Order sale(Map<String, dynamic> s) =>
    Order.fromMap(Map<String, dynamic>.from(s['order']));
List<OrderItem> items(Map<String, dynamic> s) => (s['items'] as List)
    .map((i) => OrderItem.fromMap(Map<String, dynamic>.from(i)))
    .toList();
List<OrderCheck> checks(Map<String, dynamic> s) => (s['checks'] as List)
    .map((i) => OrderCheck.fromMap(Map<String, dynamic>.from(i)))
    .toList();

class Session extends SessionController {
  @override
  SessionState build() => const SessionState(
    activeBusinessId: biz,
    permissions: {
      'pagos.reimprimir_recibo',
      'ventas.orden.dividir',
      'ventas.cuenta.split_manual',
      'ventas.mesas.mover_unir',
    },
  );
}

class FixtureSales extends SalesRepository {
  FixtureSales(super.client, {required this.current, this.afterExplode});
  Map<String, dynamic> current;
  Map<String, dynamic>? afterExplode;
  int explodeCalls = 0;
  @override
  Future<int> explodeItemsToUnits({required String orderId}) async {
    explodeCalls++;
    current = afterExplode ?? current;
    return 1;
  }

  @override
  Future<
    ({
      Order? order,
      List<OrderItem> items,
      List<OrderCheck> checks,
      String? customerId,
      String? customerName,
      String? note,
    })
  >
  getOrderBundle(String id, {String? businessId}) async => (
    order: sale(current),
    items: items(current),
    checks: checks(current),
    customerId: null,
    customerName: null,
    note: null,
  );
  @override
  Future<List<OrderItem>> getOrderItems(
    String id, {
    bool includeModifiers = true,
    int limit = 500,
    bool onlyOpen = false,
    String? businessId,
  }) async => items(current);
  @override
  Future<OrderEditResult> consolidateCheckItems({
    required String orderId,
    required String checkId,
    bool normalizeQtyToInteger = false,
  }) async => const OrderEditResult(status: 'applied');
  @override
  Future<FiscalDocument?> getFiscalDocumentById(String id) async => null;
}

class CapturePrinter extends PrintingRepository {
  CapturePrinter(super.client);
  final tickets = <String>[];
  @override
  Future<PrinterConfig?> getAssignedPrinterForType({
    required String businessId,
    required List<String> preferredAreaCodes,
    bool printsOrders = false,
    bool printsPrebills = false,
    bool printsReceipts = false,
  }) async => PrinterConfig(
    id: 'fake',
    businessId: biz,
    name: 'Repro',
    type: 'network',
    isActive: true,
    createdAt: DateTime(2026),
  );
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
    tickets.add(String.fromCharCodes(data));
    return PrintOutcome.directSuccess;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    ConnectivityService().simulateDisconnect();
    await PrinterlessMode.setDeviceOverride(
      PrinterlessDeviceOverride.alwaysPrint,
    );
    await Supabase.initialize(
      url: 'http://localhost:54321',
      publishableKey: 'test',
      httpClient: MockClient((r) async {
        Object? body = [];
        if (r.url.path.endsWith('/payments')) body = activePayments;
        if (r.url.path.endsWith('/fiscal_documents')) body = activeDocument;
        if (r.url.path.endsWith('/businesses')) {
          body = {
            'id': biz,
            'name': 'Medio Tiempo Bar',
            'business_name': 'Medio Tiempo Bar',
          };
        }
        if (r.url.path.endsWith('/business_settings')) body = {};
        if (r.url.path.endsWith('/taxes')) body = [];
        return http.Response(
          jsonEncode(body),
          200,
          headers: {'content-type': 'application/json'},
          request: r,
        );
      }),
    );
  });
  tearDownAll(() async {
    await Supabase.instance.dispose();
  });
  test(
    'la subcuenta histórica de la foto conserva total y ahora cuadra su desglose',
    () {
      final s = snap('delete_before_split', 'products_separated');
      final ch = checks(s).firstWhere((c) => c.position == 2);
      final selected = items(s).where((i) => i.checkId == ch.id).toList();
      final sum = summarizeOrderPricing(
        ch.toOrder(createdAt: sale(s).createdAt),
        selected,
      );
      expect(sum.subtotal, 312.50);
      expect(sum.tax, 87.50);
      expect(sum.discounts, 200);
      expect(sum.total, 200);
      expect(sum.subtotal + sum.tax - sum.discounts, closeTo(sum.total, .01));
      final pre = PrintTicketService.generatePrecheck(
        order: ch.toOrder(createdAt: sale(s).createdAt),
        items: selected,
        tableName: 'CAJA3',
        template: 'modern',
        taxBreakdown: const [
          (label: 'ITBIS (18%)', amount: 56.25),
          (label: 'LEY (10%)', amount: 31.25),
        ],
      );
      expect(pre.rawText, contains('312.50'));
      expect(pre.rawText, isNot(contains('512.50')));
    },
  );
  test('ofertas inclusive y exclusive aplican un solo descuento', () {
    for (final mode in ['inclusive', 'exclusive']) {
      final o = sale(snap('delete_before_split', 'two_offers'));
      final i = items(snap('delete_before_split', 'two_offers')).first;
      final exclusive = i.copyWith(
        quantity: 2,
        unitPrice: 100,
        subtotal: 200,
        tax: 56,
        discounts: 100,
        total: 156,
        taxMode: mode,
      );
      final s = summarizeOrderPricing(o, [exclusive]);
      expect(s.total, mode == 'inclusive' ? 100 : 156);
      if (mode == 'exclusive') {
        expect(s.subtotal + s.tax - s.discounts, s.total);
      }
      final full = summarizeOrderPricing(o, [i]);
      expect(
        full.subtotal + full.tax - full.discounts,
        closeTo(full.total, .01),
      );
    }
  });
  test(
    'los importes de una reimpresión salen del documento, no del saldo del check',
    () {
      final o = sale(snap('whole_offer_control', 'first_check_paid'));
      final frozen = issuedReceiptOrder(o, {
        'subtotal': 312.50,
        'itbis_amount': 56.25,
        'service_fee': 31.25,
        'total': 200,
      });
      expect(frozen.total, 200);
      expect(frozen.discounts, 200);
      expect(frozen.subtotal, 312.50);
      expect(() => issuedReceiptOrder(o, {'total': 400}), throwsStateError);
      expect(
        () => issuedReceiptOrder(o, {'subtotal': 0, 'total': double.nan}),
        throwsStateError,
      );
    },
  );
  test('la reimpresión conserva diferencias históricas menores a un peso', () {
    final source = snap('whole_offer_control', 'first_check_paid');
    final original = sale(source);
    final paidItems = items(
      source,
    ).where((item) => item.status == 'paid').toList();
    final frozen = issuedReceiptOrder(original, {
      'subtotal': 625,
      'itbis_amount': 175,
      'total': 400.50,
    });
    final ticket = PrintTicketService.generateInvoice(
      order: frozen,
      items: paidItems,
      payments: const [],
      tableName: 'C9',
      preferStoredOrderTotals: true,
    );
    expect(
      RegExp(r'\bTOTAL:\s+RD\$([\d,.]+)').firstMatch(ticket.rawText!)!.group(1),
      '400.50',
    );
  });
  test(
    'el desglose histórico no suma de nuevo la ley ni usa tasas actuales',
    () {
      final source = snap('whole_offer_control', 'first_check_paid');
      final document = issuedReceiptOrder(sale(source), {
        'subtotal': 625,
        'itbis_amount': 112.50,
        'service_fee': 62.50,
        'total': 400,
      });
      final historical = items(source).where((item) => item.status == 'paid');
      final breakdown = issuedReceiptTaxBreakdown(document, historical);
      expect(breakdown.fold<double>(0, (sum, row) => sum + row.amount), 175);
      expect(breakdown.map((row) => row.label), ['ITBIS', 'Servicio']);
      final noTax = document.copyWith(tax: 0, serviceFee: 0);
      expect(issuedReceiptTaxBreakdown(noTax, historical), isEmpty);
    },
  );
  test(
    'el generador tampoco admite una factura vacía con efectivo y cambio',
    () {
      final source = snap('whole_offer_control', 'first_check_paid');
      final payment = Payment.fromMap({
        ...(source['payments'] as List).single as Map<String, dynamic>,
        'amount': 600,
        'change_amount': 70,
      });
      expect(
        () => PrintTicketService.generateInvoice(
          order: sale(
            source,
          ).copyWith(subtotal: 0, tax: 0, discounts: 0, total: 0),
          items: const [],
          payments: [payment],
          tableName: 'C9',
          preferStoredOrderTotals: true,
        ),
        throwsStateError,
      );
    },
  );
  test(
    'abrir la división conserva los paquetes y conserva los paquetes',
    () async {
      final repo = FixtureSales(
        Supabase.instance.client,
        current: snap('delete_before_split', 'two_offers'),
      );
      final container = ProviderContainer(
        overrides: [
          sessionProvider.overrideWith(Session.new),
          salesRepositoryProvider.overrideWithValue(repo),
        ],
      );
      final sub = container.listen(splitBillViewModelProvider, (_, _) {});
      await container
          .read(splitBillViewModelProvider.notifier)
          .initialize(sale(repo.current));
      final state = container.read(splitBillViewModelProvider);
      expect(state.error, isNull);
      expect(state.allItems.length, 2);
      expect(state.allItems.every((i) => i.quantity == 2), true);
      sub.close();
      container.dispose();
    },
  );
  test('unir subcuentas no consolida dos ofertas en una sola línea', () async {
    final source = Map<String, dynamic>.from(
      snap('delete_before_split', 'two_offers'),
    );
    final original = (source['checks'] as List).first as Map;
    source['checks'] = [
      original,
      {...original, 'id': 'temp_c2', 'position': 2},
      {...original, 'id': 'temp_c3', 'position': 3},
    ];
    final originalItems = (source['items'] as List);
    source['items'] = [
      {...originalItems[0] as Map, 'check_id': 'temp_c2'},
      {...originalItems[1] as Map, 'check_id': 'temp_c3'},
    ];
    final repo = FixtureSales(Supabase.instance.client, current: source);
    final container = ProviderContainer(
      overrides: [
        sessionProvider.overrideWith(Session.new),
        salesRepositoryProvider.overrideWithValue(repo),
      ],
    );
    final sub = container.listen(splitBillViewModelProvider, (_, _) {});
    final vm = container.read(splitBillViewModelProvider.notifier);
    await vm.initialize(sale(source));
    await vm.mergeChecks(sourceCheckId: 'temp_c2', targetCheckId: 'temp_c3');
    final kept = container.read(splitBillViewModelProvider).allItems;
    expect(kept.length, 2);
    expect(kept.every((i) => i.quantity == 2 && i.discounts == 400), true);
    sub.close();
    container.dispose();
  });
  test(
    'la RPC segura no recurre a la separación antigua si falta la migración',
    () async {
      final paths = <String>[];
      final client = SupabaseClient(
        'http://localhost:54321',
        'test',
        httpClient: MockClient((r) async {
          paths.add(r.url.path);
          return http.Response(
            jsonEncode({'code': 'PGRST202', 'message': 'missing RPC'}),
            404,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      await expectLater(
        SalesRepository(client).explodeItemsToUnits(orderId: 'order'),
        throwsException,
      );
      expect(paths, ['/rest/v1/rpc/fn_explode_items_for_split']);
      await client.dispose();
    },
  );
  for (final spec in [
    ('first_check_paid', false, false),
    ('second_check_paid', false, false),
    ('first_check_paid', true, false),
    ('second_check_paid', true, false),
    ('first_check_paid', false, true),
    ('second_check_paid', false, true),
  ]) {
    final stage = spec.$1;
    final missing = spec.$2;
    final partial = spec.$3;
    testWidgets(
      'REIMPRESION REAL: subcuenta $stage ${missing
          ? 'con detalle ausente'
          : partial
          ? 'con detalle parcial'
          : 'con sus productos'}',
      (tester) async {
        final source = snap('whole_offer_control', stage);
        final ch = checks(source).firstWhere((c) => c.position == 2);
        final fd = (source['fiscal_documents'] as List)
            .cast<Map<String, dynamic>>()
            .firstWhere((f) => f['check_id'] == ch.id);
        activeDocument = {
          ...fd,
          'business_id': biz,
          'ncf_type': 'B02',
          'customer_name': 'Consumidor Final',
          'issued_at': '2026-10-14T12:00:00Z',
        };
        final supplied = Map<String, dynamic>.from(source);
        if (missing) {
          supplied['items'] = [];
          supplied['checks'] = (source['checks'] as List)
              .map(
                (c) => {
                  ...c as Map,
                  'subtotal': 0,
                  'tax': 0,
                  'total': 0,
                  'discounts': 0,
                },
              )
              .toList();
        }
        if (partial) {
          supplied['items'] = (source['items'] as List).map((raw) {
            final row = Map<String, dynamic>.from(raw as Map);
            if (row['check_id'] == ch.id) {
              for (final key in [
                'qty',
                'quantity',
                'subtotal',
                'tax',
                'discounts',
                'total',
              ]) {
                if (row[key] is num) row[key] = (row[key] as num) / 2;
              }
            }
            return row;
          }).toList();
        }
        final repo = FixtureSales(Supabase.instance.client, current: supplied);
        activePayments = (source['payments'] as List)
            .map(
              (p) => {
                ...p as Map,
                'payment_methods': {'name': 'Efectivo', 'code': 'cash'},
              },
            )
            .toList();
        final printer = CapturePrinter(Supabase.instance.client);
        late WidgetRef widgetRef;
        late BuildContext context;
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              sessionProvider.overrideWith(Session.new),
              salesRepositoryProvider.overrideWithValue(repo),
              printingPrintersRepositoryProvider.overrideWithValue(printer),
            ],
            child: MaterialApp(
              home: Consumer(
                builder: (ctx, ref, _) {
                  widgetRef = ref;
                  context = ctx;
                  return const Scaffold(body: SizedBox());
                },
              ),
            ),
          ),
        );
        var done = false;
        final call = reprintInvoiceFromPayment(context, widgetRef, {
          'order_id': sale(source).id,
          'check_id': missing ? ch.id : 'stale-check-from-history',
          'fiscal_document_id': fd['id'],
          'ncf_number': 'REPRO-SINTETICO',
          'ncf_type_name': 'B02',
          'subtotal': fd['subtotal'],
          'itbis_amount': fd['itbis_amount'],
          'total': fd['total'],
          'table_code': 'C9',
        }).whenComplete(() => done = true);
        for (var i = 0; i < 80 && !done; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(done, true, reason: 'El flujo de reimpresión terminó');
        await call;
        if (missing || partial) {
          expect(
            printer.tickets,
            isEmpty,
            reason: 'No enviar papel si faltan los productos',
          );
          expect(find.byType(AlertDialog), findsOneWidget);
        } else {
          expect(printer.tickets.length, 1);
          final raw = printer.tickets.single;
          final totalMatch = RegExp(
            r'\bTOTAL:\s+RD\$([\d,.]+)',
          ).firstMatch(raw);
          expect(totalMatch!.group(1), '400.00');
          expect(raw, contains('Margarita'));
        }
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}

List<dynamic> activePayments = [];
Map<String, dynamic>? activeDocument;
