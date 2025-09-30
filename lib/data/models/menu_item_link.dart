class MenuItemLink {
  final String menuId;
  final String itemId;
  final int position;

  const MenuItemLink({required this.menuId, required this.itemId, this.position = 0});

  Map<String, dynamic> toInsert() => {
    'menu_id': menuId,
    'item_id': itemId,
    'position': position,
  };
}
