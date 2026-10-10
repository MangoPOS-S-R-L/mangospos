// VM del PaymentModal (cobro a crédito desde la mesa): onServerConfirmed corre
// en cuanto el servidor confirma el pago, antes de buscar el comprobante y de
// la espera del e-CF (hasta ~8 s). La pantalla lo usa para la marca local de
// venta cobrada; antes solo llegaba después de esa espera. Cubre la VM; el
// paso desde el modal está en payment_modal_server_confirmed_widget_test.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mangopos/core/network/connectivity_service.dart';
import 'package:mangopos/data/models/payment_models.dart';
import 'package:mangopos/data/models/sales_models.dart';
import 'package:mangopos/data/repositories/cashier_repository.dart';
import 'package:mangopos/data/repositories/sales_repository.dart';
import 'package:mangopos/presentation/payments/state/payment_state.dart';
import 'package:mangopos/presentation/payments/viewmodel/payment_viewmodel.dart';
import 'package:mangopos/presentation/sales/state/sales_state.dart';
import 'package:mangopos/presentation/sales/viewmodel/sales_viewmodel.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _Sales extends SalesViewModel {
  @override
  CurrentOrderState build() => const CurrentOrderState();
}

class _Repository extends SalesRepository {
  _Repository(super.client, this.events);
  final List<String> events;

  @override
  Future<Payment> processPayment({
    required String orderId,
    String? checkId,
    required String paymentMethodId,
    required double amount,
    String? reference,
    String? customerId,
    String? customerRnc,
    String? fiscalType,
    String? cashierSessionId,
    double changeAmount = 0,
    bool closeOrder = true,
    bool closeCheck = true,
    int splitSequence = 0,
    DateTime? paidAt,
    String? offlineNcf,
  }) async {
    events.add('servidor');
    return Payment(
      id: 'payment-1',
      businessId: 'biz',
      orderId: orderId,
      checkId: checkId,
      paymentMethodId: paymentMethodId,
      amount: amount,
      changeAmount: changeAmount,
      status: 'completed',
      createdAt: DateTime(2026, 10, 10),
    );
  }

  @override
  Future<FiscalDocument?> getFiscalDocumentForScope({
    required String orderId,
    String? checkId,
  }) async {
    events.add('comprobante');
    return null;
  }
}

class _PaymentViewModel extends PaymentViewModel {
  _PaymentViewModel(SupabaseClient client, Ref ref, List<String> events)
    : super(CashierRepository(client), _Repository(client, events), ref);

  void seed(PaymentState value) => state = value;
  PaymentState get snapshot => state;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'http://localhost:54321',
      publishableKey: 'test',
      httpClient: MockClient(
        (request) async => http.Response(
          '[]',
          200,
          request: request,
          headers: {'content-type': 'application/json'},
        ),
      ),
    );
  });
  tearDownAll(() => Supabase.instance.dispose());

  test('onServerConfirmed corre al confirmar el servidor, antes del '
      'comprobante', () async {
    ConnectivityService().simulateReconnect();
    final events = <String>[];
    final container = ProviderContainer(
      overrides: [currentOrderProvider.overrideWith(_Sales.new)],
    );
    addTearDown(container.dispose);
    final provider = Provider<_PaymentViewModel>((ref) {
      final vm = _PaymentViewModel(Supabase.instance.client, ref, events);
      ref.onDispose(vm.dispose);
      return vm;
    });
    final vm = container.read(provider);
    vm.seed(
      PaymentState(
        order: Order(
          id: 'order-Q',
          sessionId: 'session-Q',
          status: 'open',
          subtotal: 100,
          discounts: 0,
          serviceFee: 0,
          tax: 0,
          total: 100,
          createdAt: DateTime(2026, 10, 10),
        ),
        totalToPay: 100,
        amountReceived: 100,
        selectedMethod: const PaymentMethod(
          id: 'cash',
          businessId: 'biz',
          name: 'Efectivo',
          code: 'cash',
          isActive: true,
          requiresReference: false,
          position: 0,
        ),
      ),
    );

    Payment? confirmed;
    await vm.processPayment(
      onServerConfirmed: (payment) async {
        events.add('marca');
        confirmed = payment;
      },
    );

    expect(events, ['servidor', 'marca', 'comprobante']);
    expect(confirmed?.id, 'payment-1');
    expect(vm.snapshot.paymentProcessed, isTrue);
  });
}
