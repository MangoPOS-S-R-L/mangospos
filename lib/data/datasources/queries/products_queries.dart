class ProductsQueries {
  static const tableUserBusinesses = 'user_businesses';
  static const tableMenuItems = 'menu_items';
  static const tableCategories = 'categories';
  static const tableMenus = 'menus';
  static const tableMenuItemLinks = 'menu_item_links';
  static const tableMenuItemTaxes = 'menu_item_taxes';

  static const selectProducts =
      '*, categories(name), menu_item_links(menu_id, menus(name)), menu_item_taxes(tax_id)';
}
