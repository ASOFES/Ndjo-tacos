import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

const printerMmKey = 'ndjo_printer_mm';

int defaultPrinterMm() {
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) return 56;
  return 80;
}

Future<int> loadPrinterMm() async {
  final prefs = await SharedPreferences.getInstance();
  final stored = prefs.getInt(printerMmKey);
  if (stored == 56 || stored == 80) return stored!;
  return defaultPrinterMm();
}

Future<void> savePrinterMm(int mm) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setInt(printerMmKey, mm == 56 ? 56 : 80);
}
