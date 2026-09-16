import 'dart:js_interop';

@JS('localStorage')
external JSObject get _localStorage;

extension _LocalStorageJs on JSObject {
  external void setItem(String key, String value);
  external String? getItem(String key);
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
