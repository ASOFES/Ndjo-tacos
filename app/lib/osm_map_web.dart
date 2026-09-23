import 'dart:convert';
import 'dart:html' as html;
import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';

import 'osm_types.dart';

class OsmMap extends StatefulWidget {
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
  State<OsmMap> createState() => _OsmMapState();
}

class _OsmMapState extends State<OsmMap> {
  late final String _viewType;
  html.IFrameElement? _iframe;

  @override
  void initState() {
    super.initState();
    _viewType = 'ndjo-osm-${widget.viewId}-${identityHashCode(this)}';
    ui_web.platformViewRegistry.registerViewFactory(_viewType, (int viewId) {
      final iframe = html.IFrameElement()
        ..style.border = 'none'
        ..style.width = '100%'
        ..style.height = '100%'
        ..src = _blobUrl();
      _iframe = iframe;
      return iframe;
    });
  }

  @override
  void didUpdateWidget(covariant OsmMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.markers != widget.markers || oldWidget.path != widget.path) {
      _iframe?.src = _blobUrl();
    }
  }

  String _blobUrl() {
    final blob = html.Blob([_leafletHtml(widget.markers, widget.path)], 'text/html');
    return html.Url.createObjectUrlFromBlob(blob);
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: widget.height,
      width: double.infinity,
      child: HtmlElementView(viewType: _viewType),
    );
  }
}

String _leafletHtml(List<OsmMarker> markers, List<OsmLatLng> path) {
  final payload = jsonEncode({
    'markers': [
      for (final marker in markers) {'lat': marker.lat, 'lng': marker.lng, 'label': marker.label ?? ''},
    ],
    'path': [
      for (final point in path) [point.lat, point.lng],
    ],
  });
  return '''<!DOCTYPE html>
<html lang="fr">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <link rel="stylesheet" href="https://unpkg.com/leaflet@1.9.4/dist/leaflet.css" />
  <style>html,body,#map{height:100%;margin:0;background:#14110F}</style>
</head>
<body>
  <div id="map"></div>
  <script src="https://unpkg.com/leaflet@1.9.4/dist/leaflet.js"></script>
  <script>
    (function () {
      var data = $payload;
      var map = L.map('map', { zoomControl: true });
      L.tileLayer('https://{s}.basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}{r}.png', {
        attribution: '&copy; <a href="https://www.openstreetmap.org/copyright" target="_blank" rel="noreferrer">OpenStreetMap</a> &copy; <a href="https://carto.com/attributions" target="_blank" rel="noreferrer">CARTO</a>',
        subdomains: 'abcd',
        maxZoom: 20
      }).addTo(map);
      var bounds = [];
      (data.markers || []).forEach(function (marker) {
        var ll = [marker.lat, marker.lng];
        bounds.push(ll);
        L.marker(ll).addTo(map).bindPopup(marker.label || '');
      });
      if (data.path && data.path.length > 1) {
        var line = L.polyline(data.path, { color: '#E85D04', weight: 4 });
        line.addTo(map);
        bounds = bounds.concat(data.path);
      }
      if (!bounds.length) {
        map.setView([-11.664, 27.479], 13);
      } else if (bounds.length === 1) {
        map.setView(bounds[0], 15);
      } else {
        map.fitBounds(bounds, { padding: [28, 28] });
      }
      setTimeout(function () { map.invalidateSize(); }, 180);
    })();
  </script>
</body>
</html>''';
}
