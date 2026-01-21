import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

enum ReportCategory { sales, purchases, finances, inventory }

class ReportItem {
  final String title;
  final String description;
  final VoidCallback? onTap;

  const ReportItem({
    required this.title,
    required this.description,
    this.onTap,
  });
}

class ReportsState {
  final ReportCategory? selectedCategory;

  const ReportsState({this.selectedCategory});

  ReportsState copyWith({ReportCategory? selectedCategory}) {
    return ReportsState(selectedCategory: selectedCategory);
  }
}

class ReportsViewModel extends StateNotifier<ReportsState> {
  ReportsViewModel() : super(const ReportsState());

  void selectCategory(ReportCategory? category) {
    state = state.copyWith(selectedCategory: category);
  }

  List<ReportItem> getReportsForCategory(ReportCategory category) {
    switch (category) {
      case ReportCategory.sales:
        return [
          const ReportItem(
            title: 'Todas las ventas',
            description: 'Lista completa de ventas realizadas',
          ),
          const ReportItem(
            title: 'Ventas anuladas',
            description: 'Registro de ventas canceladas',
          ),
          const ReportItem(
            title: 'Ventas por productos',
            description: 'Desglose de ventas por ítem',
          ),
          const ReportItem(
            title: 'Ventas por mozo',
            description: 'Rendimiento por personal',
          ),
        ];
      case ReportCategory.purchases:
        return [
          const ReportItem(
            title: 'Todas las compras',
            description: 'Historial de compras',
          ),
          const ReportItem(
            title: 'Compras por proveedor',
            description: 'Gastos por proveedor',
          ),
        ];
      case ReportCategory.finances:
        return [
          const ReportItem(
            title: 'Cierre de caja',
            description: 'Resumen de cierres diarios',
          ),
          const ReportItem(
            title: 'Movimientos de caja',
            description: 'Ingresos y egresos detallados',
          ),
        ];
      case ReportCategory.inventory:
        return [
          const ReportItem(
            title: 'Stock actual',
            description: 'Niveles de inventario en tiempo real',
          ),
          const ReportItem(
            title: 'Kardex',
            description: 'Movimientos de inventario',
          ),
          const ReportItem(title: 'Merma', description: 'Registro de pérdidas'),
        ];
    }
  }

  String getCategoryTitle(ReportCategory category) {
    switch (category) {
      case ReportCategory.sales:
        return 'Informe de ventas';
      case ReportCategory.purchases:
        return 'Informe de compras';
      case ReportCategory.finances:
        return 'Informe de finanzas';
      case ReportCategory.inventory:
        return 'Informe de inventario';
    }
  }

  IconData getCategoryIcon(ReportCategory category) {
    switch (category) {
      case ReportCategory.sales:
        return Icons.point_of_sale;
      case ReportCategory.purchases:
        return Icons.shopping_cart;
      case ReportCategory.finances:
        return Icons.attach_money;
      case ReportCategory.inventory:
        return Icons.inventory_2;
    }
  }
}

final reportsViewModelProvider =
    StateNotifierProvider<ReportsViewModel, ReportsState>((ref) {
      return ReportsViewModel();
    });
