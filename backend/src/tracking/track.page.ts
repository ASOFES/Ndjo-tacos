type TrackView = {
  number: string;
  status: string;
  statusLabel: string;
  restaurant: { name: string; address: string | null };
  destination: { label: string; zone: string | null; latitude: number; longitude: number };
  driver: { name: string; photoUrl: string } | null;
  location: { latitude: number; longitude: number; recordedAt: Date | string } | null;
  eta: { distanceKm: number; minutes: number; note: string } | null;
  etaAvailable: boolean;
  lastUpdate: Date | string | null;
  trackingToken: string;
  delivered: boolean;
};

function safeJson(value: unknown) {
  return JSON.stringify(value).replace(/</g, '\\u003c');
}

export function renderTrackHtml(view: TrackView) {
  return `<!DOCTYPE html>
<html lang="fr">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Suivi ${view.number} — NDJO TACOS</title>
  <link rel="stylesheet" href="https://unpkg.com/leaflet@1.9.4/dist/leaflet.css" />
  <style>
    :root { color-scheme: dark; }
    body { margin: 0; font-family: Segoe UI, sans-serif; background: #14110F; color: #FFF8F0; }
    header { padding: 18px 20px 8px; }
    h1 { margin: 0; font-size: 22px; }
    .muted { color: #C4B5A5; font-size: 14px; }
    .grid { display: grid; gap: 10px; padding: 0 16px 16px; }
    .card { background: #2B231D; border-radius: 16px; padding: 14px 16px; }
    .accent { color: #F48C06; }
    #map { height: 320px; border-radius: 16px; }
    .status { font-weight: 700; color: #E85D04; }
  </style>
</head>
<body>
  <header>
    <div class="muted">NDJO TACOS</div>
    <h1>Suivi ${view.number}</h1>
  </header>
  <div class="grid">
    <div class="card">
      <div class="status" id="status">${view.statusLabel}</div>
      <div class="muted" id="restaurant">${view.restaurant.name}${view.restaurant.address ? ' · ' + view.restaurant.address : ''}</div>
    </div>
    <div class="card">
      <div>Destination</div>
      <div class="muted" id="destination">${view.destination.label}${view.destination.zone ? ' · ' + view.destination.zone : ''}</div>
    </div>
    <div class="card">
      <div>Livreur</div>
      <div class="muted" id="driver">${view.driver ? view.driver.name : 'Pas encore affecté'}</div>
    </div>
    <div class="card">
      <div>ETA</div>
      <div class="accent" id="eta">${view.eta ? view.eta.minutes + ' min · ' + view.eta.distanceKm + ' km' : 'ETA indisponible'}</div>
    </div>
    <div class="card">
      <div>Dernière mise à jour</div>
      <div class="muted" id="updated">${view.lastUpdate ? new Date(view.lastUpdate).toLocaleString('fr-FR') : '—'}</div>
    </div>
    <div id="map"></div>
  </div>
  <script>window.__NDJO_TRACK__ = ${safeJson(view)};</script>
  <script src="https://unpkg.com/leaflet@1.9.4/dist/leaflet.js"></script>
  <script src="https://cdn.socket.io/4.8.1/socket.io.min.js"></script>
  <script>
    (function () {
      var data = window.__NDJO_TRACK__;
      var dest = [data.destination.latitude, data.destination.longitude];
      var map = L.map('map').setView(data.location ? [data.location.latitude, data.location.longitude] : dest, 14);
      L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
        attribution: '&copy; OpenStreetMap'
      }).addTo(map);
      var destMarker = L.marker(dest).addTo(map).bindPopup('Destination');
      var driverMarker = null;
      function setLocation(loc, eta) {
        if (!loc) {
          document.getElementById('eta').textContent = 'ETA indisponible';
          return;
        }
        var latlng = [loc.latitude, loc.longitude];
        if (!driverMarker) driverMarker = L.marker(latlng).addTo(map).bindPopup('Livreur');
        else driverMarker.setLatLng(latlng);
        map.panTo(latlng);
        document.getElementById('updated').textContent = loc.recordedAt
          ? new Date(loc.recordedAt).toLocaleString('fr-FR')
          : new Date().toLocaleString('fr-FR');
        document.getElementById('eta').textContent = eta
          ? eta.minutes + ' min · ' + eta.distanceKm + ' km'
          : 'ETA indisponible';
      }
      if (data.location) setLocation(data.location, data.eta);
      var socket = io('/live', { transports: ['websocket', 'polling'] });
      socket.on('connect', function () {
        socket.emit('track:join', { token: data.trackingToken });
      });
      socket.on('track:location', function (payload) {
        setLocation(payload, payload.eta);
      });
      socket.on('track:status', function (payload) {
        if (payload.statusLabel) document.getElementById('status').textContent = payload.statusLabel;
        else if (payload.status === 'LIVREE') document.getElementById('status').textContent = 'Livrée';
        else if (payload.status === 'EN_LIVRAISON') document.getElementById('status').textContent = 'En livraison';
        if (payload.driver) document.getElementById('driver').textContent = payload.driver;
        if (payload.status === 'LIVREE') {
          document.getElementById('eta').textContent = 'Livraison terminée';
        }
      });
    })();
  </script>
</body>
</html>`;
}
