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
import '../../../core/theme/app_breakpoints.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_radius.dart';
import '../../../core/theme/app_shadows.dart';
import '../../../data/repositories/inventory_repository.dart';
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
            ),
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
                  icon: Icons.fact_check_outlined,
                  title: 'Requerimientos',
                  subtitle: 'Sugerencias de reposición según stock mínimo',
                  route: AppRoutes.inventoryRequirements,
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

  const _Header({required this.bootstrapping, required this.onBootstrap});

  @override
  Widget build(BuildContext context) {
    final isCompact = ResponsiveHelper.useCompactShell(context);
    final titleBlock = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Inventario',
          style: TextStyle(
            fontSize: isCompact ? 22 : 28,
            fontWeight: FontWeight.w800,
            color: AppColors.foreground,
          ),
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
              boxShadow: AppShadows.soft,
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
