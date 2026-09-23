import 'package:flutter/material.dart';

import 'api.dart';
import 'clear_stuck_data.dart';
import 'export_file.dart';
import 'session.dart';
import 'theme.dart';

bool ndjoPageVisible(BuildContext context) => TickerMode.of(context);

String ndjoRowsFp(Iterable<dynamic> rows) {
  final maps = rows.whereType<Map>().toList()
    ..sort((a, b) => (a['id']?.toString() ?? '').compareTo(b['id']?.toString() ?? ''));
  final out = StringBuffer();
  for (final item in maps) {
    out.write(item['id']);
    out.write(':');
    out.write(item['status'] ?? item['updatedAt'] ?? item['availability'] ?? item['stockQty'] ?? '');
    out.write(';');
  }
  return out.toString();
}

String recipeQty(num quantity, String unit) {
  if (unit == 'kg') return '${(quantity * 1000).round()} g';
  if (quantity == quantity.roundToDouble()) return '${quantity.round()} $unit';
  return '$quantity $unit';
}

String fc(num value) {
  final digits = value.round().abs().toString();
  final buffer = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(' ');
    buffer.write(digits[i]);
  }
  return '${value < 0 ? '-' : ''}$buffer FC';
}

String orderPayLabel(Map<String, dynamic> order) {
  return order['paymentStatus']?.toString() == 'PAYE' ? 'Payée' : 'Non payée';
}

String orderItemsLine(Map<String, dynamic> order) {
  final items = order['items'] as List<dynamic>? ?? [];
  if (items.isEmpty) return '';
  return items.map((item) {
    final map = item is Map ? Map<String, dynamic>.from(item) : <String, dynamic>{};
    return '${map['quantity'] ?? 1} × ${map['name'] ?? ''}';
  }).join(', ');
}

String orderShortageMessage(Map<String, dynamic> order) {
  final message = order['stockShortageMessage']?.toString().trim() ?? '';
  if (message.isNotEmpty) return message;
  final rows = order['stockShortages'] as List<dynamic>? ?? [];
  if (rows.isEmpty) return '';
  final number = order['number']?.toString() ?? '';
  final lines = rows.map((item) {
    final map = item is Map ? Map<String, dynamic>.from(item) : <String, dynamic>{};
    final dish = map['dish']?.toString() ?? '';
    final name = map['name']?.toString() ?? 'Produit';
    final needed = map['needed'];
    final available = map['available'];
    final qty = 'besoin $needed, stock $available';
    if (dish.isNotEmpty && dish != name) return '$dish ($name : $qty)';
    return '$name ($qty)';
  }).join(' · ');
  return number.isEmpty ? 'Produit en carence — $lines' : 'Commande $number : produit en carence — $lines';
}

bool isStockShortageMessage(String message) {
  final lower = message.toLowerCase();
  return lower.contains('carence') || lower.contains('stock insuffisant');
}

Future<void> showStockShortageNotice(BuildContext context, String message) {
  return showDialog<void>(
    context: context,
    builder: (ctx) {
      return AlertDialog(
        title: const Text('Produit en carence'),
        content: Text(message),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            style: FilledButton.styleFrom(backgroundColor: NdjoColors.primary),
            child: const Text('OK'),
          ),
        ],
      );
    },
  );
}

Future<void> showCashierError(BuildContext context, Object error) async {
  final message = error.toString();
  if (isStockShortageMessage(message)) {
    await showStockShortageNotice(context, message);
    return;
  }
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}

Widget ndjoExportButtons({
  required VoidCallback onExcel,
  required VoidCallback onPdf,
}) {
  return Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      OutlinedButton.icon(
        onPressed: onExcel,
        icon: const Icon(Icons.table_view_outlined, size: 18),
        label: const Text('Excel'),
      ),
      OutlinedButton.icon(
        onPressed: onPdf,
        icon: const Icon(Icons.picture_as_pdf_outlined, size: 18),
        label: const Text('PDF'),
      ),
    ],
  );
}

/// Recherche locale sur listes (catalogue, stock, clients, etc.).
bool ndjoMatchesQuery(dynamic item, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return true;
  if (item is! Map) return item.toString().toLowerCase().contains(q);
  final parts = <String>[];
  void add(dynamic value) {
    if (value == null) return;
    if (value is Map) {
      add(value['name']);
      add(value['code']);
      add(value['phone']);
      add(value['number']);
      add(value['username']);
      return;
    }
    final text = value.toString().trim();
    if (text.isNotEmpty) parts.add(text);
  }

  add(item['name']);
  add(item['code']);
  add(item['phone']);
  add(item['number']);
  add(item['username']);
  add(item['role']);
  add(item['email']);
  add(item['address']);
  add(item['motif']);
  add(item['type']);
  add(item['status']);
  add(item['category']);
  add(item['product']);
  add(item['supplier']);
  add(item['source']);
  add(item['dest']);
  add(item['user']);
  add(item['label']);
  return parts.join(' ').toLowerCase().contains(q);
}

List<dynamic> ndjoFilterList(List<dynamic> items, String query) {
  if (query.trim().isEmpty) return items;
  return items.where((item) => ndjoMatchesQuery(item, query)).toList();
}

class NdjoSearchBar extends StatefulWidget {
  const NdjoSearchBar({
    super.key,
    required this.onChanged,
    this.hint = 'Rechercher…',
    this.initial = '',
  });

  final ValueChanged<String> onChanged;
  final String hint;
  final String initial;

  @override
  State<NdjoSearchBar> createState() => _NdjoSearchBarState();
}

class _NdjoSearchBarState extends State<NdjoSearchBar> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initial);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _controller,
      onChanged: (value) {
        setState(() {});
        widget.onChanged(value);
      },
      textInputAction: TextInputAction.search,
      decoration: InputDecoration(
        hintText: widget.hint,
        prefixIcon: const Icon(Icons.search),
        suffixIcon: _controller.text.isEmpty
            ? null
            : IconButton(
                tooltip: 'Effacer',
                icon: const Icon(Icons.clear),
                onPressed: () {
                  _controller.clear();
                  widget.onChanged('');
                  setState(() {});
                },
              ),
        border: const OutlineInputBorder(),
        isDense: true,
        filled: true,
        fillColor: NdjoColors.surface,
      ),
    );
  }
}


Future<void> downloadNdjoExport(
  BuildContext context,
  Session session, {
  required String kind,
  required String format,
  String? period,
}) async {
  final id = session.establishmentId ?? '';
  final query = [
    if (id.isNotEmpty) 'establishmentId=$id',
    if (period != null && period.isNotEmpty) 'period=$period',
  ].join('&');
  try {
    final file = await session.api.getFile('/export/$kind/$format${query.isEmpty ? '' : '?$query'}');
    final saved = await saveNdjoFile(file.name, file.bytes, file.mime);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Extraction enregistrée : $saved')));
  } catch (e) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
  }
}

String transferStatusLabel(String status) {
  switch (status) {
    case 'CREE':
      return 'À expédier';
    case 'EN_TRANSIT':
      return 'En transit — réception à valider';
    case 'RECU':
      return 'Réception validée';
    case 'ANNULE':
      return 'Annulé';
    default:
      return status;
  }
}

Widget cashierClientInbox({
  required List<dynamic> orders,
  required Future<void> Function(String id) onSend,
  void Function(Map<String, dynamic> order)? onTicket,
}) {
  final waiting = [
    for (final item in orders)
      if (item is Map && item['status']?.toString() == 'EN_CAISSE') Map<String, dynamic>.from(item),
  ];
  if (waiting.isEmpty) return const SizedBox.shrink();
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text('Commandes client à envoyer en cuisine', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
      const Text('Payées ou non : la cuisine ne les voit qu’après validation caisse.', style: TextStyle(color: NdjoColors.muted, fontSize: 12)),
      const SizedBox(height: 8),
      ...waiting.map((order) {
        final shortage = orderShortageMessage(order);
        return Card(
          color: shortage.isEmpty ? null : const Color(0xFFFFEBEE),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${order['number']} · ${orderPayLabel(order)}', style: const TextStyle(fontWeight: FontWeight.w800)),
                Text('${order['type']} · ${order['customerName'] ?? order['user']?['name'] ?? ''}'),
                if (orderItemsLine(order).isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(orderItemsLine(order), style: const TextStyle(color: NdjoColors.muted)),
                  ),
                if (shortage.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(shortage, style: const TextStyle(color: Color(0xFFB71C1C), fontWeight: FontWeight.w700)),
                  ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  alignment: WrapAlignment.end,
                  children: [
                    if (onTicket != null)
                      OutlinedButton(
                        onPressed: () => onTicket(order),
                        child: const Text('Ticket'),
                      ),
                    FilledButton(
                      onPressed: () => onSend(order['id'].toString()),
                      style: FilledButton.styleFrom(backgroundColor: NdjoColors.primary),
                      child: const Text('Envoyer à la cuisine'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      }),
      const SizedBox(height: 16),
    ],
  );
}

Widget cashierReadyPickup({required List<dynamic> orders}) {
  final ready = [
    for (final item in orders)
      if (item is Map && item['status']?.toString() == 'PRETE') Map<String, dynamic>.from(item),
  ];
  if (ready.isEmpty) return const SizedBox.shrink();
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text('Prêtes — après cuisine', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
      const Text(
        'Sur place / à emporter : remettre au client ici. Livraison : onglet Livraisons → Affecter un livreur.',
        style: TextStyle(color: NdjoColors.muted, fontSize: 12),
      ),
      const SizedBox(height: 8),
      ...ready.map((order) {
        final delivery = order['type']?.toString() == 'LIVRAISON';
        return Card(
          child: ListTile(
            title: Text('${order['number']} · ${delivery ? 'Livraison' : 'À remettre'}'),
            subtitle: Text(
              '${order['customerName'] ?? order['user']?['name'] ?? ''} · ${orderItemsLine(order)}',
            ),
            trailing: Text(delivery ? '→ Livraisons' : 'Caisse'),
          ),
        );
      }),
      const SizedBox(height: 16),
    ],
  );
}

num _menuNum(dynamic value) {
  if (value is num) return value;
  return num.tryParse(value?.toString() ?? '') ?? 0;
}

List<Map<String, dynamic>> menuComposition(Map<String, dynamic> product) {
  final direct = product['composition'];
  if (direct is List && direct.isNotEmpty) {
    return [for (final item in direct) if (item is Map) Map<String, dynamic>.from(item)];
  }
  final recipe = product['recipe'];
  final items = recipe is Map ? recipe['items'] : null;
  if (items is List && items.isNotEmpty) {
    return [for (final item in items) if (item is Map) Map<String, dynamic>.from(item)];
  }
  return [];
}

String menuLineText(Map<String, dynamic> line) {
  final ingredient = line['ingredient'];
  final name = line['name']?.toString() ??
      (ingredient is Map ? ingredient['name']?.toString() : null) ??
      '';
  if (line['line'] != null) return line['line'].toString();
  if (line['displayQty'] != null) return '${line['displayQty']} $name'.trim();
  final qty = line['qtyShown'] ?? line['quantity'];
  final unit = line['unitShown']?.toString() ?? line['unit']?.toString() ?? '';
  return '${qty ?? ''} $unit $name'.trim();
}

Future<bool?> showMenuDetailSheet(
  BuildContext context,
  Map<String, dynamic> product, {
  String action = 'Ajouter au panier',
}) {
  final composition = menuComposition(product);
  final photo = product['photoUrl']?.toString() ?? '';
  final description = product['description']?.toString() ?? '';
  final category = product['category'] is Map ? product['category']['name']?.toString() : product['category']?.toString();
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: NdjoColors.surface,
    builder: (context) {
      final height = MediaQuery.sizeOf(context).height;
      return SizedBox(
        height: height * 0.92,
        child: Column(
          children: [
            const SizedBox(height: 8),
            Container(
              width: 42,
              height: 4,
              decoration: BoxDecoration(color: NdjoColors.line, borderRadius: BorderRadius.circular(99)),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
                children: [
                  if (photo.isNotEmpty)
                    ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: Image.network(
                        photo,
                        height: 180,
                        width: double.infinity,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                      ),
                    ),
                  const SizedBox(height: 16),
                  Text(product['name']?.toString() ?? '', style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
                  Text(
                    fc(_menuNum(product['priceSell'])),
                    style: const TextStyle(color: NdjoColors.accent, fontSize: 20, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 12),
                  if (description.isNotEmpty) Text(description, style: const TextStyle(height: 1.4)),
                  const SizedBox(height: 16),
                  _menuKv('Catégorie', category ?? '—'),
                  _menuKv('Sous-catégorie', product['subcategory']?.toString() ?? '—'),
                  _menuKv('Format', product['format']?.toString() ?? '—'),
                  _menuKv('Poids / volume', product['volume']?.toString() ?? '—'),
                  _menuKv('Unité', product['unit']?.toString() ?? '—'),
                  if (product['code'] != null) _menuKv('Code', product['code'].toString()),
                  if (composition.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    const Text('Composition', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
                    const SizedBox(height: 8),
                    for (final line in composition)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Text('• ${menuLineText(line)}'),
                      ),
                    if (product['recipeText'] != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(product['recipeText'].toString(), style: const TextStyle(color: NdjoColors.muted, fontSize: 12)),
                      ),
                  ],
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
              child: Row(
                children: [
                  Expanded(child: OutlinedButton(onPressed: () => Navigator.pop(context, false), child: const Text('Fermer'))),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      style: FilledButton.styleFrom(backgroundColor: NdjoColors.primary, padding: const EdgeInsets.symmetric(vertical: 14)),
                      child: Text(action),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    },
  );
}

Widget _menuKv(String label, String value) {
  if (value.isEmpty || value == '—') {
    return const SizedBox.shrink();
  }
  return Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(color: NdjoColors.muted, fontSize: 13)),
        Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
      ],
    ),
  );
}

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key, required this.session});
  final Session session;

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  Map<String, dynamic>? stats;
  List<dynamic> audits = [];
  String? error;

  @override
  void initState() {
    super.initState();
    final pending = widget.session.sync?.pendingSales() ?? [];
    final cached = widget.session.sync?.store.readList('dashboard-${widget.session.establishmentId}') ?? [];
    if (cached.isNotEmpty) {
      stats = Map<String, dynamic>.from(cached.first as Map);
    } else {
      stats = {
        'salesToday': pending.fold<num>(0, (sum, item) => sum + ((item['total'] as num?) ?? 0)),
        'ordersToday': pending.length,
        'stockValue': 0,
        'deliveries': 0,
        'paymentsCash': 0,
        'paymentsMm': 0,
        'paymentsCard': 0,
        'marginToday': 0,
        'rupture': 0,
        'expiring': 0,
        'offline': true,
      };
    }
    _load();
  }

  List<dynamic> notifications = [];

  @override
  void didUpdateWidget(covariant DashboardPage oldWidget) {
    super.didUpdateWidget(oldWidget);
  }

  Future<void> _load() async {
    final pending = widget.session.sync?.pendingSales() ?? [];
    final cached = widget.session.sync?.store.readList('dashboard-${widget.session.establishmentId}') ?? [];
    if (mounted && stats == null) {
      setState(() {
        error = null;
        if (cached.isNotEmpty) {
          stats = Map<String, dynamic>.from(cached.first as Map);
        }
      });
    }
    try {
      final id = widget.session.establishmentId;
      final query = id == null ? '' : '?establishmentId=$id';
      final loaded = await Future.wait([
        widget.session.api.getJson('/admin/dashboard$query'),
        widget.session.api.getList('/admin/audits'),
        widget.session.api.getList('/admin/notifications'),
      ]);
      final nextStats = loaded[0] as Map<String, dynamic>;
      await widget.session.sync?.store.cacheList('dashboard-$id', [nextStats]);
      if (!mounted) return;
      setState(() {
        stats = nextStats;
        audits = loaded[1] as List<dynamic>;
        notifications = loaded[2] as List<dynamic>;
        error = null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        error = null;
        stats ??= {
          'salesToday': pending.fold<num>(0, (sum, item) => sum + ((item['total'] as num?) ?? 0)),
          'ordersToday': pending.length,
          'stockValue': 0,
          'deliveries': 0,
          'paymentsCash': 0,
          'paymentsMm': 0,
          'paymentsCard': 0,
          'marginToday': 0,
          'rupture': 0,
          'expiring': 0,
          'offline': true,
        };
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final pending = widget.session.sync?.pendingSales() ?? [];
    if (stats == null) return const Center(child: CircularProgressIndicator());
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const Text('Tableau de bord', style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
        const SizedBox(height: 6),
        Text('Établissement : ${widget.session.establishment?['name'] ?? 'Tous'}', style: const TextStyle(color: NdjoColors.muted)),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: NdjoRefreshButton(session: widget.session),
        ),
        if (stats!['offline'] == true || pending.isNotEmpty) ...[
          const SizedBox(height: 12),
          Card(
            child: ListTile(
              leading: Icon(stats!['offline'] == true && pending.isEmpty ? Icons.cloud_off : Icons.sync),
              title: Text(
                pending.isEmpty
                    ? 'Serveur momentanément injoignable'
                    : '${pending.length} opération(s) en cours de synchronisation',
              ),
              subtitle: Text(
                pending.isEmpty
                    ? 'API indisponible. Données locales affichées.'
                    : (widget.session.sync?.lastPendingError ??
                        'Connexion détectée : envoi immédiat au serveur.'),
              ),
            ),
          ),
        ],
        const SizedBox(height: 20),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            _StatCard(label: 'Ventes', value: fc(stats!['salesToday'] ?? 0), icon: Icons.payments),
            _StatCard(label: 'Dépense produits', value: fc(stats!['productExpenseToday'] ?? stats!['materialCostToday'] ?? 0), icon: Icons.shopping_bag_outlined),
            _StatCard(label: 'Bénéfice jour', value: fc(stats!['profitToday'] ?? stats!['marginToday'] ?? 0), icon: Icons.trending_up),
            _StatCard(label: 'Commandes', value: '${stats!['ordersToday'] ?? 0}', icon: Icons.receipt_long),
            _StatCard(label: 'Valeur stock', value: fc(stats!['stockValue'] ?? 0), icon: Icons.inventory_2),
            _StatCard(label: 'Transferts jour', value: '${stats!['transfersCountToday'] ?? 0}', icon: Icons.swap_horiz),
            _StatCard(label: 'Transferts sortis', value: fc(stats!['transferValueOutToday'] ?? 0), icon: Icons.outbox_outlined),
            _StatCard(label: 'Transferts reçus', value: fc(stats!['transferValueInToday'] ?? 0), icon: Icons.move_to_inbox_outlined),
            _StatCard(label: 'À réceptionner', value: '${stats!['transfersPendingReceive'] ?? 0}', icon: Icons.hourglass_top),
            _StatCard(label: 'Sorties → cuisine', value: fc(stats!['kitchenExtraCostToday'] ?? 0), icon: Icons.restaurant),
            _StatCard(label: 'Livraisons', value: '${stats!['deliveries'] ?? 0}', icon: Icons.delivery_dining),
            _StatCard(label: 'Espèces', value: fc(stats!['paymentsCash'] ?? 0), icon: Icons.payments_outlined),
            _StatCard(label: 'Mobile Money', value: fc(stats!['paymentsMm'] ?? 0), icon: Icons.phone_android),
            _StatCard(label: 'Carte', value: fc(stats!['paymentsCard'] ?? 0), icon: Icons.credit_card),
          ],
        ),
        const SizedBox(height: 16),
        Card(
          child: ListTile(
            leading: const Icon(Icons.warning_amber, color: NdjoColors.accent),
            title: const Text('Alertes cahier des charges'),
            subtitle: Text(
              '${stats!['rupture'] ?? 0} produits en rupture\n'
              '${stats!['expiring'] ?? 0} produits proches péremption\n'
              '${stats!['transfersPendingReceive'] ?? 0} transfert(s) en attente de réception',
            ),
          ),
        ),
        const SizedBox(height: 28),
        const Text('Messages WhatsApp (journal)', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        if (notifications.isEmpty)
          const Text('Aucun message pour l’instant. Une vente ou une commande client en crée un.', style: TextStyle(color: NdjoColors.muted))
        else
          ...notifications.take(8).map((item) {
            final map = item as Map<String, dynamic>;
            return Card(
              child: ListTile(
                leading: const Icon(Icons.chat, color: NdjoColors.success),
                title: Text(map['title']?.toString() ?? 'WhatsApp'),
                subtitle: Text('${map['status'] ?? ''} · ${map['message']} · ${map['order']?['number'] ?? ''}${map['error'] != null ? '\n${map['error']}' : ''}'),
              ),
            );
          }),
        const SizedBox(height: 28),
        const Text('Journal d’audit', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        const SizedBox(height: 12),
        ...audits.map((item) {
          final map = item as Map<String, dynamic>;
          return Card(
            child: ListTile(
              title: Text(map['details']?.toString() ?? ''),
              subtitle: Text('${map['user']?['name'] ?? 'Système'} · ${map['action']} · ${map['entity']}'),
            ),
          );
        }),
      ],
    );
  }
}

class UpdatesPage extends StatefulWidget {
  const UpdatesPage({super.key, required this.session});
  final Session session;

  @override
  State<UpdatesPage> createState() => _UpdatesPageState();
}

class _UpdatesPageState extends State<UpdatesPage> {
  List<dynamic> versions = [];
  List<dynamic> publications = [];
  List<dynamic> devices = [];
  String? error;
  bool loading = true;

  String get _id => widget.session.establishmentId ?? '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => loading = true);
    try {
      final loaded = await Future.wait([
        widget.session.api.getList('/admin/app-versions'),
        widget.session.api.getList('/admin/publications?establishmentId=$_id'),
        widget.session.api.getList('/admin/deployments?establishmentId=$_id'),
      ]);
      setState(() {
        versions = loaded[0];
        publications = loaded[1];
        devices = loaded[2];
        error = null;
        loading = false;
      });
    } catch (_) {
      setState(() {
        error = null;
        loading = false;
      });
    }
  }

  Future<void> _createVersion() async {
    final version = TextEditingController(text: '1.1.0');
    final build = TextEditingController(text: '2');
    final notes = TextEditingController(text: 'Correctifs caisse et catalogue en ligne.');
    var force = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: const Text('Nouvelle version APK / app'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: version, decoration: const InputDecoration(labelText: 'Version')),
              const SizedBox(height: 8),
              TextField(controller: build, decoration: const InputDecoration(labelText: 'Build')),
              const SizedBox(height: 8),
              TextField(controller: notes, decoration: const InputDecoration(labelText: 'Notes')),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Mise à jour forcée'),
                value: force,
                onChanged: (value) => setLocal(() => force = value),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuler')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Publier')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    await widget.session.api.post('/admin/app-versions', {
      'version': version.text,
      'buildNumber': int.parse(build.text),
      'platform': 'web',
      'notes': notes.text,
      'minBuild': int.parse(build.text),
      'forceUpdate': force,
      'publish': true,
    });
    await _load();
  }

  Future<void> _rollback(String id) async {
    await widget.session.api.post('/admin/publications/$id/rollback');
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    if (loading && versions.isEmpty && publications.isEmpty) return const Center(child: CircularProgressIndicator());
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Row(
          children: [
            const Expanded(
              child: Text('Mises à jour en ligne', style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
            ),
            FilledButton.icon(
              onPressed: _createVersion,
              icon: const Icon(Icons.upload),
              label: const Text('Publier une version'),
              style: FilledButton.styleFrom(backgroundColor: NdjoColors.primary),
            ),
          ],
        ),
        const SizedBox(height: 20),
        const Text('Versions application', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        ...versions.map((item) {
          final map = item as Map<String, dynamic>;
          return Card(
            child: ListTile(
              leading: const Icon(Icons.phone_android, color: NdjoColors.primary),
              title: Text('v${map['version']}  ·  build ${map['buildNumber']}'),
              subtitle: Text('${map['status']} · ${map['notes'] ?? ''}'),
              trailing: map['forceUpdate'] == true
                  ? const Chip(label: Text('FORCÉE'), backgroundColor: NdjoColors.danger)
                  : Chip(label: Text('${map['platform']}')),
            ),
          );
        }),
        const SizedBox(height: 20),
        const Text('Publications catalogue', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        ...publications.map((item) {
          final map = item as Map<String, dynamic>;
          return Card(
            child: ListTile(
              title: Text('${map['code']} · ${map['status']}'),
              subtitle: Text('par ${map['author']?['name'] ?? ''}'),
              trailing: map['status'] == 'PUBLIEE'
                  ? TextButton(onPressed: () => _rollback(map['id'].toString()), child: const Text('Rollback'))
                  : null,
            ),
          );
        }),
        const SizedBox(height: 20),
        const Text('Appareils', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        ...devices.map((item) {
          final map = item as Map<String, dynamic>;
          final pending = map['status'] == 'EN_ATTENTE';
          return Card(
            child: ListTile(
              title: Text(map['deviceName'].toString()),
              subtitle: Text('${map['role']} · build ${map['appBuild']}'),
              trailing: Text(
                pending ? 'En attente de MAJ' : 'À jour',
                style: TextStyle(color: pending ? NdjoColors.accent : NdjoColors.success),
              ),
            ),
          );
        }),
      ],
    );
  }
}

class ConfigPage extends StatefulWidget {
  const ConfigPage({super.key, required this.session});
  final Session session;

  @override
  State<ConfigPage> createState() => _ConfigPageState();
}

class _ConfigPageState extends State<ConfigPage> {
  Map<String, dynamic> values = {};
  final controllers = <String, TextEditingController>{};
  late final lanServer = TextEditingController(text: Api.baseUrl);
  bool loading = true;
  String? error;
  String? lanHint;

  static const labels = {
    'commandes_en_ligne_ouvertes': 'Commandes en ligne ouvertes',
    'livraison_active': 'Livraison active',
    'message_accueil': 'Message d’accueil',
    'frais_livraison_defaut': 'Frais de livraison (FC)',
    'tva_active': 'TVA active',
    'force_update_apk': 'Forcer la mise à jour APK',
    'maintenance_mode': 'Mode maintenance',
    'whatsapp_actif': 'WhatsApp actif',
  };

  String get _id => widget.session.establishmentId ?? '';

  @override
  void initState() {
    super.initState();
    _load();
    _loadLan();
  }

  @override
  void dispose() {
    lanServer.dispose();
    super.dispose();
  }

  Future<void> _loadLan() async {
    try {
      final lan = await widget.session.api.getJson('/lan');
      final urls = (lan['appUrls'] as List<dynamic>? ?? []).join('  ·  ');
      if (!mounted) return;
      setState(() => lanHint = urls.isEmpty ? null : urls);
    } catch (_) {}
  }

  Future<void> _saveLan() async {
    await Api.setBase(lanServer.text);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Serveur LAN : ${Api.baseUrl}')),
    );
  }

  Future<void> _load() async {
    try {
      final loaded = await widget.session.api.getJson('/admin/remote-config?establishmentId=$_id');
      controllers.clear();
      for (final entry in loaded.entries) {
        controllers[entry.key] = TextEditingController(text: '${entry.value}');
      }
      setState(() {
        values = loaded;
        loading = false;
      });
    } catch (_) {
      setState(() {
        error = null;
        loading = false;
      });
    }
  }

  Future<void> _save() async {
    final payload = {
      for (final entry in controllers.entries) entry.key: entry.value.text,
    };
    await widget.session.api.put('/admin/remote-config', {
      'establishmentId': _id,
      'values': payload,
    });
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Configuration publiée sur tous les appareils.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (loading && values.isEmpty) return const Center(child: CircularProgressIndicator());
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Row(
          children: [
            const Expanded(
              child: Text('Configuration distante', style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
            ),
            FilledButton(
              onPressed: _save,
              style: FilledButton.styleFrom(backgroundColor: NdjoColors.primary),
              child: const Text('Publier la config'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        const Text('Ces valeurs s’appliquent sans réinstaller l’application.', style: TextStyle(color: NdjoColors.muted)),
        const SizedBox(height: 20),
        TextField(
          controller: lanServer,
          decoration: const InputDecoration(
            labelText: 'Serveur LAN (caisse, cuisine, dépôt)',
            hintText: 'http://192.168.1.10:3000',
          ),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.tonal(onPressed: _saveLan, child: const Text('Enregistrer le serveur')),
        ),
        if (lanHint != null) ...[
          const SizedBox(height: 8),
          Text('Tablettes : $lanHint', style: const TextStyle(color: NdjoColors.muted)),
        ],
        const SizedBox(height: 20),
        ...controllers.entries.map((entry) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: TextField(
              controller: entry.value,
              decoration: InputDecoration(labelText: labels[entry.key] ?? entry.key),
            ),
          );
        }),
      ],
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({required this.label, required this.value, required this.icon});
  final String label;
  final String value;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 220,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: NdjoColors.primary),
              const SizedBox(height: 12),
              Text(value, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
              Text(label, style: const TextStyle(color: NdjoColors.muted)),
            ],
          ),
        ),
      ),
    );
  }
}

class _ErrorBox extends StatelessWidget {
  const _ErrorBox({required this.error, required this.onRetry});
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
