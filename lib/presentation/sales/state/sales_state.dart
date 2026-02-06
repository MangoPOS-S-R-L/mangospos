import 'package:equatable/equatable.dart';
import 'package:mangopos/data/models/sales_models.dart';

class CurrentOrderState extends Equatable {
  final bool loading;
  final String? error;
  final Order? order;
  final List<OrderItem> items;
  final List<OrderCheck> checks;
  final bool takeout; // ¿para llevar? a nivel orden (UI toggle)
  final String? origin; // 'table' | 'manual' | 'quick'
  final String? selectedCheckId;

  const CurrentOrderState({
    this.loading = false,
    this.error,
    this.order,
    this.items = const [],
    this.checks = const [],
    this.takeout = false,
    this.origin,
    this.selectedCheckId,
  });

  CurrentOrderState copyWith({
    bool? loading,
    String? error,
    Order? order,
    List<OrderItem>? items,
    List<OrderCheck>? checks,
    bool? takeout,
    String? origin,
    bool clearOrigin = false,
    String? selectedCheckId,
    bool clearSelectedCheck = false,
  }) {
    return CurrentOrderState(
      loading: loading ?? this.loading,
      error: error,
      order: order ?? this.order,
      items: items ?? this.items,
      checks: checks ?? this.checks,
      takeout: takeout ?? this.takeout,
      origin: clearOrigin ? null : (origin ?? this.origin),
      selectedCheckId: clearSelectedCheck
          ? null
          : (selectedCheckId ?? this.selectedCheckId),
    );
  }

  @override
  List<Object?> get props => [
    loading,
    error,
    order,
    items,
    checks,
    takeout,
    origin,
    selectedCheckId,
  ];
}
