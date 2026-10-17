import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mangopos/core/network/connectivity_service.dart';
import 'package:mangopos/core/printing/printerless_mode.dart';
import 'package:mangopos/data/models/order_item_tax_line.dart';
import 'package:mangopos/data/models/printing.dart';
import 'package:mangopos/data/models/sales_models.dart';
import 'package:mangopos/data/repositories/printing_repository.dart';
import 'package:mangopos/data/repositories/sales_repository.dart';
import 'package:mangopos/presentation/cashier/utils/invoice_reprint.dart';
import 'package:mangopos/presentation/sales/viewmodel/sales_viewmodel.dart';
import 'package:mangopos/presentation/settings/more settings/printing/printers/viewmodel/printers_viewmodel.dart';
import 'package:mangopos/services/session/session_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _businessId = 'b0000000-0000-0000-0000-000000000001';
const _orderId = 'order-mixed';
const _documentId = 'fiscal-mixed';
final _issuedAt = DateTime.utc(2026, 10, 17, 16);

class _Session extends SessionController {
  @override
  SessionState build() => const SessionState(
    activeBusinessId: _businessId,
    permissions: {'pagos.reimprimir_recibo'},
  );
}

class _FullOrderSales extends SalesRepository {
  _FullOrderSales(super.client, {this.orderOverride, this.itemOverride});

  final Order? orderOverride;
  final List<OrderItem>? itemOverride;

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
    order:
        orderOverride ??
        Order(
          id: _orderId,
          sessionId: 'session-mixed',
          status: 'paid',
          subtotal: 3320.31,
          discounts: 0,
          serviceFee: 0,
          tax: 929.69,
          total: 4250,
          createdAt: _issuedAt,
        ),
    // El detalle activo excluye productos pagados. Reimprimir debe cargar
    // el historial completo con getAllOrderItems, también en un cobro mixto.
    items: const <OrderItem>[],
    checks: const <OrderCheck>[],
    customerId: null,
    customerName: null,
    note: null,
  );

  @override
  Future<List<OrderItem>> getAllOrderItems(
    String orderId, {
    String? businessId,
  }) async =>
      itemOverride ??
      [
        OrderItem(
          id: 'item-mixed',
          orderId: _orderId,
          productName: 'Consumo de prueba',
          quantity: 1,
          unitPrice: 4250,
          subtotal: 3320.31,
          discounts: 0,
          tax: 929.69,
          total: 4250,
          isTakeout: false,
          status: 'paid',
          taxMode: 'inclusive',
          taxRate: 28,
          createdAt: _issuedAt,
          taxLines: [
            OrderItemTaxLine(
              id: 'item-itbis',
              orderItemId: 'item-mixed',
              taxId: 'itbis',
              taxName: 'ITBIS',
              taxRate: 18,
              amount: 597.66,
              createdAt: _issuedAt,
            ),
            OrderItemTaxLine(
              id: 'item-service',
              orderItemId: 'item-mixed',
              taxId: 'service',
              taxName: 'LEY',
              taxRate: 10,
              amount: 332.03,
              createdAt: _issuedAt,
            ),
          ],
        ),
      ];
}

class _CapturePrinter extends PrintingRepository {
  _CapturePrinter(super.client);

  final tickets = <String>[];

  @override
  Future<PrinterConfig?> getAssignedPrinterForType({
    required String businessId,
    required List<String> preferredAreaCodes,
    bool printsOrders = false,
    bool printsPrebills = false,
    bool printsReceipts = false,
  }) async => PrinterConfig(
    id: 'receipt-printer',
    businessId: _businessId,
    name: 'Impresora de prueba',
    type: 'network',
    isActive: true,
    createdAt: _issuedAt,
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
    tickets.add(latin1.decode(data, allowInvalid: true));
    return PrintOutcome.directSuccess;
  }
}

Map<String, dynamic> _document({bool prorated = false}) => {
  'id': _documentId,
  'business_id': _businessId,
  'order_id': _orderId,
  'check_id': null,
  'ncf_number': 'B0100000012',
  'ncf_type': 'B01',
  'customer_name': 'Cliente de prueba',
  'status': 'active',
  'subtotal': prorated ? 1660.16 : 3320.31,
  'itbis_amount': prorated ? 298.83 : 597.66,
  'service_fee': prorated ? 166.01 : 332.03,
  'total': prorated ? 2125.0 : 4250.0,
  'issued_at': _issuedAt.toIso8601String(),
};

Map<String, dynamic> _payment(
  String code,
  String name,
  double amount, {
  double change = 0,
}) => {
  'id': 'payment-$code',
  'business_id': _businessId,
  'order_id': _orderId,
  'check_id': null,
  'fiscal_document_id': _documentId,
  'payment_method_id': code,
  'payment_methods': {'code': code, 'name': name},
  'amount': amount,
  'change_amount': change,
  'status': 'completed',
  'created_at': _issuedAt.toIso8601String(),
};

late Map<String, dynamic> _activeDocument;
List<Map<String, dynamic>> _activePayments = [];
Order? _activeOrder;
List<OrderItem>? _activeItems;

Future<_CapturePrinter> _reprint(WidgetTester tester) async {
  final client = Supabase.instance.client;
  final printer = _CapturePrinter(client);
  late WidgetRef widgetRef;
  late BuildContext context;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sessionProvider.overrideWith(_Session.new),
        salesRepositoryProvider.overrideWithValue(
          _FullOrderSales(
            client,
            orderOverride: _activeOrder,
            itemOverride: _activeItems,
          ),
        ),
        printingPrintersRepositoryProvider.overrideWithValue(printer),
      ],
      child: MaterialApp(
        home: Consumer(
          builder: (ctx, ref, _) {
            context = ctx;
            widgetRef = ref;
            return const Scaffold(body: SizedBox());
          },
        ),
      ),
    ),
  );
  var finished = false;
  final printing = reprintInvoiceFromPayment(context, widgetRef, {
    'order_id': _orderId,
    'fiscal_document_id': _documentId,
    'ncf_number': 'B0100000012',
    'table_code': 'MESA82',
  }).whenComplete(() => finished = true);
  for (var i = 0; i < 80 && !finished; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(finished, isTrue, reason: 'La reimpresión debe terminar');
  await printing;
  await tester.pump();
  return printer;
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
      httpClient: MockClient((request) async {
        Object? response = [];
        final path = request.url.path;
        if (path.endsWith('/fiscal_documents')) {
          response = request.url.queryParameters.containsKey('id')
              ? _activeDocument
              : [_activeDocument];
        } else if (path.endsWith('/payments')) {
          response = _activePayments;
        } else if (path.endsWith('/businesses')) {
          response = {'id': _businessId, 'name': 'Negocio de prueba'};
        } else if (path.endsWith('/business_settings')) {
          response = {'invoice_print_template': 'standard'};
        }
        return http.Response(
          jsonEncode(response),
          200,
          headers: {'content-type': 'application/json'},
          request: request,
        );
      }),
    );
  });

  setUp(() {
    _activeDocument = _document();
    _activePayments = [];
    _activeOrder = null;
    _activeItems = null;
  });

  tearDownAll(() async {
    await Supabase.instance.dispose();
  });

  testWidgets('reimprime efectivo, tarjeta y transferencia con ITBIS y ley', (
    tester,
  ) async {
    _activePayments = [
      _payment('cash', 'Efectivo', 1000),
      _payment('card', 'Tarjeta', 2000),
      _payment('transfer', 'Transferencia', 1250),
    ];
    final printer = await _reprint(tester);
    expect(find.byType(AlertDialog), findsNothing);
    expect(printer.tickets, hasLength(1));
    final ticket = printer.tickets.single;
    expect(ticket, contains('Consumo de prueba'));
    expect(ticket, contains('B0100000012'));
    expect(ticket, contains('RD\$4,250.00'));
    expect(ticket, contains('EFECTIVO'));
    expect(ticket, contains('TARJETA'));
    expect(ticket, contains('TRANSFERENCIA'));
    expect(ticket, contains('597.66'));
    expect(ticket, contains('332.03'));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('reimprime efectivo y tarjeta conservando el cambio', (
    tester,
  ) async {
    _activePayments = [
      _payment('cash', 'Efectivo', 2500, change: 250),
      _payment('card', 'Tarjeta', 2000),
    ];
    final printer = await _reprint(tester);
    expect(find.byType(AlertDialog), findsNothing);
    expect(printer.tickets, hasLength(1));
    final ticket = printer.tickets.single;
    expect(ticket, contains('RD\$4,250.00'));
    expect(ticket, contains('RD\$2,500.00'));
    expect(ticket, contains('RD\$2,000.00'));
    expect(ticket, contains('CAMBIO:'));
    expect(ticket, contains('RD\$250.00'));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'B0100000012 reimprime descuento fiscal real con discount cero y orden saldada',
    (tester) async {
      // Importes exactos del comprobante que fallaba al reimprimir. El
      // documento fiscal mantiene discount=0 por defecto, pero sus
      // componentes emitidos sí reflejan las cinco ofertas de RD$250.
      _activeDocument = {
        ..._document(),
        'subtotal': 4296.88,
        'itbis_amount': 773.46,
        'service_fee': 429.67,
        'discount': 0,
        'total': 4250,
      };
      _activeOrder = Order(
        id: _orderId,
        sessionId: 'session-mixed',
        status: 'paid',
        subtotal: 0,
        discounts: 0,
        serviceFee: 0,
        tax: 0,
        total: 0,
        createdAt: _issuedAt,
      );
      _activeItems = List.generate(6, (index) {
        final offer = index > 0;
        return OrderItem(
          id: 'original-item-$index',
          orderId: _orderId,
          productName: 'Producto ${index + 1}',
          quantity: offer ? 4 : 2,
          unitPrice: 250,
          subtotal: offer ? 781.25 : 390.625,
          discounts: offer ? 250 : 0,
          tax: offer ? 218.75 : 109.375,
          total: offer ? 750 : 500,
          isTakeout: false,
          status: 'paid',
          taxMode: 'inclusive',
          taxRate: 28,
          createdAt: _issuedAt,
        );
      });
      _activePayments = [
        _payment('cash', 'Efectivo', 1000),
        _payment('card', 'Tarjeta', 1000),
        _payment('transfer', 'Transferencia', 2250),
      ];
      final printer = await _reprint(tester);
      expect(find.byType(AlertDialog), findsNothing);
      expect(printer.tickets, hasLength(1));
      final ticket = printer.tickets.single;
      expect(
        RegExp(r'\bTOTAL:\s+RD\$([\d,.]+)').firstMatch(ticket)?.group(1),
        '4,250.00',
      );
      expect(ticket, contains('B0100000012'));
      for (var i = 1; i <= 6; i++) {
        expect(ticket, contains('Producto $i'));
      }
      expect(ticket, contains('EFECTIVO'));
      expect(ticket, contains('TARJETA'));
      expect(ticket, contains('TRANSFERENCIA'));
      expect(ticket, contains('773.46'));
      expect(ticket, contains('429.67'));
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('reimprime el mismo comprobante con tarjeta como único método', (
    tester,
  ) async {
    _activePayments = [_payment('card', 'Tarjeta', 4250)];
    final printer = await _reprint(tester);
    expect(find.byType(AlertDialog), findsNothing);
    expect(printer.tickets, hasLength(1));
    expect(printer.tickets.single, contains('TARJETA'));
    expect(printer.tickets.single, contains('RD\$4,250.00'));
    expect(printer.tickets.single, isNot(contains('CAMBIO:')));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('bloquea un fiscal histórico prorrateado sin enviar papel', (
    tester,
  ) async {
    // El documento antiguo contiene solo la mitad del consumo, aunque el
    // scope full-order y los productos originales conservan RD$4,250.
    // El método mixto no autoriza inventar el desglose de ese comprobante.
    _activeDocument = _document(prorated: true);
    _activePayments = [
      _payment('cash', 'Efectivo', 2125),
      _payment('card', 'Tarjeta', 2125),
    ];
    final printer = await _reprint(tester);
    expect(printer.tickets, isEmpty);
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
