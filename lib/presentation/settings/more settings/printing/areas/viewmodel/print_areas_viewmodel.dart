import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:mangopos/core/business/business_resolver.dart';
import 'package:mangopos/data/models/printing_models.dart';
import 'package:mangopos/data/repositories/printing_repository.dart';

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

final printingAreasViewModelProvider =
    NotifierProvider<PrintingAreasViewModel, PrintingAreasState>(
      PrintingAreasViewModel.new,
    );

class PrintingAreasViewModel extends Notifier<PrintingAreasState> {
  String? _businessId;

  PrintingRepository get _repo => ref.read(printingAreasRepositoryProvider);

  @override
  PrintingAreasState build() => const PrintingAreasState();

  /// Carga / recarga
  Future<void> load({required String businessId}) async {
    state = state.copyWith(isLoading: true, errorMessage: null);
    try {
      _businessId = await BusinessResolver.ensure(
        businessId.isEmpty ? 'auto' : businessId,
      );

      final items = await _repo.getPrintAreas(_businessId!);
      state = state.copyWith(items: items, isLoading: false);
    } catch (e) {
      state = state.copyWith(isLoading: false, errorMessage: e.toString());
    }
  }

  Future<void> refresh() async {
    final b = _ensureBusiness();
    await load(businessId: b);
  }

  Future<bool> createArea({required String name}) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      state = state.copyWith(
        errorMessage: 'El nombre del área es obligatorio.',
      );
      return false;
    }
    try {
      state = state.copyWith(isLoading: true, errorMessage: null);
      final b = _ensureBusiness();

      final code = trimmed.toUpperCase().replaceAll(' ', '_');
      await _repo.createArea(businessId: b, name: trimmed, code: code);
      await load(businessId: b);
      return true;
    } catch (e) {
      state = state.copyWith(isLoading: false, errorMessage: e.toString());
      return false;
    }
  }

  Future<bool> deleteArea(String areaId) async {
    try {
      state = state.copyWith(isLoading: true, errorMessage: null);
      final b = _ensureBusiness();

      await _repo.deleteArea(areaId);
      await load(businessId: b);
      return true;
    } catch (e) {
      state = state.copyWith(isLoading: false, errorMessage: e.toString());
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
      final b = _ensureBusiness();

      await _repo.linkAreaToPrinter(
        businessId: b,
        areaId: areaId,
        printerId: printerId,
        enabled: enabled,
        printsOrders: printsOrders,
        printsPrebills: printsPrebills,
        printsReceipts: printsReceipts,
      );
      // No es necesario recargar; el listado de áreas no cambia por el vínculo
      return true;
    } catch (e) {
      state = state.copyWith(errorMessage: e.toString());
      return false;
    }
  }

  // -------- selección múltiple --------
  void toggleSelect(String id) {
    final next = Set<String>.from(state.selectedIds);
    next.contains(id) ? next.remove(id) : next.add(id);
    state = state.copyWith(selectedIds: next);
  }

  void clearSelection() => state = state.copyWith(selectedIds: <String>{});

  // -------- helpers --------
  String _ensureBusiness() {
    if (_businessId == null || _businessId!.isEmpty || _businessId == 'auto') {
      throw StateError(
        'BusinessId no resuelto. Llama load(businessId) primero.',
      );
    }
    return _businessId!;
  }
}
