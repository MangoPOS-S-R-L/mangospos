import 'package:equatable/equatable.dart';
import 'package:mangopos/data/models/sales_models.dart';

class CurrentOrderState extends Equatable {
  final bool loading;
  final String? error;
  final Order? order;
  final List<OrderItem> items;
  final bool takeout; // ¿para llevar? a nivel orden (UI toggle)
  final String? origin; // 'table' | 'manual' | 'quick'

  const CurrentOrderState({
    this.loading = false,
    this.error,
    this.order,
    this.items = const [],
    this.takeout = false,
    this.origin,
  });

  CurrentOrderState copyWith({
    bool? loading,
    String? error,
    Order? order,
    List<OrderItem>? items,
    bool? takeout,
    String? origin,
    bool clearOrigin = false,
  }) {
    return CurrentOrderState(
      loading: loading ?? this.loading,
      error: error,
      order: order ?? this.order,
      items: items ?? this.items,
      takeout: takeout ?? this.takeout,
      origin: clearOrigin ? null : (origin ?? this.origin),
    );
  }

  @override
  List<Object?> get props => [loading, error, order, items, takeout, origin];
}
