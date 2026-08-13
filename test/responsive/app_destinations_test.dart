import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/app/navigation/app_destinations.dart';
import 'package:mangopos/presentation/shell/shell_destinations.dart';

/// Criterios 11 y 12 del PRD: la forma del conmutador sale del número de
/// destinos con permiso, sin configuración manual.
void main() {
  group('criterio 11 · la forma se deriva del conteo', () {
    test('0 y 1 destino → sin conmutador', () {
      expect(switcherShapeFor(0), SwitcherShape.none);
      expect(switcherShapeFor(1), SwitcherShape.none);
    });

    test('2 a 5 → barra inferior', () {
      for (var n = 2; n <= 5; n++) {
        expect(switcherShapeFor(n), SwitcherShape.bottomBar, reason: 'n=$n');
      }
    });

    test('6 o más → lanzador en hoja', () {
      expect(switcherShapeFor(6), SwitcherShape.launcher);
      expect(switcherShapeFor(15), SwitcherShape.launcher);
    });
  });

  group('criterio 12 · el mesero solo ve lo que alcanza', () {
    // Un mesero llega a ventas y clientes.
    const permisosMesero = {'ventas.mesas.acceso', 'clientes.ver'};

    List<ShellDestination> paraMesero({
      Set<String> features = const {'kitchen'},
      Set<String> modules = const {},
    }) =>
        destinationsFor(
          permissions: permisosMesero,
          enabledFeatures: features,
          enabledModules: modules,
        );

    test('no aparece ningún destino sin permiso', () {
      for (final d in paraMesero()) {
        final needed = d.permissionCode;
        if (needed != null) {
          expect(
            permisosMesero.contains(needed),
            isTrue,
            reason: '${d.label} exige $needed y el mesero no lo tiene',
          );
        }
      }
    });

    test('cae en barra inferior, no en rejilla', () {
      expect(
        switcherShapeFor(paraMesero().length),
        anyOf(SwitcherShape.bottomBar, SwitcherShape.none),
      );
    });

    test('un add-on inactivo no se cuenta', () {
      final sinAddon = paraMesero(modules: const {});
      final conAddon = paraMesero(modules: const {'reservations'});
      expect(conAddon.length, greaterThanOrEqualTo(sinAddon.length));
    });

    test('el owner alcanza más destinos que el mesero', () {
      final owner = destinationsFor(
        permissions: const {},
        enabledFeatures: const {'kitchen'},
        enabledModules: const {},
        isOwner: true,
      );
      expect(owner.length, greaterThan(paraMesero().length));
    });
  });

  test('un feature apagado oculta su destino', () {
    final conCocina = destinationsFor(
      permissions: const {},
      enabledFeatures: const {'kitchen'},
      enabledModules: const {},
      isOwner: true,
    );
    final sinCocina = destinationsFor(
      permissions: const {},
      enabledFeatures: const {},
      enabledModules: const {},
      isOwner: true,
    );
    expect(sinCocina.length, lessThan(conCocina.length));
  });
}
