// Sprint 4 Inventario — ViewModel de recepciones directas.

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../data/repositories/inventory_repository.dart';
import '../../../data/utils/business_id_resolver.dart';
import '../state/direct_receipts_state.dart';
import 'inventory_viewmodel.dart';

final directReceiptsViewModelProvider =
    ChangeNotifierProvider<DirectReceiptsViewModel>((ref) {
      return DirectReceiptsViewModel(ref.read(inventoryRepositoryProvider));
    });

class DirectReceiptsViewModel extends ChangeNotifier {
  final InventoryRepository _repository;
  DirectReceiptsState _state = const DirectReceiptsState();

  DirectReceiptsViewModel(this._repository);

  DirectReceiptsState get state => _state;

  Future<void> init({bool force = false}) async {
    if (_state.loading && !force) return;
    _state = _state.copyWith(loading: true, clearError: true);
    notifyListeners();
    try {
      final businessId = await resolveBusinessIdOrNull(
        Supabase.instance.client,
        'auto',
      );
      if (businessId == null) {
        throw Exception('No se pudo resolver el negocio actual');
      }
      _state = _state.copyWith(businessId: businessId);
      await _reload();
    } catch (e) {
      _state = _state.copyWith(
        loading: false,
        error: 'Error cargando recepciones: $e',
      );
      notifyListeners();
    }
  }

  Future<void> refresh() async {
    _state = _state.copyWith(loading: true, clearError: true);
    notifyListeners();
    try {
      await _reload();
    } catch (e) {
      _state = _state.copyWith(
        loading: false,
        error: 'Error refrescando: $e',
      );
      notifyListeners();
    }
  }

  Future<void> applyStatusFilter(String? status) async {
    _state = _state.copyWith(
      statusFilter: status,
      clearStatusFilter: status == null,
      loading: true,
      clearError: true,
    );
    notifyListeners();
    try {
      await _reload();
    } catch (e) {
      _state = _state.copyWith(
        loading: false,
        error: 'Error filtrando recepciones: $e',
      );
      notifyListeners();
    }
  }

  Future<void> _reload() async {
    final businessId = _state.businessId;
    if (businessId == null) {
      _state = _state.copyWith(
        loading: false,
        receipts: const [],
        hasMore: false,
      );
      notifyListeners();
      return;
    }
    final rows = await _repository.listDirectReceipts(
      businessId: businessId,
      status: _state.statusFilter,
      limit: DirectReceiptsState.pageSize,
      offset: 0,
    );
    final receipts = rows.map(DirectReceipt.fromLogMap).toList(growable: false);
    _state = _state.copyWith(
      loading: false,
      receipts: receipts,
      hasMore: receipts.length == DirectReceiptsState.pageSize,
      clearError: true,
    );
    notifyListeners();
  }

  Future<void> loadMore() async {
    final businessId = _state.businessId;
    if (businessId == null) return;
    if (_state.loadingMore || _state.loading) return;
    if (!_state.hasMore) return;
    _state = _state.copyWith(loadingMore: true, clearError: true);
    notifyListeners();
    try {
      final rows = await _repository.listDirectReceipts(
        businessId: businessId,
        status: _state.statusFilter,
        limit: DirectReceiptsState.pageSize,
        offset: _state.receipts.length,
      );
      final more = rows.map(DirectReceipt.fromLogMap).toList(growable: false);
      _state = _state.copyWith(
        loadingMore: false,
        receipts: [..._state.receipts, ...more],
        hasMore: more.length == DirectReceiptsState.pageSize,
      );
      notifyListeners();
    } catch (e) {
      _state = _state.copyWith(
        loadingMore: false,
        error: 'Error cargando más recepciones: $e',
      );
      notifyListeners();
    }
  }

  /// Carga las líneas de una recepción (para el detail dialog).
  Future<List<DirectReceiptLine>> loadItems(String receiptId) async {
    final rows = await _repository.getDirectReceiptItems(receiptId);
    return rows.map(DirectReceiptLine.fromMap).toList(growable: false);
  }

  /// Crea una recepción directa nueva. [items] formato:
  /// `[{item_id, quantity, unit_cost?, notes?}]`.
  Future<void> createReceipt({
    required String warehouseId,
    required List<Map<String, dynamic>> items,
    String? supplierId,
    String? notes,
  }) async {
    final businessId = _state.businessId;
    if (businessId == null) {
      throw Exception('No hay negocio seleccionado');
    }
    _state = _state.copyWith(saving: true, clearError: true);
    notifyListeners();
    try {
      await _repository.createDirectReceipt(
        businessId: businessId,
        warehouseId: warehouseId,
        items: items,
        supplierId: supplierId,
        notes: notes,
      );
      _state = _state.copyWith(saving: false);
      await _reload();
    } catch (e) {
      _state = _state.copyWith(
        saving: false,
        error: 'Error creando recepción: $e',
      );
      notifyListeners();
      rethrow;
    }
  }

  /// Cancela una recepción: revierte el stock y marca el header como cancelled.
  Future<void> cancelReceipt({
    required String receiptId,
    String? reason,
  }) async {
    _state = _state.copyWith(saving: true, clearError: true);
    notifyListeners();
    try {
      await _repository.cancelDirectReceipt(
        receiptId: receiptId,
        reason: reason,
      );
      _state = _state.copyWith(saving: false);
      await _reload();
    } catch (e) {
      _state = _state.copyWith(
        saving: false,
        error: 'Error cancelando recepción: $e',
      );
      notifyListeners();
      rethrow;
    }
  }
}
