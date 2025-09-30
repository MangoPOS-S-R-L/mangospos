// lib/presentation/menu/viewmodel/categories_state.dart
import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../../../data/models/category.dart' as model;

@immutable
class CategoriesState {
  final AsyncValue<List<model.Category>> data; // loading/error/data
  final String search;
  final String? selectedId;

  const CategoriesState({
    this.data = const AsyncLoading(),
    this.search = '',
    this.selectedId,
  });

  CategoriesState copyWith({
    AsyncValue<List<model.Category>>? data,
    String? search,
    String? selectedId,
    bool clearSelected = false,
  }) {
    return CategoriesState(
      data: data ?? this.data,
      search: search ?? this.search,
      selectedId: clearSelected ? null : (selectedId ?? this.selectedId),
    );
  }

  // ---------- GETTERS DERIVADOS ----------
  /// Lista cruda (o vacía si aún no hay datos)
  List<model.Category> get list => data.value ?? const [];

  /// Lista filtrada por el texto de búsqueda
  List<model.Category> get filtered {
    final q = search.trim().toLowerCase();
    if (q.isEmpty) return list;
    return list.where((c) => c.name.toLowerCase().contains(q)).toList();
  }

  /// Flags de estado
  bool get loading => data.isLoading;
  Object? get error => data.hasError ? data.error : null;
}
