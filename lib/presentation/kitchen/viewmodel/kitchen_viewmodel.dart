import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:mangopos/data/repositories/kitchen_repository.dart';
import 'package:mangopos/data/repositories/printing_service.dart';
import 'package:mangopos/data/models/kitchen_models.dart';
import 'package:mangopos/data/utils/business_id_resolver.dart';

final kitchenRepositoryProvider = Provider<KitchenRepository>((ref) {
  return KitchenRepository(Supabase.instance.client);
});

final printingServiceProvider = Provider<PrintingService>((ref) {
  return PrintingService(Supabase.instance.client);
});

final kitchenViewModelProvider = ChangeNotifierProvider<KitchenViewModel>((
  ref,
) {
  return KitchenViewModel(
    ref.read(kitchenRepositoryProvider),
    ref.read(printingServiceProvider),
  );
});

class KitchenViewModel extends ChangeNotifier {
  final KitchenRepository _repository;
  final PrintingService _printingService;

  bool _isLoading = false;
  List<KitchenItem> _items = [];
  String? _businessId;
  RealtimeChannel? _rtItems;
  Timer? _refreshDebounce;
  bool _refreshing = false;
  bool _refreshQueued = false;
  final Map<String, _StatusOverride> _statusOverrides = {};

  KitchenViewModel(this._repository, this._printingService);

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

  Future<void> refresh({bool force = false}) async {
    if (_businessId == null) return;
    if (_refreshing && !force) {
      _refreshQueued = true;
      return;
    }
    _refreshing = true;
    try {
      final fetched = await _repository.getActiveItems(businessId: _businessId);
      _items = _applyStatusOverrides(fetched);
      notifyListeners();
    } catch (e) {
      debugPrint('Error refreshing kitchen items: $e');
    } finally {
      _refreshing = false;
      if (_refreshQueued) {
        _refreshQueued = false;
        unawaited(refresh());
      }
    }
  }

  Future<void> startCooking(String itemId) async {
    _applyLocalItemStatus(itemId, 'preparing');
    try {
      await _repository.updateItemStatus(itemId: itemId, status: 'preparing');
      _clearOverride(itemId);
      _scheduleRefresh(immediate: true);
    } catch (e) {
      debugPrint('Error starting cooking: $e');
      _clearOverride(itemId);
      _scheduleRefresh(immediate: true);
    }
  }

  Future<void> startPreparingOrder(String orderId) async {
    _applyLocalOrderStatus(orderId, from: {'pending'}, to: 'preparing');
    final affectedIds = _items
        .where((item) => item.orderId == orderId && item.status == 'preparing')
        .map((item) => item.id)
        .toSet();
    try {
      await _repository.startPreparingOrder(orderId);
      _clearOverrides(affectedIds);
      _scheduleRefresh(immediate: true);
    } catch (e) {
      debugPrint('Error starting order preparation: $e');
      _clearOverrides(affectedIds);
      _scheduleRefresh(immediate: true);
    }
  }

  Future<void> markReady(String itemId) async {
    _applyLocalItemStatus(itemId, 'ready');
    try {
      await _repository.updateItemStatus(itemId: itemId, status: 'ready');
      _clearOverride(itemId);
      _scheduleRefresh(immediate: true);
    } catch (e) {
      debugPrint('Error marking ready: $e');
      _clearOverride(itemId);
      _scheduleRefresh(immediate: true);
    }
  }

  Future<void> markOrderReady(String orderId) async {
    final affectedIds = _items
        .where(
          (item) =>
              item.orderId == orderId &&
              (item.status == 'pending' || item.status == 'preparing'),
        )
        .map((item) => item.id)
        .toSet();
    _applyLocalOrderStatus(
      orderId,
      from: {'pending', 'preparing'},
      to: 'ready',
    );
    try {
      await _repository.markOrderReady(orderId);
      if (_businessId != null && affectedIds.isNotEmpty) {
        try {
          await _printingService.printReadyOrderTicket(
            orderId: orderId,
            businessId: _businessId!,
            itemIds: affectedIds.toList(growable: false),
          );
        } catch (e) {
          debugPrint('Error printing ready ticket: $e');
        }
      }
      _clearOverrides(affectedIds);
      _scheduleRefresh(immediate: true);
    } catch (e) {
      debugPrint('Error marking order ready: $e');
      _clearOverrides(affectedIds);
      _scheduleRefresh(immediate: true);
    }
  }

  void _subscribeRealtime(SupabaseClient client, String businessId) {
    _rtItems?.unsubscribe();
    _rtItems = client.channel('rt:kitchen_items:$businessId')
      ..onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'order_items',
        callback: (_) => _scheduleRefresh(),
      )
      ..subscribe();
  }

  void _scheduleRefresh({bool immediate = false}) {
    _refreshDebounce?.cancel();
    if (immediate) {
      unawaited(refresh(force: true));
      return;
    }
    _refreshDebounce = Timer(
      const Duration(milliseconds: 220),
      () => unawaited(refresh()),
    );
  }

  void _applyLocalItemStatus(String itemId, String status) {
    final now = DateTime.now();
    var changed = false;
    _items = _items
        .where((item) {
          if (item.id != itemId) return true;
          changed = true;
          return status != 'served';
        })
        .map((item) {
          if (item.id != itemId) return item;
          _statusOverrides[itemId] = _StatusOverride(
            status: status,
            startedAt: status == 'preparing' ? (item.startedAt ?? now) : null,
            readyAt: status == 'ready' ? now : null,
          );
          return item.copyWith(
            status: status,
            startedAt: status == 'preparing'
                ? (item.startedAt ?? now)
                : item.startedAt,
            readyAt: status == 'ready' ? now : item.readyAt,
          );
        })
        .toList(growable: false);

    if (changed) notifyListeners();
  }

  void _applyLocalOrderStatus(
    String orderId, {
    required Set<String> from,
    required String to,
  }) {
    final now = DateTime.now();
    var changed = false;

    _items = _items
        .map((item) {
          if (item.orderId != orderId || !from.contains(item.status)) {
            return item;
          }
          _statusOverrides[item.id] = _StatusOverride(
            status: to,
            startedAt: to == 'preparing' ? (item.startedAt ?? now) : null,
            readyAt: to == 'ready' ? now : null,
          );
          changed = true;
          return item.copyWith(
            status: to,
            startedAt: to == 'preparing'
                ? (item.startedAt ?? now)
                : item.startedAt,
            readyAt: to == 'ready' ? now : item.readyAt,
          );
        })
        .toList(growable: false);

    if (changed) notifyListeners();
  }

  List<KitchenItem> _applyStatusOverrides(List<KitchenItem> fetched) {
    if (_statusOverrides.isEmpty) return fetched;
    final now = DateTime.now();
    final result = <KitchenItem>[];

    for (final item in fetched) {
      final override = _statusOverrides[item.id];
      if (override == null) {
        result.add(item);
        continue;
      }

      // Si backend ya confirmó el mismo estado, liberamos override.
      if (item.status == override.status) {
        _statusOverrides.remove(item.id);
        result.add(item);
        continue;
      }

      // Evita "rebotes" visuales a estados anteriores por lecturas stale breves.
      if (override.expiresAt.isAfter(now)) {
        result.add(
          item.copyWith(
            status: override.status,
            startedAt: override.startedAt ?? item.startedAt,
            readyAt: override.readyAt ?? item.readyAt,
          ),
        );
        continue;
      }

      _statusOverrides.remove(item.id);
      result.add(item);
    }

    return result;
  }

  void _clearOverride(String itemId) {
    _statusOverrides.remove(itemId);
  }

  void _clearOverrides(Iterable<String> itemIds) {
    for (final id in itemIds) {
      _statusOverrides.remove(id);
    }
  }

  @override
  void dispose() {
    _refreshDebounce?.cancel();
    _statusOverrides.clear();
    _rtItems?.unsubscribe();
    _rtItems = null;
    super.dispose();
  }
}

class _StatusOverride {
  final String status;
  final DateTime? startedAt;
  final DateTime? readyAt;
  final DateTime expiresAt;

  _StatusOverride({
    required this.status,
    this.startedAt,
    this.readyAt,
    DateTime? expiresAt,
  }) : expiresAt = expiresAt ?? DateTime.now().add(const Duration(seconds: 4));
}
