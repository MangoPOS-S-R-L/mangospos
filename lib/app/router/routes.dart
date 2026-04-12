class AppRoutes {
  static const login = '/login';
  static const selectBusiness = '/select-business';
  static const register = '/register';
  static const registerStep2 = '/register/branch';
  static const registerSetup = '/register/setup';
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
  static const kitchen = '/kitchen';
  static const reservations = '/reservations';
  static const customers = '/customers';
  static const products = '/products';
  static const reports = '/reports';
  static const reportsSales = '$reports/sales';
  static const reportsFinances = '$reports/finances';
  static const reportsInventory = '$reports/inventory';
  static const reportsPurchases = '$reports/purchases';
  static const reportsTaxes = '$reports/taxes';
  static const reportsFiscal = '$reports/fiscal';
  static const settings = '/settings';
  static const settingsPlan = '$settings/plan';
  static const purchasesList = '$settings/purchases';
  static const purchasesRegister = '$settings/purchases/register';
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

  static const settingsZonesTables = '$settings/zones-tables';
  static const settingsTaxes = '$settings/taxes';
  static const settingsFiscalReceipts = '$settings/fiscal-receipts';
  static const settingsBranches = '$settings/branches';
  static const settingsCashRegisters = '$settings/cash-registers';
  static const settingsCurrencies = '$settings/currencies';
  static const settingsRegional = '$settings/regional';
  static const inventoryKardex = '$settings/inventory-kardex';
  static const inventoryRequirements = '$settings/inventory-requirements';
  static const inventoryOutflow = '$settings/inventory-outflow';
  static const inventoryReconciliation = '$settings/inventory-reconciliation';
  static const printingBase = '$settings/printing';

  // ---- Gestión de impresión (sin businessId en URL) ----
  static const printingPrinters = '$settings/printing/printers';
  static const printingAreas = '$settings/printing/areas';
  static const printingProducts = '$settings/printing/products';
  static const printingReceipts = '$settings/printing/receipts';
  static const printingOrders = '$settings/printing/orders';

  // ---- Tests ----
  static const cacheTest = '/cache-test';
}
