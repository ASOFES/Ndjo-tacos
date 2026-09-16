import 'package:flutter/material.dart';

import 'open_link.dart';
import 'osm_map_stub.dart' if (dart.library.html) 'osm_map_web.dart';
import 'osm_types.dart';
import 'theme.dart';

export 'osm_types.dart';
export 'osm_map_stub.dart' if (dart.library.html) 'osm_map_web.dart';

class NdjoDeliveryMap extends StatelessWidget {
  const NdjoDeliveryMap({
    super.key,
    required this.viewId,
    this.location,
    this.destination,
    this.trail = const [],
    this.browseUrl,
    this.height = 220,
  });

  final String viewId;
  final Map<String, dynamic>? location;
  final Map<String, dynamic>? destination;
  final List<dynamic> trail;
  final String? browseUrl;
  final double height;

  @override
  Widget build(BuildContext context) {
    final markers = <OsmMarker>[
      if (_point(destination) != null)
        OsmMarker(
          lat: _point(destination)!.lat,
          lng: _point(destination)!.lng,
          label: destination?['label']?.toString() ?? 'Destination',
        ),
      if (_point(location) != null)
        OsmMarker(
          lat: _point(location)!.lat,
          lng: _point(location)!.lng,
          label: 'Livreur',
        ),
    ];
    final path = <OsmLatLng>[
      for (final item in trail)
        if (item is Map && _point(item) != null) _point(item)!,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: OsmMap(
            viewId: viewId,
            height: height,
            markers: markers,
            path: path,
          ),
        ),
        if (browseUrl != null && browseUrl!.isNotEmpty)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => openExternal(browseUrl!),
              icon: const Icon(Icons.open_in_new, size: 16),
              label: const Text('Ouvrir dans OpenStreetMap'),
            ),
          ),
      ],
    );
  }
}

class NdjoMovementHistory extends StatelessWidget {
  const NdjoMovementHistory({
    super.key,
    required this.movements,
    this.formatTime,
  });

  final List<dynamic> movements;
  final String Function(dynamic value)? formatTime;

  @override
  Widget build(BuildContext context) {
    if (movements.isEmpty) {
      return const Card(
        child: ListTile(
          leading: Icon(Icons.timeline, color: NdjoColors.accent),
          title: Text('Historique de mouvement'),
          subtitle: Text('Pas encore de course. Affectez le livreur, démarrez, puis envoyez le GPS.'),
        ),
      );
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Historique de mouvement', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
            const SizedBox(height: 8),
            for (final item in movements)
              if (item is Map)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        item['kind']?.toString() == 'GPS' ? Icons.my_location : Icons.flag,
                        size: 20,
                        color: NdjoColors.accent,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(item['label']?.toString() ?? 'Mouvement', style: const TextStyle(fontWeight: FontWeight.w600)),
                            Text(
                              [
                                (formatTime ?? _defaultTime)(item['at']),
                                if (item['latitude'] != null && item['longitude'] != null)
                                  '${(item['latitude'] as num).toStringAsFixed(5)}, ${(item['longitude'] as num).toStringAsFixed(5)}',
                              ].join(' · '),
                              style: const TextStyle(color: NdjoColors.muted, fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
          ],
        ),
      ),
    );
  }
}

OsmLatLng? _point(Map<dynamic, dynamic>? data) {
  final lat = data?['latitude'];
  final lng = data?['longitude'];
  if (lat is! num || lng is! num) return null;
  return OsmLatLng(lat.toDouble(), lng.toDouble());
}

String _defaultTime(dynamic value) {
  if (value == null) return '—';
  final text = value.toString();
  return text.contains('T') ? text.replaceFirst('T', ' ').split('.').first : text;
}
