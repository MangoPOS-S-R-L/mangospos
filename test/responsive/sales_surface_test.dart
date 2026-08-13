import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/theme/app_breakpoints.dart';
import 'package:mangopos/core/widgets/min_extent_grid_delegate.dart';
import 'package:mangopos/presentation/sales/layout/sales_surface.dart';

/// Criterios de aceptación 1, 2 y 5 del PRD responsive.
///
/// Son funciones puras del ancho, así que se prueban sin `WidgetTester`: por
/// eso `columnsFor`, `tileFor` y `resolve` son públicos.
void main() {
  const d = SliverGridDelegateWithMinCrossAxisExtent(
    minCrossAxisExtent: AppBreakpoints.minTile,
    mainAxisExtent: AppBreakpoints.rowProduct,
  );

  /// Ancho útil del catálogo para un ancho de pantalla dado.
  double contenido(double width) {
    final m = SalesSurfaceMetrics.resolve(width);
    return m.catalogContentWidth;
  }

  group('criterio 1 · el mosaico mide lo mismo en las dos orientaciones', () {
    test('600×1024 y 1024×600 dan el mismo mosaico y 3 columnas', () {
      final vertical = d.tileFor(contenido(600));
      final horizontal = d.tileFor(contenido(1024));

      expect((vertical - horizontal).abs(), lessThan(2));
      expect(d.columnsFor(contenido(600)), 3);
      expect(d.columnsFor(contenido(1024)), 3);
    });

    test('el ancho útil es 568 dp en las dos orientaciones', () {
      // 600 − 2×16 = 568   ·   596 − 2×14 = 568
      expect(contenido(600), 568);
      expect(contenido(1024), 568);
    });

    test('el mosaico mide 182,0 dp (anexo B del DDT)', () {
      expect(d.tileFor(contenido(600)), closeTo(182.0, 0.05));
      expect(d.tileFor(contenido(1024)), closeTo(182.0, 0.05));
    });
  });

  group('criterio 2 · ningún mosaico por debajo de su mínimo', () {
    test('barrido de 480 a 1366 dp', () {
      for (var w = 480.0; w <= 1366; w++) {
        expect(
          d.tileFor(contenido(w)),
          greaterThanOrEqualTo(AppBreakpoints.minTile),
          reason: 'el catálogo baja del mínimo a $w dp',
        );
      }
    });

    test('el delegate nunca devuelve menos de una columna', () {
      for (final w in <double>[0, 1, 40, 149, 150, 151]) {
        expect(d.columnsFor(w), greaterThanOrEqualTo(1));
      }
    });
  });

  group('criterio 5 · girar no cambia de rama', () {
    test('las dos orientaciones del equipo de referencia son tablet', () {
      expect(AppBreakpoints.isMobile(600), isFalse);
      expect(AppBreakpoints.isMobile(1024), isFalse);
    });

    test('la tablet de 7" tampoco cruza al girar', () {
      expect(AppBreakpoints.isMobile(533), isFalse);
      expect(AppBreakpoints.isMobile(853), isFalse);
    });
  });

  group('regla de superficies · anexo B del DDT', () {
    // ancho, modo, riel, comanda, catálogo, columnas
    const esperado = <List<Object>>[
      [533.0, SalesSurfaceMode.twoSurface, 0.0, 0.0, 533.0, 3],
      [600.0, SalesSurfaceMode.twoSurface, 0.0, 0.0, 600.0, 3],
      [800.0, SalesSurfaceMode.twoSurface, 0.0, 0.0, 800.0, 4],
      [1024.0, SalesSurfaceMode.threePanel, 64.0, 364.0, 596.0, 3],
      [1280.0, SalesSurfaceMode.threePanel, 88.0, 420.0, 772.0, 4],
      [1366.0, SalesSurfaceMode.threePanel, 88.0, 420.0, 858.0, 5],
    ];

    for (final fila in esperado) {
      test('${fila[0]} dp', () {
        final m = SalesSurfaceMetrics.resolve(fila[0] as double);
        expect(m.mode, fila[1]);
        expect(m.railWidth, fila[2]);
        expect(m.cartWidth, fila[3]);
        expect(m.catalogWidth, fila[4]);
        expect(d.columnsFor(m.catalogContentWidth), fila[5]);
      });
    }
  });
}
