import 'package:supabase_flutter/supabase_flutter.dart';

class MenuLiteRepository {
  final _sp = Supabase.instance.client;

  Future<List<Map<String, String>>> categoriesForBusiness(String businessId) async {
    final res = await _sp
        .from('categories')
        .select('id,name')
        .eq('business_id', businessId)
        .order('position');
    return (res as List)
        .map((e) => {'id': e['id'] as String, 'name': e['name'] as String})
        .toList();
  }

  Future<List<Map<String, String>>> menusForBusiness(String businessId) async {
    final res = await _sp
        .from('menus')
        .select('id,name')
        .eq('business_id', businessId)
        .order('created_at');
    return (res as List)
        .map((e) => {'id': e['id'] as String, 'name': e['name'] as String})
        .toList();
  }
}
