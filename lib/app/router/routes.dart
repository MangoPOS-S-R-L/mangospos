class AppRoutes {
  static const login = '/login';
  static const register = '/register';
  static const registerStep2 = '/register/branch';

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
  static const kitchen = '/kitchen';
  static const reservations = '/reservations';
  static const customers = '/customers';
  static const products = '/products';
  static const reports = '/reports';
  static const settings = '/settings';
  static const settingsUsers = '$settings/users';
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
  static const menuModifierGroups = '$menu/modifier-groups';
  static const menuModifiers = '$menu/modifiers';

  static const settingsZonesTables = '$settings/zones-tables';
  static const settingsTaxes = '$settings/taxes';
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
