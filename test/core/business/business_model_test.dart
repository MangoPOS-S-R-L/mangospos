import 'package:flutter_test/flutter_test.dart';
import 'package:mangopos/core/business/business_model.dart';
import 'package:mangopos/data/repositories/pos_settings_repository.dart';

/// Tests de la clasificación retail vs restaurante (`resolveBusinessModel`).
/// Lógica pura: no toca providers ni red.
void main() {
  // Preset retail tal como lo siembra RetailProfileDefaults al registrar.
  const retailFeatures = BusinessFeatures(
    salesModeTableEnabled: false,
    kitchenEnabled: false,
  );
  // Defaults legacy: todo prendido (restaurante completo).
  const restaurantFeatures = BusinessFeatures();

  group('resolveBusinessModel', () {
    test('tipo retail explícito → retail (sin importar flags)', () {
      for (final type in const [
        'Colmado',
        'Tienda / Minimarket',
        'Licoreria',
        'Tienda de Conveniencia',
      ]) {
        expect(
          resolveBusinessModel(
            businessType: type,
            features: restaurantFeatures, // aunque los flags digan restaurante
          ),
          BusinessModel.retail,
          reason: '$type debe ser retail por tipo',
        );
      }
    });

    test('tipo restaurante conocido → restaurante (sin importar flags)', () {
      for (final type in const [
        'Restaurante',
        'Comida Rapida',
        'Bar / Lounge',
        'Cafeteria / Panaderia',
        'Food Truck',
      ]) {
        expect(
          resolveBusinessModel(
            businessType: type,
            features: retailFeatures, // aunque los flags digan retail
          ),
          BusinessModel.restaurant,
          reason: '$type debe ser restaurante por tipo',
        );
      }
    });

    test('tipo ambiguo (Otro/null) → infiere de los flags', () {
      // Sin mesas y sin cocina = retail.
      expect(
        resolveBusinessModel(
            businessType: 'Otro', features: retailFeatures),
        BusinessModel.retail,
      );
      expect(
        resolveBusinessModel(businessType: null, features: retailFeatures),
        BusinessModel.retail,
      );
      // Con mesas/cocina = restaurante.
      expect(
        resolveBusinessModel(
            businessType: 'Otro', features: restaurantFeatures),
        BusinessModel.restaurant,
      );
      expect(
        resolveBusinessModel(businessType: '', features: restaurantFeatures),
        BusinessModel.restaurant,
      );
    });

    test('ambiguo con solo cocina apagada pero mesas activas → restaurante',
        () {
      const onlyKitchenOff = BusinessFeatures(kitchenEnabled: false);
      expect(
        resolveBusinessModel(
            businessType: null, features: onlyKitchenOff),
        BusinessModel.restaurant,
      );
    });
  });

  test('helpers de BusinessModel', () {
    expect(BusinessModel.retail.isRetail, isTrue);
    expect(BusinessModel.retail.isRestaurant, isFalse);
    expect(BusinessModel.restaurant.label, 'Restaurante');
    expect(BusinessModel.retail.label, 'Retail');
  });
}
