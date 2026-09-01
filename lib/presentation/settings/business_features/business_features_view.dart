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
import 'package:mangopos/core/utils/app_toast.dart';
import 'package:mangopos/data/repositories/inventory_repository.dart';
import 'package:mangopos/data/repositories/pos_settings_repository.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/theme/app_colors.dart';

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
      AppToast.success(
        context,
        'Inventario básico activado. Se crearon $itemsCreated '
        'producto(s) inventariables y $recipesCreated receta(s) '
        'automáticas (cardinalidad 1).',
      );
    } catch (e) {
      if (!mounted) return;
      AppToast.error(
        context,
        'No se pudo inicializar el inventario: $e. Puedes correrlo '
        'manualmente desde Inventario → Bootstrap.',
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

  /// Diálogo simple para capturar un monto (≥ 0). Devuelve null si se cancela
  /// o el valor no es válido. Se usa para el mínimo y los presets del fee.
  Future<double?> _promptAmount(String title, {double? initial}) async {
    final controller = TextEditingController(
      text: (initial != null && initial > 0) ? initial.toStringAsFixed(2) : '',
    );
    final result = await showDialog<double>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(
            prefixText: 'RD\$ ',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () {
              final v = double.tryParse(
                controller.text.trim().replaceAll(',', '.'),
              );
              Navigator.of(ctx).pop(v == null || v < 0 ? null : v);
            },
            child: const Text('Guardar'),
          ),
        ],
      ),
    );
    controller.dispose();
    return result;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
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
                    if (_features.salesModeDeliveryEnabled)
                      _FlagTile(
                        icon: Icons.location_on_outlined,
                        label: 'Pedir dirección de entrega',
                        subtitle:
                            'Muestra un campo opcional de dirección en los '
                            'pedidos de delivery. El cajero puede llenarlo o '
                            'dejarlo vacío. Desactívalo si no necesitas '
                            'capturar la dirección.',
                        value: _features.deliveryAddressEnabled,
                        onChanged: (v) => _update(
                          _features.copyWith(deliveryAddressEnabled: v),
                        ),
                      ),
                    if (_features.salesModeDeliveryEnabled) ...[
                      _FlagTile(
                        icon: Icons.delivery_dining_outlined,
                        label: 'Cobrar fee de delivery (obligatorio)',
                        subtitle:
                            'Exige fijar el monto del envío al cobrar un '
                            'delivery propio. Apágalo para hacerlo opcional. '
                            'El fee es un cargo exento (sin impuestos).',
                        value: _features.deliveryFeeRequired,
                        onChanged: (v) => _update(
                          _features.copyWith(deliveryFeeRequired: v),
                        ),
                      ),
                      ListTile(
                        leading: const Icon(Icons.south_east_outlined),
                        title: const Text('Monto mínimo del delivery'),
                        subtitle: Text(
                          _features.deliveryFeeMin > 0
                              ? 'Mínimo: RD\$ ${_features.deliveryFeeMin.toStringAsFixed(2)}'
                              : 'Sin mínimo',
                        ),
                        trailing: const Icon(Icons.edit_outlined),
                        onTap: _saving
                            ? null
                            : () async {
                                final v = await _promptAmount(
                                  'Monto mínimo del delivery',
                                  initial: _features.deliveryFeeMin,
                                );
                                if (v != null) {
                                  _update(
                                    _features.copyWith(deliveryFeeMin: v),
                                  );
                                }
                              },
                      ),
                      _DeliveryPresetsTile(
                        presets: _features.deliveryFeePresets,
                        onAdd: _saving
                            ? null
                            : () async {
                                final v = await _promptAmount(
                                  'Agregar monto sugerido',
                                );
                                if (v != null && v > 0) {
                                  final next = [
                                    ..._features.deliveryFeePresets,
                                    v,
                                  ]..sort();
                                  _update(
                                    _features.copyWith(
                                      deliveryFeePresets: next,
                                    ),
                                  );
                                }
                              },
                        onRemove: _saving
                            ? null
                            : (preset) {
                                final next = [..._features.deliveryFeePresets]
                                  ..remove(preset);
                                _update(
                                  _features.copyWith(deliveryFeePresets: next),
                                );
                              },
                      ),
                    ],

                    if (_features.salesModeQuickEnabled ||
                        _features.salesModeManualEnabled ||
                        _features.salesModeDeliveryEnabled) ...[
                      const SizedBox(height: 20),
                      _Section(title: 'Para llevar por defecto'),
                      if (_features.salesModeQuickEnabled)
                        _FlagTile(
                          icon: Icons.takeout_dining_outlined,
                          label: 'Venta rápida para llevar',
                          subtitle:
                              'Las ventas rápidas nuevas arrancan marcadas '
                              '"para llevar" (sin recargo). Se puede cambiar '
                              'en cada orden.',
                          value: _features.defaultTakeoutQuick,
                          onChanged: (v) => _update(
                            _features.copyWith(defaultTakeoutQuick: v),
                          ),
                        ),
                      if (_features.salesModeManualEnabled)
                        _FlagTile(
                          icon: Icons.takeout_dining_outlined,
                          label: 'Venta manual para llevar',
                          subtitle:
                              'Las ventas manuales nuevas arrancan marcadas '
                              '"para llevar" (sin recargo). Se puede cambiar '
                              'en cada orden.',
                          value: _features.defaultTakeoutManual,
                          onChanged: (v) => _update(
                            _features.copyWith(defaultTakeoutManual: v),
                          ),
                        ),
                      if (_features.salesModeDeliveryEnabled)
                        _FlagTile(
                          icon: Icons.takeout_dining_outlined,
                          label: 'Delivery para llevar',
                          subtitle:
                              'Los pedidos de delivery nuevos arrancan '
                              'marcados "para llevar" (sin recargo). Se puede '
                              'cambiar en cada orden.',
                          value: _features.defaultTakeoutDelivery,
                          onChanged: (v) => _update(
                            _features.copyWith(defaultTakeoutDelivery: v),
                          ),
                        ),
                    ],

                    const SizedBox(height: 20),
                    _Section(title: 'Operación'),
                    _FlagTile(
                      icon: Icons.restaurant_menu,
                      label: 'Enviar Pedido',
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
                    _FlagTile(
                      icon: Icons.group_outlined,
                      label: 'Modo multimesero',
                      subtitle:
                          'Cuando un mesero abre o entra a una mesa, el sistema '
                          'pide su PIN para identificarlo. Cada producto agregado '
                          'queda registrado a nombre de quién lo agregó. El mesero '
                          'que abre la mesa queda como "dueño" de la cuenta. '
                          'Requiere PINs únicos por empleado.',
                      value: _features.multimeseroEnabled,
                      onChanged: (v) => _update(
                        _features.copyWith(multimeseroEnabled: v),
                      ),
                    ),
                    _FlagTile(
                      icon: Icons.fact_check_outlined,
                      label: 'Aprobación de transferencias',
                      subtitle:
                          'Las transferencias entre bodegas quedan en estado '
                          '"Por aprobar" al crearse. Un usuario con permiso '
                          'de aprobar debe revisarlas antes de que el stock '
                          'se mueva. Separación de funciones — útil cuando '
                          'el creador y el aprobador son personas distintas.',
                      value: _features.transfersRequireApproval,
                      onChanged: (v) => _update(
                        _features.copyWith(transfersRequireApproval: v),
                      ),
                    ),

                    const SizedBox(height: 20),
                    _Section(title: 'Inventario'),
                    _FlagTile(
                      icon: Icons.local_shipping_outlined,
                      label: 'Recepción de mercancía obligatoria',
                      subtitle:
                          'Registrar una compra NO mete la mercancía al '
                          'inventario. El stock entra cuando el almacén la '
                          'recibe, y esa recepción emite un conduce numerado '
                          'con lo que llegó de cada producto — el soporte '
                          'que archiva contabilidad.',
                      value: _features.requireGoodsReceipt,
                      onChanged: (v) => _update(
                        _features.copyWith(requireGoodsReceipt: v),
                      ),
                    ),
                    _FlagTile(
                      icon: Icons.warehouse_outlined,
                      label: 'Almacenes por área de producción',
                      subtitle:
                          'Cada producto muestra y descuenta la existencia '
                          'del almacén de SU área. Sirve cuando el mismo '
                          'insumo se vende de dos formas: "Brugal botella" '
                          'sale del Food Shop y "Brugal trago" del Bar, cada '
                          'uno con su propio número. Requiere que los '
                          'productos estén ruteados a un área y que cada '
                          'almacén tenga la suya asignada en Inventario → '
                          'Bodegas. PRENDERLA SOLO cuando esos almacenes ya '
                          'tengan existencia real: si arrancan en cero, el '
                          'menú se bloquea entero.',
                      value: _features.warehouseSectionsEnabled,
                      onChanged: (v) => _update(
                        _features.copyWith(warehouseSectionsEnabled: v),
                      ),
                    ),
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

/// Editor de los montos sugeridos (presets) del fee de delivery propio:
/// chips con borrar + botón Agregar. Ver docs/PRD_DELIVERY_FEE_PROPIO.md.
class _DeliveryPresetsTile extends StatelessWidget {
  final List<double> presets;
  final VoidCallback? onAdd;
  final void Function(double preset)? onRemove;

  const _DeliveryPresetsTile({
    required this.presets,
    required this.onAdd,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.sell_outlined,
                size: 20,
                color: Color(0xFF6B7280),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Text(
                  'Montos sugeridos',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              TextButton.icon(
                onPressed: onAdd,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Agregar'),
              ),
            ],
          ),
          const Text(
            'Botones rápidos para el cajero al cobrar un delivery propio.',
            style: TextStyle(fontSize: 12, color: Color(0xFF6B7280)),
          ),
          if (presets.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final p in presets)
                  Chip(
                    label: Text(
                      'RD\$ ${p == p.roundToDouble() ? p.toStringAsFixed(0) : p.toStringAsFixed(2)}',
                    ),
                    onDeleted: onRemove == null ? null : () => onRemove!(p),
                  ),
              ],
            ),
          ],
        ],
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
