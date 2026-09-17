import 'dart:async';

import 'package:flutter/material.dart';

import 'pages.dart';
import 'session.dart';
import 'theme.dart';
import 'ticket.dart';
import 'api.dart';

class OrganizationPage extends StatefulWidget {
  const OrganizationPage({super.key, required this.session});
  final Session session;

  @override
  State<OrganizationPage> createState() => _OrganizationPageState();
}

class _OrganizationPageState extends State<OrganizationPage> {
  List<dynamic> establishments = [];
  List<dynamic> departments = [];
  String? selectedId;
  String? error;
  bool loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final cachedPlaces = widget.session.peekList('establishments');
    if (cachedPlaces.isNotEmpty && loading) {
      setState(() {
        establishments = cachedPlaces;
        loading = false;
      });
    }
    try {
      final list = await widget.session.cachedList('/establishments', 'establishments');
      final current = selectedId ?? widget.session.establishmentId ?? (list.isNotEmpty ? list.first['id'] : null);
      final deps = current == null
          ? <dynamic>[]
          : await widget.session.cachedList('/departments?establishmentId=$current', 'departments-$current');
      setState(() {
        establishments = list.isNotEmpty ? list : cachedPlaces;
        departments = deps;
        selectedId = current?.toString();
        loading = false;
        error = null;
      });
    } catch (e) {
      setState(() {
        establishments = establishments.isEmpty
            ? (cachedPlaces.isNotEmpty ? cachedPlaces : widget.session.establishments)
            : establishments;
        error = null;
        loading = false;
      });
    }
  }

  Future<void> _editEstablishment([Map<String, dynamic>? current]) async {
    final name = TextEditingController(text: current?['name']?.toString() ?? '');
    final code = TextEditingController(text: current?['code']?.toString() ?? '');
    final type = TextEditingController(text: current?['type']?.toString() ?? 'Restaurant');
    final address = TextEditingController(text: current?['address']?.toString() ?? '');
    final phone = TextEditingController(text: current?['phone']?.toString() ?? '');
    final ok = await _formDialog(
      context,
      current == null ? 'Nouvel établissement' : 'Modifier l’établissement',
      [
        TextField(controller: name, decoration: const InputDecoration(labelText: 'Nom')),
        TextField(controller: code, decoration: const InputDecoration(labelText: 'Code')),
        TextField(controller: type, decoration: const InputDecoration(labelText: 'Type')),
        TextField(controller: address, decoration: const InputDecoration(labelText: 'Adresse')),
        TextField(controller: phone, decoration: const InputDecoration(labelText: 'Téléphone')),
      ],
    );
    if (ok != true) return;
    final body = {
      'name': name.text,
      'code': code.text,
      'type': type.text,
      'address': address.text,
      'phone': phone.text,
    };
    if (current == null) {
      await widget.session.api.post('/establishments', body);
    } else {
      await widget.session.api.put('/establishments/${current['id']}', body);
    }
    await _load();
  }

  Future<void> _addDepartment() async {
    if (selectedId == null) return;
    final name = TextEditingController();
    final ok = await _formDialog(context, 'Nouveau département', [
      TextField(controller: name, decoration: const InputDecoration(labelText: 'Nom')),
    ]);
    if (ok != true || name.text.trim().isEmpty) return;
    await widget.session.api.post('/departments', {
      'name': name.text.trim(),
      'establishmentId': selectedId,
    });
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    if (loading) return const Center(child: CircularProgressIndicator());
    if (error != null) return _Retry(error: error!, onRetry: _load);
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Row(
          children: [
            const Expanded(child: Text('Organisation', style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold))),
            FilledButton.icon(
              onPressed: () => _editEstablishment(),
              icon: const Icon(Icons.add),
              label: const Text('Établissement'),
              style: FilledButton.styleFrom(backgroundColor: NdjoColors.primary),
            ),
          ],
        ),
        const SizedBox(height: 16),
        ...establishments.map((item) {
          final map = item as Map<String, dynamic>;
          final selected = map['id'] == selectedId;
          return Card(
            color: selected ? const Color(0xFF3A2A1C) : null,
            child: ListTile(
              title: Text(map['name'].toString()),
              subtitle: Text('${map['code']} · ${map['type']} · ${map['status']}'),
              onTap: () {
                setState(() => selectedId = map['id'].toString());
                _load();
              },
              trailing: IconButton(onPressed: () => _editEstablishment(map), icon: const Icon(Icons.edit)),
            ),
          );
        }),
        const SizedBox(height: 20),
        Row(
          children: [
            const Expanded(child: Text('Départements', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700))),
            TextButton.icon(onPressed: _addDepartment, icon: const Icon(Icons.add), label: const Text('Ajouter')),
          ],
        ),
        ...departments.map((item) {
          final map = item as Map<String, dynamic>;
          return Card(
            child: ListTile(
              title: Text(map['name'].toString()),
              subtitle: Text('${map['_count']?['users'] ?? 0} utilisateur(s)'),
              trailing: Text(map['status'].toString(), style: const TextStyle(color: NdjoColors.success)),
            ),
          );
        }),
      ],
    );
  }
}

class UsersPage extends StatefulWidget {
  const UsersPage({super.key, required this.session});
  final Session session;

  @override
  State<UsersPage> createState() => _UsersPageState();
}

class _UsersPageState extends State<UsersPage> {
  List<dynamic> users = [];
  List<dynamic> departments = [];
  String? error;
  bool loading = true;

  String get _id => widget.session.establishmentId ?? '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final cachedUsers = widget.session.peekList('users-$_id');
    if (cachedUsers.isNotEmpty && loading) {
      setState(() {
        users = cachedUsers;
        departments = widget.session.peekList('departments-$_id');
        loading = false;
      });
    }
    try {
      final loaded = await Future.wait([
        widget.session.cachedList('/users?establishmentId=$_id', 'users-$_id'),
        widget.session.cachedList('/departments?establishmentId=$_id', 'departments-$_id'),
      ]);
      setState(() {
        users = loaded[0].isNotEmpty ? loaded[0] : cachedUsers;
        departments = loaded[1];
        loading = false;
        error = null;
      });
    } catch (e) {
      setState(() {
        users = users.isEmpty ? cachedUsers : users;
        error = null;
        loading = false;
      });
    }
  }

  Future<void> _edit([Map<String, dynamic>? current]) async {
    final name = TextEditingController(text: current?['name']?.toString() ?? '');
    final username = TextEditingController(text: current?['username']?.toString() ?? '');
    final password = TextEditingController();
    final phone = TextEditingController(text: current?['phone']?.toString() ?? '');
    final photoUrl = TextEditingController(text: current?['photoUrl']?.toString() ?? '');
    var role = current?['role']?.toString() ?? 'CAISSIER';
    String? departmentId = current?['departmentId']?.toString();
    final roles = ['SUPER_ADMIN', 'ADMIN', 'GESTIONNAIRE', 'CAISSIER', 'MAGASINIER', 'CUISINIER', 'LIVREUR'];
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: Text(current == null ? 'Nouvel utilisateur' : 'Modifier l’utilisateur'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(controller: name, decoration: const InputDecoration(labelText: 'Nom')),
                TextField(controller: username, decoration: const InputDecoration(labelText: 'Nom utilisateur')),
                TextField(controller: password, obscureText: true, decoration: InputDecoration(labelText: current == null ? 'Mot de passe' : 'Nouveau mot de passe (optionnel)')),
                TextField(controller: phone, decoration: const InputDecoration(labelText: 'Téléphone')),
                TextField(controller: photoUrl, decoration: const InputDecoration(labelText: 'Photo (URL)')),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  value: role,
                  items: roles.map((item) => DropdownMenuItem(value: item, child: Text(item))).toList(),
                  onChanged: (value) => setLocal(() => role = value ?? role),
                  decoration: const InputDecoration(labelText: 'Rôle'),
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<String?>(
                  value: departmentId,
                  items: [
                    const DropdownMenuItem<String?>(value: null, child: Text('Aucun département')),
                    ...departments.map((item) => DropdownMenuItem<String?>(value: item['id'].toString(), child: Text(item['name'].toString()))),
                  ],
                  onChanged: (value) => setLocal(() => departmentId = value),
                  decoration: const InputDecoration(labelText: 'Département'),
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
    final body = {
      'name': name.text,
      'username': username.text,
      'role': role,
      'phone': phone.text,
      'photoUrl': photoUrl.text,
      'establishmentId': _id,
      'departmentId': departmentId,
      if (password.text.isNotEmpty) 'password': password.text,
    };
    if (current == null) {
      await widget.session.api.post('/users', body);
    } else {
      await widget.session.api.put('/users/${current['id']}', body);
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    if (loading) return const Center(child: CircularProgressIndicator());
    if (error != null) return _Retry(error: error!, onRetry: _load);
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Row(
          children: [
            const Expanded(child: Text('Utilisateurs', style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold))),
            FilledButton.icon(
              onPressed: () => _edit(),
              icon: const Icon(Icons.person_add),
              label: const Text('Ajouter'),
              style: FilledButton.styleFrom(backgroundColor: NdjoColors.primary),
            ),
          ],
        ),
        const SizedBox(height: 16),
        ...users.map((item) {
          final map = item as Map<String, dynamic>;
          return Card(
            child: ListTile(
              leading: CircleAvatar(
                backgroundImage: map['photoUrl'] != null && map['photoUrl'].toString().isNotEmpty
                    ? NetworkImage(map['photoUrl'].toString())
                    : null,
                child: map['photoUrl'] == null || map['photoUrl'].toString().isEmpty
                    ? Text(map['name'].toString().substring(0, 1))
                    : null,
              ),
              title: Text(map['name'].toString()),
              subtitle: Text('${map['username']} · ${map['role']} · ${map['department']?['name'] ?? 'Sans département'}'),
              trailing: IconButton(onPressed: () => _edit(map), icon: const Icon(Icons.edit)),
            ),
          );
        }),
      ],
    );
  }
}

class StockPage extends StatefulWidget {
  const StockPage({super.key, required this.session});
  final Session session;

  @override
  State<StockPage> createState() => _StockPageState();
}

class _StockPageState extends State<StockPage> {
  List<dynamic> products = [];
  List<dynamic> lots = [];
  List<dynamic> movements = [];
  List<dynamic> transfers = [];
  String? error;
  bool loading = true;
  Timer? _poll;

  String get _id => widget.session.establishmentId ?? '';

  @override
  void initState() {
    super.initState();
    _load();
    _poll = Timer.periodic(const Duration(seconds: 8), (_) {
      if (mounted) _load();
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final store = widget.session.sync?.store;
    var localProducts = store?.localStockSummary() ?? [];
    var localLots = store?.allCachedLots(_id) ?? [];
    var localMovements = widget.session.peekList('stock-mov-$_id');
    var localTransfers = widget.session.peekList('stock-tr-$_id');
    if ((localProducts.isNotEmpty || localLots.isNotEmpty) && mounted) {
      setState(() {
        products = localProducts;
        lots = localLots;
        movements = localMovements;
        transfers = localTransfers;
        loading = false;
        error = null;
      });
    }
    try {
      final loadedProducts = await widget.session.cachedList('/stock/summary?establishmentId=$_id', 'stock-summary-$_id');
      final loadedLots = await widget.session.cachedList('/stock/lots?establishmentId=$_id', 'stock-lots-$_id');
      final loadedMovements = await widget.session.cachedList('/stock/movements?establishmentId=$_id', 'stock-mov-$_id');
      final loadedTransfers = await widget.session.cachedList('/stock/transfers?establishmentId=$_id', 'stock-tr-$_id');
      if (!mounted) return;
      final nextProducts = loadedProducts.isNotEmpty ? loadedProducts : (store?.localStockSummary() ?? localProducts);
      final nextLots = loadedLots.isNotEmpty ? loadedLots : (store?.allCachedLots(_id) ?? localLots);
      setState(() {
        products = nextProducts;
        lots = nextLots;
        movements = loadedMovements.isNotEmpty ? loadedMovements : localMovements;
        transfers = loadedTransfers.isNotEmpty ? loadedTransfers : localTransfers;
        loading = false;
        error = null;
      });
    } catch (e) {
      if (!mounted) return;
      final fallback = store?.localStockSummary() ?? products;
      final fallbackLots = store?.allCachedLots(_id) ?? lots;
      setState(() {
        products = fallback.isNotEmpty ? fallback : products;
        lots = fallbackLots.isNotEmpty ? fallbackLots : lots;
        error = null;
        loading = false;
      });
    }
  }

  Future<void> _retry() async {
    if (_id.isNotEmpty) {
      try {
        await widget.session.sync?.pull(_id);
      } catch (_) {}
    }
    await _load();
  }

  Future<void> _entry() async {
    if (products.isEmpty) return;
    String productId = products.first['id'].toString();
    final qty = TextEditingController(text: '24');
    final price = TextEditingController(text: '${products.first['priceBuy'] ?? 0}');
    final expiry = TextEditingController(text: '2027-03-13');
    void applyCatalogBuy(String id) {
      final selected = products.cast<dynamic>().firstWhere(
        (item) => item['id'].toString() == id,
        orElse: () => products.first,
      );
      price.text = '${selected['priceBuy'] ?? 0}';
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: const Text('Entrée de stock'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String>(
                  value: productId,
                  items: products
                      .map((item) => DropdownMenuItem(
                            value: item['id'].toString(),
                            child: Text(
                              '${item['name']}${item['format'] == null || item['format'].toString().isEmpty ? '' : ' · ${item['format']}'}',
                              overflow: TextOverflow.ellipsis,
                            ),
                          ))
                      .toList(),
                  onChanged: (value) => setLocal(() {
                    productId = value ?? productId;
                    applyCatalogBuy(productId);
                  }),
                  decoration: const InputDecoration(labelText: 'Produit'),
                ),
                TextField(controller: qty, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Quantité (unités)')),
                TextField(
                  controller: price,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Prix d’achat de ce lot (FC)'),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Chaque entrée crée un lot distinct. Si le format est 12 / carton, 2 cartons = 24 unités.',
                  style: TextStyle(color: NdjoColors.muted, fontSize: 12),
                ),
                TextField(controller: expiry, decoration: const InputDecoration(labelText: 'Péremption (AAAA-MM-JJ)')),
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
    final body = {
      'establishmentId': _id,
      'productId': productId,
      'quantity': num.parse(qty.text),
      'priceBuy': int.tryParse(price.text.trim()) ?? 0,
      'expiryDate': expiry.text,
    };
    final result = widget.session.sync != null
        ? await widget.session.sync!.stockEntry(body)
        : await widget.session.api.post('/stock/entries', body);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(result['offline'] == true
          ? 'Entrée enregistrée hors ligne (${result['number']}).'
          : 'Entrée enregistrée.'),
    ));
    await _load();
  }

  Future<void> _exit() async {
    if (products.isEmpty) return;
    String productId = products.first['id'].toString();
    final qty = TextEditingController(text: '2');
    var destination = 'Cuisine';
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: const Text('Sortie cuisine (FEFO)'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                value: productId,
                items: products.map((item) => DropdownMenuItem(value: item['id'].toString(), child: Text(item['name'].toString()))).toList(),
                onChanged: (value) => setLocal(() => productId = value ?? productId),
                decoration: const InputDecoration(labelText: 'Produit'),
              ),
              TextField(controller: qty, decoration: const InputDecoration(labelText: 'Quantité')),
              DropdownButtonFormField<String>(
                value: destination,
                items: const [
                  DropdownMenuItem(value: 'Cuisine', child: Text('Cuisine')),
                  DropdownMenuItem(value: 'Perte', child: Text('Perte / périmé')),
                  DropdownMenuItem(value: 'Autre', child: Text('Autre')),
                ],
                onChanged: (value) => setLocal(() => destination = value ?? destination),
                decoration: const InputDecoration(labelText: 'Destination'),
              ),
              const SizedBox(height: 6),
              const Text(
                'La sortie prend les lots FEFO (le plus ancien d’abord). Chaque lot garde son prix d’achat pour le rapport du jour.',
                style: TextStyle(color: NdjoColors.muted, fontSize: 12),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuler')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Valider')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    try {
    final body = {
      'establishmentId': _id,
      'productId': productId,
      'quantity': num.parse(qty.text),
      'destination': destination,
      'type': destination == 'Perte' ? 'PERTE' : 'SORTIE',
      'motif': destination,
    };
    final result = widget.session.sync != null
        ? await widget.session.sync!.stockExit(body)
        : await widget.session.api.post('/stock/exits', body);
    if (!mounted) return;
    final lotsOut = (result['lots'] as List?) ?? [];
    final detail = lotsOut
        .map((item) {
          final lot = Map<String, dynamic>.from(item as Map);
          final entry = lot['entryDate']?.toString().split('T').first;
          return '${lot['number']} × ${lot['quantity']}${entry == null || entry.isEmpty ? '' : ' ($entry)'}';
        })
        .join(', ');
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(result['offline'] == true
          ? 'Sortie en file hors ligne (${result['number']}).'
          : (detail.isEmpty ? 'Sortie appliquée selon FEFO.' : 'Lots sortis : $detail')),
    ));
    await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  Future<void> _createTransfer() async {
    final movable = products.where((item) => ((item['stockQty'] as num?) ?? 0) > 0).toList();
    if (movable.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Aucun produit en stock à transférer.')));
      return;
    }
    var places = widget.session.establishments;
    if (places.isEmpty) {
      places = await widget.session.api.getList('/public/establishments');
    }
    final dests = places.where((item) => item['id'] != _id).toList();
    if (dests.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Aucun autre établissement pour recevoir le transfert.')));
      return;
    }
    String productId = movable.first['id'].toString();
    String destId = dests.first['id'].toString();
    final qty = TextEditingController(text: '1');
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: const Text('Nouveau transfert'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Le stock sortira à l’expédition. Il n’entrera à destination qu’après validation de réception.',
                  style: TextStyle(color: NdjoColors.muted, fontSize: 12),
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  value: productId,
                  items: movable.map((item) => DropdownMenuItem(value: item['id'].toString(), child: Text('${item['name']} (${item['stockQty']})'))).toList(),
                  onChanged: (value) => setLocal(() => productId = value ?? productId),
                  decoration: const InputDecoration(labelText: 'Produit source'),
                ),
                DropdownButtonFormField<String>(
                  value: destId,
                  items: dests.map((item) => DropdownMenuItem(value: item['id'].toString(), child: Text(item['name'].toString()))).toList(),
                  onChanged: (value) => setLocal(() => destId = value ?? destId),
                  decoration: const InputDecoration(labelText: 'Destination'),
                ),
                TextField(controller: qty, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Quantité')),
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
    if (_id.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Choisissez un établissement avant de transférer.')),
      );
      return;
    }
    try {
      await widget.session.api.post('/stock/transfers', {
        'establishmentId': _id,
        'sourceId': _id,
        'destId': destId,
        'productId': productId,
        'quantity': num.parse(qty.text),
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Transfert créé. Expédiez pour sortir le stock. La destination validera la réception.')),
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  Future<void> _shipTransfer(Map<String, dynamic> map) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Expédier le transfert'),
        content: Text(
          'Sortir ${map['quantity']} ${map['product']?['name'] ?? 'produit'} vers ${map['dest']?['name'] ?? 'la destination'} ?\nLe stock quitte cet établissement. Il n’entrera à destination qu’après validation de réception.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Expédier')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await widget.session.api.post('/stock/transfers/${map['id']}/ship', {'establishmentId': _id});
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Expédié. En attente de validation de réception à destination.')));
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  Future<void> _receiveTransfer(Map<String, dynamic> map) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Valider la réception'),
        content: Text(
          'Confirmer l’entrée de ${map['quantity']} ${map['product']?['name'] ?? 'produit'} envoyé(s) par ${map['source']?['name'] ?? 'l’autre établissement'} ?\nLe stock n’est ajouté ici qu’après cette validation.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Valider la réception')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await widget.session.api.post('/stock/transfers/${map['id']}/receive', {
        'establishmentId': _id,
        'location': 'Dépôt principal',
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Réception validée. Le stock est entré dans cet établissement.')));
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (loading) return const Center(child: CircularProgressIndicator());
    if (error != null) return _Retry(error: error!, onRetry: _retry);
    final compact = ndjoCompact(context);
    final incoming = [
      for (final item in transfers)
        if (item is Map && item['destId']?.toString() == _id) Map<String, dynamic>.from(item),
    ];
    final pendingReceive = incoming.where((item) => item['status']?.toString() == 'EN_TRANSIT').toList();
    return ListView(
      padding: EdgeInsets.all(compact ? 16 : 24),
      children: [
        if (compact)
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Stock & lots', style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ndjoExportButtons(
                    onExcel: () => downloadNdjoExport(context, widget.session, kind: 'stock', format: 'xls'),
                    onPdf: () => downloadNdjoExport(context, widget.session, kind: 'stock', format: 'pdf'),
                  ),
                  OutlinedButton(onPressed: _exit, child: const Text('Sortie cuisine')),
                  FilledButton(
                    onPressed: _entry,
                    style: FilledButton.styleFrom(backgroundColor: NdjoColors.primary),
                    child: const Text('Entrée'),
                  ),
                ],
              ),
            ],
          )
        else
          Row(
            children: [
              const Expanded(child: Text('Stock & lots', style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold))),
              ndjoExportButtons(
                onExcel: () => downloadNdjoExport(context, widget.session, kind: 'stock', format: 'xls'),
                onPdf: () => downloadNdjoExport(context, widget.session, kind: 'stock', format: 'pdf'),
              ),
              const SizedBox(width: 8),
              OutlinedButton(onPressed: _exit, child: const Text('Sortie cuisine')),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _entry,
                style: FilledButton.styleFrom(backgroundColor: NdjoColors.primary),
                child: const Text('Entrée'),
              ),
            ],
          ),
        if (pendingReceive.isNotEmpty) ...[
          const SizedBox(height: 16),
          Card(
            color: const Color(0xFFFFEBEE),
            child: ListTile(
              leading: const Icon(Icons.inventory_2, color: Color(0xFFB71C1C)),
              title: Text('${pendingReceive.length} transfert(s) à valider à la réception'),
              subtitle: const Text('Le stock n’entre dans cet établissement qu’après validation.'),
            ),
          ),
        ],
        const SizedBox(height: 16),
        Row(
          children: [
            const Expanded(child: Text('Transferts', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700))),
            TextButton(onPressed: _createTransfer, child: const Text('Nouveau transfert')),
          ],
        ),
        const Text(
          'Source : créer puis expédier. Destination : valider la réception pour entrer le stock.',
          style: TextStyle(color: NdjoColors.muted, fontSize: 12),
        ),
        const SizedBox(height: 8),
        if (transfers.isEmpty)
          const Text('Aucun transfert.', style: TextStyle(color: NdjoColors.muted))
        else
          ...transfers.map((item) {
            final map = Map<String, dynamic>.from(item as Map);
            final status = map['status']?.toString() ?? '';
            final fromHere = map['sourceId']?.toString() == _id;
            final toHere = map['destId']?.toString() == _id;
            return Card(
              color: status == 'EN_TRANSIT' && toHere ? const Color(0xFFFFEBEE) : null,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${map['number']} · ${transferStatusLabel(status)} · ${map['product']?['name'] ?? ''}',
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    Text('${map['source']?['name'] ?? ''} → ${map['dest']?['name'] ?? ''} · ${map['quantity']}'),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        if (fromHere && status == 'CREE')
                          FilledButton(
                            onPressed: () => _shipTransfer(map),
                            style: FilledButton.styleFrom(backgroundColor: NdjoColors.primary),
                            child: const Text('Expédier'),
                          ),
                        if (toHere && status == 'EN_TRANSIT')
                          FilledButton(
                            onPressed: () => _receiveTransfer(map),
                            style: FilledButton.styleFrom(backgroundColor: NdjoColors.primary),
                            child: const Text('Valider la réception'),
                          ),
                        if (fromHere && status == 'EN_TRANSIT')
                          const Text('En attente de validation à destination', style: TextStyle(color: NdjoColors.muted)),
                        if (status == 'RECU')
                          const Text('Réception validée', style: TextStyle(color: NdjoColors.success)),
                      ],
                    ),
                  ],
                ),
              ),
            );
          }),
        const SizedBox(height: 20),
        const Text('Niveaux', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        ...products.map((item) {
          final map = Map<String, dynamic>.from(item as Map);
          final low = map['lowStock'] == true;
          final prices = (map['buyPrices'] as List?)
                  ?.map((value) => fc(value as num))
                  .join(' / ') ??
              '';
          final lotCount = map['lotCount'] ?? 0;
          return Card(
            child: ListTile(
              title: Text(map['name'].toString()),
              subtitle: Text(
                [
                  map['category']?['name'] ?? '',
                  '$lotCount lot${lotCount == 1 ? '' : 's'}',
                  if (prices.isNotEmpty) prices,
                  'seuil ${map['stockAlert']}',
                ].where((part) => part.toString().trim().isNotEmpty).join(' · '),
              ),
              trailing: Text(
                '${map['stockQty']} ${map['unit']}',
                style: TextStyle(color: low ? NdjoColors.danger : NdjoColors.accent, fontWeight: FontWeight.bold),
              ),
            ),
          );
        }),
        const SizedBox(height: 20),
        const Text('Lots', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        ...lots.map((item) {
          final map = Map<String, dynamic>.from(item as Map);
          final entry = (map['entryDate'] ?? map['createdAt'])?.toString().split('T').first ?? '—';
          return Card(
            child: ListTile(
              title: Text('${map['number']} · ${map['product']?['name'] ?? ''}'),
              subtitle: Text(
                'Entrée $entry · Achat ${fc(map['priceBuy'] as num? ?? 0)} · Péremption ${map['expiryDate']?.toString().split('T').first ?? '—'}',
              ),
              trailing: Text('${map['qtyCurrent']} / ${map['qtyInitial']}'),
            ),
          );
        }),
        const SizedBox(height: 20),
        const Text('Mouvements', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        ...movements.map((item) {
          final map = item as Map<String, dynamic>;
          return Card(
            child: ListTile(
              title: Text('${map['number']} · ${map['type']}'),
              subtitle: Text('${map['product']?['name'] ?? ''} · ${map['motif'] ?? ''} · ${map['user']?['name'] ?? ''}'),
              trailing: Text('${map['quantity']}'),
            ),
          );
        }),
      ],
    );
  }
}

class PosPage extends StatefulWidget {
  const PosPage({super.key, required this.session});
  final Session session;

  @override
  State<PosPage> createState() => _PosPageState();
}

class _PosPageState extends State<PosPage> {
  List<dynamic> products = [];
  List<dynamic> orders = [];
  List<dynamic> customers = [];
  List<dynamic> zones = [];
  final cart = <String, Map<String, dynamic>>{};
  String type = 'SUR_PLACE';
  String? customerId;
  String? addressId;
  String? zoneId;
  String? error;
  bool loading = true;
  Timer? _poll;
  String? _siteId;

  String get _id => widget.session.establishmentId ?? '';

  Map<String, dynamic>? get selectedCustomer {
    final match = customers.where((item) => item['id'] == customerId);
    return match.isEmpty ? null : Map<String, dynamic>.from(match.first as Map);
  }

  List<dynamic> get customerAddresses => selectedCustomer?['addresses'] as List<dynamic>? ?? [];

  Map<String, dynamic>? get selectedAddress {
    final match = customerAddresses.where((item) => item['id'] == addressId);
    return match.isEmpty ? null : Map<String, dynamic>.from(match.first as Map);
  }

  Map<String, dynamic>? get selectedZone {
    final fromAddress = selectedAddress?['zone'] as Map<String, dynamic>?;
    if (fromAddress != null) return fromAddress;
    final match = zones.where((item) => item['id'] == zoneId);
    return match.isEmpty ? null : Map<String, dynamic>.from(match.first as Map);
  }

  int get subtotal => cart.values.fold<int>(0, (sum, item) => sum + (item['unitPrice'] as int) * (item['qty'] as int));
  int get fee => type == 'LIVRAISON' ? ((selectedZone?['fee'] as num?)?.toInt() ?? 0) : 0;
  int get total => subtotal + fee;

  @override
  void initState() {
    super.initState();
    final sync = widget.session.sync;
    try {
      products = sync?.store.readCatalog(_id) ?? [];
      orders = sync?.pendingSales() ?? [];
      customers = sync?.store.readList('customers-$_id') ?? [];
      zones = sync?.store.readList('zones-$_id') ?? [];
    } catch (_) {}
    loading = false;
    _siteId = widget.session.establishmentId;
    widget.session.addListener(_onSite);
    _load();
    _poll = Timer.periodic(const Duration(seconds: 4), (_) {
      if (mounted) _load();
    });
  }

  void _onSite() {
    final next = widget.session.establishmentId;
    if (next == _siteId) return;
    _siteId = next;
    cart.clear();
    _load();
  }

  @override
  void dispose() {
    widget.session.removeListener(_onSite);
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final sync = widget.session.sync;
    final localSales = sync?.pendingSales() ?? [];
    final localProducts = sync?.store.readCatalog(_id) ?? [];
    if (mounted) {
      setState(() {
        products = localProducts.isNotEmpty ? localProducts : products;
        customers = sync?.store.readList('customers-$_id') ?? customers;
        zones = sync?.store.readList('zones-$_id') ?? zones;
        loading = false;
        error = null;
      });
    }
    try {
      final loadedProducts = sync != null
          ? await sync.products(_id)
          : await widget.session.api.getList('/catalog/products?establishmentId=$_id&kind=VENTE');
      final loadedOrders = sync != null
          ? await sync.cachedOrFetch('/orders?establishmentId=$_id', 'orders-$_id')
          : await widget.session.api.getList('/orders?establishmentId=$_id');
      final loadedCustomers = sync != null
          ? await sync.cachedOrFetch('/customers?establishmentId=$_id', 'customers-$_id')
          : await widget.session.api.getList('/customers?establishmentId=$_id');
      final loadedZones = sync != null
          ? await sync.cachedOrFetch('/delivery-zones?establishmentId=$_id', 'zones-$_id')
          : await widget.session.api.getList('/delivery-zones?establishmentId=$_id');
      final pending = sync?.pendingSales() ?? localSales;
      final pendingIds = pending.map((item) => item['clientUuid']?.toString()).toSet();
      final merged = [
        ...pending,
        ...loadedOrders.where((item) {
          final map = item as Map;
          return !pendingIds.contains(map['clientUuid']?.toString()) &&
              !pendingIds.contains(map['id']?.toString());
        }),
      ];
      if (!mounted) return;
      setState(() {
        products = loadedProducts.isNotEmpty ? loadedProducts : products;
        orders = merged;
        customers = loadedCustomers.isNotEmpty ? loadedCustomers : customers;
        zones = loadedZones.isNotEmpty ? loadedZones : zones;
        loading = false;
        error = null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        orders = sync?.pendingSales() ?? orders;
        products = products.isEmpty ? (sync?.store.readCatalog(_id) ?? []) : products;
        loading = false;
      });
    }
  }

  void _add(Map<String, dynamic> product) {
    final id = product['id'].toString();
    setState(() {
      final current = cart[id];
      cart[id] = {
        'productId': id,
        'name': product['name'],
        'unitPrice': product['priceSell'],
        'qty': (current?['qty'] as int? ?? 0) + 1,
      };
    });
  }

  Future<void> _pickProduct(Map<String, dynamic> product) async {
    final add = await showMenuDetailSheet(context, product);
    if (add == true && mounted) _add(product);
  }

  Future<void> _checkout() async {
    if (cart.isEmpty) return;
    if (type == 'LIVRAISON' && selectedZone == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Choisissez une zone ou une adresse client pour calculer les frais.')));
      return;
    }
    final received = TextEditingController(text: '$total');
    final phoneCtrl = TextEditingController(text: selectedCustomer?['phone']?.toString() ?? '');
    var method = 'ESPECES';
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) {
          final pay = int.tryParse(received.text) ?? 0;
          return AlertDialog(
            title: Text('Paiement · ${fc(total)}'),
            content: SingleChildScrollView(
              child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (type == 'LIVRAISON')
                  Text(
                    '${selectedCustomer?['name'] ?? 'Client passage'} · ${selectedZone?['name'] ?? ''} · ${fc(fee)}',
                    style: const TextStyle(color: NdjoColors.muted),
                  ),
                DropdownButtonFormField<String>(
                  value: method,
                  items: const [
                    DropdownMenuItem(value: 'ESPECES', child: Text('Espèces')),
                    DropdownMenuItem(value: 'MOBILE_MONEY', child: Text('Mobile Money')),
                    DropdownMenuItem(value: 'CARTE', child: Text('Carte')),
                    DropdownMenuItem(value: 'VIREMENT', child: Text('Virement')),
                  ],
                  onChanged: (value) => setLocal(() => method = value ?? method),
                  decoration: const InputDecoration(labelText: 'Mode'),
                ),
                if (method == 'ESPECES')
                  TextField(
                    controller: received,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Montant reçu (FC)'),
                    onChanged: (_) => setLocal(() {}),
                  ),
                if (method == 'MOBILE_MONEY')
                  TextField(
                    controller: phoneCtrl,
                    keyboardType: TextInputType.phone,
                    decoration: const InputDecoration(labelText: 'Numéro Mobile Money (243…)'),
                  ),
                if (method != 'ESPECES')
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text(
                      'Le statut restera EN_ATTENTE jusqu’à la confirmation réelle de l’opérateur.',
                      style: TextStyle(color: NdjoColors.muted),
                    ),
                  ),
                const SizedBox(height: 8),
                Text('Monnaie : ${fc(pay - total)}', style: const TextStyle(color: NdjoColors.accent)),
              ],
            ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuler')),
              Semantics(
                identifier: 'pay-confirm',
                button: true,
                child: FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Valider')),
              ),
            ],
          );
        },
      ),
    );
    if (ok != true) return;
    if (_id.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Choisissez un établissement (pas « Tous ») avant de vendre.')),
      );
      return;
    }
    try {
    final payload = {
      'establishmentId': _id,
      'type': type,
      'method': method,
      'customerId': customerId,
      'addressId': addressId,
      'zoneId': selectedZone?['id'],
      'customerName': selectedCustomer?['name'],
      'customerPhone': selectedCustomer?['phone'],
      'address': selectedAddress?['address'],
      'zone': selectedZone?['name'],
      'deliveryFee': fee,
      'total': total,
      'received': int.tryParse(received.text) ?? total,
      'queuedBy': widget.session.user?['name'],
      'items': cart.values
          .map((item) => {
                'productId': item['productId'],
                'quantity': item['qty'],
                'name': item['name'],
                'unitPrice': item['unitPrice'],
              })
          .toList(),
    };
    final order = widget.session.sync != null
        ? await widget.session.sync!.createOrder(payload)
        : await widget.session.api.post('/orders', payload);
    final offline = order['offline'] == true;
    Map<String, dynamic>? paid;
    if (!offline && method != 'ESPECES' && order['id'] != null) {
      paid = await widget.session.api.post('/orders/${order['id']}/pay', {
        'method': method,
        'received': int.tryParse(received.text) ?? total,
        'phone': phoneCtrl.text,
      });
    }
    setState(cart.clear);
    if (!mounted) return;
    final checkout = paid?['checkout'] as Map<String, dynamic>?;
    final pending = method != 'ESPECES' || (type == 'LIVRAISON' && method == 'ESPECES');
    final created = Map<String, dynamic>.from(order);
    if ((created['items'] as List?) == null || (created['items'] as List).isEmpty) {
      created['items'] = payload['items'];
    }
    created['customerName'] ??= selectedCustomer?['name'];
    created['customerPhone'] ??= selectedCustomer?['phone'] ?? phoneCtrl.text;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(offline
          ? 'Vente en attente de confirmation serveur (${order['number']}). Pas hors ligne : nouvelle tentative automatique.'
          : pending
              ? 'Commande ${order['number']} · paiement EN_ATTENTE${checkout?['operatorRef'] != null ? ' · réf. ${checkout!['operatorRef']}' : ''}${checkout?['checkoutUrl'] != null ? ' · ${checkout!['checkoutUrl']}' : ''}.'
              : 'Commande ${order['number']} enregistrée. Paiement encaissé.'),
    ));
    await showTicketSheet(context, session: widget.session, order: created);
    await _load();
    } catch (e) {
      if (!mounted) return;
      await showCashierError(context, e);
    }
  }

  Future<void> _sendToKitchen(String id) async {
    try {
      if (widget.session.sync != null) {
        await widget.session.sync!.kitchenStatus(id, 'NOUVELLE', _id);
      } else {
        await widget.session.api.post('/orders/$id/status', {'status': 'NOUVELLE'});
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Commande envoyée en cuisine.')));
      await _load();
    } catch (e) {
      if (!mounted) return;
      await showCashierError(context, e);
    }
  }

  Map<String, dynamic> _asPosMap(dynamic item) {
    if (item is Map<String, dynamic>) return item;
    if (item is Map) return Map<String, dynamic>.from(item);
    return <String, dynamic>{};
  }

  num _asPosNum(dynamic value) {
    if (value is num) return value;
    return num.tryParse(value?.toString() ?? '') ?? 0;
  }

  @override
  Widget build(BuildContext context) {
    final pendingOps = widget.session.sync?.store.pendingCount ?? 0;
    final mappedProducts = products.map(_asPosMap).toList();
    final activeProducts = mappedProducts.where((item) => item['status']?.toString() == 'ACTIF').toList();
    final visibleProducts = activeProducts.isNotEmpty ? activeProducts : mappedProducts;
    final compact = ndjoCompact(context);
    final menu = [
                    const Text('Caisse', style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
                    ndjoExportButtons(
                      onExcel: () => downloadNdjoExport(context, widget.session, kind: 'sales', format: 'xls', period: 'jour'),
                      onPdf: () => downloadNdjoExport(context, widget.session, kind: 'sales', format: 'pdf', period: 'jour'),
                    ),
              cashierClientInbox(
                orders: orders,
                onSend: _sendToKitchen,
                onTicket: (order) => showTicketSheet(context, session: widget.session, order: order),
              ),
              if (pendingOps > 0)
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.sync),
                    title: Text('$pendingOps opération(s) en attente de confirmation'),
                    subtitle: Text(
                      widget.session.sync?.lastPendingError ??
                          'Vous êtes en ligne. La vente n’est pas encore enregistrée sur le serveur — nouvelle tentative automatique.',
                    ),
                    trailing: TextButton(
                      onPressed: () async {
                        try {
                          await widget.session.sync!.flush();
                          if (!mounted) return;
                          await _load();
                          if (!mounted) return;
                          final leftover = widget.session.sync?.lastPendingError;
                          if (leftover != null && leftover.isNotEmpty) {
                            await showCashierError(context, leftover);
                          }
                        } catch (e) {
                          if (!mounted) return;
                          await showCashierError(context, e);
                        }
                      },
                      child: const Text('Sync'),
                    ),
                  ),
                ),
              const SizedBox(height: 8),
              if (compact)
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    ChoiceChip(label: const Text('Sur place'), selected: type == 'SUR_PLACE', onSelected: (_) => setState(() => type = 'SUR_PLACE')),
                    ChoiceChip(label: const Text('À emporter'), selected: type == 'A_EMPORTER', onSelected: (_) => setState(() => type = 'A_EMPORTER')),
                    ChoiceChip(label: const Text('Livraison'), selected: type == 'LIVRAISON', onSelected: (_) => setState(() => type = 'LIVRAISON')),
                  ],
                )
              else
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'SUR_PLACE', label: Text('Sur place')),
                  ButtonSegment(value: 'A_EMPORTER', label: Text('À emporter')),
                  ButtonSegment(value: 'LIVRAISON', label: Text('Livraison')),
                ],
                selected: {type},
                onSelectionChanged: (value) => setState(() => type = value.first),
              ),
              if (type == 'LIVRAISON') ...[
                const SizedBox(height: 16),
                DropdownButtonFormField<String?>(
                  initialValue: customerId,
                  items: [
                    const DropdownMenuItem<String?>(value: null, child: Text('Client de passage')),
                    ...customers.map((item) => DropdownMenuItem<String?>(value: item['id'].toString(), child: Text('${item['name']} · ${item['phone']}'))),
                  ],
                  onChanged: (value) => setState(() {
                    customerId = value;
                    final addresses = customers
                        .where((item) => item['id'] == value)
                        .expand((item) => (item['addresses'] as List<dynamic>? ?? []))
                        .toList();
                    final preferred = addresses.cast<Map>().where((item) => item['isDefault'] == true);
                    final chosen = preferred.isNotEmpty ? preferred.first : (addresses.isNotEmpty ? addresses.first as Map : null);
                    addressId = chosen?['id']?.toString();
                    zoneId = chosen?['zoneId']?.toString() ?? zoneId;
                  }),
                  decoration: const InputDecoration(labelText: 'Client'),
                ),
                const SizedBox(height: 10),
                if (customerAddresses.isNotEmpty)
                  DropdownButtonFormField<String>(
                    initialValue: addressId,
                    items: customerAddresses
                        .map((item) => DropdownMenuItem(
                              value: item['id'].toString(),
                              child: Text('${item['label']} · ${item['address']}'),
                            ))
                        .toList(),
                    onChanged: (value) => setState(() {
                      addressId = value;
                      zoneId = selectedAddress?['zoneId']?.toString() ?? zoneId;
                    }),
                    decoration: const InputDecoration(labelText: 'Adresse'),
                  )
                else
                  DropdownButtonFormField<String>(
                    initialValue: zoneId,
                    items: zones
                        .where((item) => item['status'] == 'ACTIF')
                        .map((item) => DropdownMenuItem(value: item['id'].toString(), child: Text('${item['name']} · ${fc(item['fee'] as num)}')))
                        .toList(),
                    onChanged: (value) => setState(() => zoneId = value),
                    decoration: const InputDecoration(labelText: 'Zone de livraison'),
                  ),
                const SizedBox(height: 8),
                Text(
                  selectedZone == null ? 'Choisissez une zone pour calculer les frais.' : 'Frais ${selectedZone!['name']} : ${fc(fee)}',
                  style: TextStyle(color: selectedZone == null ? NdjoColors.danger : NdjoColors.muted),
                ),
              ],
              const SizedBox(height: 16),
              if (visibleProducts.isEmpty)
                const Card(
                  child: ListTile(
                    leading: Icon(Icons.cloud_off),
                    title: Text('Caisse hors ligne'),
                    subtitle: Text('Aucun produit en cache. Les ventes LOCAL- restent listées ci-dessous.'),
                  ),
                )
              else
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: visibleProducts.map((product) {
                  return SizedBox(
                    width: compact ? MediaQuery.sizeOf(context).width - 32 : 180,
                    child: Semantics(
                      identifier: 'pos-product-${product['name']}',
                      button: true,
                      label: product['name'].toString(),
                      child: Card(
                      child: InkWell(
                        onTap: () => compact ? _pickProduct(product) : _add(product),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(product['name'].toString(), style: const TextStyle(fontWeight: FontWeight.w700)),
                              Text(fc(_asPosNum(product['priceSell'])), style: const TextStyle(color: NdjoColors.accent)),
                              if ((product['description']?.toString() ?? '').isNotEmpty)
                                Text(product['description'].toString(), maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: NdjoColors.muted, fontSize: 12)),
                              Text(
                                [
                                  if (product['format'] != null && product['format'].toString().isNotEmpty) product['format'].toString(),
                                  'Stock ${product['stockQty'] ?? 0}',
                                ].join(' · '),
                                style: const TextStyle(color: NdjoColors.muted, fontSize: 12),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    ),
                  );
                }).toList(),
              ),
              const SizedBox(height: 24),
              const Text('Dernières commandes', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              const Text('Touchez une commande pour WhatsApp, facture ou bon de commande.', style: TextStyle(color: NdjoColors.muted, fontSize: 12)),
              if (orders.isEmpty)
                const Card(
                  child: ListTile(
                    title: Text('Aucune vente locale'),
                    subtitle: Text('Les commandes apparaissent ici après encaissement.'),
                  ),
                ),
              ...orders.take(8).map((item) {
                final map = _asPosMap(item);
                return Card(
                  child: ListTile(
                    title: Text('${map['number']} · ${map['status']}'),
                    subtitle: Text([
                      '${map['type']} · ${map['user'] is Map ? map['user']['name'] ?? '' : ''}',
                      if ((map['error']?.toString() ?? '').trim().isNotEmpty) map['error'].toString(),
                    ].where((line) => line.trim().isNotEmpty).join('\n')),
                    trailing: Text(fc(_asPosNum(map['total']))),
                    onTap: () => showTicketSheet(context, session: widget.session, order: map),
                  ),
                );
              }),
    ];
    final cartBody = Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('Panier', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                const SizedBox(height: 12),
                Expanded(
                  child: ListView(
                    children: cart.values.map((item) {
                      return ListTile(
                        dense: true,
                        title: Text(item['name'].toString()),
                        subtitle: Text('${item['qty']} × ${fc(item['unitPrice'] as num)}'),
                        trailing: IconButton(
                          icon: const Icon(Icons.remove_circle_outline),
                          onPressed: () => setState(() {
                            final id = item['productId'].toString();
                            final qty = (cart[id]!['qty'] as int) - 1;
                            if (qty <= 0) {
                              cart.remove(id);
                            } else {
                              cart[id]!['qty'] = qty;
                            }
                          }),
                        ),
                      );
                    }).toList(),
                  ),
                ),
                if (type == 'LIVRAISON') Text('Sous-total ${fc(subtotal)} · Livraison ${fc(fee)}', style: const TextStyle(color: NdjoColors.muted, fontSize: 12)),
                Text('TOTAL  ${fc(total)}', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: NdjoColors.accent)),
                const SizedBox(height: 12),
                Semantics(
                  identifier: 'pos-checkout',
                  button: true,
                  child: FilledButton(
                    onPressed: cart.isEmpty ? null : _checkout,
                    style: FilledButton.styleFrom(backgroundColor: NdjoColors.primary, padding: const EdgeInsets.symmetric(vertical: 16)),
                    child: const Text('Encaisser'),
                  ),
                ),
              ],
            );
    if (compact) {
      return Column(
        children: [
          Expanded(child: ListView(padding: const EdgeInsets.all(16), children: menu)),
          Material(
            color: NdjoColors.surface,
            elevation: 8,
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (cart.isNotEmpty)
                      ...cart.values.take(4).map((item) => Padding(
                            padding: const EdgeInsets.only(bottom: 4),
                            child: Text('${item['qty']} × ${item['name']}', style: const TextStyle(fontSize: 13)),
                          )),
                    if (type == 'LIVRAISON') Text('Sous-total ${fc(subtotal)} · Livraison ${fc(fee)}', style: const TextStyle(color: NdjoColors.muted, fontSize: 12)),
                    Text('TOTAL  ${fc(total)}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: NdjoColors.accent)),
                    const SizedBox(height: 8),
                    FilledButton(
                      onPressed: cart.isEmpty ? null : _checkout,
                      style: FilledButton.styleFrom(backgroundColor: NdjoColors.primary, padding: const EdgeInsets.symmetric(vertical: 14)),
                      child: const Text('Encaisser'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      );
    }
    return Row(
      children: [
        Expanded(
          flex: 3,
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: menu,
          ),
        ),
        const VerticalDivider(width: 1, color: NdjoColors.line),
        SizedBox(
          width: 320,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: cartBody,
          ),
        ),
      ],
    );
  }
}

class KitchenPage extends StatefulWidget {
  const KitchenPage({super.key, required this.session});
  final Session session;

  @override
  State<KitchenPage> createState() => _KitchenPageState();
}

class _KitchenPageState extends State<KitchenPage> {
  List<dynamic> orders = [];
  String? error;
  bool loading = true;
  Timer? _poll;

  String get _id => widget.session.establishmentId ?? '';

  @override
  void initState() {
    super.initState();
    orders = widget.session.peekList('kitchen-$_id');
    if (orders.isEmpty) {
      orders = widget.session.sync?.store.readKitchen(_id) ?? [];
    }
    if (orders.isNotEmpty) loading = false;
    _load();
    _poll = Timer.periodic(const Duration(seconds: 4), (_) {
      if (mounted) _load();
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final list = await widget.session.api.getList('/orders?establishmentId=$_id&kitchen=1');
      if (widget.session.sync != null) {
        await widget.session.sync!.store.cacheList('kitchen-$_id', list);
        await widget.session.sync!.store.cacheKitchen(_id, list);
      }
      final pending = widget.session.sync?.pendingSales() ?? [];
      final pendingKitchen = pending.where((item) {
        return widget.session.sync?.saleNeedsKitchen(item, establishmentId: _id) ?? true;
      }).toList();
      final pendingIds = pendingKitchen.map((item) => item['clientUuid']?.toString()).toSet();
      final merged = [
        ...pendingKitchen.map((item) => {...item, 'status': item['status'] ?? 'NOUVELLE'}),
        ...list.where((item) {
          final map = item as Map;
          final status = map['status']?.toString();
          if (status == 'EN_CAISSE') return false;
          return !pendingIds.contains(map['clientUuid']?.toString()) &&
              !pendingIds.contains(map['id']?.toString());
        }),
      ];
      if (!mounted) return;
      setState(() {
        orders = merged;
        loading = false;
        error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        error = null;
        loading = false;
      });
    }
  }

  Future<void> _setStatus(String id, String status) async {
    try {
      try {
        await widget.session.api.post('/orders/$id/status', {'status': status});
      } on ApiException catch (e) {
        final unreachable = e.message.toLowerCase().contains('injoignable');
        if (!unreachable || widget.session.sync == null) rethrow;
        final result = await widget.session.sync!.kitchenStatus(id, status, _id);
        if (!mounted) return;
        if (result['offline'] == true) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Statut cuisine enregistré hors ligne. Le stock sortira à la synchro.')),
          );
        }
      }
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (loading) return const Center(child: CircularProgressIndicator());
    if (error != null) return _Retry(error: error!, onRetry: _load);
    List<dynamic> column(String status) =>
        orders.where((item) => item['status']?.toString() == status).toList();
    Widget card(Map<String, dynamic> order, {String? action, String? next}) {
      final foods = (order['kitchenFoods'] as List<dynamic>? ?? []);
      final items = (order['items'] as List<dynamic>? ?? []);
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(order['number'].toString(), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 6),
              if (foods.isEmpty)
                Text(items.map((line) => '${line['quantity']} × ${line['name']}').join('\n'))
              else
                ...foods.map((raw) {
                  final dish = Map<String, dynamic>.from(raw as Map);
                  final parts = (dish['foods'] as List<dynamic>? ?? []);
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('${dish['quantity']} × ${dish['name']}', style: const TextStyle(fontWeight: FontWeight.w700)),
                        ...parts.map((foodRaw) {
                          final food = Map<String, dynamic>.from(foodRaw as Map);
                          final sameAsDish = food['name']?.toString() == dish['name']?.toString() && parts.length == 1;
                          if (sameAsDish) return const SizedBox.shrink();
                          return Text(
                            '· ${food['quantity']} ${food['unit'] ?? ''} ${food['product'] ?? food['name']}',
                            style: const TextStyle(color: NdjoColors.muted, fontSize: 13),
                          );
                        }),
                      ],
                    ),
                  );
                }),
              ...((order['consumedLots'] as List<dynamic>? ?? []).map((item) {
                final lot = Map<String, dynamic>.from(item as Map);
                final entry = lot['entryDate']?.toString().split('T').first;
                return Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    'Lot ${lot['lot']} · ${lot['quantity']} ${lot['unit'] ?? ''} ${lot['product']}${entry == null || entry.isEmpty ? '' : ' · entrée $entry'}',
                    style: const TextStyle(color: NdjoColors.accent, fontSize: 12),
                  ),
                );
              })),
              const SizedBox(height: 12),
              if (action != null && next != null)
                FilledButton(onPressed: () => _setStatus(order['id'].toString(), next), child: Text(action))
              else
                const Text('Prête — en attente caisse / livraison', style: TextStyle(color: NdjoColors.muted, fontSize: 12)),
            ],
          ),
        ),
      );
    }
    Widget lane(String status, String title, {String? action, String? next}) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
          ...column(status).map((item) => card(Map<String, dynamic>.from(item as Map), action: action, next: next)),
        ],
      );
    }
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Row(
          children: [
            const Expanded(child: Text('Cuisine', style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold))),
            IconButton(onPressed: _load, icon: const Icon(Icons.refresh)),
          ],
        ),
        const Text('Ticket cuisine = aliments. COMMENCER sort le stock. TERMINÉ envoie à la caisse ; le ticket reste visible ici jusqu’à encaissement / livraison.', style: TextStyle(color: NdjoColors.muted)),
        const SizedBox(height: 16),
        ndjoCompact(context)
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  lane('NOUVELLE', '🔴 NOUVELLES', action: 'COMMENCER', next: 'EN_PREPARATION'),
                  const SizedBox(height: 16),
                  lane('EN_PREPARATION', '🟡 EN PRÉPARATION', action: 'TERMINÉ', next: 'PRETE'),
                  const SizedBox(height: 16),
                  lane('PRETE', '🟢 PRÊTES'),
                ],
              )
            : Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: lane('NOUVELLE', '🔴 NOUVELLES', action: 'COMMENCER', next: 'EN_PREPARATION')),
            const SizedBox(width: 16),
            Expanded(child: lane('EN_PREPARATION', '🟡 EN PRÉPARATION', action: 'TERMINÉ', next: 'PRETE')),
            const SizedBox(width: 16),
            Expanded(child: lane('PRETE', '🟢 PRÊTES')),
          ],
        ),
      ],
    );
  }
}

class _Retry extends StatelessWidget {
  const _Retry({required this.error, required this.onRetry});
  final String error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(error, style: const TextStyle(color: NdjoColors.danger)),
          const SizedBox(height: 12),
          FilledButton(onPressed: onRetry, child: const Text('Réessayer')),
        ],
      ),
    );
  }
}

Future<bool?> _formDialog(BuildContext context, String title, List<Widget> fields) {
  return showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 420,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          for (final field in fields) ...[field, const SizedBox(height: 8)],
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuler')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Enregistrer')),
      ],
    ),
  );
}
