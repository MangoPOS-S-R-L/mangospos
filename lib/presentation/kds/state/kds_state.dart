import 'package:equatable/equatable.dart';
import '../../../data/models/kitchen_models.dart';

/// 🍳 Estado del KDS
class KdsState extends Equatable {
  final bool loading;
  final String? error;

  // Órdenes activas
  final List<KitchenOrder> orders;

  // Filtros
  final String? selectedArea;
  final String? selectedStatus;

  // Estadísticas
  final Map<String, int> stats;
  final Duration? averageTime;

  // Configuración
  final bool soundEnabled;
  final bool autoRefresh;

  const KdsState({
    this.loading = false,
    this.error,
    this.orders = const [],
    this.selectedArea,
    this.selectedStatus,
    this.stats = const {},
    this.averageTime,
    this.soundEnabled = true,
    this.autoRefresh = true,
  });

  KdsState copyWith({
    bool? loading,
    String? error,
    List<KitchenOrder>? orders,
    String? selectedArea,
    String? selectedStatus,
    Map<String, int>? stats,
    Duration? averageTime,
    bool? soundEnabled,
    bool? autoRefresh,
  }) {
    return KdsState(
      loading: loading ?? this.loading,
      error: error,
      orders: orders ?? this.orders,
      selectedArea: selectedArea ?? this.selectedArea,
      selectedStatus: selectedStatus ?? this.selectedStatus,
      stats: stats ?? this.stats,
      averageTime: averageTime ?? this.averageTime,
      soundEnabled: soundEnabled ?? this.soundEnabled,
      autoRefresh: autoRefresh ?? this.autoRefresh,
    );
  }

  // Órdenes filtradas
  List<KitchenOrder> get filteredOrders {
    return orders.where((order) {
      if (selectedStatus != null) {
        return order.items.any((item) => item.status == selectedStatus);
      }
      return true;
    }).toList();
  }

  // Órdenes pendientes
  List<KitchenOrder> get pendingOrders {
    return orders.where((o) => o.items.any((i) => i.isPending)).toList();
  }

  // Órdenes en preparación
  List<KitchenOrder> get preparingOrders {
    return orders.where((o) => o.items.any((i) => i.isPreparing)).toList();
  }

  // Órdenes listas
  List<KitchenOrder> get readyOrders {
    return orders.where((o) => o.allReady).toList();
  }

  @override
  List<Object?> get props => [
    loading,
    error,
    orders,
    selectedArea,
    selectedStatus,
    stats,
    averageTime,
    soundEnabled,
    autoRefresh,
  ];
}
