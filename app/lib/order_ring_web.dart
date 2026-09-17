import 'dart:html' as html;

class NdjoOrderRing {
  static void _emit(String name) {
    try {
      html.window.dispatchEvent(html.CustomEvent(name));
    } catch (_) {}
  }

  static Future<void> unlock() async {
    _emit('ndjo-ring-unlock');
  }

  static void start() {
    _emit('ndjo-ring-start');
  }

  static void stop() {
    _emit('ndjo-ring-stop');
  }
}
