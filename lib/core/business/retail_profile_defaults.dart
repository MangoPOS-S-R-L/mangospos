import 'package:mangopos/data/repositories/pos_settings_repository.dart';

/// Mapea `businesses.business_type` a un preset de [BusinessFeatures] para los
/// verticales **retail** (PRD de extensión Retail, fase R0).
///
/// La app lo usa al registrar un negocio: si el tipo es retail, siembra el
/// preset en `business_settings` (best-effort) para que el POS abra en modo
/// mostrador — sin mesas ni cocina, con escaneo e inventario básico. Los tipos
/// no-retail (restaurante y derivados) devuelven `null`: conservan los defaults
/// legacy (todo prendido), sin escribir fila.
///
/// El preset es solo un punto de partida: el dueño puede ajustar cada flag
/// luego en Ajustes (no es retroactivo a negocios ya creados).
///
/// Los flags específicos por vertical (control de edad, balanza, fiado,
/// multi-precio) llegan en fases posteriores (R2–R5) con sus columnas; por eso
/// hoy los tres verticales comparten el mismo "retail core".
class RetailProfileDefaults {
  const RetailProfileDefaults._();

  /// dbValues de `business_type` considerados retail. Incluye el legacy
  /// 'Tienda de Conveniencia' además de los verticales nuevos.
  static const Set<String> retailBusinessTypes = {
    'Colmado',
    'Tienda / Minimarket',
    'Licoreria',
    'Tienda de Conveniencia',
  };

  /// `true` si [businessType] corresponde a un vertical retail.
  static bool isRetail(String? businessType) =>
      businessType != null && retailBusinessTypes.contains(businessType);

  /// Preset de flags sugerido para [businessType]. `null` si el tipo no es
  /// retail (en ese caso se conservan los defaults legacy todo-true y no se
  /// escribe fila en `business_settings`).
  static BusinessFeatures? forBusinessType(String? businessType) {
    if (!isRetail(businessType)) return null;
    // Retail core: venta de mostrador, sin mesas ni cocina, con escaneo e
    // inventario básico (tracking sin editor de recetas).
    return const BusinessFeatures(
      salesModeTableEnabled: false,
      salesModeManualEnabled: false,
      salesModeQuickEnabled: true,
      salesModeDeliveryEnabled: false,
      kitchenEnabled: false,
      barcodeEnabled: true,
      inventoryMode: InventoryMode.basic,
    );
  }
}
