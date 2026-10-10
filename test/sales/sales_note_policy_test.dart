import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/fiscal/sales_note_policy.dart';
import 'package:mangopos/data/models/payment_models.dart';
import 'package:mangopos/data/repositories/cashier_repository.dart';
import 'package:mangopos/data/repositories/sales_repository.dart';
import 'package:mangopos/presentation/payments/state/payment_state.dart';
import 'package:mangopos/presentation/payments/viewmodel/payment_viewmodel.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _PaymentViewModel extends PaymentViewModel {
  _PaymentViewModel(Ref ref, SalesNotePolicy policy)
    : super(
        CashierRepository(SupabaseClient('http://localhost:54321', 'test')),
        SalesRepository(SupabaseClient('http://localhost:54321', 'test')),
        ref,
        salesNotePolicy: policy,
      );

  void seed(PaymentState value) => state = value;
  PaymentState get snapshot => state;
}

PaymentMethod method(String code) => PaymentMethod(
  id: code,
  businessId: 'business',
  name: code,
  code: code,
  isActive: true,
  requiresReference: false,
  position: 0,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('only cash consumer sales can use a note', () {
    const policy = SalesNotePolicy(enabled: true);
    for (final type in ['B02', 'E32', '02', '32']) {
      expect(
        policy.allowsNote(fiscalType: type, paymentMethodCodes: ['cash']),
        isTrue,
      );
      for (final codes in <List<String>>[
        [],
        ['card'],
        ['transfer'],
        ['credit'],
        ['cash', 'card'],
        ['cash', 'transfer'],
        ['unknown'],
      ]) {
        expect(
          policy.allowsNote(fiscalType: type, paymentMethodCodes: codes),
          isFalse,
        );
      }
    }
    for (final type in ['B01', 'E31', 'E33', 'B04', null]) {
      expect(
        policy.allowsNote(fiscalType: type, paymentMethodCodes: ['cash']),
        isFalse,
      );
    }
  });

  test('three notes then invoice, with configurable limits', () {
    for (final limit in [1, 3, 5]) {
      for (var count = 0; count <= limit + 1; count++) {
        final policy = SalesNotePolicy(
          enabled: true,
          notesBeforeInvoice: limit,
          currentCount: count,
        );
        expect(
          policy.shouldSelectNote(
            fiscalType: 'E32',
            paymentMethodCodes: ['cash', 'cash'],
          ),
          count < limit,
        );
      }
    }
    expect(
      const SalesNotePolicy(
        enabled: false,
      ).allowsNote(fiscalType: 'B02', paymentMethodCodes: ['cash']),
      isFalse,
    );
  });

  test('switching method or requesting credit removes note selection', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final provider = Provider<_PaymentViewModel>((ref) {
      final vm = _PaymentViewModel(ref, const SalesNotePolicy(enabled: true));
      ref.onDispose(vm.dispose);
      return vm;
    });
    final vm = container.read(provider);
    vm.seed(const PaymentState(totalToPay: 100, selectedNcfType: 'B02'));
    vm.selectPaymentMethod(method('cash'));
    expect(vm.snapshot.salesNoteSelected, isTrue);
    expect(vm.snapshot.selectedNcfType, 'B02');

    for (final code in ['card', 'transfer', 'credit']) {
      vm.selectPaymentMethod(method(code));
      expect(vm.snapshot.salesNoteAvailable, isFalse);
      expect(vm.snapshot.salesNoteSelected, isFalse);
      vm.selectSalesNote();
      expect(vm.snapshot.salesNoteSelected, isFalse);
      vm.selectPaymentMethod(method('cash'));
      expect(vm.snapshot.salesNoteSelected, isTrue);
    }
    vm.selectNcfType('E31');
    expect(vm.snapshot.salesNoteAvailable, isFalse);
    expect(vm.snapshot.salesNoteSelected, isFalse);
    expect(vm.snapshot.requiresCustomerRnc, isTrue);
    vm.selectSalesNote();
    expect(vm.snapshot.salesNoteSelected, isFalse);
  });

  test('cash payment chooses invoice after the quota', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final provider = Provider<_PaymentViewModel>((ref) {
      final vm = _PaymentViewModel(
        ref,
        const SalesNotePolicy(enabled: true, currentCount: 3),
      );
      ref.onDispose(vm.dispose);
      return vm;
    });
    final vm = container.read(provider);
    vm.seed(const PaymentState(totalToPay: 100, selectedNcfType: 'E32'));
    vm.selectPaymentMethod(method('cash'));
    vm.setExactAmount();
    expect(vm.snapshot.salesNoteAvailable, isFalse);
    expect(vm.snapshot.salesNoteSelected, isFalse);
    expect(vm.snapshot.selectedNcfType, 'E32');
    expect(vm.snapshot.canProcessPayment, isTrue);
  });

  test('document selection stays fixed while a payment is processing', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final provider = Provider<_PaymentViewModel>((ref) {
      final vm = _PaymentViewModel(ref, const SalesNotePolicy(enabled: true));
      ref.onDispose(vm.dispose);
      return vm;
    });
    final vm = container.read(provider);
    vm.seed(
      PaymentState(
        selectedNcfType: 'B02',
        selectedMethod: method('cash'),
        salesNoteAvailable: true,
        salesNoteSelected: true,
        processingPayment: true,
      ),
    );
    vm.selectPaymentMethod(method('card'));
    vm.selectNcfType('E31');
    expect(vm.snapshot.selectedMethod!.isCash, isTrue);
    expect(vm.snapshot.selectedNcfType, 'B02');
    expect(vm.snapshot.salesNoteSelected, isTrue);
  });
}
