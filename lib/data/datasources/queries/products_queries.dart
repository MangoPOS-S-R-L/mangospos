class ProductsQueries {
  static const tableUserBusinesses = 'user_businesses';
  static const tableMenuItems = 'menu_items';
  static const tableCategories = 'categories';
  static const tableMenus = 'menus';
  static const tableMenuItemLinks = 'menu_item_links';
  static const tableMenuItemTaxes = 'menu_item_taxes';

  static const selectProducts =
      '*, categories(name), menu_item_links(menu_id, menus(name)), menu_item_taxes(tax_id, taxes(rate, name))';

  // Vista helper: stock disponible por menu_item con receta 1:1. La
  // consultamos en una segunda query y mergeamos en memoria.
  static const viewMenuItemsStock = 'v_menu_items_stock';
  static const selectMenuItemsStock =
      'menu_item_id, available_units, unit, inventory_item_id';
  // Vínculo producto → insumo de la misma vista, para sumar ese insumo en
  // TODOS los almacenes (la vista suma solo los del punto de venta).
  static const selectMenuItemsStockLink =
      'menu_item_id, inventory_item_id, ingredient_per_unit';
  static const tableWarehouses = 'warehouses';
  static const tableInventoryStock = 'inventory_stock';
}
