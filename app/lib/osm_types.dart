class OsmLatLng {
  const OsmLatLng(this.lat, this.lng);
  final double lat;
  final double lng;
}

class OsmMarker {
  const OsmMarker({required this.lat, required this.lng, this.label});
  final double lat;
  final double lng;
  final String? label;
}
