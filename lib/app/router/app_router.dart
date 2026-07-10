import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:mangopos/core/utils/web_utils/web_utils.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:mangopos/presentation/settings/more%20settings/menus/categories/view/categories_view.dart';
import 'package:mangopos/presentation/settings/more%20settings/menus/modifiers/view/modifiers_view.dart';
import 'package:mangopos/presentation/settings/more%20settings/menus/combos/view/combos_view.dart';
import 'package:mangopos/presentation/settings/more%20settings/menus/menus/view/menus_view.dart';
import 'package:mangopos/presentation/settings/more%20settings/menus/recipes/view/recipes_view.dart';
import 'package:mangopos/presentation/settings/more%20settings/printing/printers/view/printers_view.dart.dart';
import 'package:mangopos/presentation/settings/more%20settings/printing/main/printing_home_view.dart';
import 'package:mangopos/presentation/settings/more%20settings/printing/areas/view/print_areas_view.dart';
import 'package:mangopos/presentation/settings/more%20settings/printing/products/view/printing_products_view.dart';
import 'package:mangopos/presentation/settings/more%20settings/printing/receipts/view/printing_receipts_view.dart';
import 'package:mangopos/presentation/settings/more%20settings/printing/orders/view/printing_orders_view.dart';
import 'package:mangopos/presentation/settings/more%20settings/printing/diagnostics/view/printing_diagnostics_view.dart';
import 'package:mangopos/presentation/settings/more%20settings/printing/health/view/printing_health_view.dart';
import 'package:mangopos/presentation/settings/more%20settings/system%20settings/tax/view/taxes_view.dart';
import 'package:mangopos/presentation/settings/business_profile/business_profile_screen.dart';
import 'package:mangopos/presentation/settings/my_account/my_account_screen.dart';
import 'package:mangopos/presentation/settings/more%20settings/system%20settings/zones_tables/view/zones_tables_view.dart';
import 'package:mangopos/presentation/settings/payment_methods/view/payment_methods_view.dart';
import 'package:mangopos/presentation/settings/more%20settings/system%20settings/users/view/roles_permissions_view.dart';
import 'package:mangopos/presentation/settings/more%20settings/system%20settings/users/view/users_view.dart';
import 'package:mangopos/presentation/settings/more%20settings/system%20settings/users/view/waiters_view.dart';
import 'package:mangopos/presentation/settings/more%20settings/system%20settings/fiscal/view/fiscal_receipts_view.dart';
import '../../presentation/auth/login/login_view.dart';
import '../../presentation/auth/login/select_business_view.dart';
import '../../tests/cache_test_page.dart';
import '../../presentation/auth/register/register_step1_view.dart';
import '../../presentation/auth/register/register_step2_view.dart';
import '../../presentation/auth/register/register_step3_view.dart';
import '../../presentation/auth/register/register_step4_view.dart';
import '../../presentation/auth/cross_auth/cross_auth_view.dart';
import '../../presentation/dashboard/dashboard_view.dart';
import '../../presentation/shell/main_shell.dart';
import '../../presentation/cashier/view/cashier_view.dart';
import '../../presentation/cashier/view/cash_closures_view.dart';
import '../../presentation/cashier/view/income_expense_view.dart';
import '../../presentation/cashier/view/sales_history_view.dart';
import '../../presentation/kitchen/view/kitchen_view.dart';
import '../../presentation/reservations/view/reservations_view.dart';
import '../../presentation/customers/view/customers_view.dart';
import '../../presentation/customers/view/customer_detail_view.dart';
import '../../presentation/inventory/view/inventory_hub_view.dart';
import '../../presentation/inventory/view/inventory_items_view.dart';
import '../../presentation/inventory/view/inventory_direct_receipts_view.dart';
import '../../presentation/inventory/view/inventory_kardex_view.dart';
import '../../presentation/inventory/view/inventory_lots_view.dart';
import '../../presentation/inventory/view/inventory_low_stock_view.dart';
import '../../presentation/inventory/view/inventory_rotation_view.dart';
import '../../presentation/inventory/view/inventory_valuation_view.dart';
import '../../presentation/inventory/view/consolidated_inventory_view.dart';
import '../../presentation/inventory/view/inventory_outflow_view.dart';
import '../../presentation/inventory/view/suppliers_view.dart';
import '../../presentation/inventory/view/warehouses_view.dart';
import '../../presentation/inventory/view/requirements_view.dart';
import '../../presentation/inventory/view/stock_reconciliation_view.dart';
import '../../presentation/inventory/view/production_orders_view.dart';
import '../../presentation/inventory/view/physical_count_view.dart';
import '../../presentation/inventory/view/inventory_reorder_view.dart';
import '../../presentation/inventory/view/transfers_view.dart';
import '../../presentation/purchases/view/purchases_list_view.dart';
import '../../presentation/purchases/view/purchases_register_view.dart';
import '../../presentation/promos/view/discounts_view.dart';
import '../../presentation/products/view/products_view.dart';
import '../../presentation/branches/view/branch_management_view.dart';
import '../../presentation/settings/cash_registers/view/cash_registers_view.dart';
import '../../presentation/settings/business_features/business_features_view.dart';
import '../../presentation/settings/cash_close_mode/cash_close_mode_view.dart';
import '../../presentation/settings/cash_reasons/view/cash_reasons_view.dart';
import '../../presentation/settings/comandas_config/comandas_config_view.dart';
import '../../presentation/settings/header_personalize/view/header_personalize_view.dart';
import '../../presentation/settings/currencies/view/currencies_view.dart';
import '../../presentation/settings/more settings/system settings/device/view/device_binding_view.dart';
import '../../presentation/settings/regional/view/regional_view.dart';
import 'package:mangopos/core/utils/logger.dart';
import 'route_permissions.dart';
import 'routes.dart';

// Sales module
import '../../presentation/sales/view/sales_shell_view.dart';
import '../../presentation/sales/view/sales_by_zone_view.dart';
import '../../presentation/sales/view/delivery_express_view.dart';
import '../../presentation/sales/view/self_service_view.dart';
import '../../presentation/sales/view/table_order_screen.dart';
import '../../presentation/sales/widgets/pos_barcode_scanner.dart';
import '../../presentation/reports/view/reports_view.dart';
import '../../presentation/reports/view/sales_by_waiter_view.dart';
import '../../presentation/reports/view/sales_report_view.dart';
import '../../presentation/reports/view/finance_report_view.dart';
import '../../presentation/reports/view/offers_report_view.dart';
import '../../presentation/reports/view/inventory_report_view.dart';
import '../../presentation/reports/view/purchases_report_view.dart';
import '../../presentation/reports/view/tax_report_view.dart';
import '../../presentation/reports/view/fiscal_report_view.dart';
import '../../presentation/reports/viewmodel/reports_viewmodel.dart';

// More Settings module
import 'package:mangopos/presentation/settings/view/settings_view.dart';
import 'package:mangopos/presentation/settings/view/plan_management_view.dart';
import 'package:mangopos/presentation/billing/view/my_subscription_view.dart';
import 'package:mangopos/presentation/billing/view/plan_selection_view.dart';
import 'package:mangopos/presentation/billing/view/payment_method_view.dart';
import 'package:mangopos/presentation/billing/view/charge_history_view.dart';
import 'package:mangopos/presentation/billing/view/onboarding_payment_result_view.dart';

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

  /// Permite disparar un refresh manual (ej. cuando cambian los permisos
  /// del usuario activo y el redirect global tiene que reevaluarse).
  void poke() => notifyListeners();

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

  /// Resolver inyectado desde `MyApp.build` (que tiene `ref`).
  /// Devuelve `true` si el usuario activo tiene el permiso pedido.
  /// Si el resolver no está seteado todavía (boot temprano), el router
  /// asume `true` para no bloquear la pantalla inicial.
  static bool Function(String permission)? permissionResolver;

  /// Home route por defecto según rol — fallback cuando un usuario
  /// intenta entrar a una ruta sin permiso. Inyectado desde `MyApp`.
  static String Function()? homeRouteResolver;

  /// Re-evalúa el redirect global. Lo llama `MyApp` cuando `sessionProvider`
  /// emite (cambio de rol o permisos refrescados).
  static void refreshGuards() => _authRefresh.poke();

  static String _initialLocation() {
    if (kIsWeb) {
      try {
        final href = WebUtils.href;
        final hash = WebUtils.hash;
        final search = WebUtils.search;
        AppLogger.d('[Router] href=$href');
        AppLogger.d('[Router] hash=$hash  search=$search');
        if (hash.startsWith('#')) {
          final fromHash = hash.substring(1);
          if (fromHash.isNotEmpty && fromHash != '/') {
            AppLogger.d('[Router] initialLocation from hash: $fromHash');
            return fromHash;
          }
        }
      } catch (e) {
        AppLogger.w('[Router] Error reading hash: $e');
      }
    }
    AppLogger.d('[Router] initialLocation fallback: ${AppRoutes.login}');
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

      // LOG DIAGNÓSTICO
      AppLogger.d(
        '[Router] redirect → path="$path" isAuthenticated=$isAuthenticated uri=${state.uri}',
      );

      final isAuthRoute =
          path == AppRoutes.login ||
          path == AppRoutes.register ||
          path == AppRoutes.registerStep2 ||
          path == AppRoutes.registerSetup ||
          path == AppRoutes.registerPaymentMethod ||
          path == AppRoutes.crossAuth ||
          path == AppRoutes.onboardingPaymentResult ||
          path == '/auth';

      AppLogger.d(
        '[Router] isAuthRoute=$isAuthRoute  isAuthenticated=$isAuthenticated',
      );

      if (!isAuthenticated) {
        if (isAuthRoute) return null;
        return Uri(
          path: AppRoutes.login,
          queryParameters: requestedBusinessId == null
              ? null
              : {'business_id': requestedBusinessId},
        ).toString();
      }

      // Autenticado:
      // - rutas auth -> selector interno de negocio
      // - raíz -> selector interno si tiene varios; dashboard si ya quedó negocio activo

      // EXCEPCIÓN onboarding: el Step 3 (activación) y Step 4 (método de pago)
      // del registro corren con el usuario YA autenticado — la cuenta se crea y
      // se firma la sesión DENTRO del Step 3 (submitAll). Sin esta excepción, al
      // firmarse la sesión el refresh del router rebota el Step 3 a
      // selectBusiness y el paso de pago (Step 4) nunca se muestra. Son parte
      // del onboarding del negocio recién creado (status 'pending'); Step 3
      // navega a Step 4, y Step 4 al dashboard al terminar (→ PendingApproval).
      if (path == AppRoutes.registerSetup ||
          path == AppRoutes.registerPaymentMethod) {
        return null;
      }

      if (isAuthRoute || path == '/') {
        return AppRoutes.selectBusiness;
      }

      // ── Permission gate ───────────────────────────────────────────
      // Bloquea rutas que el rol activo no debería visitar directo.
      // Sin esto, los permisos solo apagaban botones en el UI: un
      // usuario podía escribir la URL y entrar igual.
      // Excluimos selectBusiness para no romper el flujo si el resolver
      // aún no está listo durante el primer build de MyApp.
      final required = requiredPermissionForPath(path);
      if (required != null) {
        final resolver = permissionResolver;
        // Si el resolver todavía no fue inyectado (boot temprano antes
        // de que MyApp termine su primer build), no bloqueamos —
        // refreshListenable disparará otro redirect cuando esté listo.
        if (resolver != null && !resolver(required)) {
          final home = homeRouteResolver?.call() ?? AppRoutes.dashboard;
          AppLogger.d(
            '[Router] permiso denegado "$required" para "$path" → $home',
          );
          // Evita loops si la home también está bloqueada.
          if (home != path) return home;
          return AppRoutes.login;
        }
      }

      return null;
    },
    errorBuilder: (_, state) => _NotFoundView(path: state.uri.toString()),
    routes: [
      // ---------- Auth Cross (MOVIDO AL PRINCIPIO) ----------
      GoRoute(
        path: AppRoutes.selectBusiness,
        builder: (context, state) => const SelectBusinessView(),
      ),
      GoRoute(
        path: '/auth',
        builder: (context, state) {
          final at =
              state.uri.queryParameters['at'] ??
              state.uri.queryParameters['access_token'];
          final rt =
              state.uri.queryParameters['rt'] ??
              state.uri.queryParameters['refresh_token'];
          // LOG DIAGNÓSTICO
          AppLogger.i('[CrossAuth] GoRoute builder disparado!');
          AppLogger.d('[CrossAuth] state.uri = ${state.uri}');
          AppLogger.d(
            '[CrossAuth] at = ${at != null ? "[len=${at.length} inicio=${at.length > 10 ? at.substring(0, 10) : at}]" : "NULL"}',
          );
          AppLogger.d('[CrossAuth] rt = ${rt != null ? "[presente]" : "NULL"}');
          return CrossAuthView(accessToken: at, refreshToken: rt);
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
      GoRoute(
        path: '/ajustes/mozos',
        redirect: (context, state) => AppRoutes.settingsWaiters,
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
      GoRoute(
        path: AppRoutes.registerPaymentMethod,
        builder: (context, state) => const RegisterStep4View(),
      ),
      // Landing público al regresar del Payment Page de Azul (browser externo).
      GoRoute(
        path: AppRoutes.onboardingPaymentResult,
        builder: (context, state) => OnboardingPaymentResultView(
          result: state.uri.queryParameters['result'],
          reason: state.uri.queryParameters['reason'],
        ),
      ),

      // ---------- Shell principal (app autenticada) ----------
      // StatefulShellRoute.indexedStack: cada rama mantiene VIVO su Navigator
      // en un IndexedStack, así que al cambiar de sección y volver se conserva
      // el estado (scroll/página/filtro/pestaña). El menú superior/móvil usa
      // goBranch(index) para restaurar la última ubicación de cada rama; ver
      // shellBranchIndexForDestination en shell_destinations.dart — su orden
      // DEBE coincidir con el orden de estas `branches`.
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) =>
            MainShell(navigationShell: navigationShell),
        branches: [
          // ── Rama 0: Dashboard ──
          StatefulShellBranch(routes: [
          GoRoute(
            path: AppRoutes.dashboard,
            builder: (context, state) => const DashboardView(),
          ),
          ]),

          // ── Rama 1: Ventas (shell anidado + mesa a pantalla completa) ──
          StatefulShellBranch(routes: [
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
                  if (mode == 'selfservice') {
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
                      // RF-R1: escaneo de barras HID en venta rápida (retail).
                      // Gateado por barcodeEnabled dentro de PosBarcodeScanner.
                      return const PosBarcodeScanner(
                        autoOpenQuick: true,
                        child: OrderScreen(origin: OrderOrigin.quick),
                      );
                    case 'delivery':
                      return const DeliveryExpressView();
                    case 'delivery_order':
                      final tableId = state.uri.queryParameters['tableId'];
                      final deliveryType = state.uri.queryParameters['deliveryType'] ?? 'own';
                      return OrderScreen(
                        origin: OrderOrigin.delivery,
                        tableId: tableId,
                        deliveryType: deliveryType,
                      );
                    case 'selfservice':
                      return const SelfServiceView();
                    default:
                      return const SalesByZoneView(businessId: 'auto');
                  }
                },
              ),
              GoRoute(
                path: AppRoutes.salesByZone,
                builder: (context, state) => SalesByZoneView(
                  businessId: 'auto',
                  // Si viene de regreso desde una mesa, queremos
                  // mantenernos en la misma zona en vez de saltar a la
                  // primera. La pantalla de mesa pasa ?zone=<id> al
                  // hacer back.
                  initialZoneId: state.uri.queryParameters['zone'],
                ),
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
          ]),

          // ── Rama 2: Caja ──
          StatefulShellBranch(routes: [
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
          ]),

          // ── Rama 3: Cocina (KDS) ──
          StatefulShellBranch(routes: [
          // 2026-05-13: removida la ruta cashierSessionsHealth del cliente.
          // El dashboard NOC se traslada a mango_administrador. Ver PRD-12.
          GoRoute(
            path: AppRoutes.kitchen,
            builder: (context, state) => const KitchenView(),
          ),
          ]),

          // ── Rama 4: Reservas ──
          StatefulShellBranch(routes: [
          GoRoute(
            path: AppRoutes.reservations,
            builder: (context, state) => const ReservationsView(),
          ),
          ]),

          // ── Rama 5: Clientes ──
          StatefulShellBranch(routes: [
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
          ]),

          // ── Rama 6: Productos ──
          StatefulShellBranch(routes: [
          GoRoute(
            path: AppRoutes.products,
            builder: (context, state) => const ProductsView(),
          ),
          ]),

          // ── Rama 7: Reportes ──
          StatefulShellBranch(routes: [
          GoRoute(
            path: AppRoutes.reports,
            builder: (context, state) => ReportsView(
              initialCategory: _reportCategoryFromQuery(
                state.uri.queryParameters['tab'],
              ),
            ),
          ),
          GoRoute(
            path: AppRoutes.reportsSales,
            builder: (context, state) => const SalesReportView(),
          ),
          GoRoute(
            path: AppRoutes.reportsOffers,
            builder: (context, state) => const OffersReportView(),
          ),
          GoRoute(
            path: AppRoutes.reportsSalesByWaiter,
            builder: (context, state) => const SalesByWaiterView(),
          ),
          GoRoute(
            path: AppRoutes.reportsFinances,
            builder: (context, state) => const FinanceReportView(),
          ),
          GoRoute(
            path: AppRoutes.reportsInventory,
            builder: (context, state) => const InventoryReportView(),
          ),
          GoRoute(
            path: AppRoutes.reportsPurchases,
            builder: (context, state) => const PurchasesReportView(),
          ),
          GoRoute(
            path: AppRoutes.reportsTaxes,
            builder: (context, state) => const TaxReportView(),
          ),
          GoRoute(
            path: AppRoutes.reportsFiscal,
            builder: (context, state) => const FiscalReportView(),
          ),
          ]),

          // ── Rama 8: Ajustes (+ billing, sucursales, moneda, etc.) ──
          StatefulShellBranch(routes: [
          // ✅ Ajustes (vista principal)
          GoRoute(
            path: AppRoutes.settings,
            builder: (context, state) => const SettingsView(),
          ),
          GoRoute(
            path: AppRoutes.settingsPlan,
            builder: (context, state) => const PlanManagementView(),
          ),
          // Billing operativo (PRD Azul Subscriptions §5.2).
          GoRoute(
            path: AppRoutes.settingsBilling,
            builder: (context, state) => const MySubscriptionView(),
          ),
          GoRoute(
            path: AppRoutes.settingsBillingPlans,
            builder: (context, state) => const PlanSelectionView(),
          ),
          GoRoute(
            path: AppRoutes.settingsBillingPaymentMethod,
            builder: (context, state) => const PaymentMethodView(),
          ),
          GoRoute(
            path: AppRoutes.settingsBillingHistory,
            builder: (context, state) => const ChargeHistoryView(),
          ),
          GoRoute(
            path: AppRoutes.settingsUsers,
            builder: (context, state) =>
                const SettingsUsersView(businessId: 'auto'),
          ),
          GoRoute(
            path: AppRoutes.settingsWaiters,
            builder: (context, state) =>
                const SettingsWaitersView(businessId: 'auto'),
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
            path: AppRoutes.settingsBusinessProfile,
            builder: (context, state) =>
                const BusinessProfileScreen(businessId: 'auto'),
          ),
          GoRoute(
            path: AppRoutes.settingsMyAccount,
            builder: (context, state) => const MyAccountScreen(),
          ),
          GoRoute(
            path: AppRoutes.settingsZonesTables,
            builder: (context, state) =>
                const ZonesTablesView(businessId: 'auto'),
          ),
          GoRoute(
            path: AppRoutes.settingsPaymentMethods,
            builder: (context, state) =>
                const PaymentMethodsView(businessId: 'auto'),
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
            path: AppRoutes.settingsCashCloseMode,
            builder: (context, state) => const CashCloseModeView(),
          ),
          GoRoute(
            path: AppRoutes.settingsCashReasons,
            builder: (context, state) =>
                const CashReasonsView(businessId: 'auto'),
          ),
          GoRoute(
            path: AppRoutes.settingsBusinessFeatures,
            builder: (context, state) => const BusinessFeaturesView(),
          ),
          GoRoute(
            path: AppRoutes.settingsComandasConfig,
            builder: (context, state) => const ComandasConfigView(),
          ),
          GoRoute(
            path: AppRoutes.settingsHeaderPersonalize,
            builder: (context, state) => const HeaderPersonalizeView(),
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
            path: AppRoutes.settingsDeviceBinding,
            builder: (context, state) => const DeviceBindingView(),
          ),
          ]),

          // ── Rama 9: Inventario ──
          StatefulShellBranch(routes: [
          GoRoute(
            path: AppRoutes.inventoryHome,
            builder: (context, state) => const InventoryHubView(),
          ),
          GoRoute(
            path: AppRoutes.inventoryItems,
            builder: (context, state) => const InventoryItemsView(),
          ),
          GoRoute(
            path: AppRoutes.inventoryWarehouses,
            builder: (context, state) => const WarehousesView(),
          ),
          GoRoute(
            path: AppRoutes.inventorySuppliers,
            builder: (context, state) => const SuppliersView(),
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
            path: AppRoutes.inventoryKardex,
            builder: (context, state) => const InventoryKardexView(),
          ),
          GoRoute(
            path: AppRoutes.inventoryLowStock,
            builder: (context, state) => const InventoryLowStockView(),
          ),
          GoRoute(
            path: AppRoutes.inventoryReceipts,
            builder: (context, state) => const InventoryDirectReceiptsView(),
          ),
          GoRoute(
            path: AppRoutes.inventoryLots,
            builder: (context, state) => const InventoryLotsView(),
          ),
          GoRoute(
            path: AppRoutes.inventoryValuation,
            builder: (context, state) => const InventoryValuationView(),
          ),
          GoRoute(
            path: AppRoutes.inventoryRotation,
            builder: (context, state) => const InventoryRotationView(),
          ),
          GoRoute(
            path: AppRoutes.inventoryTransfers,
            builder: (context, state) => const TransfersView(),
          ),
          GoRoute(
            path: AppRoutes.inventoryConsolidated,
            builder: (context, state) => const ConsolidatedInventoryView(),
          ),
          GoRoute(
            path: AppRoutes.inventoryProduction,
            builder: (context, state) => const ProductionOrdersView(),
          ),
          GoRoute(
            path: AppRoutes.inventoryPhysicalCount,
            builder: (context, state) => const PhysicalCountView(),
          ),
          GoRoute(
            path: AppRoutes.inventoryReorder,
            builder: (context, state) => const InventoryReorderView(),
          ),
          ]),

          // ── Rama 10: Compras ──
          StatefulShellBranch(routes: [
          GoRoute(
            path: AppRoutes.purchasesList,
            builder: (context, state) => const PurchasesListView(),
          ),
          GoRoute(
            path: AppRoutes.purchasesRegister,
            builder: (context, state) => const PurchasesRegisterView(),
          ),
          ]),

          // ── Rama 11: Promociones ──
          StatefulShellBranch(routes: [
          GoRoute(
            path: AppRoutes.promosCenter,
            // ?offers=1 abre el modo solo-ofertas (sin cupones ni gift cards),
            // usado por la entrada "Ofertas y Promociones" de Ajustes. Sin el
            // query param se muestra el hub completo (Fidelización).
            builder: (context, state) => DiscountsView(
              offersOnly: state.uri.queryParameters['offers'] == '1',
            ),
          ),
          ]),

          // ── Rama 12: Menú (shell anidado) ──
          StatefulShellBranch(routes: [
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
              GoRoute(
                path: AppRoutes.menuCombos,
                builder: (context, state) => const CombosView(),
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
          ]),

          // ── Rama 13: Impresión (shell anidado) ──
          StatefulShellBranch(routes: [
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
              // /settings/printing/diagnostics
              GoRoute(
                path: AppRoutes.printingDiagnostics,
                builder: (context, state) =>
                    const PrintingDiagnosticsView(businessId: 'auto'),
              ),
              // Sprint 5 — /settings/printing/health
              GoRoute(
                path: AppRoutes.printingHealth,
                builder: (context, state) =>
                    const PrintingHealthView(businessId: 'auto'),
              ),
            ],
          ),
          // =======================================================================
          ]),
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

ReportCategory? _reportCategoryFromQuery(String? value) {
  switch (value) {
    case 'sales':
      return ReportCategory.sales;
    case 'offers':
      return ReportCategory.offers;
    case 'purchases':
      return ReportCategory.purchases;
    case 'finances':
      return ReportCategory.finances;
    case 'inventory':
      return ReportCategory.inventory;
    case 'taxes':
      return ReportCategory.taxes;
    case 'fiscal':
      return ReportCategory.fiscal;
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
