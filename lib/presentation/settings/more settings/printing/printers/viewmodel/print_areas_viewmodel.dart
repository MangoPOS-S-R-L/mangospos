import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mangopos/core/business/business_resolver.dart';
import 'package:mangopos/data/models/printing.dart';
import 'package:mangopos/data/repositories/printing_repository.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

@immutable
class PrintingAreasState {
  const PrintingAreasState({
    this.items = const [],
    this.isLoading = false,
    this.errorMessage,
    this.selectedIds = const {},
  });

  final List<PrintArea> items;
  final bool isLoading;
  final String? errorMessage;
  final Set<String> selectedIds;

  PrintingAreasState copyWith({
    List<PrintArea>? items,
    bool? isLoading,
    String? errorMessage,
    Set<String>? selectedIds,
  }) {
    return PrintingAreasState(
      items: items ?? this.items,
      isLoading: isLoading ?? this.isLoading,
      errorMessage: errorMessage,
      selectedIds: selectedIds ?? this.selectedIds,
    );
  }
}

final printingAreasRepositoryProvider = Provider<PrintingRepository>((ref) {
  final client = Supabase.instance.client;
  return PrintingRepository(client);
});

final printingAreasViewModelProvider = StateNotifierProvider.family<
    PrintingAreasViewModel,
    PrintingAreasState,
    String>(
  (ref, businessIdOrAuto) =>
      PrintingAreasViewModel(ref, businessIdOrAuto)..load(),
);

class PrintingAreasViewModel extends StateNotifier<PrintingAreasState> {
  PrintingAreasViewModel(this._ref, this._businessIdOrAuto)
      : super(const PrintingAreasState(isLoading: true));

  final Ref _ref;
  final String _businessIdOrAuto;

  PrintingRepository get _repo =>
      _ref.read(printingAreasRepositoryProvider);

  Future<String> _resolveBusinessId() async {
    if (_businessIdOrAuto.isEmpty || _businessIdOrAuto == 'auto') {
      return BusinessResolver.resolveActiveBusinessId();
    }
    return _businessIdOrAuto;
  }

  Future<void> load() async {
    state = state.copyWith(isLoading: true, errorMessage: null);
    try {
      final businessId = await _resolveBusinessId();
      final items = await _repo.getPrintAreas(businessId);
      state = state.copyWith(items: items, isLoading: false);
    } catch (error) {
      state = state.copyWith(
        isLoading: false,
        errorMessage: error.toString(),
      );
    }
  }

  Future<void> refresh() => load();

  Future<bool> createArea({required String name}) async {
    final trimmedName = name.trim();
    if (trimmedName.isEmpty) {
      state = state.copyWith(errorMessage: 'El nombre del área es obligatorio.');
      return false;
    }
    try {
      state = state.copyWith(isLoading: true, errorMessage: null);
      final businessId = await _resolveBusinessId();
      await _repo.createArea(businessId: businessId, name: trimmedName);
      await load();
      return true;
    } catch (error) {
      state = state.copyWith(isLoading: false, errorMessage: error.toString());
      return false;
    }
  }

  Future<bool> deleteArea(String areaId) async {
    try {
      state = state.copyWith(isLoading: true, errorMessage: null);
      await _repo.deleteArea(areaId);
      await load();
      return true;
    } catch (error) {
      state = state.copyWith(isLoading: false, errorMessage: error.toString());
      return false;
    }
  }

  Future<bool> linkAreaPrinter({
    required String areaId,
    required String printerId,
    bool enabled = true,
    bool printsOrders = true,
    bool printsPrebills = false,
    bool printsReceipts = false,
  }) async {
    try {
      final businessId = await _resolveBusinessId();
      await _repo.linkAreaToPrinter(
        businessId: businessId,
        areaId: areaId,
        printerId: printerId,
        enabled: enabled,
        printsOrders: printsOrders,
        printsPrebills: printsPrebills,
        printsReceipts: printsReceipts,
      );
      return true;
    } catch (error) {
      state = state.copyWith(errorMessage: error.toString());
      return false;
    }
  }

  void toggleSelect(String id) {
    final next = Set<String>.from(state.selectedIds);
    if (next.contains(id)) {
      next.remove(id);
    } else {
      next.add(id);
    }
    state = state.copyWith(selectedIds: next);
  }

  void clearSelection() {
    state = state.copyWith(selectedIds: <String>{});
  }
}
