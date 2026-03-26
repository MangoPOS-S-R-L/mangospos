// lib/core/utils/web_utils/web_utils_web.dart

import 'package:web/web.dart' as web;

class WebUtils {
  static String get href => web.window.location.href;
  static String get hash => web.window.location.hash;
  static String get search => web.window.location.search;
  static String get pathname => web.window.location.pathname;
  static String get hostname => web.window.location.hostname;
  
  static void assign(String url) {
    web.window.location.assign(url);
  }
  
  static void replaceState(dynamic data, String title, String url) {
    web.window.history.replaceState(data, title, url);
  }
  
  static String get cookie => web.window.document.cookie;
  static set cookie(String value) => web.window.document.cookie = value;
}
