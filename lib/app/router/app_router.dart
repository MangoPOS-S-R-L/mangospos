// lib/app/app_router.dart
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:mangopos/presentation/settings/more%20settings/menus/categories/view/categories_view.dart';
import 'package:mangopos/presentation/settings/more%20settings/menus/menu%20items/view/menu_items_view.dart';
import 'package:mangopos/presentation/settings/more%20settings/menus/menus/view/menus_view.dart';
import 'package:mangopos/presentation/settings/more%20settings/printing/printers/view/printers_view.dart.dart';
import 'package:mangopos/presentation/settings/more%20settings/printing/main/printing_home_view.dart';
import 'package:mangopos/presentation/settings/more%20settings/printing/areas/view/print_areas_view.dart';
import 'package:mangopos/presentation/settings/more%20settings/printing/products/view/printing_products_view.dart';
import 'package:mangopos/presentation/settings/more%20settings/printing/receipts/view/printing_receipts_view.dart';
import 'package:mangopos/presentation/settings/more%20settings/printing/orders/view/printing_orders_view.dart';
import 'package:mangopos/presentation/settings/more%20settings/system%20settings/tax/view/taxes_view.dart';
import 'package:mangopos/presentation/settings/more%20settings/system%20settings/zones_tables/view/zones_tables_view.dart';
import 'package:mangopos/presentation/settings/more%20settings/system%20settings/users/view/roles_permissions_view.dart';
import 'package:mangopos/presentation/settings/more%20settings/system%20settings/users/view/users_view.dart';
import '../../presentation/auth/login/login_view.dart';
import '../../tests/cache_test_page.dart';
import '../../presentation/auth/register/register_step1_view.dart';
import '../../presentation/auth/register/register_step2_view.dart';
import '../../presentation/dashboard/dashboard_view.dart';
import '../../presentation/shell/main_shell.dart';
import '../../presentation/cashier/view/cashier_view.dart';
import '../../presentation/kitchen/view/kitchen_view.dart';
import '../../presentation/customers/view/customers_view.dart';
import '../../presentation/customers/view/customer_detail_view.dart';
import '../../presentation/products/view/products_view.dart';
import 'routes.dart';

// Sales module
import '../../presentation/sales/view/sales_shell_view.dart';
import '../../presentation/sales/view/sales_by_zone_view.dart';
import '../../presentation/sales/view/manual_sale_view.dart';
import '../../presentation/sales/view/sale_quick_view.dart';
import '../../presentation/sales/view/delivery_express_view.dart';
import '../../presentation/sales/view/self_service_view.dart';
import '../../presentation/sales/view/table_order_screen.dart';
import '../../presentation/reports/view/reports_view.dart';

// More Settings module
import 'package:mangopos/presentation/settings/view/settings_view.dart';

// ====== Gestión de impresión (imports) ======

// Si ya tienes las vistas reales del módulo Menú, impórtalas y
// reemplaza los _Placeholder donde corresponda.
// import 'package:mangopos/presentation/menu/view/menus_view.dart';
// import 'package:mangopos/presentation/menu/view/menu_items_view.dart';
// import 'package:mangopos/presentation/menu/view/categories_view.dart';
// import 'package:mangopos/presentation/menu/view/modifier_groups_view.dart';
// import 'package:mangopos/presentation/menu/view/modifiers_view.dart';

class AppRouter {
  static GoRouter router = GoRouter(
    // cambia a login/dashboard según tu flujo
    initialLocation: AppRoutes.login,
    routes: [
      // ---------- Auth ----------
      GoRoute(path: AppRoutes.login, builder: (_, __) => const LoginView()),
      GoRoute(
        path: AppRoutes.cacheTest,
        builder: (_, __) => const CacheTestPage(),
      ),
      GoRoute(
        path: AppRoutes.register,
        builder: (_, __) => const RegisterStep1View(),
      ),
      GoRoute(
        path: AppRoutes.registerStep2,
        builder: (_, __) => const RegisterStep2View(),
      ),

      // ---------- Shell principal (app autenticada) ----------
      ShellRoute(
        builder: (_, __, child) => MainShell(child: child),
        routes: [
          GoRoute(
            path: AppRoutes.dashboard,
            builder: (_, __) => const DashboardView(),
          ),

          // ---------- Shell anidado: Ventas ----------
          ShellRoute(
            builder: (_, __, child) => SalesShellView(child: child),
            routes: [
              // /sales  -> redirect a /sales/by-zone
              GoRoute(
                path: AppRoutes.sales,
                redirect: (_, __) => AppRoutes.salesByZone,
              ),
              GoRoute(
                path: AppRoutes.salesByZone,
                builder: (_, __) => const SalesByZoneView(businessId: 'auto'),
              ),
              GoRoute(
                path: AppRoutes.salesManual,
                builder: (_, __) => const ManualSaleView(),
              ),
              GoRoute(
                path: AppRoutes.salesQuick,
                builder: (_, __) => const SaleQuickView(),
              ),
              GoRoute(
                path: AppRoutes.salesDelivery,
                builder: (_, __) => const DeliveryExpressView(),
              ),
              GoRoute(
                path: AppRoutes.salesSelfService,
                builder: (_, __) => const SelfServiceView(),
              ),
            ],
          ),

          // ---------- Ruta de mesa (fuera del shell para pantalla completa) ----------
          GoRoute(
            path: '${AppRoutes.sales}/table/:tableId',
            builder: (_, state) {
              final tableId = state.pathParameters['tableId']!;
              final tableCode = state.uri.queryParameters['code'] ?? 'Mesa';
              final zoneId = state.uri.queryParameters['zone'] ?? '';
              return TableOrderScreen(
                tableId: tableId,
                tableCode: tableCode,
                zoneId: zoneId,
              );
            },
          ),

          // ---------- Otros módulos (placeholder por ahora) ----------
          GoRoute(
            path: AppRoutes.cashier,
            builder: (_, __) => const CashierView(),
          ),
          GoRoute(
            path: AppRoutes.kitchen,
            builder: (_, __) => const KitchenView(),
          ),
          GoRoute(
            path: AppRoutes.reservations,
            builder: (_, __) => const _Placeholder('Tables/Reservations'),
          ),
          GoRoute(
            path: AppRoutes.customers,
            builder: (_, __) => const CustomersView(),
            routes: [
              GoRoute(
                path: ':id',
                builder: (_, state) {
                  final id = state.pathParameters['id']!;
                  final name = state.uri.queryParameters['name'] ?? 'Cliente';
                  final orders =
                      int.tryParse(
                        state.uri.queryParameters['orders'] ?? '0',
                      ) ??
                      0;
                  return CustomerDetailView(
                    customerName: name,
                    ordersCount: orders,
                  );
                },
              ),
            ],
          ),
          GoRoute(
            path: AppRoutes.products,
            builder: (_, __) => const ProductsView(),
          ),
          GoRoute(
            path: AppRoutes.reports,
            builder: (_, __) => const ReportsView(),
          ),

          // ✅ Ajustes (vista principal)
          GoRoute(
            path: AppRoutes.settings,
            builder: (_, __) => const SettingsView(),
          ),
          GoRoute(
            path: AppRoutes.settingsUsers,
            builder: (_, __) => const SettingsUsersView(businessId: 'auto'),
          ),
          GoRoute(
            path: AppRoutes.settingsRoles,
            builder: (_, __) => const SettingsRolesView(businessId: 'auto'),
          ),
          GoRoute(
            path: AppRoutes.settingsZonesTables,
            builder: (_, __) => const ZonesTablesView(businessId: 'auto'),
          ),
          GoRoute(
            path: AppRoutes.settingsTaxes,
            builder: (_, __) => const TaxesView(businessId: 'auto'),
          ),

          // ===================== GESTIÓN DE PRODUCTOS (MENÚ) =====================
          ShellRoute(
            builder: (_, __, child) => MenuShellView(child: child),
            routes: [
              // /menu -> redirige a /menu/menus
              GoRoute(
                path: AppRoutes.menu,
                redirect: (_, __) => AppRoutes.menuMenus,
              ),

              // /menu/menus
              GoRoute(
                path: AppRoutes.menuMenus,
                builder: (_, __) => const MenusView(businessId: 'auto'),
              ),

              // /menu/items
              GoRoute(
                path: AppRoutes.menuItems,
                builder: (_, __) => const MenuItemsView(businessId: 'auto'),
              ),

              // /menu/categories
              GoRoute(
                path: AppRoutes.menuCategories,
                builder: (_, __) => const CategoriesView(businessId: 'auto'),
              ),

              // /menu/modifier-groups
              GoRoute(
                path: AppRoutes.menuModifierGroups,
                builder: (_, __) =>
                    const _Placeholder('Grupos de modificadores'),
              ),

              // /menu/modifiers
              GoRoute(
                path: AppRoutes.menuModifiers,
                builder: (_, __) =>
                    const _Placeholder('Modificadores de artículo'),
              ),
            ],
          ),
          // =======================================================================

          // ===================== GESTIÓN DE IMPRESIÓN =====================
          ShellRoute(
            builder: (_, __, child) => PrintingShellView(child: child),
            routes: [
              // /settings/printing
              GoRoute(
                path: AppRoutes.printingBase,
                builder: (_, __) => const PrintingHomeView(businessId: 'auto'),
              ),
              // /settings/printing/printers
              GoRoute(
                path: AppRoutes.printingPrinters,
                builder: (_, __) =>
                    const PrintingPrintersView(businessId: 'auto'),
              ),
              // /settings/printing/areas
              GoRoute(
                path: AppRoutes.printingAreas,
                builder: (_, __) => const PrintingAreasView(businessId: 'auto'),
              ),
              // /settings/printing/products
              GoRoute(
                path: AppRoutes.printingProducts,
                builder: (_, __) =>
                    const PrintingProductsView(businessId: 'auto'),
              ),
              // /settings/printing/receipts
              GoRoute(
                path: AppRoutes.printingReceipts,
                builder: (_, __) =>
                    const PrintingReceiptsView(businessId: 'auto'),
              ),
              // /settings/printing/orders
              GoRoute(
                path: AppRoutes.printingOrders,
                builder: (_, __) =>
                    const PrintingOrdersView(businessId: 'auto'),
              ),
            ],
          ),
          // =======================================================================
        ],
      ),
    ],
  );
}

// Shell sencillo para el módulo Menú (cámbialo por algo más elaborado si quieres)
class MenuShellView extends StatelessWidget {
  final Widget child;
  const MenuShellView({super.key, required this.child});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Gestión de productos')),
      body: child,
    );
  }
}

// ✅ Shell para Gestión de impresión (anidado)
class PrintingShellView extends StatelessWidget {
  final Widget child;
  const PrintingShellView({super.key, required this.child});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Gestión de impresión')),
      backgroundColor: Colors.white,
      body: child,
    );
  }
}

// Placeholder temporal para los módulos que aún no tienen vista real
class _Placeholder extends StatelessWidget {
  final String label;
  const _Placeholder(this.label);

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: Text(
        label,
        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
      ),
    ),
  );
}
