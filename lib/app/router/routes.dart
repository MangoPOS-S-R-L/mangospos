class AppRoutes {
  static const login = '/login';
  static const register = '/register';
  static const registerStep2 = '/register/branch';

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

  // ---- Subrutas de ventas ----
  static const salesByZone = '$sales/by-zone';
  static const salesManual = '$sales/manual';
  static const salesQuick = '$sales/quick';
  static const salesDelivery = '$sales/delivery';
  static const salesSelfService = '$sales/self-service';

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
  static const printingAreas    = '$settings/printing/areas';

}
