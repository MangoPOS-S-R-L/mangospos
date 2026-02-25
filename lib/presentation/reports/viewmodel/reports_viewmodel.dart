import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../data/repositories/reports_repository.dart';
import '../../../data/utils/business_id_resolver.dart';

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
  final bool loading;
  final String? error;
  final Map<String, dynamic>? salesSummary;
  final Map<String, dynamic>? cashSummary;

  const ReportsState({
    this.selectedCategory,
    this.loading = false,
    this.error,
    this.salesSummary,
    this.cashSummary,
  });

  ReportsState copyWith({
    ReportCategory? selectedCategory,
    bool? loading,
    String? error,
    Map<String, dynamic>? salesSummary,
    Map<String, dynamic>? cashSummary,
    bool clearError = false,
  }) {
    return ReportsState(
      selectedCategory: selectedCategory ?? this.selectedCategory,
      loading: loading ?? this.loading,
      error: clearError ? null : (error ?? this.error),
      salesSummary: salesSummary ?? this.salesSummary,
      cashSummary: cashSummary ?? this.cashSummary,
    );
  }
}

final reportsRepositoryProvider = Provider<ReportsRepository>((ref) {
  return ReportsRepository(Supabase.instance.client);
});

class ReportsViewModel extends StateNotifier<ReportsState> {
  final ReportsRepository _repository;

  ReportsViewModel(this._repository) : super(const ReportsState()) {
    Future<void>.microtask(load);
  }

  Future<void> load() async {
    state = state.copyWith(loading: true, clearError: true);

    try {
      final businessId = await resolveBusinessIdOrNull(
        Supabase.instance.client,
        'auto',
      );

      if (businessId == null) {
        throw Exception('No se pudo resolver el negocio actual');
      }

      final now = DateTime.now();
      final from = DateTime(
        now.year,
        now.month,
        now.day,
      ).subtract(const Duration(days: 7));
      final to = now.add(const Duration(days: 1));

      final results = await Future.wait([
        _repository.getSalesSummary(businessId: businessId, from: from, to: to),
        _repository.getCashSummary(businessId: businessId, from: from, to: to),
      ]);

      state = state.copyWith(
        loading: false,
        salesSummary: results[0],
        cashSummary: results[1],
        clearError: true,
      );
    } catch (e) {
      state = state.copyWith(
        loading: false,
        error: 'Error cargando reportes: $e',
      );
    }
  }

  void selectCategory(ReportCategory? category) {
    state = state.copyWith(selectedCategory: category);
  }

  List<ReportItem> getReportsForCategory(ReportCategory category) {
    switch (category) {
      case ReportCategory.sales:
        final total =
            (state.salesSummary?['total_sales'] as num?)?.toDouble() ?? 0;
        final txCount = state.salesSummary?['payments_count'] ?? 0;
        final itemsSold = state.salesSummary?['items_sold'] ?? 0;
        return [
          ReportItem(
            title: 'Ventas por rango',
            description:
                'Total: RD\$${total.toStringAsFixed(2)} | Transacciones: $txCount',
          ),
          ReportItem(
            title: 'Items vendidos',
            description: 'Items cobrados en el rango: $itemsSold',
          ),
        ];
      case ReportCategory.purchases:
        return const [
          ReportItem(
            title: 'Compras (pendiente)',
            description: 'Módulo de compras se implementa en Sprint 3',
          ),
        ];
      case ReportCategory.finances:
        final sessions = state.cashSummary?['sessions_count'] ?? 0;
        final differences =
            (state.cashSummary?['differences_total'] as num?)?.toDouble() ?? 0;
        final inTotal =
            (state.cashSummary?['manual_in_total'] as num?)?.toDouble() ?? 0;
        final outTotal =
            (state.cashSummary?['manual_out_total'] as num?)?.toDouble() ?? 0;
        return [
          ReportItem(
            title: 'Resumen de caja',
            description:
                'Sesiones: $sessions | Diferencia acumulada: RD\$${differences.toStringAsFixed(2)}',
          ),
          ReportItem(
            title: 'Movimientos manuales',
            description:
                'Entradas: RD\$${inTotal.toStringAsFixed(2)} | Salidas: RD\$${outTotal.toStringAsFixed(2)}',
          ),
        ];
      case ReportCategory.inventory:
        return const [
          ReportItem(
            title: 'Inventario (pendiente)',
            description: 'Módulo de inventario se implementa en Sprint 2',
          ),
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
      return ReportsViewModel(ref.read(reportsRepositoryProvider));
    });
