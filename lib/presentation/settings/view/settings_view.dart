import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mangopos/app/router/routes.dart';
import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/app/theme/ui_scale.dart';
import 'package:mangopos/core/business/business_features_provider.dart';
import 'package:mangopos/core/cache/cache_manager.dart';
import 'package:mangopos/core/utils/app_toast.dart';
import 'package:mangopos/data/repositories/pos_settings_repository.dart';
import 'package:mangopos/core/offline/hub/hub_mode.dart';
import 'package:mangopos/core/offline/offline_pos_service.dart';
import 'package:mangopos/presentation/settings/hub/hub_network_settings_view.dart';
import 'package:mangopos/services/session/session_controller.dart';
import 'package:mangopos/presentation/settings/widgets/system_update_dialog.dart';

class SettingsView extends ConsumerStatefulWidget {
  const SettingsView({super.key, this.businessId = ''});

  final String businessId;

  @override
  ConsumerState<SettingsView> createState() => _SettingsViewState();
}

class _SettingsViewState extends ConsumerState<SettingsView> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// Normaliza para búsqueda: minúsculas y sin acentos, de modo que
  /// "informacion" encuentre "Información" y "monedas" encuentre "Monedas".
  static String _normalize(String input) {
    var s = input.toLowerCase().trim();
    const from = 'áàäâãéèëêíìïîóòöôõúùüûñç';
    const to = 'aaaaaeeeeiiiiooooouuuunc';
    for (var i = 0; i < from.length; i++) {
      s = s.replaceAll(from[i], to[i]);
    }
    return s;
  }

  /// Filtra las secciones por el texto de búsqueda. Si el título de la
  /// sección coincide, se muestran todos sus ítems; de lo contrario solo
  /// los ítems cuyo título o subtítulo coincidan. Secciones sin
  /// coincidencias se omiten.
  List<_SettingsSection> _filterSections(List<_SettingsSection> sections) {
    final q = _normalize(_query);
    if (q.isEmpty) return sections;
    final result = <_SettingsSection>[];
    for (final section in sections) {
      final sectionMatches = _normalize(section.title).contains(q);
      final items = sectionMatches
          ? section.items
          : section.items
                .where(
                  (o) =>
                      _normalize(o.title).contains(q) ||
                      _normalize(o.subtitle).contains(q),
                )
                .toList();
      if (items.isNotEmpty) {
        result.add(_SettingsSection(title: section.title, items: items));
      }
    }
    return result;
  }

  Future<void> _confirmAndClearSystemCache(BuildContext context) async {
    // Contar operaciones/mesas sin sincronizar para advertir. Limpiar caché NO
    // las borra (viven en otro namespace / en SQLite), pero SÍ fuerza una
    // recarga desde el servidor que puede OCULTAR temporalmente las mesas
    // locales aún no subidas hasta que vuelva la conexión y sincronicen. Se
    // avisa para que el cajero sincronice antes y no crea que perdió la mesa.
    final businessId = widget.businessId.isNotEmpty
        ? widget.businessId
        : (ref.read(sessionProvider).activeBusinessId ?? '');
    int pendingOffline = 0;
    if (businessId.isNotEmpty) {
      try {
        final svc = OfflinePosService();
        pendingOffline = await svc.pendingActionsCount(businessId) +
            await svc.deadActionsCount(businessId);
      } catch (_) {
        pendingOffline = 0;
      }
    }
    if (!context.mounted) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Limpiar caché del sistema'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Se borrarán datos temporales locales para forzar una recarga fresca del sistema. '
                'No se cerrará tu sesión ni se eliminarán operaciones offline pendientes.',
              ),
              if (pendingOffline > 0) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFEF3C7),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(
                        Icons.warning_amber_rounded,
                        color: Color(0xFFB45309),
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Tienes $pendingOffline operación(es) sin sincronizar. No se '
                          'borrarán, pero al recargar, las mesas locales que aún no '
                          'subieron pueden dejar de verse en el salón hasta que vuelva '
                          'la conexión y sincronicen. Sincroniza antes de limpiar.',
                          style: const TextStyle(
                            color: Color(0xFF92400E),
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFEF4444),
                foregroundColor: Colors.white,
              ),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Limpiar caché'),
            ),
          ],
        );
      },
    );

    if (confirmed != true || !context.mounted) return;

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) {
        return const Center(
          child: Card(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 24, vertical: 20),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2.5),
                  ),
                  SizedBox(width: 14),
                  Text('Limpiando caché...'),
                ],
              ),
            ),
          ),
        );
      },
    );

    try {
      final result = await CacheManager().clearSystemCache();
      if (!context.mounted) return;

      Navigator.of(context, rootNavigator: true).pop();
      AppToast.success(
        context,
        'Caché limpiado correctamente (${result.deletedCount} elementos).',
      );
    } catch (e) {
      if (!context.mounted) return;

      Navigator.of(context, rootNavigator: true).pop();
      AppToast.error(context, 'No se pudo limpiar la caché: $e');
    }
  }

  /// Selector del tamaño global de la interfaz. Aplica en vivo al seleccionar
  /// (se ve el reescalado al instante) y se guarda por dispositivo.
  Future<void> _showUiScaleDialog(BuildContext context) async {
    UiScaleOption selected = ref.read(uiScaleProvider);
    await showDialog<void>(
      context: context,
      builder: (dialogCtx) {
        return StatefulBuilder(
          builder: (ctx, setSt) {
            return AlertDialog(
              title: const Text('Tamaño de interfaz'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Agranda toda la interfaz. Útil en pantallas de alta '
                      'densidad como la Toast Flex (14", 1920×1080). Se guarda '
                      'solo en este equipo.',
                      style: TextStyle(fontSize: 13, color: Color(0xFF78716C)),
                    ),
                    const SizedBox(height: 8),
                    ...UiScaleOption.values.map((opt) {
                      final pct = (opt.factor * 100).round();
                      final isSel = selected == opt;
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        onTap: () {
                          setSt(() => selected = opt);
                          // Aplica en vivo + persiste.
                          ref.read(uiScaleProvider.notifier).set(opt);
                        },
                        leading: Icon(
                          isSel
                              ? Icons.radio_button_checked
                              : Icons.radio_button_unchecked,
                          color: isSel
                              ? MangoColors.primaryOrange
                              : const Color(0xFF9CA3AF),
                        ),
                        title: Text(opt.label),
                        subtitle: Text(
                          opt == UiScaleOption.normal
                              ? 'Sin cambios (100%)'
                              : 'Interfaz al $pct%',
                        ),
                      );
                    }),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogCtx).pop(),
                  child: const Text('Listo'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final sections = _filterSections(_buildSections(context));
    final isSearching = _normalize(_query).isNotEmpty;
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: MangoColors.white,
        foregroundColor: _SettingsSurface.foreground,
        elevation: 0.4,
        scrolledUnderElevation: 0.6,
        titleSpacing: 12,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Más Ajustes',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.2,
              ),
            ),
            Text(
              'Configuración completa del sistema MangoPOS',
              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
            ),
          ],
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
        children: [
          _BusinessSummaryCard(
            businessName: ref.watch(sessionProvider).activeBusinessName,
          ),
          const SizedBox(height: 18),
          _SettingsSearchField(
            controller: _searchController,
            onChanged: (value) => setState(() => _query = value),
            onClear: () => setState(() {
              _searchController.clear();
              _query = '';
            }),
          ),
          const SizedBox(height: 18),
          if (isSearching && sections.isEmpty)
            _SettingsNoResults(query: _query.trim())
          else
            ...sections.expand((section) sync* {
              yield section;
              yield const SizedBox(height: 28);
            }),
        ],
      ),
    );
  }

  List<_SettingsSection> _buildSections(BuildContext context) {
    // Feature flag de inventario: si el negocio eligió "sin inventario",
    // toda la sección desaparece del menú de Ajustes para no saturar la
    // UI con módulos que no se van a usar.
    final inventoryMode = ref.watchBusinessFeatures().inventoryMode;
    final inventoryEnabled = inventoryMode.isEnabled;
    return [
      _SettingsSection(
        title: 'Negocio',
        items: [
          if (ref.watch(sessionProvider).isOwner)
            const _SettingsOption(
              title: 'Mi cuenta',
              subtitle:
                  'Tu información de propietario, PIN de acceso y datos de sesión',
              icon: Icons.account_circle_rounded,
              color: Color(0xFFFFF7F1),
              route: AppRoutes.settingsMyAccount,
            ),
          const _SettingsOption(
            title: 'Datos del Negocio',
            subtitle:
                'Nombre, RNC, dirección, logo, eslogan y personalización del ticket',
            icon: Icons.store_rounded,
            color: Color(0xFFFFE6D5),
            route: AppRoutes.settingsBusinessProfile,
          ),
        ],
      ),
      _SettingsSection(
        title: 'Punto de Venta',
        items: [
          _SettingsOption(
            title: 'Venta Rápida',
            subtitle: 'Ventas express sin mesa',
            icon: Icons.flash_on_rounded,
            color: const Color(0xFFFFE6D5),
          ),
          _SettingsOption(
            title: 'Venta Manual',
            subtitle: 'Asignar manual de pedidos y precios',
            icon: Icons.edit_rounded,
            color: const Color(0xFFEAF0FF),
          ),
          _SettingsOption(
            title: 'Delivery',
            subtitle: 'Configurar ordenes de entrega a domicilio',
            icon: Icons.delivery_dining_rounded,
            color: const Color(0xFFFFF0D9),
          ),
          _SettingsOption(
            title: 'Self Service',
            subtitle: 'Modo autoservicio para el cliente',
            icon: Icons.self_improvement_rounded,
            color: const Color(0xFFE6F7EE),
          ),
          _SettingsOption(
            title: 'Salones y Mesas',
            subtitle: 'Gestión de zonas y mesas del local',
            icon: Icons.grid_view_rounded,
            color: const Color(0xFFF0F0F0),
            route: AppRoutes.settingsZonesTables,
          ),
        ],
      ),
      _SettingsSection(
        title: 'Caja',
        items: const [
          _SettingsOption(
            title: 'Apertura y Cierre',
            subtitle: 'Flujos de apertura y cierre de caja',
            icon: Icons.point_of_sale_rounded,
            color: Color(0xFFE6F7EE),
            route: AppRoutes.cashier,
          ),
          _SettingsOption(
            title: 'Historial de Venta',
            subtitle: 'Consulta de ventas realizadas',
            icon: Icons.receipt_long_rounded,
            color: Color(0xFFF1F1F1),
            route: AppRoutes.cashierHistory,
          ),
          _SettingsOption(
            title: 'Registro de Ingresos y Egresos',
            subtitle: 'Movimientos de efectivo en caja',
            icon: Icons.attach_money_rounded,
            color: Color(0xFFEAF0FF),
            route: AppRoutes.cashierIncomeExpense,
          ),
          _SettingsOption(
            title: 'Razones de Ingresos y Egresos',
            subtitle: 'Catálogo de razones para movimientos de caja',
            icon: Icons.fact_check_rounded,
            color: Color(0xFFE6F4FF),
            route: AppRoutes.settingsCashReasons,
          ),
          _SettingsOption(
            title: 'Tipos de Pago',
            subtitle: 'Cuentas bancarias para transferencias',
            icon: Icons.account_balance_rounded,
            color: Color(0xFFEDE9FE),
            route: AppRoutes.settingsPaymentMethods,
          ),
          _SettingsOption(
            title: 'Gestión de Cierres de Caja',
            subtitle: 'Administración de cierres y arqueos',
            icon: Icons.lock_rounded,
            color: Color(0xFFFFEFE3),
            route: AppRoutes.cashierClosures,
          ),
          _SettingsOption(
            title: 'Modo de cierre de caja',
            subtitle: 'Clásico (con monto esperado) o a ciegas',
            icon: Icons.shield_outlined,
            color: Color(0xFFEDE9FE),
            route: AppRoutes.settingsCashCloseMode,
          ),
          _SettingsOption(
            title: 'Modos de negocio',
            subtitle:
                'Activa/desactiva ventas por zona, cocina, código de barras',
            icon: Icons.tune,
            color: Color(0xFFFFEDD5),
            route: AppRoutes.settingsBusinessFeatures,
          ),
          _SettingsOption(
            title: 'Gestión de Notas de Crédito',
            subtitle: 'Anulaciones y devoluciones',
            icon: Icons.note_alt_rounded,
            color: Color(0xFFFFE6E6),
          ),
          _SettingsOption(
            title: 'Monitor de Ventas',
            subtitle: 'Visualización en tiempo real',
            icon: Icons.monitor_rounded,
            color: Color(0xFFF3F3F3),
          ),
        ],
      ),
      _SettingsSection(
        title: 'Gestión de Productos',
        items: [
          _SettingsOption(
            title: 'Productos',
            subtitle: 'Catálogo de productos',
            icon: Icons.inventory_2_rounded,
            color: const Color(0xFFFFE6D5),
            route: AppRoutes.products,
          ),
          _SettingsOption(
            title: 'Categorías',
            subtitle: 'Crear, renombrar, activar y eliminar categorías',
            icon: Icons.category_rounded,
            color: const Color(0xFFFFF7ED),
            route: AppRoutes.menuCategories,
          ),
          _SettingsOption(
            title: 'Modificadores',
            subtitle: 'Extras y variantes de productos',
            icon: Icons.tune_rounded,
            color: const Color(0xFFEAF0FF),
            route: AppRoutes.menuModifiers,
          ),
          _SettingsOption(
            title: 'Menú',
            subtitle: 'Configuración de menús',
            icon: Icons.menu_book_rounded,
            color: const Color(0xFFFFF0D9),
            route: AppRoutes.menuMenus.replaceFirst(
              ':businessId',
              widget.businessId,
            ),
          ),
          // Recetas: solo cuando inventory_mode = advanced. El modo
          // 'basic' usa cardinalidad 1:1 menu→inventory auto-creada y
          // no necesita editor de recetas. 'none' no toca inventario.
          if (inventoryMode == InventoryMode.advanced)
            _SettingsOption(
              title: 'Recetas',
              subtitle: 'Ingredientes y costos de recetas',
              icon: Icons.receipt_rounded,
              color: const Color(0xFFF1F1F1),
              route: AppRoutes.menuRecipes,
            ),
          // Insumos: vinculado al módulo de inventario. Si está
          // apagado (`none`), ocultamos también la entrada.
          if (inventoryEnabled)
            _SettingsOption(
              title: 'Insumos',
              subtitle: 'Materias primas e ingredientes',
              icon: Icons.science_rounded,
              color: const Color(0xFFFFEDED),
              route: AppRoutes.inventoryOutflow,
            ),
        ],
      ),
      _SettingsSection(
        title: 'Ofertas y Combos',
        items: const [
          _SettingsOption(
            title: 'Ofertas y Promociones',
            subtitle: 'Crear ofertas, BOGO (X paga Y) y descuentos',
            icon: Icons.local_offer_rounded,
            color: Color(0xFFE6F7EE),
            route: '${AppRoutes.promosCenter}?offers=1',
          ),
          _SettingsOption(
            title: 'Combos',
            subtitle: 'Paquetes de productos vendidos como uno',
            icon: Icons.widgets_rounded,
            color: Color(0xFFFFF0D9),
            route: AppRoutes.menuCombos,
          ),
        ],
      ),
      _SettingsSection(
        title: 'Comandas y Precuentas',
        items: const [
          _SettingsOption(
            title: 'Config. de Comandas',
            subtitle: 'Formato y comportamiento de comandas',
            icon: Icons.list_alt_rounded,
            color: Color(0xFFFFE6D5),
            route: AppRoutes.settingsComandasConfig,
          ),
          _SettingsOption(
            title: 'Config. de Precuentas',
            subtitle: 'Formato de precuentas',
            icon: Icons.receipt_rounded,
            color: Color(0xFFEAF0FF),
          ),
          _SettingsOption(
            title: 'Turnos',
            subtitle: 'Gestión de turnos de trabajo',
            icon: Icons.schedule_rounded,
            color: Color(0xFFE6F7EE),
          ),
        ],
      ),
      _SettingsSection(
        title: 'Ajustes Generales',
        items: [
          _SettingsOption(
            title: 'Usuarios',
            subtitle: 'Gestión de usuarios del sistema',
            icon: Icons.person_outline_rounded,
            color: const Color(0xFFFFE6D5),
            route: AppRoutes.settingsUsers,
          ),
          const _SettingsOption(
            title: 'Clientes',
            subtitle: 'Gestión de clientes y contactos',
            icon: Icons.people_alt_rounded,
            color: Color(0xFFEAF0FF),
            route: AppRoutes.customers,
          ),
          const _SettingsOption(
            title: 'Cajas',
            subtitle: 'Configuración de puntos de venta',
            icon: Icons.point_of_sale_rounded,
            color: Color(0xFFE6F7EE),
            route: AppRoutes.settingsCashRegisters,
          ),
          const _SettingsOption(
            title: 'Impuestos',
            subtitle: 'ITBIS y configuración fiscal',
            icon: Icons.percent_rounded,
            color: Color(0xFFFFF0D9),
            route: AppRoutes.settingsTaxes,
          ),
          const _SettingsOption(
            title: 'Monedas',
            subtitle: 'Configuración de divisas',
            icon: Icons.monetization_on_rounded,
            color: Color(0xFFEAF0FF),
            route: AppRoutes.settingsCurrencies,
          ),
          const _SettingsOption(
            title: 'Configuraciones Regionales',
            subtitle: 'Idioma, zona horaria y formato',
            icon: Icons.language_rounded,
            color: Color(0xFFF1F1F1),
            route: AppRoutes.settingsRegional,
          ),
          const _SettingsOption(
            title: 'Personalizar Header',
            subtitle: 'Elige qué módulos aparecen en la barra superior',
            icon: Icons.view_quilt_rounded,
            color: Color(0xFFFFE6D5),
            route: AppRoutes.settingsHeaderPersonalize,
          ),
          _SettingsOption(
            title: 'Tamaño de interfaz',
            subtitle:
                'Agranda la UI para pantallas de alta densidad (Toast Flex, etc.)',
            icon: Icons.format_size_rounded,
            color: const Color(0xFFEAF0FF),
            onTap: () => _showUiScaleDialog(context),
          ),
          if (ref.watch(sessionProvider).isOwner)
            const _SettingsOption(
              title: 'Sucursales',
              subtitle: 'Gestión de múltiples locales',
              icon: Icons.store_mall_directory_rounded,
              color: Color(0xFFFFEDED),
              route: AppRoutes.settingsBranches,
            ),
        ],
      ),
      _SettingsSection(
        title: inventoryMode == InventoryMode.advanced
            ? 'Almacenes e Inventario (recetas)'
            : 'Almacenes e Inventario',
        items: const [
          _SettingsOption(
            title: 'Inventario',
            subtitle: 'Insumos, recetas, almacenes y proveedores',
            icon: Icons.inventory_2_rounded,
            color: Color(0xFFFFE6D5),
            route: AppRoutes.inventoryHome,
          ),
          _SettingsOption(
            title: 'Kardex por Sucursal',
            subtitle: 'Historial de movimientos por ubicación',
            icon: Icons.list_rounded,
            color: Color(0xFFFFE6D5),
            route: AppRoutes.inventoryKardex,
          ),
          _SettingsOption(
            title: 'Recepciones',
            subtitle: 'Ingreso directo de mercancía sin OC',
            icon: Icons.move_to_inbox_rounded,
            color: Color(0xFFE6F7EE),
            route: AppRoutes.inventoryReceipts,
          ),
          _SettingsOption(
            title: 'Registro de Salida de Inventario',
            subtitle: 'Control de salidas de stock',
            icon: Icons.logout_rounded,
            color: Color(0xFFFFF0D9),
            route: AppRoutes.inventoryOutflow,
          ),
          _SettingsOption(
            title: 'Mover Inventario entre Almacenes',
            subtitle: 'Transferencias entre almacenes',
            icon: Icons.swap_horiz_rounded,
            color: Color(0xFFEAF0FF),
            route: AppRoutes.inventoryTransfers,
          ),
          _SettingsOption(
            title: 'Cuadre de Stock',
            subtitle: 'Ajustes de inventario',
            icon: Icons.inventory_rounded,
            color: Color(0xFFE6F7EE),
            route: AppRoutes.inventoryReconciliation,
          ),
          _SettingsOption(
            title: 'Mermas o Perecederos',
            subtitle: 'Registro de pérdidas',
            icon: Icons.warning_rounded,
            color: Color(0xFFFFEDED),
          ),
          _SettingsOption(
            title: 'Lotes y Vencimientos',
            subtitle: 'Tracking de lote y fecha de vencimiento',
            icon: Icons.event_note_rounded,
            color: Color(0xFFFFF0D9),
            route: AppRoutes.inventoryLots,
          ),
          _SettingsOption(
            title: 'Valoración y ABC',
            subtitle: 'Valor de existencias y clasificación Pareto',
            icon: Icons.assessment_rounded,
            color: Color(0xFFEAF0FF),
            route: AppRoutes.inventoryValuation,
          ),
          _SettingsOption(
            title: 'Análisis de Rotación',
            subtitle: 'Velocidad de consumo, estrellas y estancados',
            icon: Icons.trending_up_rounded,
            color: Color(0xFFE6F7EE),
            route: AppRoutes.inventoryRotation,
          ),
          _SettingsOption(
            title: 'Alertas de Stock',
            subtitle: 'Insumos bajo el mínimo configurado',
            icon: Icons.notifications_active_rounded,
            color: Color(0xFFFFEDED),
            route: AppRoutes.inventoryLowStock,
          ),
          _SettingsOption(
            title: 'Requerimientos',
            subtitle: 'Solicitudes de stock',
            icon: Icons.assignment_rounded,
            color: Color(0xFFF1F1F1),
            route: AppRoutes.inventoryRequirements,
          ),
        ],
      ),
      _SettingsSection(
        title: 'Compras',
        items: const [
          _SettingsOption(
            title: 'Lista de Compras',
            subtitle: 'Listado de pedidos a proveedores',
            icon: Icons.list_alt_rounded,
            color: Color(0xFFFFE6D5),
            route: AppRoutes.purchasesList,
          ),
          _SettingsOption(
            title: 'Registro de Compras',
            subtitle: 'Historial de compras realizadas',
            icon: Icons.receipt_long_rounded,
            color: Color(0xFFEAF0FF),
            route: AppRoutes.purchasesRegister,
          ),
          _SettingsOption(
            title: 'Gestión de Proveedores',
            subtitle: 'Catálogo de proveedores',
            icon: Icons.local_shipping_rounded,
            color: Color(0xFFE6F7EE),
            route: AppRoutes.purchasesList,
          ),
          _SettingsOption(
            title: 'Crédito de Compras a Proveedores',
            subtitle: 'Cuentas por pagar',
            icon: Icons.credit_score_rounded,
            color: Color(0xFFFFF0D9),
            route: AppRoutes.credits,
          ),
        ],
      ),
      _SettingsSection(
        title: 'Gestión de Impresión',
        items: [
          _SettingsOption(
            title: 'Impresoras',
            subtitle: 'Configurar y agregar impresoras',
            icon: Icons.print_rounded,
            color: const Color(0xFFFFE6D5),
            route: AppRoutes.printingPrinters,
          ),
          _SettingsOption(
            title: 'Asignar Impresión de Productos',
            subtitle: 'Productos por impresora',
            icon: Icons.inventory_2_rounded,
            color: const Color(0xFFEAF0FF),
            route: AppRoutes.printingProducts,
          ),
          _SettingsOption(
            title: 'Asignar Impresión de Comprobantes',
            subtitle: 'Comprobantes por impresora',
            icon: Icons.receipt_rounded,
            color: const Color(0xFFE6F7EE),
            route: AppRoutes.printingReceipts,
          ),
          _SettingsOption(
            title: 'Asignar Impresión de Comandas',
            subtitle: 'Comandas por impresora de cocina',
            icon: Icons.list_alt_rounded,
            color: const Color(0xFFFFF0D9),
            route: AppRoutes.printingOrders,
          ),
          _SettingsOption(
            title: 'Diagnóstico',
            subtitle: 'Estado del agente, dispositivos e impresoras',
            icon: Icons.health_and_safety_outlined,
            color: const Color(0xFFEAF0FF),
            route: AppRoutes.printingDiagnostics,
          ),
          _SettingsOption(
            title: 'Salud de impresión',
            subtitle: 'Semáforo de impresoras y cola pendiente',
            icon: Icons.monitor_heart_outlined,
            color: const Color(0xFFE6F7EE),
            route: AppRoutes.printingHealth,
          ),
        ],
      ),
      _SettingsSection(
        title: 'Pagos del Sistema',
        items: const [
          _SettingsOption(
            title: 'Tarjeta',
            subtitle: 'Configuración de pagos con tarjeta',
            icon: Icons.credit_card_rounded,
            color: Color(0xFFFFE6D5),
          ),
          _SettingsOption(
            title: 'Transferencias',
            subtitle: 'Pagos por transferencia bancaria',
            icon: Icons.alt_route_rounded,
            color: Color(0xFFEAF0FF),
          ),
          _SettingsOption(
            title: 'Información Histórica de Pagos',
            subtitle: 'Historial de transacciones',
            icon: Icons.history_rounded,
            color: Color(0xFFE6F7EE),
          ),
        ],
      ),
      _SettingsSection(
        title: 'Crédito',
        items: const [
          _SettingsOption(
            title: 'Gestión de Créditos',
            subtitle: 'Cuentas por cobrar y por pagar, abonos e historial',
            icon: Icons.account_balance_wallet_rounded,
            color: Color(0xFFEAF0FF),
            route: AppRoutes.credits,
          ),
        ],
      ),
      _SettingsSection(
        title: 'Finanzas',
        items: const [
          _SettingsOption(
            title: 'Gestión de Costos',
            subtitle: 'Control de costos y gastos',
            icon: Icons.request_quote_rounded,
            color: Color(0xFFFFE6D5),
          ),
          _SettingsOption(
            title: 'Gestión de Metas',
            subtitle: 'Objetivos y metas del negocio',
            icon: Icons.flag_rounded,
            color: Color(0xFFE6F7EE),
          ),
        ],
      ),
      _SettingsSection(
        title: 'Fidelización',
        items: const [
          _SettingsOption(
            title: 'Tarjeta de Fidelidad',
            subtitle: 'Programa de puntos y recompensas',
            icon: Icons.card_membership_rounded,
            color: Color(0xFFFFE6D5),
            route: AppRoutes.promosCenter,
          ),
          _SettingsOption(
            title: 'Niveles de Membresías',
            subtitle: 'Categorías de clientes VIP',
            icon: Icons.verified_user_rounded,
            color: Color(0xFFEAF0FF),
            route: AppRoutes.promosCenter,
          ),
          _SettingsOption(
            title: 'Promociones y Descuentos',
            subtitle: 'Ofertas y promociones activas',
            icon: Icons.local_offer_rounded,
            color: Color(0xFFE6F7EE),
            route: AppRoutes.promosCenter,
          ),
          _SettingsOption(
            title: 'Gestión de Cupones',
            subtitle: 'Códigos promocionales',
            icon: Icons.confirmation_number_rounded,
            color: Color(0xFFFFF0D9),
            route: AppRoutes.promosCenter,
          ),
          _SettingsOption(
            title: 'Gift Cards y Bonos',
            subtitle: 'Tarjetas de regalo',
            icon: Icons.redeem_rounded,
            color: Color(0xFFFFEDED),
            route: AppRoutes.promosCenter,
          ),
          _SettingsOption(
            title: 'Puntos de Recompensa',
            subtitle: 'Sistema de puntos acumulables',
            icon: Icons.workspace_premium_rounded,
            color: Color(0xFFF1F1F1),
            route: AppRoutes.promosCenter,
          ),
          _SettingsOption(
            title: 'Historial de Fidelidad',
            subtitle: 'Registro de actividad de clientes',
            icon: Icons.history_rounded,
            color: Color(0xFFEAF0FF),
            route: AppRoutes.promosCenter,
          ),
        ],
      ),
      _SettingsSection(
        title: 'Sistema',
        items: [
          const _SettingsOption(
            title: 'Opciones del Sistema',
            subtitle: 'Configuración general del sistema',
            icon: Icons.tune_rounded,
            color: Color(0xFFFFE6D5),
          ),
          const _SettingsOption(
            title: 'Opciones de APP MangoPOS',
            subtitle: 'Configuración de la aplicación móvil',
            icon: Icons.smartphone_rounded,
            color: Color(0xFFEAF0FF),
          ),
          const _SettingsOption(
            title: 'Información del Restaurante',
            subtitle: 'Datos del negocio',
            icon: Icons.business_rounded,
            color: Color(0xFFE6F7EE),
          ),
          if (ref.watch(sessionProvider).isOwner)
            const _SettingsOption(
              title: 'Gestión de Sucursales',
              subtitle: 'Administración multisucursal',
              icon: Icons.store_rounded,
              color: Color(0xFFFFF0D9),
              route: AppRoutes.settingsBranches,
            ),
          _SettingsOption(
            title: 'Actualizaciones',
            subtitle: 'Versiones y actualizaciones',
            icon: Icons.system_update_alt_rounded,
            color: const Color(0xFFF1F1F1),
            onTap: () {
              showDialog(
                context: context,
                builder: (context) => const SystemUpdateDialog(),
              );
            },
          ),
          _SettingsOption(
            title: 'Limpiar caché del sistema',
            subtitle: 'Borra datos temporales y fuerza recarga',
            icon: Icons.cleaning_services_rounded,
            color: const Color(0xFFFFEDED),
            onTap: () => _confirmAndClearSystemCache(context),
          ),
          // Gateado tras kHubModeEnabled: no aparece en producción hasta que
          // el ruteo LAN-first esté cableado y probado (H4+).
          if (kHubModeEnabled)
            _SettingsOption(
              title: 'Red local (Hub)',
              subtitle: 'Modo híbrido: caja principal como servidor local',
              icon: Icons.hub_rounded,
              color: const Color(0xFFEFF6FF),
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const HubNetworkSettingsView(),
                  ),
                );
              },
            ),
          const _SettingsOption(
            title: 'Integración con Marketing',
            subtitle: 'Conexión con herramientas de marketing',
            icon: Icons.track_changes_rounded,
            color: Color(0xFFFFEDED),
          ),
        ],
      ),
      _SettingsSection(
        title: 'Comprobantes de Ventas',
        items: const [
          _SettingsOption(
            title: 'Configuración de Crédito Fiscal',
            subtitle: 'NCF y comprobantes fiscales DGII',
            icon: Icons.receipt_long_rounded,
            color: Color(0xFFFFE6D5),
            route: AppRoutes.settingsFiscalReceipts,
          ),
        ],
      ),
      _SettingsSection(
        title: 'Informes',
        items: const [
          _SettingsOption(
            title: 'Informe de Ventas',
            subtitle: 'Reportes de ventas detallados',
            icon: Icons.bar_chart_rounded,
            color: Color(0xFFFFE6D5),
            route: '${AppRoutes.reports}?tab=sales',
          ),
          _SettingsOption(
            title: 'Informe de Compras',
            subtitle: 'Reportes de compras',
            icon: Icons.receipt_rounded,
            color: Color(0xFFEAF0FF),
            route: '${AppRoutes.reports}?tab=purchases',
          ),
          _SettingsOption(
            title: 'Informe de Finanzas',
            subtitle: 'Reportes financieros',
            icon: Icons.trending_up_rounded,
            color: Color(0xFFE6F7EE),
            route: '${AppRoutes.reports}?tab=finances',
          ),
          _SettingsOption(
            title: 'Informe de Inventario',
            subtitle: 'Reportes de stock',
            icon: Icons.inventory_2_rounded,
            color: Color(0xFFFFF0D9),
            route: '${AppRoutes.reports}?tab=inventory',
          ),
          _SettingsOption(
            title: 'Informe de Asistencia',
            subtitle: 'Reportes del personal',
            icon: Icons.groups_rounded,
            color: Color(0xFFF1F1F1),
          ),
          _SettingsOption(
            title: 'Indicadores Gráficos',
            subtitle: 'Dashboard de indicadores',
            icon: Icons.analytics_rounded,
            color: Color(0xFFFFEDED),
          ),
        ],
      ),
      _SettingsSection(
        title: 'Cuenta y Facturación',
        items: const [
          _SettingsOption(
            title: 'Suscripción y pagos',
            subtitle:
                'Plan actual, próximo cobro, tarjeta registrada e historial',
            icon: Icons.credit_card_rounded,
            color: Color(0xFFFFE6D5),
            route: AppRoutes.settingsBilling,
          ),
        ],
      ),
    ];
  }
}

class _SettingsSearchField extends StatelessWidget {
  const _SettingsSearchField({
    required this.controller,
    required this.onChanged,
    required this.onClear,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final hasText = controller.text.isNotEmpty;
    return Container(
      decoration: BoxDecoration(
        color: MangoColors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _SettingsSurface.border),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0D1C1917),
            blurRadius: 12,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        textInputAction: TextInputAction.search,
        style: const TextStyle(fontSize: 14, color: _SettingsSurface.foreground),
        decoration: InputDecoration(
          isDense: true,
          hintText: 'Buscar en ajustes…',
          hintStyle: const TextStyle(fontSize: 14, color: _SettingsSurface.muted),
          prefixIcon: const Icon(
            Icons.search_rounded,
            size: 20,
            color: _SettingsSurface.muted,
          ),
          suffixIcon: hasText
              ? IconButton(
                  icon: const Icon(
                    Icons.close_rounded,
                    size: 18,
                    color: _SettingsSurface.muted,
                  ),
                  tooltip: 'Limpiar',
                  onPressed: onClear,
                )
              : null,
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 14,
            vertical: 14,
          ),
        ),
      ),
    );
  }
}

class _SettingsNoResults extends StatelessWidget {
  const _SettingsNoResults({required this.query});

  final String query;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48),
      child: Column(
        children: [
          const Icon(
            Icons.search_off_rounded,
            size: 48,
            color: _SettingsSurface.muted,
          ),
          const SizedBox(height: 14),
          Text(
            'Sin resultados para "$query"',
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: _SettingsSurface.foreground,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Prueba con otra palabra o revisa la ortografía.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: _SettingsSurface.muted),
          ),
        ],
      ),
    );
  }
}

class _BusinessSummaryCard extends StatelessWidget {
  const _BusinessSummaryCard({this.businessName});

  final String? businessName;

  @override
  Widget build(BuildContext context) {
    final resolvedBusinessName = businessName?.trim().isNotEmpty == true
        ? businessName!.trim()
        : 'Negocio no configurado';
    return Container(
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFFFF5EC), Colors.white],
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: _SettingsSurface.border),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0D1C1917),
            blurRadius: 18,
            offset: Offset(0, 6),
          ),
          BoxShadow(
            color: Color(0x141C1917),
            blurRadius: 4,
            offset: Offset(0, 1),
          ),
        ],
      ),
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0xFFFF8A3D), Color(0xFFF97316)],
                  ),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Icon(
                  Icons.business_rounded,
                  color: Colors.white,
                  size: 30,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      resolvedBusinessName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF1C1917),
                        letterSpacing: -0.3,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Configuración general del negocio',
                      style: TextStyle(fontSize: 13, color: Colors.grey[600]),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'RNC pendiente de sincronizar',
                      style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          const Divider(height: 1, color: Color(0xFFE7E0D9)),
          const SizedBox(height: 16),
          Row(
            children: const [
              _MiniStat(
                label: 'NCF Disponibles',
                value: '2,450',
                color: MangoColors.primaryOrange,
                icon: Icons.receipt_long_outlined,
              ),
              SizedBox(width: 12),
              _MiniStat(
                label: 'e-CF',
                value: 'Pendiente',
                color: Color(0xFFEAB308),
                icon: Icons.shield_outlined,
              ),
              SizedBox(width: 12),
              _MiniStat(
                label: 'Impresoras',
                value: '3 activas',
                color: Color(0xFF22C55E),
                icon: Icons.print_outlined,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MiniStat extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  final IconData icon;

  const _MiniStat({
    required this.label,
    required this.value,
    required this.color,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: color.withValues(alpha: 0.14)),
        ),
        child: Row(
          children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: color,
                      fontSize: 12,
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

class _SettingsSection extends StatelessWidget {
  final String title;
  final List<_SettingsOption> items;

  const _SettingsSection({required this.title, required this.items});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                title.toUpperCase(),
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF1C1917),
                  letterSpacing: 0.25,
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: const Color(0xFFF3ECE5),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: _SettingsSurface.border),
              ),
              child: Text(
                '${items.length}',
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF78716C),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Container(
          height: 1,
          width: double.infinity,
          color: _SettingsSurface.divider,
        ),
        const SizedBox(height: 14),
        LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            int crossAxisCount = 4;
            if (width < 1280) crossAxisCount = 3;
            if (width < 1024) crossAxisCount = 2;
            if (width < 768) crossAxisCount = 1;
            return GridView.builder(
              itemCount: items.length,
              physics: const NeverScrollableScrollPhysics(),
              shrinkWrap: true,
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: crossAxisCount,
                mainAxisSpacing: 16,
                crossAxisSpacing: 16,
                mainAxisExtent: 104, // Altura fija garantizada
              ),
              itemBuilder: (context, index) {
                return _SettingsCardItem(data: items[index]);
              },
            );
          },
        ),
      ],
    );
  }
}

class _SettingsOption {
  final String title;
  final String subtitle;
  final IconData icon;
  final Color color;
  final String? route;
  final VoidCallback? onTap;

  const _SettingsOption({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.color,
    this.route,
    this.onTap,
  });
}

class _SettingsSurface {
  static const foreground = Color(0xFF1C1917);
  static const muted = Color(0xFF78716C);
  static const border = Color(0xFFE7E0D9);
  static const divider = Color(0xFFECE5DE);
}

class _SettingsCardItem extends StatefulWidget {
  final _SettingsOption data;
  const _SettingsCardItem({required this.data});

  @override
  State<_SettingsCardItem> createState() => _SettingsCardItemState();
}

class _SettingsCardItemState extends State<_SettingsCardItem> {
  bool _hovered = false;

  Color _accentFor(Color base) {
    if (base == const Color(0xFFFFE6D5)) return const Color(0xFFF97316);
    if (base == const Color(0xFFEAF0FF)) return const Color(0xFF3B82F6);
    if (base == const Color(0xFFE6F7EE)) return const Color(0xFF22C55E);
    if (base == const Color(0xFFFFF0D9) || base == const Color(0xFFFFEFE3)) {
      return const Color(0xFFEAB308);
    }
    if (base == const Color(0xFFFFE6E6) || base == const Color(0xFFFFEDED)) {
      return const Color(0xFFEF4444);
    }
    return _SettingsSurface.muted;
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    final accent = _accentFor(data.color);
    final isClickable = data.route != null || data.onTap != null;
    final active = isClickable && _hovered;

    return MouseRegion(
      cursor: isClickable ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        transform: Matrix4.translationValues(0, active ? -2 : 0, 0),
        decoration: BoxDecoration(
          color: isClickable ? Colors.white : const Color(0xFFF5F5F5),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: active
                ? accent.withValues(alpha: 0.30)
                : (isClickable ? _SettingsSurface.border : Colors.transparent),
          ),
          boxShadow: isClickable
              ? [
                  BoxShadow(
                    color: const Color(0x0D1C1917),
                    blurRadius: active ? 18 : 12,
                    offset: Offset(0, active ? 8 : 4),
                  ),
                  const BoxShadow(
                    color: Color(0x141C1917),
                    blurRadius: 4,
                    offset: Offset(0, 1),
                  ),
                ]
              : null,
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: isClickable
                ? () {
                    if (data.route != null) {
                      context.go(data.route!);
                    } else if (data.onTap != null) {
                      data.onTap!();
                    }
                  }
                : null,
            child: Opacity(
              opacity: isClickable ? 1.0 : 0.62,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment
                      .center, // Centrado vertical del contenido
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: isClickable
                            ? accent.withValues(alpha: 0.10)
                            : Colors.grey[300],
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: isClickable
                              ? accent.withValues(alpha: active ? 0.20 : 0.12)
                              : Colors.transparent,
                        ),
                      ),
                      child: Icon(
                        data.icon,
                        size: 20,
                        color: isClickable ? accent : Colors.grey[600],
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize:
                            MainAxisSize.min, // Ocupa solo el espacio necesario
                        children: [
                          Text(
                            data.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: isClickable
                                  ? _SettingsSurface.foreground
                                  : Colors.grey[700],
                              letterSpacing: -0.1,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            data.subtitle,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              height: 1.25,
                              fontSize: 12,
                              color: isClickable
                                  ? _SettingsSurface.muted
                                  : Colors.grey[500],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    if (isClickable)
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 180),
                        width: 24,
                        height: 24,
                        decoration: BoxDecoration(
                          color: active
                              ? accent.withValues(alpha: 0.08)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: AnimatedSlide(
                          duration: const Duration(milliseconds: 180),
                          offset: active ? const Offset(0.12, 0) : Offset.zero,
                          child: Icon(
                            Icons.chevron_right_rounded,
                            size: 18,
                            color: active ? accent : _SettingsSurface.muted,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
