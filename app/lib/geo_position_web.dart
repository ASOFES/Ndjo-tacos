import 'dart:html';

Future<Map<String, double>?> currentGps() async {
  try {
    final position = await window.navigator.geolocation.getCurrentPosition();
    final coords = position.coords;
    if (coords == null || coords.latitude == null || coords.longitude == null) {
      return null;
    }
    return {
      'latitude': coords.latitude!.toDouble(),
      'longitude': coords.longitude!.toDouble(),
    };
  } catch (_) {
    return null;
  }
}
