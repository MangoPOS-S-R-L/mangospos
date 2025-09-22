class SidebarItem {
  final String label;
  final dynamic icon; // Acepta tanto IconData como Widget
  final String route;

  const SidebarItem({
    required this.label,
    required this.icon,
    required this.route,
  });
}
