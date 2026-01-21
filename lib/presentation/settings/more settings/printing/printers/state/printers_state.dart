// lib/presentation/settings/printing/state/printers_state.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mangopos/data/models/printing_models.dart';
import 'package:mangopos/data/repositories/printing_repository.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:mangopos/core/business/business_resolver.dart';

/// Repo provider (inyecta SupabaseClient)
final printersRepoProvider = Provider<PrintingRepository>((ref) {
  final client = Supabase.instance.client;
  return PrintingRepository(client);
});

/// Lista “read-only” de impresoras (útil para combos, etc.)
final printersListProvider = FutureProvider.family<List<PrinterConfig>, String>(
  (ref, businessIdOrAuto) async {
    final repo = ref.read(printersRepoProvider);
    final bid = await _ensureBid(businessIdOrAuto);
    return repo.getPrinters(bid);
  },
);

Future<String> _ensureBid(String businessIdOrAuto) async {
  // usa tu BusinessResolver.ensure(...)
  return BusinessResolver.ensure(
    (businessIdOrAuto.isEmpty) ? 'auto' : businessIdOrAuto,
  );
}
