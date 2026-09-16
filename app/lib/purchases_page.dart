import 'package:flutter/material.dart';

import 'pages.dart';
import 'session.dart';
import 'theme.dart';

class PurchasesPage extends StatefulWidget {
  const PurchasesPage({super.key, required this.session});
  final Session session;

  @override
  State<PurchasesPage> createState() => _PurchasesPageState();
}

class _PurchasesPageState extends State<PurchasesPage> {
  List<dynamic> suppliers = [];
  List<dynamic> purchases = [];
  List<dynamic> products = [];
  Map<String, dynamic>? open;
  String tab = 'achats';
  String? error;
  bool loading = true;

  String get _id => widget.session.establishmentId ?? '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant PurchasesPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    _load();
  }

  Future<void> _load() async {
    setState(() => loading = true);
    suppliers = widget.session.peekList('suppliers-$_id');
    purchases = widget.session.peekList('purchases-$_id');
    products = widget.session.peekList('catalog-$_id-TOUS');
    if (suppliers.isNotEmpty || purchases.isNotEmpty) loading = false;
    try {
      final loaded = await Future.wait([
        widget.session.cachedList('/suppliers?establishmentId=$_id', 'suppliers-$_id'),
        widget.session.cachedList('/purchases?establishmentId=$_id', 'purchases-$_id'),
        widget.session.cachedList('/catalog/products?establishmentId=$_id', 'catalog-$_id-TOUS'),
      ]);
      setState(() {
        suppliers = loaded[0].isNotEmpty ? loaded[0] : suppliers;
        purchases = loaded[1].isNotEmpty ? loaded[1] : purchases;
        products = loaded[2].isNotEmpty ? loaded[2] : products;
        if (open != null) {
          final match = purchases.where((item) => item['id'] == open!['id']);
          open = match.isEmpty ? open : Map<String, dynamic>.from(match.first as Map);
        }
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

  Future<void> _editSupplier([Map<String, dynamic>? current]) async {
    final name = TextEditingController(text: current?['name']?.toString() ?? '');
    final phone = TextEditingController(text: current?['phone']?.toString() ?? '');
    final email = TextEditingController(text: current?['email']?.toString() ?? '');
    final address = TextEditingController(text: current?['address']?.toString() ?? '');
    var status = current?['status']?.toString() ?? 'ACTIF';
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          insetPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 24),
          title: Text(current == null ? 'Nouveau fournisseur' : 'Modifier le fournisseur'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(controller: name, decoration: const InputDecoration(labelText: 'Nom')),
                const SizedBox(height: 8),
                TextField(controller: phone, decoration: const InputDecoration(labelText: 'Téléphone')),
                const SizedBox(height: 8),
                TextField(controller: email, decoration: const InputDecoration(labelText: 'E-mail')),
                const SizedBox(height: 8),
                TextField(controller: address, decoration: const InputDecoration(labelText: 'Adresse')),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  initialValue: status,
                  isExpanded: true,
                  items: const [
                    DropdownMenuItem(value: 'ACTIF', child: Text('Actif')),
                    DropdownMenuItem(value: 'INACTIF', child: Text('Inactif')),
                  ],
                  onChanged: (value) => setLocal(() => status = value ?? status),
                  decoration: const InputDecoration(labelText: 'Statut'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuler')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Enregistrer')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final payload = {
      'establishmentId': _id,
      'name': name.text.trim(),
      'phone': phone.text.trim(),
      'email': email.text.trim(),
      'address': address.text.trim(),
      'status': status,
    };
    if (current == null) {
      await widget.session.api.post('/suppliers', payload);
    } else {
      await widget.session.api.put('/suppliers/${current['id']}', payload);
    }
    await _load();
  }

  Future<void> _createPurchase() async {
    if (suppliers.isEmpty || products.isEmpty) return;
    String supplierId = suppliers.first['id'].toString();
    String productId = products.first['id'].toString();
    final qty = TextEditingController(text: '10');
    final price = TextEditingController(text: '${products.first['priceBuy'] ?? 0}');
    final location = TextEditingController(text: 'Dépôt principal');
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          insetPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 24),
          title: const Text('Bon d’achat'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String>(
                  initialValue: supplierId,
                  isExpanded: true,
                  items: suppliers.map((item) => DropdownMenuItem(value: item['id'].toString(), child: Text(item['name'].toString(), overflow: TextOverflow.ellipsis))).toList(),
                  onChanged: (value) => setLocal(() => supplierId = value ?? supplierId),
                  decoration: const InputDecoration(labelText: 'Fournisseur'),
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  initialValue: productId,
                  isExpanded: true,
                  items: products.map((item) => DropdownMenuItem(value: item['id'].toString(), child: Text('${item['name']} · ${item['format'] ?? item['unit']}', overflow: TextOverflow.ellipsis))).toList(),
                  onChanged: (value) {
                    final product = products.firstWhere((item) => item['id'] == value);
                    setLocal(() {
                      productId = value ?? productId;
                      price.text = '${product['priceBuy'] ?? 0}';
                    });
                  },
                  decoration: const InputDecoration(labelText: 'Produit'),
                ),
                const SizedBox(height: 8),
                TextField(controller: qty, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Quantité')),
                const SizedBox(height: 8),
                TextField(controller: price, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Prix unitaire (FC)')),
                const SizedBox(height: 8),
                TextField(controller: location, decoration: const InputDecoration(labelText: 'Emplacement de réception')),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuler')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Créer')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final created = await widget.session.api.post('/purchases', {
      'establishmentId': _id,
      'supplierId': supplierId,
      'location': location.text.trim(),
      'lines': [
        {
          'productId': productId,
          'quantity': num.parse(qty.text.replaceAll(',', '.')),
          'unitPrice': int.parse(price.text),
        },
      ],
    });
    setState(() {
      tab = 'achats';
      open = created;
    });
    await _load();
  }

  Future<void> _receive(Map<String, dynamic> line) async {
    if (open == null) return;
    final remaining = (line['quantity'] as num) - (line['receivedQty'] as num? ?? 0);
    final qty = TextEditingController(text: '$remaining');
    final expiry = TextEditingController(text: DateTime.now().add(const Duration(days: 180)).toIso8601String().split('T').first);
    final price = TextEditingController(text: '${line['unitPrice']}');
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 24),
        title: const Text('Réception'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${line['product']?['name'] ?? 'Produit'}', style: const TextStyle(fontWeight: FontWeight.w800)),
              const SizedBox(height: 4),
              Text('Restant : $remaining ${line['unit']}', style: const TextStyle(color: NdjoColors.muted)),
              const SizedBox(height: 8),
              TextField(controller: qty, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Quantité reçue')),
              const SizedBox(height: 8),
              TextField(controller: expiry, decoration: const InputDecoration(labelText: 'Péremption (AAAA-MM-JJ)')),
              const SizedBox(height: 8),
              TextField(controller: price, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Prix d’achat réel (FC)')),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Créer le lot')),
        ],
      ),
    );
    if (ok != true) return;
    await widget.session.api.post('/purchases/${open!['id']}/receive', {
      'location': open!['location'],
      'lines': [
        {
          'lineId': line['id'],
          'quantity': num.parse(qty.text.replaceAll(',', '.')),
          'expiryDate': expiry.text,
          'priceBuy': int.parse(price.text),
        },
      ],
    });
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Lot créé. Le catalogue n’a pas été modifié.')));
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    if (loading && purchases.isEmpty && suppliers.isEmpty) return const Center(child: CircularProgressIndicator());
    if (error != null) {
      return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [Text(error!), TextButton(onPressed: _load, child: const Text('Réessayer'))]));
    }
    final compact = ndjoCompact(context);
    final hideBar = compact && tab == 'achats' && open != null;
    return Column(
      children: [
        if (!hideBar)
        Padding(
          padding: EdgeInsets.fromLTRB(compact ? 16 : 24, 16, compact ? 16 : 24, 0),
          child: compact
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        ChoiceChip(label: const Text('Achats'), selected: tab == 'achats', onSelected: (_) => setState(() => tab = 'achats')),
                        ChoiceChip(label: const Text('Fournisseurs'), selected: tab == 'fournisseurs', onSelected: (_) => setState(() => tab = 'fournisseurs')),
                      ],
                    ),
                    const SizedBox(height: 10),
                    FilledButton.icon(
                      onPressed: tab == 'achats' ? _createPurchase : () => _editSupplier(),
                      icon: const Icon(Icons.add),
                      label: Text(tab == 'achats' ? 'Bon d’achat' : 'Fournisseur'),
                    ),
                  ],
                )
              : Row(
                  children: [
                    SegmentedButton<String>(
                      segments: const [
                        ButtonSegment(value: 'achats', label: Text('Achats')),
                        ButtonSegment(value: 'fournisseurs', label: Text('Fournisseurs')),
                      ],
                      selected: {tab},
                      onSelectionChanged: (value) => setState(() => tab = value.first),
                    ),
                    const Spacer(),
                    FilledButton.icon(
                      onPressed: tab == 'achats' ? _createPurchase : () => _editSupplier(),
                      icon: const Icon(Icons.add),
                      label: Text(tab == 'achats' ? 'Bon d’achat' : 'Fournisseur'),
                    ),
                  ],
                ),
        ),
        Expanded(child: tab == 'achats' ? _purchases() : _suppliers()),
      ],
    );
  }

  Widget _suppliers() {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const Text('Fournisseurs', style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
        const Text('Fiches distinctes du catalogue. Un achat crée des lots, pas un nouveau prix catalogue.', style: TextStyle(color: NdjoColors.muted)),
        const SizedBox(height: 16),
        ...suppliers.map((item) {
          final supplier = item as Map<String, dynamic>;
          return Card(
            child: ListTile(
              title: Text(supplier['name'].toString(), style: const TextStyle(fontWeight: FontWeight.w700)),
              subtitle: Text('${supplier['phone'] ?? '—'} · ${supplier['address'] ?? ''}\n${supplier['email'] ?? ''}'),
              isThreeLine: true,
              trailing: Text(supplier['status']?.toString() ?? ''),
              onTap: () => _editSupplier(supplier),
            ),
          );
        }),
      ],
    );
  }

  Widget _purchases() {
    final compact = ndjoCompact(context);
    final list = ListView(
      padding: EdgeInsets.all(compact ? 16 : 20),
      children: [
        const Text('Bons d’achat', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        if (purchases.isEmpty)
          const Text('Aucun bon d’achat en copie locale.', style: TextStyle(color: NdjoColors.muted)),
        ...purchases.map((item) {
          final purchase = item as Map<String, dynamic>;
          return Card(
            color: purchase['id'] == open?['id'] ? const Color(0xFF3A2A1C) : null,
            child: ListTile(
              title: Text(purchase['number']?.toString() ?? '', overflow: TextOverflow.ellipsis),
              subtitle: Text(
                '${purchase['supplier']?['name'] ?? ''} · ${purchase['status']}\n${fc(purchase['total'] as num? ?? 0)}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              isThreeLine: true,
              trailing: const Icon(Icons.chevron_right),
              onTap: () => setState(() => open = Map<String, dynamic>.from(purchase)),
            ),
          );
        }),
      ],
    );

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
                            open!['number']?.toString() ?? 'Bon d’achat',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
                          ),
                          Text(
                            '${open!['supplier']?['name'] ?? ''} · ${open!['status']}',
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
      return list;
    }

    return Row(
      children: [
        SizedBox(width: 340, child: list),
        const VerticalDivider(width: 1, color: NdjoColors.line),
        Expanded(child: open == null ? const Center(child: Text('Créez ou ouvrez un bon d’achat.', textAlign: TextAlign.center, style: TextStyle(color: NdjoColors.muted))) : _detail()),
      ],
    );
  }

  Widget _detail() {
    final lines = open!['lines'] as List<dynamic>? ?? [];
    final lots = open!['lots'] as List<dynamic>? ?? [];
    final compact = ndjoCompact(context);
    return ListView(
      padding: EdgeInsets.fromLTRB(compact ? 16 : 24, compact ? 12 : 24, compact ? 16 : 24, compact ? 32 : 24),
      children: [
        if (!compact) ...[
          Text(open!['number'].toString(), style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text('${open!['supplier']?['name'] ?? '—'} · ${open!['status']}'),
        ],
        if ((open!['location']?.toString() ?? '').isNotEmpty)
          Text(open!['location'].toString(), style: const TextStyle(color: NdjoColors.muted)),
        Text('Total ${fc(open!['total'] as num? ?? 0)}', style: const TextStyle(fontWeight: FontWeight.w800, color: NdjoColors.accent, fontSize: 18)),
        Text('Créé par ${open!['createdBy']?['name'] ?? '—'}', style: const TextStyle(color: NdjoColors.muted)),
        const SizedBox(height: 16),
        const Text('Lignes', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        if (lines.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text('Aucune ligne sur ce bon.', style: TextStyle(color: NdjoColors.muted)),
          ),
        ...lines.map((item) {
          final line = item as Map<String, dynamic>;
          final remaining = (line['quantity'] as num) - (line['receivedQty'] as num? ?? 0);
          final canReceive = remaining > 0 && open!['status'] != 'ANNULE';
          return Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${line['product']?['name'] ?? 'Produit'}', style: const TextStyle(fontWeight: FontWeight.w800)),
                  const SizedBox(height: 6),
                  Text('Commandé : ${line['quantity']} ${line['unit']}'),
                  Text('Prix unitaire : ${fc(line['unitPrice'] as num? ?? 0)}'),
                  Text('Reçu : ${line['receivedQty'] ?? 0}'),
                  Text('Reste : $remaining'),
                  if (line['lineTotal'] != null)
                    Text('Ligne ${fc(line['lineTotal'] as num)}', style: const TextStyle(color: NdjoColors.accent, fontWeight: FontWeight.w700)),
                  if (canReceive) ...[
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(onPressed: () => _receive(line), child: const Text('Réceptionner')),
                    ),
                  ] else
                    const Padding(
                      padding: EdgeInsets.only(top: 6),
                      child: Text('Réception OK', style: TextStyle(color: NdjoColors.success, fontWeight: FontWeight.w700)),
                    ),
                ],
              ),
            ),
          );
        }),
        const SizedBox(height: 16),
        const Text('Lots créés (module Stock)', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        if (lots.isEmpty)
          const Text('Aucun lot tant que la réception n’est pas validée.', style: TextStyle(color: NdjoColors.muted))
        else
          ...lots.map((item) {
            final lot = item as Map<String, dynamic>;
            return Card(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(lot['number']?.toString() ?? '', style: const TextStyle(fontWeight: FontWeight.w800)),
                    Text(lot['product']?['name']?.toString() ?? ''),
                    Text('Stock ${lot['qtyCurrent']} / ${lot['qtyInitial']}'),
                    Text('Achat ${fc(lot['priceBuy'] as num? ?? 0)}'),
                    if (lot['expiryDate'] != null)
                      Text('Péremption ${lot['expiryDate'].toString().split('T').first}', style: const TextStyle(color: NdjoColors.muted, fontSize: 12)),
                  ],
                ),
              ),
            );
          }),
      ],
    );
  }
}
