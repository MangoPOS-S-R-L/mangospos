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
  String? _lastLoadedBusinessId;

  PrintingRepository get _repo => ref.read(printingAreasRepositoryProvider);

  @override
  PrintingAreasState build() => const PrintingAreasState();

  /// Carga / recarga
  Future<void> load({required String businessId, bool force = false}) async {
    state = state.copyWith(isLoading: true, errorMessage: null);
    try {
      final resolvedBusinessId = await _resolveBusiness(businessId);

      if (!force &&
          _lastLoadedBusinessId == resolvedBusinessId &&
          state.items.isNotEmpty) {
        state = state.copyWith(isLoading: false);
        return;
      }

      final items = await _repo.getPrintAreas(resolvedBusinessId);
      _lastLoadedBusinessId = resolvedBusinessId;
      state = state.copyWith(items: items, isLoading: false);
    } catch (e) {
      state = state.copyWith(isLoading: false, errorMessage: e.toString());
    }
  }

  Future<void> refresh() async {
    final b = await _ensureBusiness();
    await load(businessId: b, force: true);
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
      final b = await _ensureBusiness();

      final code = trimmed.toUpperCase().replaceAll(' ', '_');
      await _repo.createArea(businessId: b, name: trimmed, code: code);
      await load(businessId: b, force: true);
      return true;
    } catch (e) {
      state = state.copyWith(isLoading: false, errorMessage: e.toString());
      return false;
    }
  }

  Future<bool> deleteArea(String areaId) async {
    try {
      state = state.copyWith(isLoading: true, errorMessage: null);
      final b = await _ensureBusiness();

      await _repo.deleteArea(areaId);
      await load(businessId: b, force: true);
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
      final b = await _ensureBusiness();

      await _repo.setAreaPrinterAssignment(
        businessId: b,
        areaId: areaId,
        printerId: printerId,
        printsOrders: enabled && printsOrders,
        printsPrebills: enabled && printsPrebills,
        printsReceipts: enabled && printsReceipts,
      );
      return true;
    } catch (e) {
      state = state.copyWith(errorMessage: e.toString());
      return false;
    }
  }

  Future<bool> unlinkAreaPrinter({
    required String areaId,
    required String printerId,
    bool removeOrders = true,
    bool removePrebills = true,
    bool removeReceipts = true,
  }) async {
    try {
      await _repo.removePrinterFromArea(
        areaId: areaId,
        printerId: printerId,
        removeOrders: removeOrders,
        removePrebills: removePrebills,
        removeReceipts: removeReceipts,
      );
      return true;
    } catch (e) {
      state = state.copyWith(errorMessage: e.toString());
      return false;
    }
  }

  Future<Map<String, String>> loadOrderPrinterSelections() async {
    final b = await _ensureBusiness();
    return _repo.getOrderPrinterSelections(b);
  }

  Future<Map<String, String>> loadPrinterSelectionsByType({
    bool printsOrders = false,
    bool printsPrebills = false,
    bool printsReceipts = false,
  }) async {
    final b = await _ensureBusiness();
    return _repo.getPrinterSelectionsByType(
      businessId: b,
      printsOrders: printsOrders,
      printsPrebills: printsPrebills,
      printsReceipts: printsReceipts,
    );
  }

  Future<PrintArea> ensureSystemArea({
    required String code,
    required String name,
  }) async {
    final b = await _ensureBusiness();
    return _repo.ensurePrintArea(businessId: b, code: code, name: name);
  }

  Future<Map<String, String>> bootstrapOrderPrinterSelections({
    required String businessId,
  }) async {
    await load(businessId: businessId);
    return loadOrderPrinterSelections();
  }

  Future<ReceiptAssignmentsBootstrap> bootstrapReceiptAssignments({
    required String businessId,
  }) async {
    await load(businessId: businessId);

    final cashierArea = await ensureSystemArea(code: 'cashier', name: 'Caja');
    final fiscalArea = await ensureSystemArea(code: 'fiscal', name: 'Fiscal');

    await refresh();

    final prebills = await loadPrinterSelectionsByType(printsPrebills: true);
    final receipts = await loadPrinterSelectionsByType(printsReceipts: true);

    return ReceiptAssignmentsBootstrap(
      cashierArea: cashierArea,
      fiscalArea: fiscalArea,
      selectedPrebillPrinter: prebills[cashierArea.id],
      selectedReceiptPrinter: receipts[fiscalArea.id],
    );
  }

  // -------- selección múltiple --------
  void toggleSelect(String id) {
    final next = Set<String>.from(state.selectedIds);
    next.contains(id) ? next.remove(id) : next.add(id);
    state = state.copyWith(selectedIds: next);
  }

  void clearSelection() => state = state.copyWith(selectedIds: <String>{});

  // -------- helpers --------
  Future<String> _resolveBusiness(String businessId) async {
    _businessId = await BusinessResolver.ensure(
      businessId.isEmpty ? 'auto' : businessId,
    );
    return _businessId!;
  }

  Future<String> _ensureBusiness() async {
    if (_businessId == null || _businessId!.isEmpty || _businessId == 'auto') {
      _businessId = await BusinessResolver.ensure('auto');
    }
    return _businessId!;
  }
}

class ReceiptAssignmentsBootstrap {
  const ReceiptAssignmentsBootstrap({
    required this.cashierArea,
    required this.fiscalArea,
    required this.selectedPrebillPrinter,
    required this.selectedReceiptPrinter,
  });

  final PrintArea cashierArea;
  final PrintArea fiscalArea;
  final String? selectedPrebillPrinter;
  final String? selectedReceiptPrinter;
}
