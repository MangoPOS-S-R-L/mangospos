// Ajustes → Modos de negocio.
//
// Permite al admin prender/apagar módulos del POS según el tipo de
// negocio:
//   - Modos de venta visibles en el sidebar (por zona, manual, rápida,
//     delivery).
//   - "Enviar a cocina" — apaga el botón y auto-marca items ready al
//     cobrar. Para tiendas/kioskos sin preparación.
//   - Códigos de barras — esconde el campo en el formulario de
//     producto y el escáner en el POS.
//
// Default: todo prendido. Cualquier cambio se guarda con upsert
// atómico (todas las flags juntas) para evitar estado parcial si dos
// admins editan al mismo tiempo.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:mangopos/app/router/routes.dart';
import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/core/business/business_features_provider.dart';
import 'package:mangopos/core/business/business_resolver.dart';
import 'package:mangopos/data/repositories/inventory_repository.dart';
import 'package:mangopos/data/repositories/pos_settings_repository.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class BusinessFeaturesView extends ConsumerStatefulWidget {
  const BusinessFeaturesView({super.key, this.businessId = 'auto'});

  final String businessId;

  @override
  ConsumerState<BusinessFeaturesView> createState() =>
      _BusinessFeaturesViewState();
}

class _BusinessFeaturesViewState extends ConsumerState<BusinessFeaturesView> {
  String? _resolvedBusinessId;
  BusinessFeatures _features = BusinessFeatures.defaults;
  bool _loading = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    Future.microtask(_load);
  }

  Future<void> _load() async {
    try {
      final id = await BusinessResolver.ensure(widget.businessId);
      final repo = ref.read(posSettingsRepositoryProvider);
      final features = await repo.getBusinessFeatures(id);
      if (!mounted) return;
      setState(() {
        _resolvedBusinessId = id;
        _features = features;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'No se pudo cargar la configuración: $e';
        _loading = false;
      });
    }
  }

  /// Crea inventory_items + recetas 1:1 + ingredients (qty=1) para
  /// cada menu_item activo del negocio. Idempotente — re-ejecutarlo
  /// no duplica. Lo invocamos cuando el admin pasa de `none` a `basic`
  /// para que el flujo de descuento de stock funcione al instante.
  Future<void> _bootstrapBasicInventory() async {
    if (_resolvedBusinessId == null) return;
    try {
      final repo = InventoryRepository(Supabase.instance.client);
      final result = await repo.bootstrapMenuToInventoryLinks(
        _resolvedBusinessId!,
      );
      if (!mounted) return;
      final itemsCreated = (result['items_created'] as num?)?.toInt() ?? 0;
      final recipesCreated =
          (result['recipes_created'] as num?)?.toInt() ?? 0;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: MangoColors.successGreen,
          duration: const Duration(seconds: 4),
          content: Text(
            'Inventario básico activado. Se crearon $itemsCreated '
            'producto(s) inventariables y $recipesCreated receta(s) '
            'automáticas (cardinalidad 1).',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: const Color(0xFFEF4444),
          content: Text(
            'No se pudo inicializar el inventario: $e. Puedes correrlo '
            'manualmente desde Inventario → Bootstrap.',
          ),
        ),
      );
    }
  }

  Future<void> _update(BusinessFeatures next) async {
    if (_saving || _resolvedBusinessId == null) return;
    final previous = _features;
    setState(() {
      _features = next;
      _saving = true;
      _error = null;
    });
    try {
      await ref
          .read(posSettingsRepositoryProvider)
          .setBusinessFeatures(
            businessId: _resolvedBusinessId!,
            features: next,
          );
      // Invalidar el provider global para que el resto del POS reflecte
      // el cambio al instante (sin recargar la app).
      ref.invalidate(businessFeaturesProvider);
      if (!mounted) return;
      setState(() => _saving = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _features = previous;
        _saving = false;
        _error = 'No se pudo guardar: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF7F7F7),
      body: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextButton.icon(
              style: TextButton.styleFrom(
                foregroundColor: MangoColors.darkGray,
                padding: const EdgeInsets.symmetric(horizontal: 0),
              ),
              onPressed: () => context.go(AppRoutes.settings),
              icon: const Icon(Icons.arrow_back),
              label: const Text('Regresar'),
            ),
            const SizedBox(height: 12),
            const Text(
              'Modos de negocio',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w800,
                color: MangoColors.darkGray,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              'Activa o desactiva módulos según cómo opera tu negocio. '
              'Lo que apagues desaparece del menú del cajero.',
              style: TextStyle(fontSize: 13, color: MangoColors.muted),
            ),
            const SizedBox(height: 20),

            if (_loading)
              const Center(
                child: CircularProgressIndicator(
                  valueColor:
                      AlwaysStoppedAnimation(MangoColors.primaryOrange),
                ),
              )
            else
              Expanded(
                child: ListView(
                  children: [
                    _Section(title: 'Modos de venta'),
                    _FlagTile(
                      icon: Icons.grid_view_rounded,
                      label: 'Por zona (mesas)',
                      subtitle: 'Restaurantes con servicio de mesa.',
                      value: _features.salesModeTableEnabled,
                      onChanged: (v) => _update(
                        _features.copyWith(salesModeTableEnabled: v),
                      ),
                    ),
                    _FlagTile(
                      icon: Icons.description_outlined,
                      label: 'Venta manual',
                      subtitle: 'Crear órdenes sin asignar mesa.',
                      value: _features.salesModeManualEnabled,
                      onChanged: (v) => _update(
                        _features.copyWith(salesModeManualEnabled: v),
                      ),
                    ),
                    _FlagTile(
                      icon: Icons.bolt_rounded,
                      label: 'Venta rápida',
                      subtitle:
                          'POS de mostrador: producto → carrito → cobrar.',
                      value: _features.salesModeQuickEnabled,
                      onChanged: (v) => _update(
                        _features.copyWith(salesModeQuickEnabled: v),
                      ),
                    ),
                    _FlagTile(
                      icon: Icons.local_shipping_outlined,
                      label: 'Delivery',
                      subtitle:
                          'Pedidos para entrega — Uber Eats, PedidosYa, propio.',
                      value: _features.salesModeDeliveryEnabled,
                      onChanged: (v) => _update(
                        _features.copyWith(salesModeDeliveryEnabled: v),
                      ),
                    ),

                    const SizedBox(height: 20),
                    _Section(title: 'Operación'),
                    _FlagTile(
                      icon: Icons.restaurant_menu,
                      label: 'Enviar a cocina',
                      subtitle:
                          'Si está apagado, los items se marcan listos al cobrar '
                          'y no se imprime comanda. Para tiendas / barberías / '
                          'minimarkets donde no hay preparación.',
                      value: _features.kitchenEnabled,
                      onChanged: (v) => _update(
                        _features.copyWith(kitchenEnabled: v),
                      ),
                    ),
                    _FlagTile(
                      icon: Icons.qr_code_2,
                      label: 'Código de barras',
                      subtitle:
                          'Habilita el campo de código de barras en el formulario '
                          'de producto y el escáner en el POS.',
                      value: _features.barcodeEnabled,
                      onChanged: (v) => _update(
                        _features.copyWith(barcodeEnabled: v),
                      ),
                    ),

                    const SizedBox(height: 20),
                    _Section(title: 'Inventario'),
                    _InventoryModeSelector(
                      selected: _features.inventoryMode,
                      onChanged: (mode) async {
                        final previousMode = _features.inventoryMode;
                        await _update(
                          _features.copyWith(inventoryMode: mode),
                        );
                        // Auto-bootstrap si el admin acaba de activar
                        // "básico" desde none. Crea inventory_items +
                        // recetas 1:1 para que el descuento de stock
                        // funcione sin pasos manuales.
                        if (mode == InventoryMode.basic &&
                            previousMode == InventoryMode.none &&
                            _resolvedBusinessId != null &&
                            mounted) {
                          await _bootstrapBasicInventory();
                        }
                      },
                    ),

                    if (!_features.hasAnySalesMode)
                      Container(
                        margin: const EdgeInsets.only(top: 16),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFFBEB),
                          borderRadius: BorderRadius.circular(10),
                          border:
                              Border.all(color: const Color(0xFFFDE68A)),
                        ),
                        child: const Row(
                          children: [
                            Icon(
                              Icons.warning_amber_rounded,
                              color: Color(0xFFB45309),
                            ),
                            SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                'Apagaste todos los modos de venta. El POS '
                                'mostrará "Venta rápida" por defecto para '
                                'que el cajero no se quede sin opciones.',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Color(0xFF92400E),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Text(
                          _error!,
                          style: const TextStyle(
                            fontSize: 12,
                            color: Color(0xFFB91C1C),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  final String title;
  const _Section({required this.title});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        title,
        style: const TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w800,
          color: MangoColors.darkGray,
        ),
      ),
    );
  }
}

class _InventoryModeSelector extends StatelessWidget {
  final InventoryMode selected;
  final ValueChanged<InventoryMode> onChanged;
  const _InventoryModeSelector({
    required this.selected,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _InventoryModeOption(
          icon: Icons.block,
          label: 'Sin inventario',
          subtitle:
              'No se lleva control de stock. El módulo de Inventario '
              'no aparece en Ajustes. Para negocios que no necesitan '
              'tracking (kiosko sin contabilidad, eventos puntuales).',
          value: InventoryMode.none,
          selected: selected,
          onTap: onChanged,
        ),
        _InventoryModeOption(
          icon: Icons.inventory_2_outlined,
          label: 'Básico (conteo de unidades)',
          subtitle:
              'Cada producto del menú descuenta 1 unidad de stock al '
              'venderse. Ideal para tiendas, minimarkets y bares donde '
              'cada producto se vende tal cual. Al activarlo se crean '
              'automáticamente los productos inventariables.',
          value: InventoryMode.basic,
          selected: selected,
          onTap: onChanged,
        ),
        _InventoryModeOption(
          icon: Icons.menu_book_outlined,
          label: 'Avanzado (con recetas)',
          subtitle:
              'Cada producto puede tener una receta con varios '
              'ingredientes y cantidades. Al vender un coctel, descuenta '
              '60 ml de ginebra + 90 ml de tónica + 1 limón, etc. Para '
              'restaurantes y bares con preparación compuesta.',
          value: InventoryMode.advanced,
          selected: selected,
          onTap: onChanged,
        ),
      ],
    );
  }
}

class _InventoryModeOption extends StatelessWidget {
  final IconData icon;
  final String label;
  final String subtitle;
  final InventoryMode value;
  final InventoryMode selected;
  final ValueChanged<InventoryMode> onTap;

  const _InventoryModeOption({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.value,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isSelected = selected == value;
    return InkWell(
      onTap: () => onTap(value),
      borderRadius: BorderRadius.circular(10),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFFFFF7ED) : Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isSelected
                ? MangoColors.primaryOrange
                : MangoColors.cardBorder,
            width: isSelected ? 1.5 : 1,
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: isSelected
                    ? const Color(0xFFFFEDD5)
                    : const Color(0xFFF3F4F6),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(
                icon,
                color: isSelected
                    ? MangoColors.primaryOrange
                    : MangoColors.muted,
                size: 20,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: isSelected
                          ? MangoColors.primaryOrange
                          : MangoColors.darkGray,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      fontSize: 12,
                      color: MangoColors.muted,
                      height: 1.35,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              isSelected
                  ? Icons.radio_button_checked
                  : Icons.radio_button_off,
              color: isSelected
                  ? MangoColors.primaryOrange
                  : MangoColors.muted,
              size: 22,
            ),
          ],
        ),
      ),
    );
  }
}

class _FlagTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _FlagTile({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: MangoColors.cardBorder),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: value
                  ? const Color(0xFFFFEDD5)
                  : const Color(0xFFF3F4F6),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              icon,
              color: value
                  ? MangoColors.primaryOrange
                  : MangoColors.muted,
              size: 20,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: MangoColors.darkGray,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: const TextStyle(
                    fontSize: 12,
                    color: MangoColors.muted,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
          Switch.adaptive(
            value: value,
            activeTrackColor: MangoColors.primaryOrange,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}
