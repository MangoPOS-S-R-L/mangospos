import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:mangopos/data/repositories/kitchen_repository.dart';
import 'package:mangopos/data/models/kitchen_models.dart';
import 'package:mangopos/data/utils/business_id_resolver.dart';

final kitchenRepositoryProvider = Provider<KitchenRepository>((ref) {
  return KitchenRepository(Supabase.instance.client);
});

final kitchenViewModelProvider = ChangeNotifierProvider<KitchenViewModel>((
  ref,
) {
  return KitchenViewModel(ref.read(kitchenRepositoryProvider));
});

class KitchenViewModel extends ChangeNotifier {
  final KitchenRepository _repository;

  bool _isLoading = false;
  List<KitchenItem> _items = [];
  String? _businessId;
  RealtimeChannel? _rtItems;

  KitchenViewModel(this._repository);

  bool get isLoading => _isLoading;
  List<KitchenItem> get items => _items;

  // Derive filtered lists
  List<KitchenItem> get pendingItems =>
      _items.where((i) => i.status == 'pending').toList();
  List<KitchenItem> get preparingItems =>
      _items.where((i) => i.status == 'preparing').toList();
  List<KitchenItem> get readyItems =>
      _items.where((i) => i.status == 'ready').toList();

  Future<void> init() async {
    _isLoading = true;
    notifyListeners();
    try {
      final client = Supabase.instance.client;
      _businessId = await resolveBusinessIdOrNull(client, 'auto');
      if (_businessId != null) {
        _subscribeRealtime(client, _businessId!);
        await refresh();
      }
    } catch (e) {
      debugPrint('Error initializing kitchen: $e');
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> refresh() async {
    if (_businessId == null) return;
    try {
      _items = await _repository.getActiveItems(businessId: _businessId);
      notifyListeners();
    } catch (e) {
      debugPrint('Error refreshing kitchen items: $e');
    }
  }

  Future<void> startCooking(String itemId) async {
    await _repository.updateItemStatus(itemId: itemId, status: 'preparing');
    await refresh();
  }

  Future<void> startPreparingOrder(String orderId) async {
    await _repository.startPreparingOrder(orderId);
    await refresh();
  }

  Future<void> markReady(String itemId) async {
    await _repository.updateItemStatus(itemId: itemId, status: 'ready');
    await refresh();
  }

  Future<void> markOrderReady(String orderId) async {
    await _repository.markOrderReady(orderId);
    await refresh();
  }

  void _subscribeRealtime(SupabaseClient client, String businessId) {
    _rtItems?.unsubscribe();
    _rtItems = client
        .channel('rt:kitchen_items:$businessId')
      ..onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'order_items',
        callback: (_) => refresh(),
      )
      ..subscribe();
  }

  @override
  void dispose() {
    _rtItems?.unsubscribe();
    _rtItems = null;
    super.dispose();
  }
}
