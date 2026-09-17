import 'dart:async';

import 'package:flutter/services.dart';

class NdjoOrderRing {
  static Timer? _timer;

  static Future<void> unlock() async {}

  static void start() {
    stop();
    SystemSound.play(SystemSoundType.alert);
    _timer = Timer.periodic(const Duration(milliseconds: 1300), (_) {
      SystemSound.play(SystemSoundType.alert);
    });
  }

  static void stop() {
    _timer?.cancel();
    _timer = null;
  }
}
