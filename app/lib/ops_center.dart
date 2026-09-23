import 'package:flutter/material.dart';

import 'api.dart';
import 'osm_map.dart';
import 'session.dart';
import 'theme.dart';
import 'time_fmt.dart';

Color _tone(String? status) {
  switch (status) {
    case 'VERT':
      return NdjoColors.success;
    case 'ORANGE':
      return NdjoColors.accent;
    case 'ROUGE':
    case 'MAINTENANCE':
      return NdjoColors.danger;
    default:
      return NdjoColors.muted;
  }
}

String _dot(String? status) {
  switch (status) {
    case 'VERT':
      return '🟢';
    case 'ORANGE':
      return '🟠';
    case 'ROUGE':
      return '🔴';
    case 'MAINTENANCE':
      return '⚙️';
    default:
      return '⚪';
  }
}

class SyncCenterPage extends StatefulWidget {
  const SyncCenterPage({super.key, required this.session});
  final Session session;

  @override
  State<SyncCenterPage> createState() => _SyncCenterPageState();
}

class _SyncCenterPageState extends State<SyncCenterPage> {
  Map<String, dynamic>? data;
  String? error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final id = widget.session.establishmentId;
      final query = id == null ? '' : '?establishmentId=$id';
      final loaded = await widget.session.api.getJson('/admin/ops/sync$query');
      setState(() {
        data = loaded;
        error = null;
      });
    } catch (e) {
      setState(() => error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final localPending = widget.session.sync?.store.pending() ?? [];
    final localHistory = widget.session.sync?.store.historyRows() ?? [];
    final snapshots = widget.session.sync?.store.snapshotCounts() ?? {};
    final localDb = Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Base locale de cet appareil', style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            const Text(
              'Copie temporaire (PC : navigateur / téléphone : fichiers Hive). Les écrans lisent ces données hors ligne. Dès que le serveur répond, la file part tout de suite — pas besoin d’attendre le prochain cycle.',
              style: TextStyle(color: NdjoColors.muted),
            ),
            const SizedBox(height: 12),
            if (snapshots.isEmpty)
              const Text('Aucune copie locale. Ouvrez les menus une fois en ligne, ou cliquez Synchroniser.')
            else
              ...snapshots.entries.take(24).map(
                (entry) => Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text('${entry.key} · ${entry.value} enregistrement(s)'),
                ),
              ),
            const SizedBox(height: 8),
            const Text(
              'Pour recharger les données : bouton Actualiser en haut de l’écran, sur le tableau de bord ou à la caisse.',
              style: TextStyle(color: NdjoColors.muted, fontSize: 12),
            ),
          ],
        ),
      ),
    );
    if (error != null && data == null) {
      return ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const Text('Centre de synchronisation', style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
          Text('Serveur injoignable : $error', style: const TextStyle(color: NdjoColors.danger)),
          const SizedBox(height: 16),
          localDb,
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () async {
              final id = widget.session.establishmentId;
              if (id != null) await widget.session.sync?.pull(id);
              await widget.session.sync?.flush();
              await _load();
              if (mounted) setState(() {});
            },
            child: const Text('Réessayer / synchroniser'),
          ),
        ],
      );
    }
    if (data == null) return const Center(child: CircularProgressIndicator());
    final places = data!['establishments'] as List<dynamic>? ?? [];
    final devices = data!['devices'] as List<dynamic>? ?? [];
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const Text('Centre de synchronisation', style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
        const Text('État des établissements et des appareils hors ligne.', style: TextStyle(color: NdjoColors.muted)),
        const SizedBox(height: 16),
        localDb,
        const SizedBox(height: 12),
        FilledButton(
          onPressed: () async {
            final id = widget.session.establishmentId;
            if (id != null) await widget.session.sync?.pull(id);
            await widget.session.sync?.flush();
            await _load();
            if (mounted) setState(() {});
          },
          child: const Text('Copier les données sur cet appareil + synchroniser'),
        ),
        const SizedBox(height: 16),
        Card(
          child: ListTile(
            leading: const Icon(Icons.cloud_sync),
            title: Text('${localPending.length} opération(s) locales à synchroniser'),
            subtitle: const Text('Dès que le serveur répond, l’envoi est immédiat. Le Wi‑Fi seul ne suffit pas : l’API doit répondre.'),
            trailing: TextButton(
              onPressed: () async {
                await widget.session.sync?.flush();
                await _load();
                if (mounted) setState(() {});
              },
              child: const Text('Sync'),
            ),
          ),
        ),
        ...localPending.map((item) {
          return Card(
            child: ListTile(
              title: Text('${item['type']} · ${item['clientUuid']}'),
              subtitle: Text('${item['status'] ?? 'EN_ATTENTE_SYNC'} · ${item['error'] ?? 'en file'}'),
            ),
          );
        }),
        if (localHistory.isNotEmpty) ...[
          const SizedBox(height: 12),
          const Text('Historique local', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          ...localHistory.take(12).map((item) {
            return Card(
              child: ListTile(
                title: Text('${item['type']} · ${item['status']}'),
                subtitle: Text(item['error']?.toString() ?? item['clientUuid']?.toString() ?? ''),
              ),
            );
          }),
        ],
        const SizedBox(height: 16),
        ...places.map((item) {
          final map = item as Map<String, dynamic>;
          return Card(
            child: ListTile(
              leading: Text(_dot(map['status']?.toString()), style: const TextStyle(fontSize: 22)),
              title: Text('${map['code']} · ${map['name']}'),
              subtitle: Text('${map['devices']} appareil(s) · ${map['pendingOps']} opération(s) en attente'),
              trailing: Text(map['status']?.toString() ?? '', style: TextStyle(color: _tone(map['status']?.toString()))),
            ),
          );
        }),
        const SizedBox(height: 20),
        const Text('Appareils', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        ...devices.map((item) {
          final map = item as Map<String, dynamic>;
          final pending = map['pendingOps'] ?? 0;
          return Card(
            child: ListTile(
              leading: Text(_dot(map['status']?.toString()), style: const TextStyle(fontSize: 22)),
              title: Text('${map['deviceName']} · ${map['role']}'),
              subtitle: Text(
                pending > 0
                    ? '$pending opération(s) en attente · ${map['establishment']}'
                    : 'Dernière sync : ${map['lastSyncAt'] ?? map['lastSeenAt'] ?? '—'}',
              ),
              trailing: Text(map['status']?.toString() ?? ''),
            ),
          );
        }),
      ],
    );
  }
}

class SystemHealthPage extends StatefulWidget {
  const SystemHealthPage({super.key, required this.session});
  final Session session;

  @override
  State<SystemHealthPage> createState() => _SystemHealthPageState();
}

class _SystemHealthPageState extends State<SystemHealthPage> {
  Map<String, dynamic>? data;
  String? error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final loaded = await widget.session.api.getJson('/admin/ops/health');
      setState(() {
        data = loaded;
        error = null;
      });
    } catch (_) {
      setState(() {
        data = {
          'services': <String, dynamic>{},
          'details': <String, dynamic>{},
        };
        error = null;
      });
    }
  }

  Future<void> _set(String key, String status) async {
    await widget.session.api.put('/admin/ops/flags', {'key': key, 'status': status});
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    if (data == null) return const Center(child: CircularProgressIndicator());
    final services = Map<String, dynamic>.from(data!['services'] as Map? ?? {});
    final details = Map<String, dynamic>.from(data!['details'] as Map? ?? {});
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const Text('État du système', style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
        const Text('Mode maintenance et diagnostic des services.', style: TextStyle(color: NdjoColors.muted)),
        const SizedBox(height: 16),
        ...services.entries.map((entry) {
          return Card(
            child: ListTile(
              leading: Text(_dot(entry.value.toString()), style: const TextStyle(fontSize: 22)),
              title: Text(entry.key.toUpperCase()),
              subtitle: Text(entry.value.toString(), style: TextStyle(color: _tone(entry.value.toString()))),
              trailing: PopupMenuButton<String>(
                onSelected: (value) => _set(entry.key, value),
                itemBuilder: (context) => const [
                  PopupMenuItem(value: 'VERT', child: Text('Forcer 🟢')),
                  PopupMenuItem(value: 'ORANGE', child: Text('Forcer 🟠')),
                  PopupMenuItem(value: 'ROUGE', child: Text('Forcer 🔴')),
                  PopupMenuItem(value: 'MAINTENANCE', child: Text('Maintenance')),
                ],
              ),
            ),
          );
        }),
        const SizedBox(height: 16),
        Text('Base : ${details['databaseProvider'] ?? '—'}', style: const TextStyle(color: NdjoColors.muted)),
        Text('WhatsApp configuré : ${details['whatsappConfigured'] == true ? 'oui' : 'non'} · webhook : ${details['whatsappWebhookReady'] == true ? 'oui' : 'non'}', style: const TextStyle(color: NdjoColors.muted)),
        Text('FlexPay : ${details['flexpayConfigured'] == true ? 'oui' : 'non'} · Stripe : ${details['stripeConfigured'] == true ? 'oui' : 'non'}', style: const TextStyle(color: NdjoColors.muted)),
        Text('Mobile Money : ${details['mobileMoneyConfigured'] == true ? 'oui' : 'non'} · Carte : ${details['cardConfigured'] == true ? 'oui' : 'non'}', style: const TextStyle(color: NdjoColors.muted)),
        Text('API locale : ${Api.baseUrl}', style: const TextStyle(color: NdjoColors.muted)),
        if ((details['lan'] as Map?)?['appUrls'] is List)
          Text(
            'Tablettes Wi‑Fi : ${((details['lan'] as Map)['appUrls'] as List).join('  ·  ')}',
            style: const TextStyle(color: NdjoColors.muted),
          ),
      ],
    );
  }
}

class TrackOrderPage extends StatefulWidget {
  const TrackOrderPage({super.key, required this.token, this.session});
  final String token;
  final Session? session;

  @override
  State<TrackOrderPage> createState() => _TrackOrderPageState();
}

class _TrackOrderPageState extends State<TrackOrderPage> {
  Map<String, dynamic>? data;
  String? error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final api = widget.session?.api ?? Api();
      final loaded = await api.getJson('/track/${widget.token}');
      setState(() {
        data = loaded;
        error = null;
      });
    } catch (e) {
      setState(() => error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    if (error != null) {
      return Center(child: Text(error!, style: const TextStyle(color: NdjoColors.danger)));
    }
    if (data == null) return const Center(child: CircularProgressIndicator());
    final items = data!['items'] as List<dynamic>? ?? [];
    final location = data!['location'] as Map<String, dynamic>?;
    final eta = data!['eta'] as Map<String, dynamic>?;
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text('Suivi ${data!['number']}', style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
        Text('${data!['establishment']?['name'] ?? ''} · ${data!['status']} · paiement ${data!['paymentStatus']}', style: const TextStyle(color: NdjoColors.muted)),
        const SizedBox(height: 16),
        Card(
          child: ListTile(
            leading: data!['driver']?['photoUrl'] != null
                ? CircleAvatar(backgroundImage: NetworkImage(data!['driver']['photoUrl'].toString()))
                : const Icon(Icons.delivery_dining),
            title: Text(data!['driver']?['name']?.toString() ?? 'Livreur non encore affecté'),
            subtitle: Text(data!['address']?.toString() ?? data!['destination']?['label']?.toString() ?? ''),
          ),
        ),
        Card(
          child: ListTile(
            leading: const Icon(Icons.schedule),
            title: Text('Prise ${_fmtTrack(data!['pickedUpAt'])} · Départ ${_fmtTrack(data!['departedAt'])}'),
            subtitle: Text('Arrivée ${_fmtTrack(data!['arrivedAt'])} · durée ${data!['durationMinutes'] ?? '—'} min'),
          ),
        ),
        if (data!['receptionCode'] != null)
          Card(
            child: ListTile(
              leading: const Icon(Icons.lock, color: NdjoColors.accent),
              title: Text('Code de réception : ${data!['receptionCode']}'),
              subtitle: const Text('À donner au livreur à la remise'),
            ),
          ),
        if (eta != null)
          Card(
            child: ListTile(
              leading: const Icon(Icons.schedule, color: NdjoColors.accent),
              title: Text('Arrivée estimée : ${eta['minutes']} min'),
              subtitle: Text('${eta['distanceKm']} km · ${eta['note'] ?? ''}'),
            ),
          )
        else if (location == null)
          const Card(
            child: ListTile(
              title: Text('ETA non disponible'),
              subtitle: Text('En attente de la position GPS du livreur.'),
            ),
          ),
        if (data!['proof'] != null)
          Card(
            child: ListTile(
              leading: const Icon(Icons.verified, color: NdjoColors.accent),
              title: Text('Livré ${_fmtTrack(data!['proof']?['deliveredAt'])} par ${data!['proof']?['deliveredBy'] ?? '—'}'),
              subtitle: Text('Signature : ${data!['proof']?['signature'] ?? '—'} · OTP ${data!['proof']?['otpVerified'] == true ? 'validé' : '—'}'),
            ),
          ),
        NdjoDeliveryMap(
          viewId: 'track-${widget.token}',
          location: location,
          destination: data!['destination'] as Map<String, dynamic>?,
          trail: data!['trail'] as List<dynamic>? ?? const [],
          browseUrl: data!['mapBrowseUrl']?.toString(),
        ),
        NdjoMovementHistory(
          movements: data!['movements'] as List<dynamic>? ?? const [],
          formatTime: _fmtTrack,
        ),
        if (location != null)
          Card(
            child: ListTile(
              leading: const Icon(Icons.my_location, color: NdjoColors.accent),
              title: Text('Position ${location['latitude']} , ${location['longitude']}'),
              subtitle: Text('Mis à jour ${location['recordedAt']}'),
            ),
          )
        else
          const Card(
            child: ListTile(
              title: Text('Position GPS pas encore reçue'),
              subtitle: Text('Le livreur enverra sa position une fois en route.'),
            ),
          ),
        const SizedBox(height: 16),
        ...items.map((item) {
          final map = item as Map<String, dynamic>;
          return ListTile(
            dense: true,
            title: Text('${map['quantity']} × ${map['name']}'),
          );
        }),
        const SizedBox(height: 12),
        OutlinedButton(onPressed: _load, child: const Text('Actualiser')),
      ],
    );
  }
}

String _fmtTrack(dynamic value) => formatLocalDateTime(value);
