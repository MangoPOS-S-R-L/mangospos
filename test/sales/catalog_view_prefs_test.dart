import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/presentation/sales/state/catalog_view_prefs.dart';

void main() {
  ProviderContainer makeContainer() {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    return container;
  }

  group('multiplicador de cantidad', () {
    test('arranca en 1 e inactivo', () {
      final c = makeContainer();
      expect(c.read(quantityMultiplierProvider), 1);
      expect(c.read(quantityMultiplierProvider.notifier).isActive, isFalse);
    });

    test('consume devuelve el valor armado y vuelve a 1', () {
      final c = makeContainer();
      final n = c.read(quantityMultiplierProvider.notifier);
      n.set(6);
      expect(c.read(quantityMultiplierProvider), 6);

      expect(n.consume(), 6, reason: 'el producto entra con 6 unidades');
      expect(
        c.read(quantityMultiplierProvider),
        1,
        reason: 'no debe arrastrar al siguiente producto',
      );
    });

    test('consumir dos veces seguidas no repite el multiplicador', () {
      final c = makeContainer();
      final n = c.read(quantityMultiplierProvider.notifier);
      n.set(4);

      expect(n.consume(), 4);
      expect(
        n.consume(),
        1,
        reason: 'el segundo producto va a 1: el multiplicador ya se gastó',
      );
    });

    test('se capa entre 1 y el máximo', () {
      final c = makeContainer();
      final n = c.read(quantityMultiplierProvider.notifier);

      n.set(0);
      expect(c.read(quantityMultiplierProvider), 1);

      n.set(-5);
      expect(c.read(quantityMultiplierProvider), 1);

      n.set(9999);
      expect(c.read(quantityMultiplierProvider), QuantityMultiplier.max);
    });

    test('reset apaga el multiplicador armado', () {
      final c = makeContainer();
      final n = c.read(quantityMultiplierProvider.notifier);
      n.set(12);
      expect(n.isActive, isTrue);

      n.reset();
      expect(c.read(quantityMultiplierProvider), 1);
      expect(n.isActive, isFalse);
    });
  });

  group('modo de vista del catálogo', () {
    test('arranca en mosaico', () {
      final c = makeContainer();
      expect(c.read(catalogViewModeProvider), CatalogViewMode.grid);
    });

    test('toggle alterna en los dos sentidos', () {
      final c = makeContainer();
      final n = c.read(catalogViewModeProvider.notifier);

      n.toggle();
      expect(c.read(catalogViewModeProvider), CatalogViewMode.list);

      n.toggle();
      expect(c.read(catalogViewModeProvider), CatalogViewMode.grid);
    });
  });
}
