import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/data/repositories/table_deposit_repository.dart';
import 'package:mangopos/presentation/sales/viewmodel/payment_split_viewmodel.dart';

PaymentTransaction _tx(PaymentMethodType method, double amount) =>
    PaymentTransaction(
      id: '${method.name}-$amount',
      method: method,
      amount: amount,
      timestamp: DateTime(2026, 9, 17),
    );

TableDepositAccount _account(double balance, {String? holder}) =>
    TableDepositAccount(
      tableId: 'mesa-vip-1',
      balance: balance,
      holderName: holder,
    );

void main() {
  // El caso que pidió el negocio: la mesa VIP abona 10,000 al llegar. Cada
  // factura de la noche descuenta de ahí y el ticket dice con cuánto quedó.
  // Cuando el consumo pasa del saldo, la diferencia se cobra aparte.
  group('saldo de mesa dentro del cobro', () {
    test('sin saldo el método no se ofrece: el cobro es el de siempre', () {
      const state = PaymentSplitState(totalAmount: 1000);

      expect(state.hasTableDeposit, isFalse);
      expect(state.depositAvailable, 0);
      expect(state.depositShortfall, 0);
    });

    test('mesa sin abono (cuenta en cero) tampoco ofrece el método', () {
      final state = PaymentSplitState(
        totalAmount: 1000,
        tableDeposit: _account(0),
      );

      expect(state.hasTableDeposit, isFalse);
    });

    test('consumo de 1,000 sobre un abono de 10,000: alcanza completo', () {
      final state = PaymentSplitState(
        totalAmount: 1000,
        tableDeposit: _account(10000, holder: 'Juan Pérez'),
      );

      expect(state.hasTableDeposit, isTrue);
      expect(state.depositAvailable, 10000);
      // El saldo cubre todo: no hay diferencia que cobrar aparte.
      expect(state.depositShortfall, 0);
    });

    test('lo ya apartado en este cobro no se puede volver a apartar', () {
      final state = PaymentSplitState(
        totalAmount: 1000,
        tableDeposit: _account(10000),
        transactions: [_tx(PaymentMethodType.tableDeposit, 400)],
      );

      expect(state.depositApplied, 400);
      expect(state.depositAvailable, 9600);
    });

    test(
      'consumo de 9,500 con 9,000 de saldo: faltan 500 por otro método',
      () {
        final state = PaymentSplitState(
          totalAmount: 9500,
          tableDeposit: _account(9000),
        );

        expect(state.depositAvailable, 9000);
        expect(state.depositShortfall, 500);

        // Así queda el cobro mixto: 9,000 del saldo + 500 en efectivo.
        final mixed = PaymentSplitState(
          totalAmount: 9500,
          tableDeposit: _account(9000),
          transactions: [
            _tx(PaymentMethodType.tableDeposit, 9000),
            _tx(PaymentMethodType.cash, 500),
          ],
        );

        expect(mixed.totalPaid, 9500);
        expect(mixed.isComplete, isTrue);
        expect(mixed.remaining, 0);
        expect(mixed.change, 0);
        // El saldo quedó agotado: no se puede apartar más.
        expect(mixed.depositAvailable, 0);
        expect(mixed.hasTableDeposit, isFalse);
      },
    );

    test('el saldo no es dinero nuevo: no genera vuelto', () {
      // El saldo nunca se agrega por encima de lo pendiente (lo bloquea
      // addTransaction), así que el cambio sale solo del efectivo.
      final state = PaymentSplitState(
        totalAmount: 1000,
        tableDeposit: _account(10000),
        transactions: [
          _tx(PaymentMethodType.tableDeposit, 800),
          _tx(PaymentMethodType.cash, 300),
        ],
      );

      expect(state.change, closeTo(100, 0.001));
      expect(state.depositApplied, 800);
    });

    test('el abono etiquetado se distingue en la lista de pagos', () {
      expect(
        _tx(PaymentMethodType.tableDeposit, 9000).methodLabel,
        'Saldo de mesa',
      );
    });
  });

  group('errores del saldo traducidos para el cajero', () {
    test('saldo insuficiente explica que no alcanza', () {
      expect(
        TableDepositRepository.friendlyError(
          Exception('PostgrestException: TABLE_DEPOSIT_INSUFFICIENT'),
        ),
        contains('saldo suficiente'),
      );
    });

    test('venta sin mesa explica por qué no aplica', () {
      expect(
        TableDepositRepository.friendlyError(
          Exception('TABLE_DEPOSIT_NO_TABLE'),
        ),
        contains('no tiene mesa'),
      );
    });

    test('cajera intentando abonar recibe el porqué, no un error genérico', () {
      final msg = TableDepositRepository.friendlyError(
        Exception('PostgrestException: DEPOSIT_OWNER_ADMIN_ONLY'),
      );
      // Dice quién puede cargarlo...
      expect(msg, contains('administrador'));
      // ...y aclara que cobrar contra el saldo sí es de la caja, para que la
      // cajera no crea que el módulo entero le está vedado.
      expect(msg, contains('Cobrar contra el saldo'));
    });

    test('sin caja abierta pide abrir caja', () {
      expect(
        TableDepositRepository.friendlyError(
          Exception('CASH_SESSION_NOT_OPEN'),
        ),
        contains('caja abierta'),
      );
    });

    test('módulo sin instalar no se reporta como error genérico', () {
      expect(
        TableDepositRepository.friendlyError(
          Exception(
            'PostgrestException(message: function '
            'public.fn_table_deposit_add does not exist, code: 42883)',
          ),
        ),
        contains('no está instalado'),
      );
    });
  });

  group('lectura del saldo', () {
    test('la cuenta vacía no se muestra como saldo disponible', () {
      expect(TableDepositAccount.empty.hasBalance, isFalse);
    });

    test('un saldo de centavos redondeado a cero no se ofrece', () {
      expect(_account(0.004).hasBalance, isFalse);
      expect(_account(0.01).hasBalance, isTrue);
    });

    test('el movimiento de consumo se lee firmado en negativo', () {
      final movement = TableDepositMovement.fromRow({
        'id': 'mov-1',
        'type': 'consumption',
        'amount': -1000,
        'balance_after': 9000,
        'created_at': '2026-09-17T22:15:00Z',
        'order_id': 'orden-1',
      });

      expect(movement.amount, -1000);
      expect(movement.balanceAfter, 9000);
      expect(movement.typeLabel, 'Consumo');
    });

    test('numeric de Postgres llega como String y se parsea igual', () {
      final movement = TableDepositMovement.fromRow({
        'id': 'mov-2',
        'type': 'deposit',
        'amount': '10000.00',
        'balance_after': '10000.00',
        'created_at': '2026-09-17T21:40:00Z',
      });

      expect(movement.amount, 10000);
      expect(movement.balanceAfter, 10000);
      expect(movement.typeLabel, 'Abono');
    });
  });
}
