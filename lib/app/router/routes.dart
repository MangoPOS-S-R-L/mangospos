class AppRoutes {
  static const login = '/login';
  static const selectBusiness = '/select-business';
  static const register = '/register';
  static const registerStep2 = '/register/branch';
  static const registerSetup = '/register/setup';
  static const registerPaymentMethod = '/register/payment-method';
  static const crossAuth = '/auth';

  // Alias React (paridad 1:1)
  static const homeReact = '/';
  static const salesReact = '/ventas';
  static const cashierReact = '/caja';
  static const kitchenReact = '/cocina';
  static const productsReact = '/productos';
  static const customersReact = '/clientes';
  static const reportsReact = '/reportes';
  static const settingsReact = '/ajustes';

  // Shell autenticado
  static const dashboard = '/dashboard';
  static const sales = '/sales';
  static const cashier = '/cashier';
  static const cashierHistory = '$cashier/history';
  static const cashierClosures = '$cashier/closures';
  static const cashierIncomeExpense = '$cashier/income-expense';
  // 2026-05-13: removida cashierSessionsHealth — el NOC se traslada a
  // mango_administrador (ver PRD-12).
  static const kitchen = '/kitchen';
  static const reservations = '/reservations';
  static const customers = '/customers';
  static const credits = '/credits';
  static const accounting = '/accounting';
  static const products = '/products';
  static const reports = '/reports';
  static const reportsSales = '$reports/sales';
  static const reportsOffers = '$reports/offers';
  static const reportsDelivery = '$reports/delivery';
  static const reportsSalesByWaiter = '$reports/sales-by-waiter';
  static const reportsFinances = '$reports/finances';
  static const reportsInventory = '$reports/inventory';
  static const reportsPurchases = '$reports/purchases';
  static const reportsTaxes = '$reports/taxes';
  static const reportsFiscal = '$reports/fiscal';
  static const settings = '/settings';
  static const settingsPlan = '$settings/plan';
  static const purchasesList = '$settings/purchases';
  static const purchasesRegister = '$settings/purchases/register';
  /// Detalle de UNA factura de compra. `:orderId` es el uuid de la orden.
  /// Cuelga de `purchasesList`, así hereda su permiso (`compras.acceso`):
  /// consultar una factura es lo mismo que consultar el listado.
  static const purchasesOrderDetail = '$purchasesList/order/:orderId';
  static String purchasesOrderDetailPath(String orderId) =>
      '$purchasesList/order/$orderId';
  static const promosCenter = '$settings/promos';
  static const settingsUsers = '$settings/users';
  static const settingsWaiters = '$settings/waiters';
  static const settingsRoles = '$settings/roles';

  // ---- Subrutas de ventas ----
  static const salesByZone = '$sales/by-zone';
  static const salesManual = '$sales/manual';
  static const salesQuick = '$sales/quick';
  static const salesDelivery = '$sales/delivery';
  static const salesSelfService = '$sales/self-service';
  static const salesTable = '$sales/table';

  // 👇 subruta de Ajustes

  // ---- Módulo Menú (Gestión de productos) ----
  static const menu = '/menu';

  // ---- Subrutas de Menú ----
  static const menuMenus = '$menu/menus';
  static const menuItems = '$menu/items';
  static const menuCategories = '$menu/categories';
  static const menuRecipes = '$menu/recipes';
  static const menuCombos = '$menu/combos';
  static const menuModifierGroups = '$menu/modifier-groups';
  static const menuModifiers = '$menu/modifiers';

  static const settingsBusinessProfile = '$settings/business-profile';
  static const settingsHeaderPersonalize = '$settings/header-personalize';
  static const settingsMyAccount = '$settings/my-account';
  static const settingsZonesTables = '$settings/zones-tables';
  static const settingsPaymentMethods = '$settings/payment-methods';
  static const settingsTaxes = '$settings/taxes';
  static const settingsFiscalReceipts = '$settings/fiscal-receipts';
  static const settingsBranches = '$settings/branches';
  static const settingsCashRegisters = '$settings/cash-registers';
  static const settingsCashCloseMode = '$settings/cash-close-mode';
  static const settingsMallSalesExport = '$settings/cash-close-mode/mall-export';
  static const settingsCashReasons = '$settings/cash-reasons';
  static const settingsBusinessFeatures = '$settings/business-features';

  // ---- Billing (PRD Azul Subscriptions §5.2) ----
  static const settingsBilling = '$settings/billing';
  static const settingsBillingPlans = '$settingsBilling/plans';
  static const settingsBillingPaymentMethod = '$settingsBilling/payment-method';
  static const settingsBillingHistory = '$settingsBilling/history';
  static const onboardingPaymentResult = '/onboarding/payment-result';
  static const settingsComandasConfig = '$settings/comandas-config';
  static const settingsCurrencies = '$settings/currencies';
  static const settingsRegional = '$settings/regional';
  static const settingsDeviceBinding = '$settings/device-binding';
  static const inventoryKardex = '$settings/inventory-kardex';
  static const inventoryRequirements = '$settings/inventory-requirements';
  static const inventoryOutflow = '$settings/inventory-outflow';
  static const inventoryReconciliation = '$settings/inventory-reconciliation';
  static const inventoryLowStock = '$settings/inventory-low-stock';
  static const inventoryLots = '$settings/inventory-lots';
  static const inventoryValuation = '$settings/inventory-valuation';
  static const inventoryRotation = '$settings/inventory-rotation';

  // ---- Módulo Inventario (PRD 9) ----
  static const inventoryHome = '/inventory';
  static const inventoryItems = '$inventoryHome/items';
  static const inventoryWarehouses = '$inventoryHome/warehouses';
  /// Interior de UNA bodega (Fase 2). `:warehouseId` es el uuid; el query
  /// opcional `?tab=movimientos|transferencias` abre la pestaña directo.
  static const inventoryWarehouseDetail =
      '$inventoryWarehouses/:warehouseId';
  static const inventorySuppliers = '$inventoryHome/suppliers';
  /// Interior de UN proveedor (Fase 3). `:supplierId` es el uuid; el query
  /// opcional `?tab=ordenes|cuenta` abre la pestaña directo.
  static const inventorySupplierDetail = '$inventorySuppliers/:supplierId';
  static const inventoryReceipts = '$inventoryHome/receipts';
  static const inventoryTransfers = '$inventoryHome/transfers';
  static const inventoryAdjustments = '$inventoryHome/adjustments';
  static const inventoryProduction = '$inventoryHome/production';
  static const inventoryPhysicalCount = '$inventoryHome/physical-count';
  static const inventoryReorder = '$inventoryHome/reorder';
  static const inventoryConsolidated = '$inventoryHome/consolidated';
  static const printingBase = '$settings/printing';

  // ---- Gestión de impresión (sin businessId en URL) ----
  static const printingPrinters = '$settings/printing/printers';
  static const printingAreas = '$settings/printing/areas';
  static const printingProducts = '$settings/printing/products';
  static const printingReceipts = '$settings/printing/receipts';
  static const printingOrders = '$settings/printing/orders';
  static const printingDiagnostics = '$settings/printing/diagnostics';
  static const printingHealth = '$settings/printing/health';
  static const printingPrinterless = '$settings/printing/printerless';

  // ---- Tests ----
  static const cacheTest = '/cache-test';
}
