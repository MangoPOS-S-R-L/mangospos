import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:mangopos/core/business/business_resolver.dart';
import 'package:mangopos/data/models/printing.dart';
import 'package:mangopos/data/repositories/printing_repository.dart';

final printAreasRepoProvider = Provider<PrintingRepository>((ref) {
  final client = Supabase.instance.client;
  return PrintingRepository(client);
});

final printAreasListProvider =
    FutureProvider.family<List<PrintArea>, String>((ref, businessIdOrAuto) async {
  final repo = ref.read(printAreasRepoProvider);
  final bid = await _ensureBid(businessIdOrAuto);
  return repo.getPrintAreas(bid);
});

Future<String> _ensureBid(String businessIdOrAuto) async {
  // usa el resolver que sí existe en tu proyecto
  return BusinessResolver.ensure(
    businessIdOrAuto.isEmpty ? 'auto' : businessIdOrAuto,
  );
}
