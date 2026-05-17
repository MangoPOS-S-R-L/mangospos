// PRD 9 Fase 1A — Hub del módulo Inventario.
//
// Landing page del módulo: cards de navegación a sub-secciones (items,
// bodegas, proveedores, recepciones, transferencias, ajustes) + botón
// de Bootstrap que invoca `bootstrap_menu_to_inventory_links` en
// Supabase para preparar el menú existente del business.
//
// El bootstrap es idempotente y la RPC enforce role owner/admin/manager.
// Slices B/C/D agregan los sub-views; las cards a páginas no implementadas
// muestran un snackbar "próximamente".

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../app/router/routes.dart';
import '../../../core/business/business_features_provider.dart';
import '../../../core/theme/app_breakpoints.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_radius.dart';
import '../../../data/repositories/inventory_repository.dart';
import '../../../data/repositories/pos_settings_repository.dart';
import '../../../data/utils/business_id_resolver.dart';

class InventoryHubView extends ConsumerStatefulWidget {
  const InventoryHubView({super.key});

  @override
  ConsumerState<InventoryHubView> createState() => _InventoryHubViewState();
}

class _InventoryHubViewState extends ConsumerState<InventoryHubView> {
  bool _bootstrapping = false;

  Future<void> _runBootstrap() async {
    if (_bootstrapping) return;
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Inicializar inventario desde el menú'),
        content: const Text(
          'Se crearán los insumos faltantes y las recetas 1:1 (qty=1) '
          'a partir de tus productos del menú activos. La operación es '
          'segura de re-ejecutar: no duplica registros existentes.\n\n'
          '¿Continuar?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Inicializar'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _bootstrapping = true);
    try {
      final client = Supabase.instance.client;
      final businessId = await resolveBusinessIdOrNull(client, 'auto');
      if (businessId == null) {
        messenger.showSnackBar(const SnackBar(
          content: Text('No se pudo resolver el negocio activo.'),
        ));
        return;
      }

      final result = await InventoryRepository(client)
          .bootstrapMenuToInventoryLinks(businessId);

      if (!mounted) return;
      await showDialog<void>(
        context: navigator.context,
        builder: (ctx) => AlertDialog(
          title: const Text('Inicialización completada'),
          content: Text(
            'Items creados: ${result['items_created'] ?? 0}\n'
            'Recetas creadas: ${result['recipes_created'] ?? 0}\n'
            'Ingredientes creados: ${result['ingredients_created'] ?? 0}',
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Listo'),
            ),
          ],
        ),
      );
    } catch (e) {
      final msg = e.toString();
      final friendly = msg.contains('NOT_AUTHORIZED')
          ? 'No tenés permisos. Solo owner, admin o manager pueden inicializar.'
          : msg.contains('AUTH_REQUIRED')
              ? 'Sesión expirada. Volvé a iniciar sesión.'
              : 'Error: $msg';
      messenger.showSnackBar(SnackBar(content: Text(friendly)));
    } finally {
      if (mounted) setState(() => _bootstrapping = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isCompact = ResponsiveHelper.useCompactShell(context);
    final pagePadding = isCompact
        ? const EdgeInsets.fromLTRB(16, 16, 16, 24)
        : const EdgeInsets.all(24);
    final featuresAsync = ref.watch(businessFeaturesProvider);
    final inventoryMode = featuresAsync.maybeWhen(
      data: (f) => f.inventoryMode,
      orElse: () => InventoryMode.none,
    );
    return Scaffold(
      backgroundColor: Colors.white,
      body: SingleChildScrollView(
        padding: pagePadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Header(
              bootstrapping: _bootstrapping,
              onBootstrap: _runBootstrap,
              inventoryMode: inventoryMode,
            ),
            if (inventoryMode == InventoryMode.none) ...[
              const SizedBox(height: 16),
              _InventoryDisabledBanner(
                onActivate: () =>
                    context.go(AppRoutes.settingsBusinessFeatures),
              ),
            ],
            const SizedBox(height: 24),
            const _SectionTitle('Maestros'),
            const SizedBox(height: 12),
            _HubGrid(
              children: [
                _HubCard(
                  icon: Icons.inventory_2_outlined,
                  title: 'Insumos',
                  subtitle: 'Items inventariables, costo y stock mínimo',
                  route: AppRoutes.inventoryItems,
                  available: true,
                ),
                _HubCard(
                  icon: Icons.warehouse_outlined,
                  title: 'Bodegas',
                  subtitle: 'Almacenes físicos y bodega de tránsito',
                  route: AppRoutes.inventoryWarehouses,
                  available: true,
                ),
                _HubCard(
                  icon: Icons.local_shipping_outlined,
                  title: 'Proveedores',
                  subtitle: 'Catálogo de proveedores y condiciones',
                  route: AppRoutes.inventorySuppliers,
                  available: true,
                ),
              ],
            ),
            const SizedBox(height: 24),
            const _SectionTitle('Operaciones'),
            const SizedBox(height: 12),
            _HubGrid(
              children: [
                _HubCard(
                  icon: Icons.move_to_inbox_outlined,
                  title: 'Recepciones',
                  subtitle: 'Mercancía entrante sin OC formal',
                  route: AppRoutes.inventoryReceipts,
                  available: true,
                ),
                _HubCard(
                  icon: Icons.swap_horiz_outlined,
                  title: 'Transferencias',
                  subtitle: 'Movimientos entre bodegas',
                  route: AppRoutes.inventoryTransfers,
                  available: true,
                ),
                _HubCard(
                  icon: Icons.precision_manufacturing_outlined,
                  title: 'Producción',
                  subtitle:
                      'Transforma materias primas en productos terminados',
                  route: AppRoutes.inventoryProduction,
                  available: true,
                ),
                _HubCard(
                  icon: Icons.checklist_outlined,
                  title: 'Conteo físico',
                  subtitle:
                      'Congela el stock, registra el conteo real y aplica ajustes',
                  route: AppRoutes.inventoryPhysicalCount,
                  available: true,
                ),
                _HubCard(
                  icon: Icons.tune_outlined,
                  title: 'Ajustes',
                  subtitle: 'Correcciones puntuales de stock',
                  route: AppRoutes.inventoryReconciliation,
                  available: true,
                ),
                _HubCard(
                  icon: Icons.outbox_outlined,
                  title: 'Salidas / Mermas',
                  subtitle: 'Registra consumo interno, mermas y donaciones',
                  route: AppRoutes.inventoryOutflow,
                  available: true,
                ),
                _HubCard(
                  icon: Icons.shopping_cart_outlined,
                  title: 'Sugerencias de reorden',
                  subtitle:
                      'Productos bajo mínimo + crear OC directo al proveedor',
                  route: AppRoutes.inventoryReorder,
                  available: true,
                ),
                _HubCard(
                  icon: Icons.receipt_long_outlined,
                  title: 'Kardex',
                  subtitle: 'Historial de movimientos con saldo corrido',
                  route: AppRoutes.inventoryKardex,
                  available: true,
                ),
                _HubCard(
                  icon: Icons.notifications_active_outlined,
                  title: 'Alertas de stock',
                  subtitle: 'Insumos bajo el mínimo configurado',
                  route: AppRoutes.inventoryLowStock,
                  available: true,
                ),
                _HubCard(
                  icon: Icons.event_note_outlined,
                  title: 'Lotes y vencimientos',
                  subtitle: 'Tracking de lote y fecha de vencimiento',
                  route: AppRoutes.inventoryLots,
                  available: true,
                ),
                _HubCard(
                  icon: Icons.assessment_outlined,
                  title: 'Valoración y ABC',
                  subtitle: 'Valor de existencias con clasificación Pareto',
                  route: AppRoutes.inventoryValuation,
                  available: true,
                ),
                _HubCard(
                  icon: Icons.trending_up_outlined,
                  title: 'Análisis de Rotación',
                  subtitle: 'Velocidad de consumo, estrellas y estancados',
                  route: AppRoutes.inventoryRotation,
                  available: true,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final bool bootstrapping;
  final VoidCallback onBootstrap;
  final InventoryMode inventoryMode;

  const _Header({
    required this.bootstrapping,
    required this.onBootstrap,
    required this.inventoryMode,
  });

  @override
  Widget build(BuildContext context) {
    final isCompact = ResponsiveHelper.useCompactShell(context);
    final titleBlock = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Flexible(
              child: Text(
                'Inventario',
                style: TextStyle(
                  fontSize: isCompact ? 22 : 28,
                  fontWeight: FontWeight.w800,
                  color: AppColors.foreground,
                ),
              ),
            ),
            const SizedBox(width: 10),
            _InventoryModeChip(mode: inventoryMode),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          'Maestros, recepciones, transferencias y reportes de stock',
          style: TextStyle(
            fontSize: isCompact ? 12 : 14,
            color: AppColors.mutedForeground,
          ),
        ),
      ],
    );
    final button = FilledButton.icon(
      onPressed: bootstrapping ? null : onBootstrap,
      icon: bootstrapping
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: Colors.white),
            )
          : const Icon(Icons.auto_fix_high_outlined),
      label: Text(bootstrapping
          ? 'Inicializando...'
          : 'Inicializar desde menú'),
    );
    if (isCompact) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          titleBlock,
          const SizedBox(height: 12),
          button,
        ],
      );
    }
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: titleBlock),
        button,
      ],
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.w700,
        color: AppColors.foreground,
      ),
    );
  }
}

class _HubGrid extends StatelessWidget {
  final List<Widget> children;
  const _HubGrid({required this.children});

  @override
  Widget build(BuildContext context) {
    const spacing = 16.0;
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxW = constraints.maxWidth;
        final int cols;
        if (maxW < 600) {
          cols = 1;
        } else if (maxW < 900) {
          cols = 2;
        } else if (maxW < 1280) {
          cols = 3;
        } else {
          cols = 4;
        }
        final cardWidth = (maxW - (cols - 1) * spacing) / cols;
        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: [
            for (final c in children)
              SizedBox(width: cardWidth, child: c),
          ],
        );
      },
    );
  }
}

class _HubCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final String route;
  final bool available;

  const _HubCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.route,
    required this.available,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.card,
      borderRadius: BorderRadius.circular(AppRadius.lg),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        onTap: available
            ? () => context.go(route)
            : () => ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Disponible en una próxima fase.'),
                    duration: Duration(seconds: 2),
                  ),
                ),
        child: Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppRadius.lg),
              border: Border.all(color: AppColors.border),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(AppRadius.md),
                  ),
                  child: Icon(icon, color: AppColors.primary, size: 22),
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: AppColors.foreground,
                        ),
                      ),
                    ),
                    if (!available)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: AppColors.muted,
                          borderRadius: BorderRadius.circular(AppRadius.sm),
                        ),
                        child: Text(
                          'pronto',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            color: AppColors.mutedForeground,
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 12,
                    color: AppColors.mutedForeground,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
  }
}

/// Chip visible al lado del título "Inventario" que indica el modo actual.
/// Naranja para basic, morado para advanced, gris para none.
class _InventoryModeChip extends StatelessWidget {
  final InventoryMode mode;
  const _InventoryModeChip({required this.mode});

  @override
  Widget build(BuildContext context) {
    final (label, bg, fg, icon) = switch (mode) {
      InventoryMode.none => (
          'Apagado',
          const Color(0xFFF1F5F9),
          const Color(0xFF64748B),
          Icons.block,
        ),
      InventoryMode.basic => (
          'Básico',
          const Color(0xFFFFEDD5),
          const Color(0xFFC2410C),
          Icons.inventory_2_outlined,
        ),
      InventoryMode.advanced => (
          'Avanzado',
          const Color(0xFFEDE9FE),
          const Color(0xFF6D28D9),
          Icons.menu_book_outlined,
        ),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: fg),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.3,
              color: fg,
            ),
          ),
        ],
      ),
    );
  }
}

/// Banner que aparece SOLO cuando `inventory_mode = 'none'`. Avisa que el
/// módulo está apagado y ofrece un atajo directo a Settings → Modos de
/// negocio para activarlo. Resuelve el caso "está en none y no me daba
/// cuenta" que reportó el usuario.
class _InventoryDisabledBanner extends StatelessWidget {
  final VoidCallback onActivate;
  const _InventoryDisabledBanner({required this.onActivate});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFFFFBEB),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFFDE68A)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.warning_amber_rounded,
            color: Color(0xFFB45309),
            size: 28,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Inventario está apagado',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF92400E),
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  'En este modo el sistema no descuenta stock al vender, '
                  'no muestra alertas de bajo nivel ni habilita auto-86. '
                  'Actívalo en Modos de negocio para empezar a controlar '
                  'tu inventario.',
                  style: TextStyle(
                    fontSize: 12,
                    color: Color(0xFF92400E),
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 10),
                FilledButton.icon(
                  onPressed: onActivate,
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFFB45309),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                  ),
                  icon: const Icon(Icons.settings, size: 16),
                  label: const Text('Configurar modo de inventario'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
