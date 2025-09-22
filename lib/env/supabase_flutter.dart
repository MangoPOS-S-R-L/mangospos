// lib/config/supabase_config.dart
import 'package:supabase_flutter/supabase_flutter.dart';
import '../env/env.dart';

class SupabaseConfig {
  static Future<void> initialize() async {
    await Supabase.initialize(
      url: Env.supabaseUrl,
      anonKey: Env.supabaseAnonKey,
    );
  }

  // Helper para obtener el cliente de Supabase
  static SupabaseClient get client => Supabase.instance.client;
}
