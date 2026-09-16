import 'package:flutter/material.dart';

import 'osm_types.dart';
import 'theme.dart';

class OsmMap extends StatelessWidget {
  const OsmMap({
    super.key,
    required this.viewId,
    this.height = 220,
    this.markers = const [],
    this.path = const [],
  });

  final String viewId;
  final double height;
  final List<OsmMarker> markers;
  final List<OsmLatLng> path;

  @override
  Widget build(BuildContext context) {
    final marker = markers.isNotEmpty
        ? markers.last
        : path.isNotEmpty
            ? OsmMarker(lat: path.last.lat, lng: path.last.lng)
            : null;
    return Container(
      height: height,
      width: double.infinity,
      color: const Color(0xFF2B231D),
      alignment: Alignment.center,
      child: Text(
        marker == null
            ? 'Carte GPS — en attente de position'
            : 'Carte GPS ${marker.lat.toStringAsFixed(5)}, ${marker.lng.toStringAsFixed(5)}',
        style: const TextStyle(color: NdjoColors.muted),
        textAlign: TextAlign.center,
      ),
    );
  }
}
