import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/data/repositories/pos_settings_repository.dart';

void main() {
  group('Configuración del ciclo de notas de venta', () {
    test('las columnas ausentes usan tres notas y contador cero', () {
      final features = BusinessFeatures.fromMap({});
      expect(features.salesNoteLimit, 3);
      expect(features.salesNoteCount, 0);
    });

    test('un servidor sin el ciclo no habilita notas sin límite', () {
      for (final map in <Map<String, dynamic>>[
        {'sales_note_enabled': true},
        {'sales_note_enabled': true, 'sales_note_limit': 3},
        {'sales_note_enabled': true, 'sales_note_count': 0},
      ]) {
        expect(BusinessFeatures.fromMap(map).salesNoteEnabled, isFalse);
      }
      expect(
        BusinessFeatures.fromMap({
          'sales_note_enabled': true,
          'sales_note_limit': 3,
          'sales_note_count': 0,
        }).salesNoteEnabled,
        isTrue,
      );
    });

    test('lee el límite y contador persistidos', () {
      final features = BusinessFeatures.fromMap({
        'sales_note_limit': '5',
        'sales_note_count': 2,
      });
      expect(features.salesNoteLimit, 5);
      expect(features.salesNoteCount, 2);
    });

    test('descarta cantidades inválidas del servidor', () {
      for (final invalid in [null, '', 'abc', 0, -1, 2.5]) {
        expect(
          BusinessFeatures.fromMap({
            'sales_note_limit': invalid,
          }).salesNoteLimit,
          3,
        );
      }
      for (final invalid in [null, '', 'abc', -1, 2.5]) {
        expect(
          BusinessFeatures.fromMap({
            'sales_note_count': invalid,
          }).salesNoteCount,
          0,
        );
      }
    });

    test('guardar otro ajuste conserva el ciclo vigente', () {
      const features = BusinessFeatures(salesNoteLimit: 5, salesNoteCount: 2);
      final next = features.copyWith(salesNotePrefix: 'NOTA-');
      expect(next.salesNoteLimit, 5);
      expect(next.salesNoteCount, 2);
      expect(next.salesNotePrefix, 'NOTA-');
    });

    test('cambiar límite no reinicia el contador', () {
      const features = BusinessFeatures(salesNoteLimit: 3, salesNoteCount: 2);
      final next = features.copyWith(salesNoteLimit: 5);
      expect(next.salesNoteLimit, 5);
      expect(next.salesNoteCount, 2);
    });
  });
}
