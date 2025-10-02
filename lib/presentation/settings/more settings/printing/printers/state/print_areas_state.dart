import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mangopos/core/business/business_resolver.dart';
import 'package:mangopos/data/models/printing.dart';
import 'package:mangopos/data/repositories/printing_repository.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

final printAreasRepoProvider = Provider<PrintingRepository>((ref) {
  final client = Supabase.instance.client;
  return PrintingRepository(client);
});

final printAreasListProvider =
    FutureProvider.family<List<PrintArea>, String>((ref, businessIdOrAuto) async {
  final repo = ref.watch(printAreasRepoProvider);
  final bid = await _resolveBusinessId(businessIdOrAuto);
  return repo.getPrintAreas(bid);
});

Future<String> _resolveBusinessId(String businessIdOrAuto) async {
  if (businessIdOrAuto.isEmpty || businessIdOrAuto == 'auto') {
    return BusinessResolver.resolveActiveBusinessId();
  }
  return businessIdOrAuto;
}
