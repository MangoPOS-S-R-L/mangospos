// PaymentModal pasa onServerConfirmed a su VM al tocar el botón de cobro: es
// lo que permite a la pantalla de ventas escribir la marca local de venta
// cobrada antes de la espera del e-CF. Si el modal vuelve a llamar
// processPayment() sin el hook, esta prueba falla.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mangopos/data/models/payment_models.dart';
import 'package:mangopos/data/models/sales_models.dart';
import 'package:mangopos/data/repositories/cashier_repository.dart';
import 'package:mangopos/data/repositories/sales_repository.dart';
import 'package:mangopos/presentation/payments/state/payment_state.dart';
import 'package:mangopos/presentation/payments/viewmodel/payment_viewmodel.dart';
import 'package:mangopos/presentation/payments/widgets/payment_modal.dart';
import 'package:mangopos/services/session/session_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

final _order = Order(
  id: 'order-quick-0001',
  sessionId: 'session-quick-0001',
  status: 'open',
  subtotal: 100,
  discounts: 0,
  serviceFee: 0,
  tax: 0,
  total: 100,
  createdAt: DateTime(2026, 10, 10),
);

const _cash = PaymentMethod(
  id: 'cash',
  businessId: 'biz',
  name: 'Efectivo',
  code: 'cash',
  isActive: true,
  requiresReference: false,
  position: 0,
);

class _Session extends SessionController {
  @override
  SessionState build() => const SessionState();
}

/// Lista para cobrar sin red; registra el hook que le pasa el modal.
class _PaymentViewModel extends PaymentViewModel {
  _PaymentViewModel(SupabaseClient client, Ref ref)
    : super(CashierRepository(client), SalesRepository(client), ref);

  final hooks = <Future<void> Function(Payment payment)?>[];

  @override
  Future<void> initializeForOrder(
    Order order, {
    String? initialMethodCode,
    String? initialCustomerId,
    String? initialCustomerName,
  }) async {
    state = PaymentState(
      order: order,
      totalToPay: order.total,
      amountReceived: order.total,
      paymentMethods: const [_cash],
      selectedMethod: _cash,
    );
  }

  @override
  Future<void> processPayment({
    Future<void> Function(Payment payment)? onServerConfirmed,
  }) async {
    hooks.add(onServerConfirmed);
  }
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

  testWidgets('el botón de cobro pasa onServerConfirmed a la VM', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    late _PaymentViewModel vm;
    Future<void> hook(Payment payment) async {}

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sessionProvider.overrideWith(_Session.new),
          paymentViewModelProvider.overrideWith(
            (ref) => vm = _PaymentViewModel(Supabase.instance.client, ref),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: PaymentModal(
              order: _order,
              onPaymentSuccess: () {},
              onServerConfirmed: hook,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final button = find.widgetWithText(ElevatedButton, 'COMPLETAR PAGO');
    expect(button, findsOneWidget);
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pump();

    expect(vm.hooks, [same(hook)]);
  });
}
