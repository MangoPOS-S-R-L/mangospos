// NOTA DE VENTA: elección en el cobro y lectura del flag del negocio.
//
// Lo que estas pruebas fijan:
//
//  1. LOS DOS DOCUMENTOS SON EXCLUYENTES. Elegir nota de venta tiene que
//     apagar el NCF seleccionado y viceversa. Si los dos quedan vivos, el
//     cobro manda `requested_ncf_type` con la marca de nota puesta y la
//     venta termina quemando un NCF que nadie pidió.
//
//  2. LA NOTA NUNCA EXIGE RNC. No ampara crédito fiscal, así que el gate de
//     comprador que bloquea el botón de cobrar en B01/E31 no aplica.
//
//  3. EL FLAG DEGRADA SOLO. Un servidor sin la migración no devuelve las
//     columnas nuevas: la feature tiene que quedar apagada, no romperse.

import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/data/models/sales_note.dart';
import 'package:mangopos/data/repositories/pos_settings_repository.dart';
import 'package:mangopos/presentation/payments/state/payment_state.dart';

void main() {
  group('Selección de documento en el cobro', () {
    test('elegir nota de venta apaga el NCF seleccionado', () {
      const conNcf = PaymentState(
        availableNcfTypes: ['B02', 'E31'],
        selectedNcfType: 'B02',
        salesNoteAvailable: true,
      );

      final conNota = conNcf.copyWith(
        salesNoteSelected: true,
        clearNcfType: true,
      );

      expect(conNota.salesNoteSelected, isTrue);
      expect(conNota.selectedNcfType, isNull);
    });

    test('elegir un NCF apaga la nota de venta', () {
      const conNota = PaymentState(
        availableNcfTypes: ['B02'],
        salesNoteAvailable: true,
        salesNoteSelected: true,
      );

      final conNcf = conNota.copyWith(
        selectedNcfType: 'B02',
        salesNoteSelected: false,
      );

      expect(conNcf.salesNoteSelected, isFalse);
      expect(conNcf.selectedNcfType, equals('B02'));
    });

    test(
      'la nota de venta no exige RNC aunque quede un tipo que sí lo pide',
      () {
        // Caso real del bug que esto previene: el cajero elige B01 (crédito
        // fiscal, exige RNC), se arrepiente y pasa a nota de venta. Si el gate
        // siguiera mirando el NCF viejo, el botón de cobrar quedaría bloqueado
        // pidiendo un RNC que la nota no necesita.
        const state = PaymentState(
          selectedNcfType: 'B01',
          salesNoteAvailable: true,
          salesNoteSelected: true,
        );

        expect(state.requiresCustomerRnc, isFalse);
      },
    );

    test('sin nota seleccionada, el gate de RNC sigue igual que antes', () {
      const state = PaymentState(selectedNcfType: 'B01');

      expect(state.requiresCustomerRnc, isTrue);
    });

    test('copyWith sin clearNcfType conserva el NCF', () {
      const state = PaymentState(selectedNcfType: 'B02');

      expect(state.copyWith(reference: 'x').selectedNcfType, equals('B02'));
    });
  });

  group('Flags del negocio', () {
    test('un servidor sin la migración deja la feature apagada', () {
      final features = BusinessFeatures.fromMap({
        'sales_mode_table_enabled': true,
      });

      expect(features.salesNoteEnabled, isFalse);
      expect(features.salesNoteDefault, isFalse);
      // El prefijo nunca puede venir vacío: sin él la nota se imprimiría como
      // un número pelado, indistinguible de un número de orden.
      expect(features.salesNotePrefix, equals('NV-'));
    });

    test('lee los flags cuando la columna existe', () {
      final features = BusinessFeatures.fromMap({
        'sales_note_enabled': true,
        'sales_note_default': true,
        'sales_note_prefix': 'NOTA-',
      });

      expect(features.salesNoteEnabled, isTrue);
      expect(features.salesNoteDefault, isTrue);
      expect(features.salesNotePrefix, equals('NOTA-'));
    });

    test('cambiar un ajuste de la nota no pisa el resto de las banderas', () {
      // Importa porque `setBusinessFeatures` reescribe la fila COMPLETA de
      // business_settings: si el copyWith perdiera un campo, prender la nota
      // de venta desde Configuración fiscal apagaría cocina, inventario o los
      // modos de venta del negocio.
      const base = BusinessFeatures(
        kitchenEnabled: false,
        multimeseroEnabled: true,
        inventoryMode: InventoryMode.advanced,
        salesNotePrefix: 'NOTA-',
        deliveryFeeMin: 150,
      );

      final next = base.copyWith(salesNoteEnabled: true);

      expect(next.salesNoteEnabled, isTrue);
      expect(next.kitchenEnabled, isFalse);
      expect(next.multimeseroEnabled, isTrue);
      expect(next.inventoryMode, equals(InventoryMode.advanced));
      expect(next.salesNotePrefix, equals('NOTA-'));
      expect(next.deliveryFeeMin, equals(150));
      // Lo que no se pasa no cambia.
      expect(next.salesNoteDefault, isFalse);
    });

    test('un prefijo vacío o en blanco cae al default', () {
      expect(
        BusinessFeatures.fromMap({'sales_note_prefix': '   '}).salesNotePrefix,
        equals('NV-'),
      );
      expect(
        BusinessFeatures.fromMap({'sales_note_prefix': null}).salesNotePrefix,
        equals('NV-'),
      );
    });
  });

  group('Modelo de la nota', () {
    test('parsea la fila del servidor', () {
      final note = SalesNote.fromMap({
        'id': 'note-1',
        'business_id': 'biz-1',
        'order_id': 'order-1',
        'check_id': null,
        'note_number': 'NV-000123',
        'customer_name': 'Juan Perez',
        'subtotal': '1000.00',
        'tax': 180,
        'total': '1180.00',
        'status': 'active',
        'issued_at': '2026-09-10T16:00:00Z',
      });

      expect(note.noteNumber, equals('NV-000123'));
      expect(note.total, equals(1180.0));
      expect(note.tax, equals(180.0));
      expect(note.isActive, isTrue);
    });

    test('sin cliente cae a Consumidor Final', () {
      final note = SalesNote.fromMap({
        'id': 'note-1',
        'business_id': 'biz-1',
        'order_id': 'order-1',
        'note_number': 'NV-000124',
        'customer_name': '',
      });

      expect(note.customerName, equals('Consumidor Final'));
    });
  });
}
