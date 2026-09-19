import 'package:flutter/material.dart';

import 'pages.dart';
import 'session.dart';
import 'theme.dart';

class InventoryPage extends StatefulWidget {
  const InventoryPage({super.key, required this.session});
  final Session session;

  @override
  State<InventoryPage> createState() => _InventoryPageState();
}

class _InventoryPageState extends State<InventoryPage> {
  List<dynamic> sessions = [];
  List<dynamic> theoretical = [];
  Map<String, dynamic>? open;
  String? error;
  bool loading = true;
  String query = '';

  String get _id => widget.session.establishmentId ?? '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant InventoryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    _load();
  }

  Future<void> _load() async {
    setState(() => loading = true);
    final cached = widget.session.peekList('inventories-$_id');
    theoretical = widget.session.sync?.store.localStockSummary() ?? [];
    if (cached.isNotEmpty) {
      sessions = cached;
      loading = false;
    }
    try {
      final list = await widget.session.cachedList('/stock/inventories?establishmentId=$_id', 'inventories-$_id');
      setState(() {
        sessions = list.isNotEmpty ? list : cached;
        theoretical = widget.session.sync?.store.localStockSummary() ?? theoretical;
        if (open != null) {
          final match = sessions.where((item) => item['id'] == open!['id']);
          open = match.isEmpty ? null : Map<String, dynamic>.from(match.first as Map);
        }
        error = null;
        loading = false;
      });
    } catch (_) {
      setState(() {
        sessions = sessions.isEmpty ? cached : sessions;
        error = null;
        loading = false;
      });
    }
  }

  Future<void> _start() async {
    final location = TextEditingController(text: 'Dépôt principal');
    final notes = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 24),
        title: const Text('Lancer un inventaire'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: location, decoration: const InputDecoration(labelText: 'Emplacement / stock')),
              const SizedBox(height: 8),
              TextField(controller: notes, decoration: const InputDecoration(labelText: 'Note')),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Lancer')),
        ],
      ),
    );
    if (ok != true) return;
    final created = await widget.session.api.post('/stock/inventories', {
      'establishmentId': _id,
      'location': location.text.trim(),
      'notes': notes.text.trim(),
    });
    setState(() => open = created);
    await _load();
    if (created['id'] != null) await _open(Map<String, dynamic>.from(created as Map));
  }

  Future<void> _open(Map<String, dynamic> session) async {
    setState(() => open = session);
    try {
      final full = await widget.session.api.getJson('/stock/inventories/${session['id']}');
      if (!mounted) return;
      if (full['id'] != null) setState(() => open = full);
    } catch (_) {}
  }

  Future<void> _count(Map<String, dynamic> line) async {
    final qty = TextEditingController(text: '${line['realQty'] ?? line['theoreticalQty'] ?? ''}');
    final note = TextEditingController(text: line['note']?.toString() ?? '');
    final product = line['product'] as Map? ?? {};
    final lot = line['lot'] as Map? ?? {};
    final kind = line['kind']?.toString() ?? '—';
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) {
        final size = MediaQuery.sizeOf(context);
        return Dialog(
          insetPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 16),
          child: SizedBox(
            height: size.height * 0.92,
            width: size.width > 580 ? 560 : size.width - 20,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 4, 8),
                  child: Row(
                    children: [
                      const Expanded(child: Text('Comptage inventaire', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800))),
                      IconButton(onPressed: () => Navigator.pop(context, false), icon: const Icon(Icons.close)),
                    ],
                  ),
                ),
                const Divider(height: 1, color: NdjoColors.line),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(product['name']?.toString() ?? 'Produit', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                        const SizedBox(height: 10),
                        _kv('Code produit', product['code']?.toString() ?? '—'),
                        _kv('Unité', line['unit']?.toString() ?? product['unit']?.toString() ?? '—'),
                        _kv('Lot', lot['number']?.toString() ?? '—'),
                        _kv('Emplacement du lot', lot['location']?.toString() ?? open?['location']?.toString() ?? '—'),
                        _kv('Péremption', lot['expiryDate']?.toString().split('T').first ?? '—'),
                        _kv('Entrée lot', lot['entryDate']?.toString().split('T').first ?? '—'),
                        _kv('Stock lot actuel', '${lot['qtyCurrent'] ?? '—'} / ${lot['qtyInitial'] ?? '—'}'),
                        _kv('Prix d’achat', lot['priceBuy'] != null ? '${lot['priceBuy']} FC' : '—'),
                        _kv('Statut lot', lot['status']?.toString() ?? '—'),
                        const SizedBox(height: 8),
                        _kv('Théorique', '${line['theoreticalQty']} ${line['unit'] ?? ''}'),
                        _kv('Réel déjà saisi', '${line['realQty'] ?? '—'}'),
                        _kv('Écart', '${line['variance'] ?? '—'}'),
                        _kv('Type d’écart', kind),
                        _kv('Compté par', line['countedBy']?['name']?.toString() ?? '—'),
                        _kv('Compté le', line['countedAt']?.toString().split('T').first ?? '—'),
                        if ((line['note']?.toString() ?? '').isNotEmpty) _kv('Note actuelle', line['note'].toString()),
                        const SizedBox(height: 14),
                        TextField(
                          controller: qty,
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          decoration: const InputDecoration(labelText: 'Quantité réelle'),
                        ),
                        const SizedBox(height: 10),
                        TextField(
                          controller: note,
                          maxLines: 3,
                          decoration: const InputDecoration(labelText: 'Observation'),
                        ),
                      ],
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                  child: Row(
                    children: [
                      TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuler')),
                      const Spacer(),
                      FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Enregistrer')),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
    if (ok != true || open == null) return;
    await widget.session.api.put('/stock/inventories/${open!['id']}/lines/${line['id']}', {
      'realQty': num.parse(qty.text.replaceAll(',', '.')),
      'note': note.text.trim(),
    });
    await _load();
    if (open?['id'] != null) await _open(Map<String, dynamic>.from(open!));
  }

  Widget _kv(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(color: NdjoColors.muted, fontSize: 11)),
          Text(value, style: const TextStyle(fontSize: 14, height: 1.3)),
        ],
      ),
    );
  }

  Future<void> _submit() async {
    if (open == null) return;
    await widget.session.api.post('/stock/inventories/${open!['id']}/submit');
    await _load();
  }

  Future<void> _validate() async {
    if (open == null) return;
    await widget.session.api.post('/stock/inventories/${open!['id']}/validate');
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Inventaire validé. Les écarts sont passés en mouvements de stock.')));
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    if (loading && sessions.isEmpty && theoretical.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    final compact = ndjoCompact(context);
    if (compact) {
      if (open != null) {
        return Column(
          children: [
            Material(
              color: NdjoColors.surface,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(4, 4, 16, 8),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back),
                      onPressed: () => setState(() => open = null),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            open!['number']?.toString() ?? 'Inventaire',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
                          ),
                          Text(
                            '${open!['location'] ?? ''} · ${open!['status']}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: NdjoColors.muted, fontSize: 13),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const Divider(height: 1, color: NdjoColors.line),
            Expanded(child: _detail()),
          ],
        );
      }
      return _list();
    }
    return Row(
      children: [
        SizedBox(width: 320, child: _list(sidebar: true)),
        const VerticalDivider(width: 1, color: NdjoColors.line),
        Expanded(child: open != null ? _detail() : _theoretical()),
      ],
    );
  }

  Widget _list({bool sidebar = false}) {
    final compact = ndjoCompact(context);
    return ListView(
      padding: EdgeInsets.all(compact ? 16 : 20),
      children: [
        Row(
          children: [
            const Expanded(child: Text('Inventaires', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold))),
            IconButton(onPressed: _start, icon: const Icon(Icons.add)),
          ],
        ),
        const Text('Hors ligne : copie du stock théorique. Lancer / valider un inventaire nécessite le réseau.', style: TextStyle(color: NdjoColors.muted, fontSize: 12)),
        const SizedBox(height: 12),
        NdjoSearchBar(
          hint: 'Rechercher un inventaire…',
          onChanged: (value) => setState(() => query = value),
        ),
        const SizedBox(height: 12),
        if (ndjoFilterList(sessions, query).isEmpty)
          Text(query.trim().isEmpty ? 'Aucun inventaire en copie locale.' : 'Aucun inventaire trouvé.', style: const TextStyle(color: NdjoColors.muted)),
        ...ndjoFilterList(sessions, query).map((item) {
          final session = Map<String, dynamic>.from(item as Map);
          return Card(
            color: session['id'] == open?['id'] ? const Color(0xFF3A2A1C) : null,
            child: ListTile(
              title: Text(session['number']?.toString() ?? '', overflow: TextOverflow.ellipsis),
              subtitle: Text(
                '${session['location']} · ${session['status']}'
                '${session['totals'] != null ? '\n${session['totals']?['counted'] ?? 0}/${session['totals']?['lines'] ?? 0} lignes comptées' : ''}',
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
              isThreeLine: session['totals'] != null,
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _open(session),
            ),
          );
        }),
        if (compact && !sidebar) ...[
          const SizedBox(height: 20),
          _theoreticalBody(),
        ],
      ],
    );
  }

  Widget _theoretical() {
    return ListView(
      padding: EdgeInsets.all(ndjoCompact(context) ? 16 : 24),
      children: [_theoreticalBody()],
    );
  }

  Widget _theoreticalBody() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Stock théorique (copie locale)', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        const Text('Données du catalogue / caisse déjà enregistrées sur cet appareil.', style: TextStyle(color: NdjoColors.muted)),
        const SizedBox(height: 16),
        if (ndjoFilterList(theoretical, query).isEmpty)
          Text(
            query.trim().isEmpty
                ? 'Aucune quantité en copie locale. Ouvrez d’abord la Caisse en ligne une fois.'
                : 'Aucun produit trouvé.',
            style: const TextStyle(color: NdjoColors.muted),
          ),
        ...ndjoFilterList(theoretical, query).map((item) {
          final map = Map<String, dynamic>.from(item as Map);
          return Card(
            child: ListTile(
              title: Text(map['name']?.toString() ?? '', overflow: TextOverflow.ellipsis),
              trailing: Text('${map['stockQty'] ?? 0} ${map['unit'] ?? ''}'),
            ),
          );
        }),
      ],
    );
  }

  Widget _detail() {
    final lines = open!['lines'] as List<dynamic>? ?? [];
    final canEdit = open!['status'] == 'EN_COURS';
    final canSubmit = open!['status'] == 'EN_COURS';
    final canValidate = open!['status'] == 'SOUMIS' || open!['status'] == 'EN_COURS';
    final compact = ndjoCompact(context);
    return ListView(
      padding: EdgeInsets.fromLTRB(compact ? 16 : 24, compact ? 12 : 24, compact ? 16 : 24, compact ? 32 : 24),
      children: [
        if (!compact) ...[
          Text(open!['number'].toString(), style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
        ],
        _kv('Emplacement', open!['location']?.toString() ?? '—'),
        _kv('Statut', open!['status']?.toString() ?? '—'),
        _kv('Compté par', open!['countedBy']?['name']?.toString() ?? '—'),
        if (open!['validatedBy'] != null) _kv('Validé par', open!['validatedBy']['name'].toString()),
        if ((open!['notes']?.toString() ?? '').isNotEmpty) _kv('Note', open!['notes'].toString()),
        _kv('Créé le', open!['countedAt']?.toString().split('T').first ?? open!['createdAt']?.toString().split('T').first ?? '—'),
        if (open!['submittedAt'] != null) _kv('Soumis le', open!['submittedAt'].toString().split('T').first),
        if (open!['validatedAt'] != null) _kv('Validé le', open!['validatedAt'].toString().split('T').first),
        if (open!['totals'] is Map)
          _kv('Progression', '${open!['totals']?['counted'] ?? 0} / ${open!['totals']?['lines'] ?? lines.length} lignes · ${open!['totals']?['gaps'] ?? 0} écart(s)'),
        const SizedBox(height: 12),
        NdjoSearchBar(
          hint: 'Rechercher une ligne (produit, lot…)',
          onChanged: (value) => setState(() => query = value),
        ),
        const SizedBox(height: 12),
        if (ndjoFilterList(lines, query).isEmpty)
          Text(query.trim().isEmpty ? 'Aucune ligne sur cet inventaire.' : 'Aucune ligne trouvée.', style: const TextStyle(color: NdjoColors.muted)),
        ...ndjoFilterList(lines, query).map((item) {
          final line = item as Map<String, dynamic>;
          final kind = line['kind']?.toString() ?? '—';
          final color = kind == 'MANQUE'
              ? NdjoColors.danger
              : kind == 'SURPLUS'
                  ? NdjoColors.success
                  : NdjoColors.muted;
          final lot = line['lot'] as Map? ?? {};
          return Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(line['product']?['name']?.toString() ?? 'Produit', style: const TextStyle(fontWeight: FontWeight.w800)),
                  const SizedBox(height: 6),
                  if (line['product']?['code'] != null) Text('Code ${line['product']['code']}'),
                  Text('Lot ${lot['number'] ?? '—'} · ${lot['location'] ?? open!['location'] ?? ''}'),
                  Text('Péremption ${lot['expiryDate']?.toString().split('T').first ?? '—'}', style: const TextStyle(color: NdjoColors.muted, fontSize: 12)),
                  Text('Stock lot ${lot['qtyCurrent'] ?? '—'} / ${lot['qtyInitial'] ?? '—'}'),
                  Text('Théorique : ${line['theoreticalQty']} ${line['unit']}'),
                  Text('Réel : ${line['realQty'] ?? '—'}'),
                  Text('Écart : ${line['variance'] ?? '—'} · $kind', style: TextStyle(color: color, fontWeight: FontWeight.w700)),
                  if (line['countedBy']?['name'] != null) Text('Saisi par ${line['countedBy']['name']}', style: const TextStyle(color: NdjoColors.muted, fontSize: 12)),
                  if ((line['note']?.toString() ?? '').isNotEmpty) Text('Note : ${line['note']}'),
                  if (canEdit) ...[
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(onPressed: () => _count(line), child: const Text('Compter')),
                    ),
                  ],
                ],
              ),
            ),
          );
        }),
        const SizedBox(height: 16),
        if (canSubmit)
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(onPressed: _submit, child: const Text('Soumettre')),
          ),
        if (canSubmit && canValidate) const SizedBox(height: 8),
        if (canValidate)
          SizedBox(
            width: double.infinity,
            child: FilledButton(onPressed: _validate, child: const Text('Valider les écarts')),
          ),
      ],
    );
  }
}

class LossesPage extends StatefulWidget {
  const LossesPage({super.key, required this.session});
  final Session session;

  @override
  State<LossesPage> createState() => _LossesPageState();
}

class _LossesPageState extends State<LossesPage> {
  List<dynamic> losses = [];
  List<dynamic> lots = [];
  String? error;
  bool loading = true;

  String get _id => widget.session.establishmentId ?? '';

  static const motifs = {
    'PERIME': 'Périmé',
    'AVARIE': 'Avarié',
    'ENDOMMAGE': 'Endommagé',
    'CASSE': 'Casse',
    'ERREUR': 'Erreur de manipulation',
    'AUTRE': 'Autre',
  };

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    losses = widget.session.peekList('losses-$_id');
    lots = widget.session.peekList('stock-lots-$_id');
    if (lots.isEmpty) lots = widget.session.sync?.store.allCachedLots(_id) ?? [];
    if (losses.isNotEmpty || lots.isNotEmpty) loading = false;
    try {
      final loaded = await Future.wait([
        widget.session.cachedList('/stock/losses?establishmentId=$_id', 'losses-$_id'),
        widget.session.cachedList('/stock/lots?establishmentId=$_id', 'stock-lots-$_id'),
      ]);
      setState(() {
        losses = loaded[0].isNotEmpty ? loaded[0] : losses;
        lots = loaded[1].isNotEmpty ? loaded[1] : lots;
        error = null;
        loading = false;
      });
    } catch (e) {
      setState(() {
        error = null;
        loading = false;
      });
    }
  }

  Future<void> _declare() async {
    if (lots.isEmpty) return;
    String lotId = lots.first['id'].toString();
    var motif = 'PERIME';
    final qty = TextEditingController(text: '1');
    final note = TextEditingController();
    final date = TextEditingController(text: DateTime.now().toIso8601String().split('T').first);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: const Text('Déclarer une perte'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String>(
                  initialValue: lotId,
                  items: lots
                      .map((item) => DropdownMenuItem(
                            value: item['id'].toString(),
                            child: Text('${item['product']?['name']} · ${item['number']} · ${item['qtyCurrent']}'),
                          ))
                      .toList(),
                  onChanged: (value) => setLocal(() => lotId = value ?? lotId),
                  decoration: const InputDecoration(labelText: 'Produit / lot'),
                ),
                TextField(controller: qty, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Quantité perdue')),
                DropdownButtonFormField<String>(
                  initialValue: motif,
                  items: motifs.entries.map((entry) => DropdownMenuItem(value: entry.key, child: Text(entry.value))).toList(),
                  onChanged: (value) => setLocal(() => motif = value ?? motif),
                  decoration: const InputDecoration(labelText: 'Motif'),
                ),
                TextField(controller: date, decoration: const InputDecoration(labelText: 'Date')),
                TextField(controller: note, decoration: const InputDecoration(labelText: 'Observation')),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuler')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Déclarer')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    await widget.session.api.post('/stock/losses', {
      'establishmentId': _id,
      'lotId': lotId,
      'quantity': num.parse(qty.text.replaceAll(',', '.')),
      'motif': motif,
      'note': note.text.trim(),
      'occurredAt': date.text,
    });
    await _load();
  }

  Future<void> _validate(String id) async {
    await widget.session.api.post('/stock/losses/$id/validate');
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Perte validée. Sortie de stock enregistrée.')));
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    if (loading) return const Center(child: CircularProgressIndicator());
    if (error != null) {
      return ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const Text('Pertes', style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          Text(error!, style: const TextStyle(color: NdjoColors.muted)),
        ],
      );
    }
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Row(
          children: [
            const Expanded(child: Text('Pertes', style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold))),
            FilledButton.icon(onPressed: _declare, icon: const Icon(Icons.add), label: const Text('Déclarer une perte')),
          ],
        ),
        const SizedBox(height: 8),
        const Text('La quantité du lot ne change qu’après validation, via un mouvement PERTE.', style: TextStyle(color: NdjoColors.muted)),
        const SizedBox(height: 16),
        ...losses.map((item) {
          final loss = item as Map<String, dynamic>;
          final pending = loss['status'] == 'DECLAREE';
          return Card(
            child: ListTile(
              title: Text('${loss['product']?['name']} · ${loss['lot']?['number']} · ${loss['quantity']} ${loss['unit']}'),
              subtitle: Text(
                '${motifs[loss['motif']] ?? loss['motif']} · ${loss['occurredAt']?.toString().split('T').first ?? ''}\n'
                'Déclaré par ${loss['declaredBy']?['name'] ?? '—'}'
                '${loss['validatedBy'] != null ? ' · Validé par ${loss['validatedBy']['name']}' : ''}',
              ),
              isThreeLine: true,
              trailing: pending
                  ? FilledButton(onPressed: () => _validate(loss['id'].toString()), child: const Text('Valider'))
                  : Text(loss['status']?.toString() ?? ''),
            ),
          );
        }),
      ],
    );
  }
}
