import 'dart:js_interop';

@JS('localStorage')
external JSObject get _localStorage;

@JS('location')
external JSObject get _location;

extension _LocalStorageJs on JSObject {
  external void setItem(String key, String value);
  external String? getItem(String key);
  external void removeItem(String key);
  external String? key(int index);
  external int get length;
}

extension _LocationJs on JSObject {
  external void reload();
}

void saveWebBackup(String key, String json) {
  try {
    _localStorage.setItem(key, json);
  } catch (_) {}
}

String? loadWebBackup(String key) {
  try {
    return _localStorage.getItem(key);
  } catch (_) {
    return null;
  }
}

void clearWebBackup(String key) {
  try {
    _localStorage.removeItem(key);
  } catch (_) {}
}

/// Supprime toutes les clés NDJO / Flutter dans localStorage.
void clearAllNdjoWebStorage() {
  try {
    final keys = <String>[];
    final n = _localStorage.length;
    for (var i = 0; i < n; i++) {
      final key = _localStorage.key(i) ?? '';
      final lower = key.toLowerCase();
      if (lower.contains('ndjo') ||
          lower.contains('flutter') ||
          lower.contains('hive')) {
        keys.add(key);
      }
    }
    for (final key in keys) {
      _localStorage.removeItem(key);
    }
  } catch (_) {}
}

void reloadAppPage() {
  try {
    _location.reload();
  } catch (_) {}
}
