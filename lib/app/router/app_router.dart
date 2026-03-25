// lib/app/app_router.dart
import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
// ignore: avoid_web_libraries_in_dot_dart
import 'package:web/web.dart' as web;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:mangopos/presentation/settings/more%20settings/menus/categories/view/categories_view.dart';
import 'package:mangopos/presentation/settings/more%20settings/menus/modifiers/view/modifiers_view.dart';
import 'package:mangopos/presentation/settings/more%20settings/menus/menus/view/menus_view.dart';
import 'package:mangopos/presentation/settings/more%20settings/menus/recipes/view/recipes_view.dart';
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
import 'package:mangopos/presentation/settings/more%20settings/system%20settings/fiscal/view/fiscal_receipts_view.dart';
import '../../presentation/auth/login/login_view.dart';
import '../../tests/cache_test_page.dart';
import '../../presentation/auth/register/register_step1_view.dart';
import '../../presentation/auth/register/register_step2_view.dart';
import '../../presentation/auth/register/register_step3_view.dart';
import '../../presentation/auth/cross_auth/cross_auth_view.dart';
import '../../presentation/dashboard/dashboard_view.dart';
import '../../presentation/shell/main_shell.dart';
import '../../presentation/cashier/view/cashier_view.dart';
import '../../presentation/cashier/view/cash_closures_view.dart';
import '../../presentation/cashier/view/income_expense_view.dart';
import '../../presentation/cashier/view/sales_history_view.dart';
import '../../presentation/kitchen/view/kitchen_view.dart';
import '../../presentation/customers/view/customers_view.dart';
import '../../presentation/customers/view/customer_detail_view.dart';
import '../../presentation/inventory/view/inventory_outflow_view.dart';
import '../../presentation/inventory/view/requirements_view.dart';
import '../../presentation/inventory/view/stock_reconciliation_view.dart';
import '../../presentation/purchases/view/purchases_list_view.dart';
import '../../presentation/purchases/view/purchases_register_view.dart';
import '../../presentation/promos/view/discounts_view.dart';
import '../../presentation/products/view/products_view.dart';
import '../../presentation/branches/view/branch_management_view.dart';
import '../../presentation/settings/cash_registers/view/cash_registers_view.dart';
import '../../presentation/settings/currencies/view/currencies_view.dart';
import '../../presentation/settings/regional/view/regional_view.dart';
import 'package:mangopos/core/utils/logger.dart';
import 'routes.dart';

// Sales module
import '../../presentation/sales/view/sales_shell_view.dart';
import '../../presentation/sales/view/sales_by_zone_view.dart';
import '../../presentation/sales/view/delivery_express_view.dart';
import '../../presentation/sales/view/self_service_view.dart';
import '../../presentation/sales/view/table_order_screen.dart';
import '../../presentation/reports/view/reports_view.dart';
import '../../presentation/reports/viewmodel/reports_viewmodel.dart';

// More Settings module
import 'package:mangopos/presentation/settings/view/settings_view.dart';
import 'package:mangopos/presentation/settings/view/plan_management_view.dart';

// ====== Gestión de impresión (imports) ======

// Si ya tienes las vistas reales del módulo Menú, impórtalas y
// reemplaza los _Placeholder donde corresponda.
// import 'package:mangopos/presentation/menu/view/menus_view.dart';
// import 'package:mangopos/presentation/menu/view/menu_items_view.dart';
// import 'package:mangopos/presentation/menu/view/categories_view.dart';
// import 'package:mangopos/presentation/menu/view/modifier_groups_view.dart';
// import 'package:mangopos/presentation/menu/view/modifiers_view.dart';

class GoRouterRefreshStream extends ChangeNotifier {
  GoRouterRefreshStream(Stream<dynamic> stream) {
    _subscription = stream.asBroadcastStream().listen((_) => notifyListeners());
  }

  late final StreamSubscription<dynamic> _subscription;

  @override
  void dispose() {
    _subscription.cancel();
    super.dispose();
  }
}

class AppRouter {
  static final GoRouterRefreshStream _authRefresh = GoRouterRefreshStream(
    Supabase.instance.client.auth.onAuthStateChange,
  );

  static String _initialLocation() {
    if (kIsWeb) {
      try {
        // ignore: avoid_web_libraries_in_dot_dart
        final hash = web.window.location.hash; // '#/auth?at=...&rt=...'
        if (hash.startsWith('#')) {
          final fromHash = hash.substring(1); // '/auth?at=...&rt=...'
          if (fromHash.isNotEmpty && fromHash != '/') {
            AppLogger.d('GoRouter initial from hash: $fromHash');
            return fromHash;
          }
        }
      } catch (_) {}
    }
    return AppRoutes.login;
  }

  static GoRouter router = GoRouter(
    initialLocation: _initialLocation(),
    refreshListenable: _authRefresh,
    redirect: (context, state) {
      final session = Supabase.instance.client.auth.currentSession;
      final isAuthenticated = session != null;
      final path = state.uri.path;
      final requestedBusinessId = state.uri.queryParameters['business_id'];
      
      // LOG PARA DEPURAR (ver en consola de Coolify/Browser)
      AppLogger.d('GoRouter Redirect: path=$path isAuthenticated=$isAuthenticated');

      final isAuthRoute =
          path == AppRoutes.login ||
          path == AppRoutes.register ||
          path == AppRoutes.registerStep2 ||
          path == AppRoutes.registerSetup ||
          path == AppRoutes.crossAuth ||
          path == '/auth'; // Hardcoded fallback

      if (!isAuthenticated) {
        if (isAuthRoute) return null;
        return Uri(
          path: AppRoutes.login,
          queryParameters: requestedBusinessId == null
              ? null
              : {'business_id': requestedBusinessId},
        ).toString();
      }

      if (isAuthRoute) {
        return Uri(
          path: AppRoutes.dashboard,
          queryParameters: requestedBusinessId == null
              ? null
              : {'business_id': requestedBusinessId},
        ).toString();
      }

      return null;
    },
    errorBuilder: (_, state) => _NotFoundView(path: state.uri.toString()),
    routes: [
      // ---------- Auth Cross (MOVIDO AL PRINCIPIO) ----------
      GoRoute(
        path: '/auth',
        builder: (context, state) {
          // Los tokens vienen como query params REALES de la URL (antes del '#'):
          // https://tenant.mangopos.do/?at=TOKEN&rt=TOKEN#/auth
          // GoRouter con hash-routing puede no pasarlos en state.uri, así que
          // CrossAuthView los leerá directamente de window.location como fallback.
          final at = state.uri.queryParameters['at']
              ?? state.uri.queryParameters['access_token'];
          final rt = state.uri.queryParameters['rt']
              ?? state.uri.queryParameters['refresh_token'];
          AppLogger.i(
            'CrossAuth route: at=${at != null && at.length > 10 ? "${at.substring(0, 10)}..." : at ?? "null (será leído de window.location)"}',
          );
          return CrossAuthView(
            accessToken: at,
            refreshToken: rt,
          );
        },
      ),
      // ---------- Alias React (paridad de rutas 1:1) ----------
      GoRoute(
        path: AppRoutes.homeReact,
        redirect: (context, state) => AppRoutes.dashboard,
      ),
      GoRoute(
        path: AppRoutes.cashierReact,
        redirect: (context, state) => AppRoutes.cashier,
      ),
      GoRoute(
        path: AppRoutes.kitchenReact,
        redirect: (context, state) => AppRoutes.kitchen,
      ),
      GoRoute(
        path: AppRoutes.productsReact,
        redirect: (context, state) => AppRoutes.products,
      ),
      GoRoute(
        path: AppRoutes.customersReact,
        redirect: (context, state) => AppRoutes.customers,
      ),
      GoRoute(
        path: AppRoutes.reportsReact,
        redirect: (context, state) => AppRoutes.reports,
      ),
      GoRoute(
        path: AppRoutes.settingsReact,
        redirect: (context, state) => AppRoutes.settings,
      ),

      // ---------- Auth ----------
      GoRoute(
        path: AppRoutes.login,
        builder: (context, state) => const LoginView(),
      ),
      GoRoute(
        path: AppRoutes.cacheTest,
        builder: (context, state) => const CacheTestPage(),
      ),
      GoRoute(
        path: AppRoutes.register,
        builder: (context, state) =>
            RegisterStep1View(initialPlan: state.uri.queryParameters['plan']),
      ),
      GoRoute(
        path: AppRoutes.registerStep2,
        builder: (context, state) => const RegisterStep2View(),
      ),
      GoRoute(
        path: AppRoutes.registerSetup,
        builder: (context, state) => const RegisterStep3View(),
      ),

      // ---------- Shell principal (app autenticada) ----------
      ShellRoute(
        builder: (context, state, child) => MainShell(child: child),
        routes: [
          GoRoute(
            path: AppRoutes.dashboard,
            builder: (context, state) => const DashboardView(),
          ),

          // ---------- Shell anidado: Ventas ----------
          ShellRoute(
            builder: (context, state, child) => SalesShellView(child: child),
            routes: [
              // /sales (legacy) -> /ventas
              GoRoute(
                path: AppRoutes.sales,
                redirect: (context, state) {
                  final mode = state.uri.queryParameters['mode'];
                  if (mode == null || mode.isEmpty) return AppRoutes.salesReact;
                  return Uri(
                    path: AppRoutes.salesReact,
                    queryParameters: {'mode': mode},
                  ).toString();
                },
              ),
              // /ventas?mode=manual|rapida|delivery|selfservice
              GoRoute(
                path: AppRoutes.salesReact,
                redirect: (context, state) {
                  final mode = state.uri.queryParameters['mode']
                      ?.toLowerCase()
                      .trim();
                  if (mode == 'delivery' || mode == 'selfservice') {
                    return AppRoutes.salesReact;
                  }
                  return null;
                },
                builder: (context, state) {
                  final mode = state.uri.queryParameters['mode']
                      ?.toLowerCase()
                      .trim();
                  switch (mode) {
                    case 'manual':
                      return const OrderScreen(origin: OrderOrigin.manual);
                    case 'rapida':
                      return const OrderScreen(origin: OrderOrigin.quick);
                    case 'delivery':
                      return const DeliveryExpressView();
                    case 'selfservice':
                      return const SelfServiceView();
                    default:
                      return const SalesByZoneView(businessId: 'auto');
                  }
                },
              ),
              GoRoute(
                path: AppRoutes.salesByZone,
                builder: (context, state) =>
                    const SalesByZoneView(businessId: 'auto'),
              ),
              GoRoute(
                path: AppRoutes.salesManual,
                builder: (context, state) =>
                    const OrderScreen(origin: OrderOrigin.manual),
              ),
              GoRoute(
                path: AppRoutes.salesQuick,
                builder: (context, state) =>
                    const OrderScreen(origin: OrderOrigin.quick),
              ),
              GoRoute(
                path: AppRoutes.salesDelivery,
                redirect: (context, state) => AppRoutes.salesReact,
                builder: (context, state) => const DeliveryExpressView(),
              ),
              GoRoute(
                path: AppRoutes.salesSelfService,
                redirect: (context, state) => AppRoutes.salesReact,
                builder: (context, state) => const SelfServiceView(),
              ),
            ],
          ),

          // ---------- Ruta de mesa (fuera del shell para pantalla completa) ----------
          GoRoute(
            path: '${AppRoutes.sales}/table/:tableId',
            builder: (context, state) {
              final tableId = state.pathParameters['tableId']!;
              final tableCode = state.uri.queryParameters['code'] ?? 'Mesa';
              final zoneId = state.uri.queryParameters['zone'] ?? '';
              final initialPeopleCount =
                  int.tryParse(state.uri.queryParameters['guests'] ?? '') ?? 1;
              return OrderScreen(
                origin: OrderOrigin.table,
                tableId: tableId,
                tableCode: tableCode,
                zoneId: zoneId,
                initialPeopleCount: initialPeopleCount > 0
                    ? initialPeopleCount
                    : 1,
              );
            },
          ),

          // ---------- Otros módulos (placeholder por ahora) ----------
          GoRoute(
            path: AppRoutes.cashier,
            builder: (context, state) => const CashierView(),
          ),
          GoRoute(
            path: AppRoutes.cashierHistory,
            builder: (context, state) => const SalesHistoryView(),
          ),
          GoRoute(
            path: AppRoutes.cashierClosures,
            builder: (context, state) => const CashClosuresView(),
          ),
          GoRoute(
            path: AppRoutes.cashierIncomeExpense,
            builder: (context, state) => const IncomeExpenseView(),
          ),
          GoRoute(
            path: AppRoutes.kitchen,
            builder: (context, state) => const KitchenView(),
          ),
          GoRoute(
            path: AppRoutes.reservations,
            builder: (context, state) =>
                const _Placeholder('Tables/Reservations'),
          ),
          GoRoute(
            path: AppRoutes.customers,
            builder: (context, state) => const CustomersView(),
            routes: [
              GoRoute(
                path: ':id',
                builder: (context, state) {
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
            builder: (context, state) => const ProductsView(),
          ),
          GoRoute(
            path: AppRoutes.reports,
            builder: (context, state) => ReportsView(
              initialCategory: _reportCategoryFromQuery(
                state.uri.queryParameters['tab'],
              ),
            ),
          ),

          // ✅ Ajustes (vista principal)
          GoRoute(
            path: AppRoutes.settings,
            builder: (context, state) => const SettingsView(),
          ),
          GoRoute(
            path: AppRoutes.settingsPlan,
            builder: (context, state) => const PlanManagementView(),
          ),
          GoRoute(
            path: AppRoutes.settingsUsers,
            builder: (context, state) =>
                const SettingsUsersView(businessId: 'auto'),
          ),
          GoRoute(
            path: '${AppRoutes.settingsRoles}/:userId/:employeeId',
            builder: (context, state) {
              final userId = state.pathParameters['userId'];
              final employeeId = state.pathParameters['employeeId'];
              return SettingsRolesView(
                businessId: 'auto',
                targetUserId: userId,
                targetEmployeeId: employeeId,
              );
            },
          ),
          GoRoute(
            path: AppRoutes.settingsRoles,
            builder: (context, state) =>
                const SettingsRolesView(businessId: 'auto'),
          ),
          GoRoute(
            path: AppRoutes.settingsZonesTables,
            builder: (context, state) =>
                const ZonesTablesView(businessId: 'auto'),
          ),
          GoRoute(
            path: AppRoutes.settingsTaxes,
            builder: (context, state) => const TaxesView(businessId: 'auto'),
          ),
          GoRoute(
            path: AppRoutes.settingsFiscalReceipts,
            builder: (context, state) =>
                const FiscalReceiptsView(businessId: 'auto'),
          ),
          GoRoute(
            path: AppRoutes.settingsBranches,
            builder: (context, state) => const BranchManagementView(),
          ),
          GoRoute(
            path: AppRoutes.settingsCashRegisters,
            builder: (context, state) => const CashRegistersView(),
          ),
          GoRoute(
            path: AppRoutes.settingsCurrencies,
            builder: (context, state) => const CurrenciesView(),
          ),
          GoRoute(
            path: AppRoutes.settingsRegional,
            builder: (context, state) => const RegionalView(),
          ),
          GoRoute(
            path: AppRoutes.inventoryRequirements,
            builder: (context, state) => const RequirementsView(),
          ),
          GoRoute(
            path: AppRoutes.inventoryOutflow,
            builder: (context, state) => const InventoryOutflowView(),
          ),
          GoRoute(
            path: AppRoutes.inventoryReconciliation,
            builder: (context, state) => const StockReconciliationView(),
          ),
          GoRoute(
            path: AppRoutes.purchasesList,
            builder: (context, state) => const PurchasesListView(),
          ),
          GoRoute(
            path: AppRoutes.purchasesRegister,
            builder: (context, state) => const PurchasesRegisterView(),
          ),
          GoRoute(
            path: AppRoutes.promosCenter,
            builder: (context, state) => const DiscountsView(),
          ),

          // ===================== GESTIÓN DE PRODUCTOS (MENÚ) =====================
          ShellRoute(
            builder: (context, state, child) => MenuShellView(child: child),
            routes: [
              // /menu -> redirige a /menu/menus
              GoRoute(
                path: AppRoutes.menu,
                redirect: (context, state) => AppRoutes.menuMenus,
              ),

              // /menu/menus
              GoRoute(
                path: AppRoutes.menuMenus,
                builder: (context, state) =>
                    const MenusView(businessId: 'auto'),
              ),

              // /menu/items
              GoRoute(
                path: AppRoutes.menuItems,
                builder: (context, state) => const ProductsView(),
              ),

              // /menu/categories
              GoRoute(
                path: AppRoutes.menuCategories,
                builder: (context, state) =>
                    const CategoriesView(businessId: 'auto'),
              ),

              GoRoute(
                path: AppRoutes.menuRecipes,
                builder: (context, state) => const RecipesView(),
              ),

              // /menu/modifier-groups
              GoRoute(
                path: AppRoutes.menuModifierGroups,
                redirect: (context, state) => AppRoutes.menuModifiers,
              ),

              // /menu/modifiers
              GoRoute(
                path: AppRoutes.menuModifiers,
                builder: (context, state) => const ModifiersView(),
              ),
            ],
          ),
          // =======================================================================

          // ===================== GESTIÓN DE IMPRESIÓN =====================
          ShellRoute(
            builder: (context, state, child) => PrintingShellView(child: child),
            routes: [
              // /settings/printing
              GoRoute(
                path: AppRoutes.printingBase,
                builder: (context, state) =>
                    const PrintingHomeView(businessId: 'auto'),
              ),
              // /settings/printing/printers
              GoRoute(
                path: AppRoutes.printingPrinters,
                builder: (context, state) =>
                    const PrintingPrintersView(businessId: 'auto'),
              ),
              // /settings/printing/areas
              GoRoute(
                path: AppRoutes.printingAreas,
                builder: (context, state) =>
                    const PrintingAreasView(businessId: 'auto'),
              ),
              // /settings/printing/products
              GoRoute(
                path: AppRoutes.printingProducts,
                builder: (context, state) =>
                    const PrintingProductsView(businessId: 'auto'),
              ),
              // /settings/printing/receipts
              GoRoute(
                path: AppRoutes.printingReceipts,
                builder: (context, state) =>
                    const PrintingReceiptsView(businessId: 'auto'),
              ),
              // /settings/printing/orders
              GoRoute(
                path: AppRoutes.printingOrders,
                builder: (context, state) =>
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
    return ColoredBox(color: const Color(0xFFFBFAF9), child: child);
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

ReportCategory? _reportCategoryFromQuery(String? value) {
  switch (value) {
    case 'sales':
      return ReportCategory.sales;
    case 'purchases':
      return ReportCategory.purchases;
    case 'finances':
      return ReportCategory.finances;
    case 'inventory':
      return ReportCategory.inventory;
    default:
      return null;
  }
}

class _NotFoundView extends StatelessWidget {
  final String path;
  const _NotFoundView({required this.path});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                '404',
                style: TextStyle(fontSize: 52, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 8),
              const Text('Ruta no encontrada'),
              const SizedBox(height: 8),
              Text(path, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => context.go(AppRoutes.dashboard),
                child: const Text('Volver al inicio'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
