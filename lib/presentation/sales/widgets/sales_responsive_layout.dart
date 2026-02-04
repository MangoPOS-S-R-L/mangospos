import 'package:flutter/material.dart';
import 'package:mangopos/presentation/sales/view/theme/sales_theme.dart';

class SalesResponsiveLayout extends StatelessWidget {
  final Widget sidebar;
  final Widget cart;
  final Widget catalog;
  final GlobalKey<ScaffoldState> scaffoldKey;

  final Widget? mobileBottomBar;

  const SalesResponsiveLayout({
    super.key,
    required this.sidebar,
    required this.cart,
    required this.catalog,
    required this.scaffoldKey,
    this.mobileBottomBar,
  });

  static bool isDesktop(BuildContext context) =>
      MediaQuery.of(context).size.width >= 1024;

  @override
  Widget build(BuildContext context) {
    final desktop = isDesktop(context);

    if (desktop) {
      return Scaffold(
        backgroundColor: SalesTheme.background,
        body: Row(
          children: [
            // Column 1: Sales Mode Sidebar
            SizedBox(width: 224, child: sidebar),
            // Divider
            Container(width: 1, color: SalesTheme.border),
            // Column 2: Cart
            SizedBox(width: 400, child: cart),
            // Divider
            Container(width: 1, color: SalesTheme.border),
            // Column 3: Catalog
            Expanded(child: catalog),
          ],
        ),
      );
    }

    // Mobile/Tablet Layout
    return Scaffold(
      key: scaffoldKey,
      backgroundColor: SalesTheme.background,
      drawer: Drawer(
        width: 280,
        backgroundColor: SalesTheme.cardBackground,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(),
        child: sidebar,
      ),
      endDrawer: Drawer(
        width: 400, // Same logic as desktop cart width for consistency
        backgroundColor: SalesTheme.cardBackground,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(),
        child: cart,
      ),
      body: catalog,
      bottomNavigationBar: mobileBottomBar,
    );
  }
}
