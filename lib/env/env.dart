// lib/env/env.dart
class Env {
  static const supabaseUrl = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: 'https://supabase.mangopos.do:8000',
  );

  // Anon PUBLIC de Supabase Cloud (ok en cliente; RLS es la barrera real)
  static const supabaseAnonKey = String.fromEnvironment(
    'SUPABASE_ANON_KEY',
    defaultValue:
        'eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9.eyJpc3MiOiJzdXBhYmFzZSIsImlhdCI6MTc3MjgzOTUwMCwiZXhwIjo0OTI4NTEzMTAwLCJyb2xlIjoiYW5vbiJ9.LHw1pkCZ3DySAmly08hFoykgbG0CCC7k7Igh2izbCAg',
  );
}

/*

class Env {
  static const supabaseUrl = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: 'http://127.0.0.1:54321',
  );
  static const supabaseAnonKey = String.fromEnvironment(
    'SUPABASE_ANON_KEY',
    defaultValue:
        'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0',
  );
}
*/

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
