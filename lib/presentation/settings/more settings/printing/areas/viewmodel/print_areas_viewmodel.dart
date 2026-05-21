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

  Future<bool> createArea({required String name, String? code}) async {
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

      // PRD 5 F4.1: code consistente con áreas existentes (lowercase
      // + underscore + sufijo numérico si hay duplicados).
      final baseCode = (code != null && code.trim().isNotEmpty)
          ? _slugify(code)
          : _slugify(trimmed);
      final finalCode = await _ensureUniqueCode(b, baseCode);

      await _repo.createArea(businessId: b, name: trimmed, code: finalCode);
      await load(businessId: b, force: true);
      return true;
    } catch (e) {
      state = state.copyWith(isLoading: false, errorMessage: e.toString());
      return false;
    }
  }

  Future<bool> updateArea({
    required String areaId,
    String? name,
    String? code,
    bool? isActive,
  }) async {
    final trimmedName = name?.trim();
    if (trimmedName != null && trimmedName.isEmpty) {
      state = state.copyWith(
        errorMessage: 'El nombre del área no puede estar vacío.',
      );
      return false;
    }
    try {
      state = state.copyWith(isLoading: true, errorMessage: null);
      final b = await _ensureBusiness();

      String? finalCode;
      if (code != null && code.trim().isNotEmpty) {
        final slug = _slugify(code);
        // Si el code está siendo cambiado, validar unicidad excluyendo
        // el área actual (para que pueda mantener su propio code).
        finalCode = await _ensureUniqueCode(b, slug, excludeAreaId: areaId);
      }

      await _repo.updateArea(
        areaId: areaId,
        name: trimmedName,
        code: finalCode,
        isActive: isActive,
      );
      await load(businessId: b, force: true);
      return true;
    } catch (e) {
      state = state.copyWith(isLoading: false, errorMessage: e.toString());
      return false;
    }
  }

  /// PRD 5 F4.1: convierte "Bar 2do piso" → "bar_2do_piso", removiendo
  /// tildes y caracteres no alfanuméricos.
  String _slugify(String input) {
    final lowered = input.toLowerCase().trim();
    final stripped = lowered
        .replaceAll(RegExp('[áàä]'), 'a')
        .replaceAll(RegExp('[éèë]'), 'e')
        .replaceAll(RegExp('[íìï]'), 'i')
        .replaceAll(RegExp('[óòö]'), 'o')
        .replaceAll(RegExp('[úùü]'), 'u')
        .replaceAll('ñ', 'n');
    final slug = stripped
        .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    return slug.isEmpty ? 'area' : slug;
  }

  /// PRD 5 F4.1: si [base] ya existe en otra área del business, agrega
  /// un sufijo numérico (`bar`, `bar_2`, `bar_3`...) hasta encontrar libre.
  Future<String> _ensureUniqueCode(
    String businessId,
    String base, {
    String? excludeAreaId,
  }) async {
    final existing = await _repo.getPrintAreas(businessId);
    final taken = existing
        .where((a) => excludeAreaId == null || a.id != excludeAreaId)
        .map((a) => a.code)
        .toSet();
    if (!taken.contains(base)) return base;
    var suffix = 2;
    while (taken.contains('${base}_$suffix')) {
      suffix++;
    }
    return '${base}_$suffix';
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

  Future<bool> updateAreaPrinterModes({
    required String areaId,
    required String printerId,
    required bool printsOrders,
    required bool printsReceipts,
  }) async {
    try {
      await _repo.updateAreaPrinterModes(
        areaId: areaId,
        printerId: printerId,
        printsOrders: printsOrders,
        printsReceipts: printsReceipts,
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

  /// Printing v2 (Slice 1.5): devuelve TODAS las impresoras por (área, tipo),
  /// no solo la primera. Usado por la pantalla "Asignar por comprobantes"
  /// para mostrar lista en vez de slot único.
  Future<Map<String, List<String>>> loadAllPrinterIdsByType({
    bool printsOrders = false,
    bool printsPrebills = false,
    bool printsReceipts = false,
  }) async {
    final b = await _ensureBusiness();
    return _repo.getAllPrinterIdsByType(
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
    final closureArea =
        await ensureSystemArea(code: 'cash_close', name: 'Cierre de caja');

    await refresh();

    // Printing v2 (Slice 1.5): traer TODAS las impresoras por área/tipo.
    final prebillsAll =
        await loadAllPrinterIdsByType(printsPrebills: true);
    final receiptsAll =
        await loadAllPrinterIdsByType(printsReceipts: true);

    final prebillIds = prebillsAll[cashierArea.id] ?? const <String>[];
    final receiptIds = receiptsAll[fiscalArea.id] ?? const <String>[];
    final closureIds = receiptsAll[closureArea.id] ?? const <String>[];

    return ReceiptAssignmentsBootstrap(
      cashierArea: cashierArea,
      fiscalArea: fiscalArea,
      closureArea: closureArea,
      // Legacy: primer ID por área (mantiene compat con callers viejos).
      selectedPrebillPrinter: prebillIds.isEmpty ? null : prebillIds.first,
      selectedReceiptPrinter: receiptIds.isEmpty ? null : receiptIds.first,
      selectedClosurePrinter: closureIds.isEmpty ? null : closureIds.first,
      // v2: listas completas.
      prebillPrinterIds: prebillIds,
      receiptPrinterIds: receiptIds,
      closurePrinterIds: closureIds,
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
    required this.closureArea,
    required this.selectedPrebillPrinter,
    required this.selectedReceiptPrinter,
    required this.selectedClosurePrinter,
    this.prebillPrinterIds = const [],
    this.receiptPrinterIds = const [],
    this.closurePrinterIds = const [],
  });

  final PrintArea cashierArea;
  final PrintArea fiscalArea;
  final PrintArea closureArea;
  // Legacy: primer printer asignado (mantiene compat con consumidores viejos).
  final String? selectedPrebillPrinter;
  final String? selectedReceiptPrinter;
  final String? selectedClosurePrinter;
  // v2 (Slice 1.5): listas completas para soportar N impresoras por tipo.
  final List<String> prebillPrinterIds;
  final List<String> receiptPrinterIds;
  final List<String> closurePrinterIds;
}
