import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mangopos/data/models/tax.dart';

class TaxesState {
  final AsyncValue<List<Tax>> data;
  final String search;
  final String? selectedId;

  const TaxesState({
    this.data = const AsyncLoading(),
    this.search = '',
    this.selectedId,
  });

  TaxesState copyWith({
    AsyncValue<List<Tax>>? data,
    String? search,
    String? selectedId,
    bool clearSelected = false,
  }) {
    return TaxesState(
      data: data ?? this.data,
      search: search ?? this.search,
      selectedId: clearSelected ? null : (selectedId ?? this.selectedId),
    );
  }

  List<Tax> get list => data.value ?? const [];

  List<Tax> get filtered {
    final q = search.trim().toLowerCase();
    if (q.isEmpty) return list;
    return list.where((t) {
      final name = t.name.toLowerCase();
      final rate = t.rate.toString();
      return name.contains(q) || rate.contains(q);
    }).toList();
  }

  Tax? get selected =>
      selectedId == null ? null : list.firstWhere((e) => e.id == selectedId, orElse: () => list.first);
}
