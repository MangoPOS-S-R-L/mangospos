import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:mangopos/presentation/sales/view/theme/sales_theme.dart';

class SalesSidebar extends StatelessWidget {
  final VoidCallback onModeChange;

  const SalesSidebar({super.key, required this.onModeChange});

  @override
  Widget build(BuildContext context) {
    // Width 224px (w-56)
    return Container(
      width: 224,
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(right: BorderSide(color: SalesTheme.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header (h-16)
          Container(
            height: 64,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            alignment: Alignment.centerLeft,
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: SalesTheme.border)),
            ),
            child: Text(
              'MODO DE VENTA',
              style: GoogleFonts.plusJakartaSans(
                fontSize:
                    12, // text-sm (14?) spec says text-sm but usually uppercase is smaller. text-sm is 14px.
                // Spec: text-sm font-bold text-muted-foreground uppercase tracking-wide
                fontWeight: FontWeight.bold,
                color: SalesTheme.mutedForeground,
                letterSpacing: 1.0, // tracking-wide
              ),
            ),
          ),

          // Navigation
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // Active: Por Zona
                _SidebarButton(
                  icon: Icons.store,
                  label: 'Por Zona',
                  isActive:
                      true, // Should be active if routing matches, assuming current context is table order which is part of zone flow?
                  // Actually TableOrderScreen is "Por Zona" context.
                  onTap: () {}, // Already here
                ),
                const SizedBox(height: 8), // space-y-2
                // Inactive: Venta Manual
                _SidebarButton(
                  icon: Icons.edit_note, // PenTool equivalent
                  label: 'Venta Manual',
                  isActive: false,
                  onTap: onModeChange, // Goes back to zones or manual logic
                ),
                const SizedBox(height: 8),

                _SidebarButton(
                  icon: Icons.bolt, // Zap
                  label: 'Venta Rápida',
                  isActive: false,
                  onTap: () {},
                ),
                const SizedBox(height: 8),

                _SidebarButton(
                  icon: Icons.delivery_dining, // Bike
                  label: 'Delivery',
                  isActive: false,
                  onTap: () {},
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SidebarButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isActive;
  final VoidCallback onTap;

  const _SidebarButton({
    required this.icon,
    required this.label,
    required this.isActive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    // Active style: bg-primary text-white shadow-md focus:ring...
    // Inactive style: hover:bg-accent text-foreground
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        height: 40, // h-10
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: isActive ? SalesTheme.primary : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          boxShadow: isActive
              ? [
                  BoxShadow(
                    color: SalesTheme.primary.withOpacity(0.5),
                    blurRadius: 4,
                    offset: const Offset(0, 2),
                  ),
                ]
              : null,
        ),
        child: Row(
          children: [
            Icon(
              icon,
              size: 16, // w-4 h-4
              color: isActive ? Colors.white : SalesTheme.mutedForeground,
            ),
            const SizedBox(width: 12),
            Text(
              label,
              style: GoogleFonts.plusJakartaSans(
                fontSize: 14, // text-sm
                fontWeight: isActive ? FontWeight.w600 : FontWeight.w500,
                color: isActive ? Colors.white : SalesTheme.foreground,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
