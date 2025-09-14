import 'package:flutter/material.dart';
import '../../app/widgets/sidebar/admin_sidebar.dart';
import '../../app/theme/mango_colors.dart';

class MainShell extends StatelessWidget {
  final Widget child;
  const MainShell({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final isWide = MediaQuery.of(context).size.width >= 900;

    return Scaffold(
      backgroundColor: const Color(0xFFF2F2F2),
      body: Row(
        children: [
          const AdminSidebar(width: 96),
          Expanded(
            child: Column(
              children: [
                // AppBar simple
                Container(
                  height: 56,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  alignment: Alignment.centerLeft,
                  decoration: const BoxDecoration(color: MangoColors.white),
                  child: Text('MangoPOS', style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: MangoColors.darkGray, fontWeight: FontWeight.w700)),
                ),
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.all(isWide ? 16 : 8),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: Container(color: MangoColors.white, child: child),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
