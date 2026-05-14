import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../data/repositories/inventory_repository.dart';
import '../../../data/utils/business_id_resolver.dart';
import '../state/transfers_state.dart';
import 'inventory_viewmodel.dart';

final transfersViewModelProvider =
    ChangeNotifierProvider<TransfersViewModel>((ref) {
      return TransfersViewModel(ref.read(inventoryRepositoryProvider));
    });

class TransfersViewModel extends ChangeNotifier {
  final InventoryRepository _repository;
  TransfersState _state = const TransfersState();

  TransfersViewModel(this._repository);

  TransfersState get state => _state;

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
        error: 'Error cargando transferencias: $e',
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

  Future<void> _reload() async {
    final businessId = _state.businessId;
    if (businessId == null) {
      _state = _state.copyWith(loading: false, transfers: const []);
      notifyListeners();
      return;
    }
    final transfers = await _repository.listTransfers(businessId: businessId);
    _state = _state.copyWith(
      loading: false,
      transfers: transfers,
      clearError: true,
    );
    notifyListeners();
  }

  Future<List<StockTransferItem>> loadItems(String transferId) {
    return _repository.getTransferItems(transferId);
  }

  Future<void> createTransfer({
    required String fromWarehouseId,
    required String toWarehouseId,
    required List<Map<String, dynamic>> items,
    String? notes,
  }) async {
    final businessId = _state.businessId;
    if (businessId == null) {
      throw Exception('No hay negocio seleccionado');
    }
    _state = _state.copyWith(saving: true, clearError: true);
    notifyListeners();
    try {
      await _repository.sendTransfer(
        businessId: businessId,
        fromWarehouseId: fromWarehouseId,
        toWarehouseId: toWarehouseId,
        items: items,
        notes: notes,
      );
      _state = _state.copyWith(saving: false);
      await _reload();
    } catch (e) {
      _state = _state.copyWith(
        saving: false,
        error: 'Error enviando transferencia: $e',
      );
      notifyListeners();
      rethrow;
    }
  }

  Future<void> receiveTransfer({
    required String transferId,
    required List<Map<String, dynamic>> receivedItems,
    String? varianceNotes,
  }) async {
    _state = _state.copyWith(saving: true, clearError: true);
    notifyListeners();
    try {
      await _repository.receiveTransfer(
        transferId: transferId,
        receivedItems: receivedItems,
        varianceNotes: varianceNotes,
      );
      _state = _state.copyWith(saving: false);
      await _reload();
    } catch (e) {
      _state = _state.copyWith(
        saving: false,
        error: 'Error recibiendo transferencia: $e',
      );
      notifyListeners();
      rethrow;
    }
  }

  Future<void> cancelTransfer({
    required String transferId,
    String? reason,
  }) async {
    _state = _state.copyWith(saving: true, clearError: true);
    notifyListeners();
    try {
      await _repository.cancelTransfer(
        transferId: transferId,
        reason: reason,
      );
      _state = _state.copyWith(saving: false);
      await _reload();
    } catch (e) {
      _state = _state.copyWith(
        saving: false,
        error: 'Error cancelando transferencia: $e',
      );
      notifyListeners();
      rethrow;
    }
  }
}
