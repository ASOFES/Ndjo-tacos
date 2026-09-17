import 'dart:async';

import 'package:flutter/material.dart';

import 'api.dart';
import 'geo_position.dart';
import 'ops_center.dart';
import 'pages.dart';
import 'session.dart';
import 'theme.dart';
import 'ticket.dart';
import 'osm_map.dart';
import 'time_fmt.dart';

class RecipesPage extends StatefulWidget {
  const RecipesPage({super.key, required this.session});
  final Session session;

  @override
  State<RecipesPage> createState() => _RecipesPageState();
}

class _RecipesPageState extends State<RecipesPage> {
  List<dynamic> recipes = [];
  List<dynamic> dishes = [];
  List<dynamic> ingredients = [];
  String? error;
  bool loading = true;

  String get _id => widget.session.establishmentId ?? '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    recipes = widget.session.peekList('recipes-$_id');
    dishes = widget.session.peekList('catalog-$_id-VENTE');
    ingredients = widget.session.peekList('ingredients-$_id');
    if (recipes.isNotEmpty || dishes.isNotEmpty) loading = false;
    try {
      final loaded = await Future.wait([
        widget.session.cachedList('/recipes?establishmentId=$_id', 'recipes-$_id'),
        widget.session.cachedList('/catalog/products?establishmentId=$_id&kind=VENTE', 'catalog-$_id-VENTE'),
        widget.session.cachedList('/catalog/products?establishmentId=$_id&kind=INGREDIENT', 'ingredients-$_id'),
      ]);
      setState(() {
        recipes = loaded[0].isNotEmpty ? loaded[0] : recipes;
        dishes = loaded[1].isNotEmpty ? loaded[1] : dishes;
        ingredients = loaded[2].isNotEmpty ? loaded[2] : ingredients;
        loading = false;
        error = null;
      });
    } catch (e) {
      setState(() {
        error = null;
        loading = false;
      });
    }
  }

  Future<void> _edit([Map<String, dynamic>? recipe]) async {
    String? productId = recipe?['productId']?.toString() ?? recipe?['product']?['id']?.toString();
    final rows = <_RecipeEditLine>[
      ...((recipe?['items'] as List<dynamic>?) ?? []).map((item) {
        final map = item as Map<String, dynamic>;
        final unit = map['unit']?.toString() ?? 'g';
        final qty = (map['quantity'] as num?) ?? 0;
        return _RecipeEditLine(
          ingredientId: (map['ingredientId'] ?? map['ingredient']?['id'])?.toString() ?? '',
          quantity: unit == 'kg' ? '${(qty * 1000).round()}' : '$qty',
          unit: unit == 'kg' ? 'g' : unit,
        );
      }),
    ];
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: Text(recipe == null ? 'Nouvelle recette' : 'Modifier la composition'),
          content: SizedBox(
            width: 560,
            child: SingleChildScrollView(
              child: Column(
                children: [
                  DropdownButtonFormField<String>(
                    initialValue: productId,
                    isExpanded: true,
                    items: dishes.map((item) => DropdownMenuItem(value: item['id'].toString(), child: Text(item['name'].toString()))).toList(),
                    onChanged: (value) => setLocal(() => productId = value),
                    decoration: const InputDecoration(labelText: 'Produit de vente'),
                  ),
                  const SizedBox(height: 12),
                  ...rows.asMap().entries.map((entry) {
                    final line = entry.value;
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Row(
                        children: [
                          Expanded(
                            child: DropdownButtonFormField<String>(
                              initialValue: ingredients.any((item) => item['id'] == line.ingredientId) ? line.ingredientId : null,
                              isExpanded: true,
                              items: ingredients.map((item) => DropdownMenuItem(value: item['id'].toString(), child: Text(item['name'].toString()))).toList(),
                              onChanged: (value) => setLocal(() => line.ingredientId = value ?? ''),
                              decoration: const InputDecoration(hintText: 'Ingrédient'),
                            ),
                          ),
                          const SizedBox(width: 8),
                          SizedBox(width: 80, child: TextField(controller: line.quantity, decoration: const InputDecoration(hintText: 'Qté'))),
                          const SizedBox(width: 8),
                          SizedBox(
                            width: 88,
                            child: DropdownButtonFormField<String>(
                              initialValue: line.unit,
                              items: const [
                                DropdownMenuItem(value: 'g', child: Text('g')),
                                DropdownMenuItem(value: 'pièce', child: Text('pièce')),
                              ],
                              onChanged: (value) => setLocal(() => line.unit = value ?? line.unit),
                            ),
                          ),
                          IconButton(onPressed: () => setLocal(() => rows.removeAt(entry.key)), icon: const Icon(Icons.remove_circle_outline)),
                        ],
                      ),
                    );
                  }),
                  TextButton.icon(
                    onPressed: () => setLocal(() => rows.add(_RecipeEditLine(
                      ingredientId: ingredients.isNotEmpty ? ingredients.first['id'].toString() : '',
                      quantity: '150',
                      unit: 'g',
                    ))),
                    icon: const Icon(Icons.add),
                    label: const Text('Ajouter un ingrédient'),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuler')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Enregistrer')),
          ],
        ),
      ),
    );
    if (ok != true || productId == null) return;
    await widget.session.api.post('/recipes', {
      'establishmentId': _id,
      'productId': productId,
      'items': rows.where((line) => line.ingredientId.isNotEmpty).map((line) {
        final qty = num.tryParse(line.quantity.text.replaceAll(',', '.')) ?? 0;
        return {
          'ingredientId': line.ingredientId,
          'quantity': line.unit == 'g' ? qty / 1000 : qty,
          'unit': line.unit == 'g' ? 'kg' : line.unit,
        };
      }).toList(),
    });
    for (final line in rows) {
      line.quantity.dispose();
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    if (loading) return const Center(child: CircularProgressIndicator());
    if (error != null) return Center(child: Text(error!));
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Row(
          children: [
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Recettes', style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
                  Text('Composez ici la recette d’un plat. Elle apparaît aussi dans Catalogue.', style: TextStyle(color: NdjoColors.muted)),
                ],
              ),
            ),
            FilledButton.icon(onPressed: () => _edit(), icon: const Icon(Icons.add), label: const Text('Composer une recette')),
          ],
        ),
        const SizedBox(height: 16),
        ...recipes.map((item) {
          final recipe = item as Map<String, dynamic>;
          final lines = recipe['items'] as List<dynamic>? ?? [];
          return Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(child: Text(recipe['product']?['name']?.toString() ?? 'Recette', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700))),
                      Text(fc(recipe['product']?['priceSell'] ?? 0), style: const TextStyle(color: NdjoColors.accent, fontWeight: FontWeight.bold)),
                      IconButton(onPressed: () => _edit(recipe), icon: const Icon(Icons.edit)),
                    ],
                  ),
                  DataTable(
                    columns: const [
                      DataColumn(label: Text('Ingrédient')),
                      DataColumn(label: Text('Quantité')),
                      DataColumn(label: Text('Unité')),
                    ],
                    rows: lines.map((line) {
                      final map = line as Map<String, dynamic>;
                      final unit = map['unit']?.toString() ?? '';
                      final qty = map['quantity'] as num? ?? 0;
                      return DataRow(cells: [
                        DataCell(Text(map['ingredient']?['name']?.toString() ?? '')),
                        DataCell(Text(unit == 'kg' ? '${(qty * 1000).round()}' : '$qty')),
                        DataCell(Text(unit == 'kg' ? 'g' : unit)),
                      ]);
                    }).toList(),
                  ),
                ],
              ),
            ),
          );
        }),
      ],
    );
  }
}

class _RecipeEditLine {
  _RecipeEditLine({required this.ingredientId, required String quantity, required this.unit})
      : quantity = TextEditingController(text: quantity);
  String ingredientId;
  String unit;
  final TextEditingController quantity;
}

class OrdersPage extends StatefulWidget {
  const OrdersPage({super.key, required this.session});
  final Session session;

  @override
  State<OrdersPage> createState() => _OrdersPageState();
}

class _OrdersPageState extends State<OrdersPage> {
  List<dynamic> orders = [];
  Timer? _poll;

  String get _id => widget.session.establishmentId ?? '';

  @override
  void initState() {
    super.initState();
    orders = [
      ...?widget.session.sync?.pendingSales(),
      ...widget.session.peekList('orders-$_id'),
    ];
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
      final list = await widget.session.cachedList('/orders?establishmentId=$_id', 'orders-$_id');
      final pending = widget.session.sync?.pendingSales() ?? [];
      final pendingIds = pending.map((item) => item['clientUuid']?.toString()).toSet();
      if (!mounted) return;
      setState(() {
        orders = [
          ...pending,
          ...list.where((item) {
            final map = item as Map;
            return !pendingIds.contains(map['clientUuid']?.toString()) &&
                !pendingIds.contains(map['id']?.toString());
          }),
        ];
      });
    } catch (_) {
      if (!mounted) return;
      if (orders.isEmpty) {
        setState(() => orders = widget.session.peekList('orders-$_id'));
      }
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

  @override
  Widget build(BuildContext context) {
    final waiting = orders.where((item) => item is Map && item['status']?.toString() == 'EN_CAISSE').toList();
    final rest = orders.where((item) => item is! Map || item['status']?.toString() != 'EN_CAISSE').toList();
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const Text('Commandes', style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
        const Text('Les commandes client arrivent ici. La caisse les envoie ensuite en cuisine.', style: TextStyle(color: NdjoColors.muted)),
        const Text('Touchez une commande pour WhatsApp, impression facture ou bon de commande.', style: TextStyle(color: NdjoColors.muted, fontSize: 12)),
        const SizedBox(height: 8),
        ndjoExportButtons(
          onExcel: () => downloadNdjoExport(context, widget.session, kind: 'sales', format: 'xls', period: 'jour'),
          onPdf: () => downloadNdjoExport(context, widget.session, kind: 'sales', format: 'pdf', period: 'jour'),
        ),
        const SizedBox(height: 12),
        cashierClientInbox(
          orders: waiting,
          onSend: _sendToKitchen,
          onTicket: (order) => showTicketSheet(context, session: widget.session, order: order),
        ),
        ...rest.map((item) {
          final order = Map<String, dynamic>.from(item as Map);
          return Card(
            child: ListTile(
              title: Text('${order['number']} · ${order['status']}'),
              subtitle: Text('${order['type']} · ${order['customerName'] ?? order['user']?['name'] ?? ''} · ${orderPayLabel(order)}'),
              trailing: Text(fc((order['total'] as num?) ?? 0)),
              onTap: () => showTicketSheet(context, session: widget.session, order: order),
            ),
          );
        }),
      ],
    );
  }
}

class InvoicesPage extends StatefulWidget {
  const InvoicesPage({super.key, required this.session});
  final Session session;

  @override
  State<InvoicesPage> createState() => _InvoicesPageState();
}

class _InvoicesPageState extends State<InvoicesPage> {
  List<dynamic> invoices = [];

  String get _id => widget.session.establishmentId ?? '';

  @override
  void initState() {
    super.initState();
    invoices = widget.session.peekList('invoices-$_id');
    _load();
  }

  Future<void> _load() async {
    try {
      final list = await widget.session.cachedList('/orders/invoices?establishmentId=$_id', 'invoices-$_id');
      setState(() => invoices = list.isNotEmpty ? list : invoices);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final compact = ndjoCompact(context);
    return ListView(
      padding: EdgeInsets.all(compact ? 16 : 24),
      children: [
        const Text('Factures', style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
        const Text(
          'WhatsApp du téléphone pour envoyer au client. Impression locale de la facture ou du bon de commande.',
          style: TextStyle(color: NdjoColors.muted),
        ),
        const SizedBox(height: 12),
        if (invoices.isEmpty)
          const Text('Aucune facture en copie locale.', style: TextStyle(color: NdjoColors.muted)),
        ...invoices.map((item) {
          final invoice = item as Map<String, dynamic>;
          final order = ticketOrderFromInvoice(invoice);
          return Card(
            child: ListTile(
              title: Text(invoice['number'].toString()),
              subtitle: Text(
                '${order['customerName'] ?? order['customer']?['name'] ?? order['number'] ?? ''} · ${orderPayLabel(order)}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: Text(fc(invoice['total'] as num)),
              onTap: () => showTicketSheet(context, session: widget.session, order: order),
            ),
          );
        }),
      ],
    );
  }
}

class DeliveryPage extends StatefulWidget {
  const DeliveryPage({super.key, required this.session});
  final Session session;

  @override
  State<DeliveryPage> createState() => _DeliveryPageState();
}

class _DeliveryPageState extends State<DeliveryPage> {
  List<dynamic> deliveries = [];
  List<dynamic> drivers = [];
  String? availability;
  String? error;
  Timer? _gpsTimer;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _load();
    _poll = Timer.periodic(const Duration(seconds: 5), (_) {
      if (mounted) _load();
    });
    if (widget.session.role == 'LIVREUR') {
      _gpsTimer = Timer.periodic(const Duration(seconds: 15), (_) => _pushActiveGps());
    }
  }

  @override
  void dispose() {
    _gpsTimer?.cancel();
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final id = widget.session.establishmentId;
    deliveries = widget.session.peekList('delivery-$id');
    drivers = widget.session.peekList('drivers-$id');
    try {
      final loadedDeliveries = await widget.session.cachedList('/delivery?establishmentId=$id', 'delivery-$id');
      final loadedDrivers = await widget.session.cachedList('/delivery/drivers?establishmentId=$id', 'drivers-$id');
      if (!mounted) return;
      setState(() {
        deliveries = loadedDeliveries.isNotEmpty ? loadedDeliveries : deliveries;
        drivers = loadedDrivers.isNotEmpty ? loadedDrivers : drivers;
        availability = widget.session.user?['availability']?.toString() ?? 'HORS_LIGNE';
        error = null;
      });
    } catch (e) {
      setState(() => error = null);
    }
  }

  Future<void> _syncEvent(String action, String orderId, [Map<String, dynamic>? extra]) async {
    final id = widget.session.establishmentId ?? '';
    if (widget.session.sync != null) {
      final result = await widget.session.sync!.deliveryEvent(action, orderId, id, extra);
      if (result['offline'] == true && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Événement livraison mis en file hors ligne.')),
        );
      }
      return;
    }
    final path = switch (action) {
      'assign' => '/delivery/$orderId/assign',
      'start' => '/delivery/$orderId/start',
      'arrive' => '/delivery/$orderId/arrive',
      'deliver' => '/delivery/$orderId/deliver',
      'location' => '/delivery/location',
      'collect' => '/delivery/$orderId/collect',
      _ => '/delivery/$orderId/$action',
    };
    await widget.session.api.post(path, extra);
  }

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  Future<void> _toggle() async {
    await _run(() async {
      final next = availability == 'DISPONIBLE' ? 'HORS_LIGNE' : 'DISPONIBLE';
      final result = await widget.session.api.post('/delivery/availability', {'availability': next});
      widget.session.user?['availability'] = result['availability'];
      setState(() => availability = result['availability']?.toString());
    });
  }

  Future<void> _pushActiveGps() async {
    final gps = await currentGps();
    if (gps == null || !mounted) return;
    for (final item in deliveries) {
      final order = Map<String, dynamic>.from(item as Map);
      if (order['status'] != 'EN_LIVRAISON') continue;
      try {
        if (widget.session.sync != null) {
          await _syncEvent('location', order['id'].toString(), gps);
        } else {
          await widget.session.api.post('/delivery/location', {
            ...gps,
            'orderId': order['id'],
          });
        }
      } catch (_) {}
    }
  }

  Future<void> _sendGps(Map<String, dynamic> order) async {
    await _run(() async {
      final gps = await currentGps();
      if (gps == null) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('GPS indisponible. Autorisez la localisation du navigateur.')),
        );
        return;
      }
      if (widget.session.sync != null) {
        await _syncEvent('location', order['id'].toString(), gps);
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Position GPS enregistrée')));
        return;
      }
      final result = await widget.session.api.post('/delivery/location', {
        ...gps,
        'orderId': order['id'],
      });
      final eta = result['eta'] as Map<String, dynamic>?;
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(eta == null ? 'Position GPS enregistrée' : 'GPS envoyé · ETA ${eta['minutes']} min · ${eta['distanceKm']} km')),
      );
    });
  }

  Future<void> _sendOtp(Map<String, dynamic> order) async {
    await _run(() async {
      final result = await widget.session.api.post('/delivery/${order['id']}/send-otp');
      if (!mounted) return;
      final staffOtp = result['staffOtp'];
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            staffOtp != null
                ? 'OTP envoyé au client (${result['channel']}). Code staff : $staffOtp'
                : 'OTP envoyé au client (${result['channel']}). Indice ${result['otpHint']}',
          ),
        ),
      );
    });
  }

  Future<void> _deliver(Map<String, dynamic> order) async {
    final otp = TextEditingController();
    final photo = TextEditingController(text: order['proof']?['photoUrl']?.toString() ?? '');
    final signature = TextEditingController();
    final coords = await currentGps();
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Preuve de livraison'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: otp, decoration: const InputDecoration(labelText: 'OTP client'), keyboardType: TextInputType.number),
              TextField(controller: signature, decoration: const InputDecoration(labelText: 'Signature du client')),
              TextField(controller: photo, decoration: const InputDecoration(labelText: 'Photo de preuve (URL)')),
              const SizedBox(height: 8),
              Text(
                coords == null
                    ? 'GPS remise : indisponible'
                    : 'GPS remise : ${coords['latitude']!.toStringAsFixed(5)}, ${coords['longitude']!.toStringAsFixed(5)}',
                style: const TextStyle(color: NdjoColors.muted),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Confirmer')),
        ],
      ),
    );
    if (ok != true) return;
    await _run(() async {
      await _syncEvent('deliver', order['id'].toString(), {
        'otp': otp.text.trim(),
        'proofSignature': signature.text.trim(),
        'proofPhotoUrl': photo.text.trim().isEmpty ? null : photo.text.trim(),
        if (coords != null) ...{
          'latitude': coords['latitude'],
          'longitude': coords['longitude'],
        },
      });
    });
  }

  Future<void> _openHistory(String driverId) async {
    try {
      final data = await widget.session.api.getJson('/delivery/drivers/$driverId');
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (context) {
            final courses = data['courses'] as List<dynamic>? ?? [];
            final movements = _deliveryMovements(data);
            return Scaffold(
              appBar: AppBar(title: Text('Profil · ${data['name'] ?? 'Livreur'}')),
              body: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  if (data['photoUrl'] != null)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: CircleAvatar(radius: 36, backgroundImage: NetworkImage(data['photoUrl'].toString())),
                    ),
                  const SizedBox(height: 8),
                  Text(data['name']?.toString() ?? 'Livreur', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                  Text('${data['phone'] ?? '—'} · ${_driverStatus(data['availability']?.toString())}'),
                  Text('Courses : ${data['stats']?['total'] ?? 0} · livrées ${data['stats']?['delivered'] ?? 0} · actives ${data['stats']?['active'] ?? 0}'),
                  const SizedBox(height: 16),
                  NdjoMovementHistory(movements: movements, formatTime: _fmt),
                  const SizedBox(height: 8),
                  FilledButton.icon(
                    onPressed: () => _openMap({
                      'location': data['lastLocation'],
                      'destination': data['destination'],
                      'trail': data['trail'],
                      'mapBrowseUrl': data['mapBrowseUrl'],
                      'number': data['name'],
                    }),
                    icon: const Icon(Icons.map),
                    label: const Text('Voir la carte'),
                  ),
                  const SizedBox(height: 16),
                  const Text('Courses', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 18)),
                  if (courses.isEmpty)
                    const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Text('Aucune course encore. Affectez ce livreur à une livraison.'),
                    ),
                  ...courses.map((item) {
                    final course = item as Map<String, dynamic>;
                    return Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('${course['number']} · ${course['status']}', style: const TextStyle(fontWeight: FontWeight.w700)),
                          Text(
                            '${course['address'] ?? ''} · ${_fmtDuration(course['durationMinutes'])}',
                            style: const TextStyle(color: NdjoColors.muted, fontSize: 12),
                          ),
                          const SizedBox(height: 6),
                          NdjoMovementHistory(movements: _deliveryMovements(course), formatTime: _fmt),
                        ],
                      ),
                    );
                  }),
                ],
              ),
            );
          },
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  Future<void> _openOrderProfile(Map<String, dynamic> order) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) {
          return Scaffold(
            appBar: AppBar(title: Text('Profil · ${order['number'] ?? 'Livraison'}')),
            body: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text('${order['number']} · ${order['status']}', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                Text('Client : ${order['customerName'] ?? '—'}'),
                Text(order['address']?.toString() ?? ''),
                Text('Livreur : ${order['driver']?['name'] ?? 'Non affecté'}'),
                const SizedBox(height: 16),
                NdjoMovementHistory(movements: _deliveryMovements(order), formatTime: _fmt),
                const SizedBox(height: 8),
                FilledButton.icon(
                  onPressed: () => _openMap(order),
                  icon: const Icon(Icons.map),
                  label: const Text('Voir la carte'),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  void _openMap(Map<String, dynamic> data) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => Scaffold(
          appBar: AppBar(title: Text('Carte · ${data['number'] ?? 'Livraison'}')),
          body: Padding(
            padding: const EdgeInsets.all(12),
            child: NdjoDeliveryMap(
              viewId: 'map-${data['id'] ?? data['number'] ?? 'livraison'}',
              location: data['location'] as Map<String, dynamic>? ?? data['lastLocation'] as Map<String, dynamic>?,
              destination: data['destination'] as Map<String, dynamic>?,
              trail: data['trail'] as List<dynamic>? ?? const [],
              browseUrl: data['mapBrowseUrl']?.toString(),
              height: MediaQuery.sizeOf(context).height - 160,
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDriver = widget.session.role == 'LIVREUR';
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const Text('Livraisons', style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
        if (error != null) Text(error!, style: const TextStyle(color: NdjoColors.danger)),
        if (isDriver) ...[
          const SizedBox(height: 8),
          Text('Statut : ${_driverStatus(availability)}'),
          TextButton(onPressed: _toggle, child: Text(availability == 'DISPONIBLE' ? 'Passer hors ligne' : 'Se rendre disponible')),
        ],
        const SizedBox(height: 12),
        const Text('Livreurs', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        ...drivers.map((item) {
          final driver = item as Map<String, dynamic>;
          return Card(
            child: ListTile(
              leading: CircleAvatar(
                backgroundImage: driver['photoUrl'] != null ? NetworkImage(driver['photoUrl'].toString()) : null,
                child: driver['photoUrl'] == null ? Text(driver['name'].toString().substring(0, 1)) : null,
              ),
              title: Text(driver['name'].toString()),
              subtitle: Text('${driver['phone'] ?? ''} · profil et historique'),
              trailing: Text(_driverStatus(driver['availability']?.toString())),
              onTap: () => _openHistory(driver['id'].toString()),
            ),
          );
        }),
        const SizedBox(height: 16),
        ...deliveries.map((item) {
          final order = item as Map<String, dynamic>;
          final eta = order['eta'] as Map<String, dynamic>?;
          final proof = order['proof'] as Map<String, dynamic>?;
          return Card(
            child: InkWell(
              onTap: () => _openOrderProfile(order),
              child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${order['number']} · ${order['status']}', style: const TextStyle(fontWeight: FontWeight.bold)),
                  Text('Client : ${order['customerName'] ?? '—'} · ${order['address'] ?? ''}'),
                  Text('Livreur : ${order['driver']?['name'] ?? 'Non affecté'}'),
                  Text('Prise ${_fmt(order['pickedUpAt'])} · Départ ${_fmt(order['departedAt'])} · Arrivée ${_fmt(order['arrivedAt'])}'),
                  if (eta != null) Text('ETA : ${eta['minutes']} min · ${eta['distanceKm']} km', style: const TextStyle(color: NdjoColors.accent)),
                  if (order['location'] == null && order['status'] == 'EN_LIVRAISON')
                    const Text('GPS livreur en attente — ETA non calculé', style: TextStyle(color: NdjoColors.muted)),
                  if (proof?['deliveredBy'] != null) Text('Remis par ${proof?['deliveredBy']?['name'] ?? proof?['deliveredBy']} · OTP ${order['otpVerifiedAt'] != null ? 'validé' : '—'}'),
                  const SizedBox(height: 8),
                  NdjoMovementHistory(movements: _deliveryMovements(order), formatTime: _fmt),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilledButton.tonal(
                        onPressed: () => _openOrderProfile(order),
                        child: const Text('Profil + historique'),
                      ),
                      OutlinedButton.icon(
                        onPressed: () => _openMap(order),
                        icon: const Icon(Icons.map, size: 16),
                        label: const Text('Carte'),
                      ),
                      if (!isDriver && order['driver'] == null)
                        FilledButton(onPressed: () => _run(() => _syncEvent('assign', order['id'].toString())), child: const Text('Affecter')),
                      if (order['status'] == 'PRETE')
                        FilledButton(onPressed: () => _run(() => _syncEvent('start', order['id'].toString())), child: const Text('Démarrer livraison')),
                      if (order['status'] == 'EN_LIVRAISON') ...[
                        OutlinedButton(onPressed: () => _sendOtp(order), child: const Text('Envoyer OTP')),
                        OutlinedButton(onPressed: () => _sendGps(order), child: const Text('Envoyer GPS')),
                        OutlinedButton(onPressed: () => _run(() => _syncEvent('arrive', order['id'].toString())), child: const Text('Arrivée')),
                        FilledButton(onPressed: () => _deliver(order), child: const Text('Livrer + preuve')),
                      ],
                      if (order['status'] == 'LIVREE' && order['paymentStatus'] != 'PAYE')
                        FilledButton(
                          onPressed: () => _run(() => _syncEvent('collect', order['id'].toString(), {
                            'received': order['total'],
                          })),
                          child: const Text('Encaisser cash'),
                        ),
                      if (order['trackingToken'] != null)
                        TextButton(
                          onPressed: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => Scaffold(
                                appBar: AppBar(title: const Text('Suivi client')),
                                body: TrackOrderPage(token: order['trackingToken'].toString(), session: widget.session),
                              ),
                            ),
                          ),
                          child: const Text('Suivi'),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            ),
          );
        }),
      ],
    );
  }
}

List<Map<String, dynamic>> _deliveryMovements(Map<String, dynamic> order) {
  final fromApi = order['movements'];
  if (fromApi is List && fromApi.isNotEmpty) {
    return [
      for (final item in fromApi)
        if (item is Map) Map<String, dynamic>.from(item),
    ];
  }
  final events = <Map<String, dynamic>>[];
  void add(dynamic at, String label, {String kind = 'STATUS', dynamic lat, dynamic lng}) {
    if (at == null) return;
    events.add({
      'at': at,
      'label': label,
      'kind': kind,
      if (lat is num) 'latitude': lat,
      if (lng is num) 'longitude': lng,
    });
  }

  add(order['createdAt'], 'Commande créée');
  add(order['pickedUpAt'], 'Prise en charge');
  add(order['departedAt'], 'Départ');
  for (final point in order['trail'] as List<dynamic>? ?? const []) {
    if (point is Map) {
      add(point['recordedAt'], 'Position GPS', kind: 'GPS', lat: point['latitude'], lng: point['longitude']);
    }
  }
  add(order['arrivedAt'], 'Arrivée client');
  final proof = order['proof'] as Map<String, dynamic>?;
  add(order['deliveredAt'], 'Livrée', lat: proof?['latitude'] ?? order['deliveredLat'], lng: proof?['longitude'] ?? order['deliveredLng']);
  if (events.isEmpty) {
    events.add({'at': DateTime.now().toIso8601String(), 'label': 'En attente de mouvement · ${order['status'] ?? ''}', 'kind': 'STATUS'});
  }
  return events;
}

String _driverStatus(String? value) {
  if (value == 'DISPONIBLE') return '🟢 Disponible';
  if (value == 'EN_LIVRAISON') return '🟡 En course';
  return '⚫ Hors ligne';
}

String _fmt(dynamic value) => formatLocalDateTime(value);

String _fmtDuration(dynamic minutes) {
  if (minutes == null) return 'durée —';
  return 'durée ${minutes} min';
}

class ClientShopPage extends StatefulWidget {
  const ClientShopPage({super.key, required this.session});
  final Session session;

  @override
  State<ClientShopPage> createState() => _ClientShopPageState();
}

class _ClientShopPageState extends State<ClientShopPage> {
  List<dynamic> places = [];
  List<dynamic> categories = [];
  List<dynamic> zones = [];
  String? placeId;
  String? zoneId;
  final cart = <String, Map<String, dynamic>>{};
  String type = 'A_EMPORTER';
  String payMethod = 'EN_ATTENTE';
  final name = TextEditingController();
  final phone = TextEditingController();
  final address = TextEditingController();

  Map<String, dynamic>? get selectedZone {
    final match = zones.where((item) => item['id'] == zoneId);
    return match.isEmpty ? null : Map<String, dynamic>.from(match.first as Map);
  }

  int get subtotal => cart.values.fold(0, (sum, item) => sum + (item['unitPrice'] as int) * (item['qty'] as int));
  int get fee => type == 'LIVRAISON' ? ((selectedZone?['fee'] as num?)?.toInt() ?? 0) : 0;
  int get total => subtotal + fee;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    final list = await widget.session.api.getList('/public/establishments');
    setState(() {
      places = list;
      placeId = widget.session.establishmentId ?? (list.isNotEmpty ? list.first['id'].toString() : null);
    });
    if (placeId != null) await _loadCatalog();
  }

  Future<void> _loadCatalog() async {
    final loaded = await Future.wait([
      widget.session.api.getList('/public/catalog?establishmentId=$placeId'),
      widget.session.api.getList('/public/delivery-zones?establishmentId=$placeId'),
    ]);
    setState(() {
      categories = loaded[0];
      zones = loaded[1];
      if (zoneId == null && zones.isNotEmpty) zoneId = zones.first['id'].toString();
    });
  }

  Future<void> _order() async {
    try {
      final order = await widget.session.api.post('/public/orders', {
        'establishmentId': placeId,
        'type': type,
        'customerName': name.text,
        'customerPhone': phone.text,
        'address': address.text,
        'zoneId': zoneId,
        'items': cart.values.map((item) => {'productId': item['productId'], 'quantity': item['qty']}).toList(),
      });
      setState(cart.clear);
      if (!mounted) return;
      final token = order['trackingToken']?.toString();
      if (token != null && payMethod != 'EN_ATTENTE') {
        await widget.session.api.post('/public/orders/$token/pay', {
          'method': payMethod,
          'phone': phone.text,
        });
      }
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Commande ${order['number']} reçue à la caisse. Payée ou non, la cuisine la verra après validation. Suivi : ${token ?? '—'}')));
      if (token != null) {
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => Scaffold(
              appBar: AppBar(title: const Text('Suivi de commande')),
              body: TrackOrderPage(token: token, session: widget.session),
            ),
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const Text('NDJO TACOS', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800, color: NdjoColors.primary)),
        const Text('Catalogue client', style: TextStyle(color: NdjoColors.muted)),
        const SizedBox(height: 12),
        if (places.isNotEmpty)
          DropdownButtonFormField<String>(
            initialValue: placeId,
            items: places.map((item) => DropdownMenuItem(value: item['id'].toString(), child: Text(item['name'].toString()))).toList(),
            onChanged: (value) {
              setState(() => placeId = value);
              _loadCatalog();
            },
            decoration: const InputDecoration(labelText: 'Choisir votre établissement'),
          ),
        const SizedBox(height: 16),
        ...categories.map((item) {
          final category = item as Map<String, dynamic>;
          final products = category['products'] as List<dynamic>? ?? [];
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(category['name'].toString().toUpperCase(), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: products.map((product) {
                  final map = product as Map<String, dynamic>;
                  return SizedBox(
                    width: ndjoCompact(context) ? MediaQuery.sizeOf(context).width - 48 : 170,
                    child: Card(
                      child: InkWell(
                        onTap: () async {
                          final add = await showMenuDetailSheet(context, {
                            ...map,
                            'category': category,
                          });
                          if (add == true && mounted) {
                            setState(() {
                              final id = map['id'].toString();
                              cart[id] = {
                                'productId': id,
                                'name': map['name'],
                                'unitPrice': map['priceSell'],
                                'qty': (cart[id]?['qty'] as int? ?? 0) + 1,
                              };
                            });
                          }
                        },
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(map['name'].toString(), style: const TextStyle(fontWeight: FontWeight.w700)),
                              Text(fc(map['priceSell'] as num), style: const TextStyle(color: NdjoColors.accent)),
                              if ((map['description']?.toString() ?? '').isNotEmpty)
                                Text(map['description'].toString(), maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: NdjoColors.muted, fontSize: 12)),
                              if (map['format'] != null)
                                Text(map['format'].toString(), style: const TextStyle(color: NdjoColors.muted, fontSize: 12)),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
              const SizedBox(height: 16),
            ],
          );
        }),
        const Text('Panier', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
        ...cart.values.map((item) => ListTile(dense: true, title: Text('${item['qty']} × ${item['name']}'), trailing: Text(fc((item['unitPrice'] as int) * (item['qty'] as int))))),
        if (ndjoCompact(context))
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
          TextField(controller: address, decoration: const InputDecoration(labelText: 'Adresse')),
          DropdownButtonFormField<String>(
            initialValue: zoneId,
            items: zones
                .map((item) => DropdownMenuItem(value: item['id'].toString(), child: Text('${item['name']} · ${fc(item['fee'] as num)}')))
                .toList(),
            onChanged: (value) => setState(() => zoneId = value),
            decoration: const InputDecoration(labelText: 'Zone de livraison'),
          ),
          Text(
            selectedZone == null ? 'Choisissez une zone pour calculer les frais.' : 'Frais : ${fc(fee)}',
            style: TextStyle(color: selectedZone == null ? NdjoColors.danger : NdjoColors.muted),
          ),
        ],
        TextField(controller: name, decoration: const InputDecoration(labelText: 'Nom')),
        TextField(controller: phone, decoration: const InputDecoration(labelText: 'Téléphone')),
        DropdownButtonFormField<String>(
          initialValue: payMethod,
          items: const [
            DropdownMenuItem(value: 'EN_ATTENTE', child: Text('Payer plus tard / à la livraison')),
            DropdownMenuItem(value: 'MOBILE_MONEY', child: Text('Mobile Money')),
            DropdownMenuItem(value: 'CARTE', child: Text('Carte')),
            DropdownMenuItem(value: 'VIREMENT', child: Text('Virement')),
          ],
          onChanged: (value) => setState(() => payMethod = value ?? payMethod),
          decoration: const InputDecoration(labelText: 'Paiement'),
        ),
        const SizedBox(height: 8),
        Text('TOTAL  ${fc(total)}', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: NdjoColors.accent)),
        const SizedBox(height: 8),
        FilledButton(
          onPressed: cart.isEmpty ? null : _order,
          style: FilledButton.styleFrom(backgroundColor: NdjoColors.primary, padding: const EdgeInsets.symmetric(vertical: 16)),
          child: const Text('Confirmer la commande'),
        ),
      ],
    );
  }
}
