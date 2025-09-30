class Env {
  static const supabaseUrl = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: 'https://sqdwjjewdqzxglvqerqt.supabase.co',
  );

  // Anon PUBLIC de Supabase Cloud (ok en cliente; RLS es la barrera real)
  static const supabaseAnonKey = String.fromEnvironment(
    'SUPABASE_ANON_KEY',
    defaultValue:
        'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InNxZHdqamV3ZHF6eGdsdnFlcnF0Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NTgxMzEzODgsImV4cCI6MjA3MzcwNzM4OH0.voROjWT1TgOOVOS27JumfzQgEJ3sp1F8vH5QvcIWvFw',
  );
}

/*

// lib/env/env.dart
class Env {
  static const supabaseUrl = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: 'https://sqdwjjewdqzxglvqerqt.supabase.co',
  );

  // Anon PUBLIC de Supabase Cloud (ok en cliente; RLS es la barrera real)
  static const supabaseAnonKey = String.fromEnvironment(
    'SUPABASE_ANON_KEY',
    defaultValue:
        'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InNxZHdqamV3ZHF6eGdsdnFlcnF0Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NTgxMzEzODgsImV4cCI6MjA3MzcwNzM4OH0.voROjWT1TgOOVOS27JumfzQgEJ3sp1F8vH5QvcIWvFw',
  );
}
*/
