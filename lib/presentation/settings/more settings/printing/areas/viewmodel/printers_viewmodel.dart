// lib/presentation/settings/printing/viewmodel/printers_viewmodel.dart
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mangopos/data/models/printing.dart';
import 'package:mangopos/data/repositories/printing_repository.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:mangopos/core/business/business_resolver.dart';

@immutable
class PrintersVMState {
  final List<PrinterDevice> items;
  final bool isLoading;
  final String? error;
  final Set<String> selected;
  const PrintersVMState({
    this.items = const [],
    this.isLoading = false,
    this.error,
    this.selected = const {},
  });

  PrintersVMState copyWith({
    List<PrinterDevice>? items,
    bool? isLoading,
    String? error,
    Set<String>? selected,
  }) =>
      PrintersVMState(
        items: items ?? this.items,
        isLoading: isLoading ?? this.isLoading,
        error: error,
        selected: selected ?? this.selected,
      );
}

final printersVMRepoProvider = Provider<PrintingRepository>((ref) {
  final client = Supabase.instance.client;
  return PrintingRepository(client);
});

final printersVMProvider =
    StateNotifierProvider.family<PrintersViewModel, PrintersVMState, String>(
  (ref, businessIdOrAuto) => PrintersViewModel(ref, businessIdOrAuto),
);

class PrintersViewModel extends StateNotifier<PrintersVMState> {
  final Ref ref;
  final String businessIdOrAuto;
  PrintersViewModel(this.ref, this.businessIdOrAuto)
      : super(const PrintersVMState(isLoading: true)) {
    _load();
  }

  PrintingRepository get _repo => ref.read(printersVMRepoProvider);

  Future<String> _bid() async {
    if (businessIdOrAuto.isEmpty || businessIdOrAuto == 'auto') {
      return BusinessResolver.resolveActiveBusinessId();
    }
    return businessIdOrAuto;
  }

  Future<void> _load() async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      final bid = await _bid();
      final items = await _repo.getPrinters(bid);
      state = state.copyWith(items: items, isLoading: false);
    } catch (e) {
      state = state.copyWith(isLoading: false, error: e.toString());
    }
  }

  Future<void> refresh() => _load();

  Future<bool> addPrinter({
    required String name,
    String ip = '',
    String mac = '',
    PrinterConn conn = PrinterConn.network,
    PrinterBrand brand = PrinterBrand.generic,
    String? notes,
  }) async {
    try {
      state = state.copyWith(isLoading: true, error: null);
      final bid = await _bid();
      await _repo.insertPrinter(PrinterDevice(
        id: 'temp', // lo genera el backend
        businessId: bid,
        name: name.trim(),
        ip: ip.trim(),
        mac: mac.trim(),
        conn: conn,
        brand: brand,
        online: false,
        notes: notes,
      ));
      await _load();
      return true;
    } catch (e) {
      state = state.copyWith(isLoading: false, error: e.toString());
      return false;
    }
  }

  Future<bool> deletePrinter(String printerId) async {
    try {
      state = state.copyWith(isLoading: true, error: null);
      await _repo.deletePrinter(printerId);
      await _load();
      return true;
    } catch (e) {
      state = state.copyWith(isLoading: false, error: e.toString());
      return false;
    }
  }

  Future<bool> printTest(String printerId) async {
    try {
      await _repo.enqueueTestPrint(printerId);
      return true;
    } catch (e) {
      state = state.copyWith(error: e.toString());
      return false;
    }
  }

  // selección múltiple
  void toggleSelect(String id) {
    final next = Set<String>.from(state.selected);
    next.contains(id) ? next.remove(id) : next.add(id);
    state = state.copyWith(selected: next);
  }

  void clearSelection() => state = state.copyWith(selected: {});
}
