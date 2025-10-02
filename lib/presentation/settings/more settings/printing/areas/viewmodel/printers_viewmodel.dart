import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mangopos/core/business/business_resolver.dart';
import 'package:mangopos/data/models/printing.dart';
import 'package:mangopos/data/repositories/printing_repository.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

@immutable
class PrintingPrintersState {
  const PrintingPrintersState({
    this.items = const [],
    this.isLoading = false,
    this.errorMessage,
    this.selectedIds = const {},
  });

  final List<PrinterDevice> items;
  final bool isLoading;
  final String? errorMessage;
  final Set<String> selectedIds;

  PrintingPrintersState copyWith({
    List<PrinterDevice>? items,
    bool? isLoading,
    String? errorMessage,
    Set<String>? selectedIds,
  }) {
    return PrintingPrintersState(
      items: items ?? this.items,
      isLoading: isLoading ?? this.isLoading,
      errorMessage: errorMessage,
      selectedIds: selectedIds ?? this.selectedIds,
    );
  }
}

final printingPrintersRepositoryProvider = Provider<PrintingRepository>((ref) {
  final client = Supabase.instance.client;
  return PrintingRepository(client);
});

final printingPrintersViewModelProvider = StateNotifierProvider.family<
    PrintingPrintersViewModel,
    PrintingPrintersState,
    String>(
  (ref, businessIdOrAuto) =>
      PrintingPrintersViewModel(ref, businessIdOrAuto)..load(),
);

class PrintingPrintersViewModel extends StateNotifier<PrintingPrintersState> {
  PrintingPrintersViewModel(this._ref, this._businessIdOrAuto)
      : super(const PrintingPrintersState(isLoading: true));

  final Ref _ref;
  final String _businessIdOrAuto;

  PrintingRepository get _repo =>
      _ref.read(printingPrintersRepositoryProvider);

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
      final items = await _repo.getPrinters(businessId);
      state = state.copyWith(items: items, isLoading: false);
    } catch (error) {
      state = state.copyWith(
        isLoading: false,
        errorMessage: error.toString(),
      );
    }
  }

  Future<void> refresh() => load();

  Future<void> discoverOnLAN() async {
    // Placeholder for future LAN discovery implementation.
  }

  Future<bool> createPrinter({
    required String name,
    String? ip,
    String? mac,
    String type = 'network',
  }) async {
    final trimmedName = name.trim();
    if (trimmedName.isEmpty) {
      state = state.copyWith(errorMessage: 'El nombre de la impresora es obligatorio.');
      return false;
    }
    try {
      state = state.copyWith(isLoading: true, errorMessage: null);
      final businessId = await _resolveBusinessId();
      final trimmedIp = (ip ?? '').trim();
      final trimmedMac = (mac ?? '').trim();
      await _repo.createPrinter(
        businessId: businessId,
        name: trimmedName,
        ip: trimmedIp.isEmpty ? null : trimmedIp,
        mac: trimmedMac.isEmpty ? null : trimmedMac,
        type: PrinterTypeX.fromName(type),
      );
      await load();
      return true;
    } catch (error) {
      state = state.copyWith(isLoading: false, errorMessage: error.toString());
      return false;
    }
  }

  Future<bool> deletePrinter(String printerId) async {
    try {
      state = state.copyWith(isLoading: true, errorMessage: null);
      await _repo.deletePrinter(printerId);
      await load();
      return true;
    } catch (error) {
      state = state.copyWith(isLoading: false, errorMessage: error.toString());
      return false;
    }
  }

  Future<bool> printSample(String printerId) async {
    try {
      await _repo.enqueueTestPrint(printerId);
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
