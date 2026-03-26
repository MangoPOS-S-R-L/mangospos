// lib/core/utils/web_utils/web_utils_stub.dart

class WebUtils {
  static String get href => '';
  static String get hash => '';
  static String get search => '';
  static String get pathname => '';
  static String get hostname => '';
  
  static void assign(String url) {
    // No-op on native
  }
  
  static void replaceState(dynamic data, String title, String url) {
    // No-op on native
  }
  
  static String get cookie => '';
  static set cookie(String value) {
    // No-op on native
  }
}
