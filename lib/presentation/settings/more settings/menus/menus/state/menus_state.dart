import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../../../data/models/menu.dart';

@immutable
class MenusState {
  final AsyncValue<List<Menu>> data;
  final String search;
  final String? selectedId;

  const MenusState({
    this.data = const AsyncLoading(),
    this.search = '',
    this.selectedId,
  });

  MenusState copyWith({
    AsyncValue<List<Menu>>? data,
    String? search,
    String? selectedId,
    bool clearSelected = false,
  }) {
    return MenusState(
      data: data ?? this.data,
      search: search ?? this.search,
      selectedId: clearSelected ? null : (selectedId ?? this.selectedId),
    );
  }

  // Getters derivados
  List<Menu> get list => data.value ?? const [];
  List<Menu> get filtered {
    final q = search.trim().toLowerCase();
    if (q.isEmpty) return list;
    return list.where((m) => m.name.toLowerCase().contains(q)).toList();
  }

  Menu? get selected {
    if (list.isEmpty) return null; // no hay menús
    if (selectedId == null) return list.first; // nada seleccionado -> primero
    // intenta buscarlo; si no está, devuelve el primero
    return list.firstWhere((m) => m.id == selectedId, orElse: () => list.first);
  }

  bool get loading => data.isLoading;
  Object? get error => data.hasError ? data.error : null;
}
