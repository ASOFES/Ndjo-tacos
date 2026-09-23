import 'package:flutter/material.dart';

import 'api.dart';
import 'order_alert.dart';
import 'order_ring.dart';
import 'offline/local_store.dart';
import 'offline/sync_service.dart';
import 'offline/web_backup.dart';
import 'catalog_page.dart';
import 'customers_page.dart';
import 'inventory_pages.dart';
import 'purchases_page.dart';
import 'reports_page.dart';
import 'ops_center.dart';
import 'ops_pages.dart';
import 'pages.dart';
import 'permissions_page.dart';
import 'session.dart';
import 'spec_pages.dart';
import 'theme.dart';

final localStore = LocalStore();

String? _readNavMenu(String shell) => loadWebBackup('ndjo_nav_$shell');

void _writeNavMenu(String shell, String menuLabel) {
  saveWebBackup('ndjo_nav_$shell', menuLabel);
}

int _navIndexFor(List<String> labels, String? saved, {int fallback = 0}) {
  if (saved == null || saved.isEmpty) return fallback;
  final i = labels.indexOf(saved);
  return i >= 0 ? i : fallback;
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  localStore.restoreFromDom();
  try {
    await LocalStore.init();
  } catch (_) {}
  await localStore.hydrate();
  final api = Api();
  runApp(NdjoApp(session: Session(api, SyncService(api, localStore))));
}

class NdjoApp extends StatefulWidget {
  const NdjoApp({super.key, required this.session});

  final Session session;

  @override
  State<NdjoApp> createState() => _NdjoAppState();
}

class _NdjoAppState extends State<NdjoApp> {
  late String _shellSig;

  @override
  void initState() {
    super.initState();
    _shellSig = _sig();
    widget.session.addListener(_onSession);
  }

  @override
  void dispose() {
    widget.session.removeListener(_onSession);
    super.dispose();
  }

  String _sig() {
    final s = widget.session;
    return [
      s.ready,
      s.user?['id'],
      s.role,
      s.clientMode,
      s.establishmentId,
      s.selectedEstablishmentId,
      s.appUpdate?['force'],
      s.appUpdate?['updateRequired'],
      s.appUpdate?['updateAvailable'],
    ].join('|');
  }

  void _onSession() {
    final next = _sig();
    if (next == _shellSig) return;
    _shellSig = next;
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'NDJO TACOS',
      debugShowCheckedModeBanner: false,
      theme: ndjoTheme(),
      home: !widget.session.ready
          ? SplashScreen(session: widget.session)
          : _Home(session: widget.session),
    );
  }
}

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key, required this.session});

  final Session session;

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    widget.session.boot();
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('NDJO TACOS', style: TextStyle(fontSize: 32, fontWeight: FontWeight.w800, color: NdjoColors.primary)),
            SizedBox(height: 8),
            Text('Vérification de la version…', style: TextStyle(color: NdjoColors.muted)),
            SizedBox(height: 24),
            CircularProgressIndicator(color: NdjoColors.primary),
          ],
        ),
      ),
    );
  }
}

class _Home extends StatelessWidget {
  const _Home({required this.session});

  final Session session;

  @override
  Widget build(BuildContext context) {
    final update = session.appUpdate;
    final force = update?['force'] == true || update?['updateRequired'] == true;
    if (force && session.user == null) {
      return ForcedUpdateScreen(update: update!);
    }
    if (session.clientMode && session.user == null) {
      return ClientShell(session: session);
    }
    if (session.user == null) {
      return LoginScreen(session: session);
    }
    switch (session.role) {
      case 'CAISSIER':
        return RoleShell(key: ValueKey('caisse-${session.establishmentId}'), session: session, title: 'Caisse', cashierAlerts: true, pages: [
          (Icons.point_of_sale, 'Caisse', PosPage(key: const ValueKey('caisse'), session: session)),
          (Icons.receipt_long, 'Commandes', OrdersPage(key: ValueKey('ord-${session.establishmentId}'), session: session)),
          (Icons.people_outline, 'Clients', CustomersPage(key: ValueKey('cli-${session.establishmentId}'), session: session)),
        ]);
      case 'MAGASINIER':
        return RoleShell(key: ValueKey('stock-${session.establishmentId}'), session: session, title: 'Stock', pages: [
          (Icons.inventory_2_outlined, 'Stock', StockPage(key: ValueKey('stk-${session.establishmentId}'), session: session)),
          (Icons.fact_check_outlined, 'Inventaire', InventoryPage(key: ValueKey('inv-${session.establishmentId}'), session: session)),
          (Icons.report_gmailerrorred_outlined, 'Pertes', LossesPage(key: ValueKey('loss-${session.establishmentId}'), session: session)),
          (Icons.local_shipping_outlined, 'Achats', PurchasesPage(key: ValueKey('ach-${session.establishmentId}'), session: session)),
        ]);
      case 'CUISINIER':
        return RoleShell(key: ValueKey('cuisine-${session.establishmentId}'), session: session, title: 'Cuisine', kitchenAlerts: true, pages: [
          (Icons.soup_kitchen_outlined, 'Cuisine', KitchenPage(key: ValueKey('kit-${session.establishmentId}'), session: session)),
        ]);
      case 'LIVREUR':
        return RoleShell(key: ValueKey('livreur-${session.establishmentId}'), session: session, title: 'Livraison', driverAlerts: true, pages: [
          (Icons.delivery_dining, 'Livraisons', DeliveryPage(key: ValueKey('liv-${session.establishmentId}'), session: session)),
        ]);
      case 'CLIENT':
        return ClientShell(session: session);
      default:
        return AdminShell(key: const ValueKey('admin-shell'), session: session);
    }
  }
}

class ForcedUpdateScreen extends StatelessWidget {
  const ForcedUpdateScreen({super.key, required this.update});

  final Map<String, dynamic> update;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.system_update, size: 48, color: NdjoColors.primary),
                  const SizedBox(height: 16),
                  Text('Nouvelle version ${update['version'] ?? ''}', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  const Text('Cette mise à jour est obligatoire pour continuer.', textAlign: TextAlign.center, style: TextStyle(color: NdjoColors.muted)),
                  if (update['notes'] != null) ...[
                    const SizedBox(height: 12),
                    Text('${update['notes']}', textAlign: TextAlign.center),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.session});

  final Session session;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final username = TextEditingController();
  final password = TextEditingController();
  late final server = TextEditingController(text: Api.baseUrl);
  bool loading = false;
  String? error;

  bool get _publicSite {
    if (Api.compiledApiBase.isNotEmpty) return true;
    final host = Uri.base.host.toLowerCase();
    return host.endsWith('.netlify.app');
  }

  @override
  void dispose() {
    username.dispose();
    password.dispose();
    server.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      loading = true;
      error = null;
    });
    NdjoOrderRing.unlock();
    try {
      if (!_publicSite) {
        await Api.setBase(server.text);
      }
      await widget.session.login(username.text.trim(), password.text);
    } catch (e) {
      setState(() {
        error = e is ApiException ? e.message : 'Connexion impossible. Réessayez.';
      });
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('NDJO TACOS', textAlign: TextAlign.center, style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800, color: NdjoColors.primary)),
                  const SizedBox(height: 6),
                  const Text('Connexion', textAlign: TextAlign.center, style: TextStyle(color: NdjoColors.muted)),
                  const SizedBox(height: 24),
                  if (!_publicSite) ...[
                    TextField(
                      controller: server,
                      decoration: const InputDecoration(
                        labelText: 'Serveur LAN',
                        hintText: 'http://192.168.1.10:3000',
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  TextField(
                    controller: username,
                    autofillHints: const [AutofillHints.username],
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(labelText: 'Nom utilisateur'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: password,
                    obscureText: true,
                    autofillHints: const [AutofillHints.password],
                    textInputAction: TextInputAction.done,
                    decoration: const InputDecoration(labelText: 'Mot de passe'),
                    onSubmitted: (_) => _submit(),
                  ),
                  if (error != null) ...[
                    const SizedBox(height: 12),
                    Text(error!, style: const TextStyle(color: NdjoColors.danger)),
                  ],
                  const SizedBox(height: 20),
                  Semantics(
                    identifier: 'login-submit',
                    button: true,
                    child: FilledButton(
                      onPressed: loading ? null : _submit,
                      style: FilledButton.styleFrom(backgroundColor: NdjoColors.primary, padding: const EdgeInsets.symmetric(vertical: 16)),
                      child: Text(loading ? 'Connexion…' : 'Se connecter'),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextButton(
                    onPressed: widget.session.openClientShop,
                    child: const Text('Commander en tant que client'),
                  ),
                ],
              ),
            ),
          ),
        ),
        ),
      ),
    );
  }
}

class AdminShell extends StatefulWidget {
  const AdminShell({super.key, required this.session});

  final Session session;

  @override
  State<AdminShell> createState() => _AdminShellState();
}

class _AdminShellState extends State<AdminShell> {
  static const _shell = 'admin';
  static const _labels = [
    'Tableau de bord',
    'Rapports',
    'Organisation',
    'Utilisateurs',
    'Permissions',
    'Catalogue',
    'Clients',
    'Recettes',
    'Stock',
    'Inventaire',
    'Pertes',
    'Achats',
    'Caisse',
    'Commandes',
    'Cuisine',
    'Livraisons',
    'Factures',
    'Mises à jour',
    'Paramètres',
    'Synchronisation',
    'Système',
  ];

  late int index;
  String? _aliveEst;
  final Map<int, Widget> _alive = {};

  @override
  void initState() {
    super.initState();
    index = _navIndexFor(_labels, _readNavMenu(_shell));
  }

  void _go(int i) {
    if (i < 0 || i >= _labels.length) return;
    setState(() => index = i);
    _writeNavMenu(_shell, _labels[i]);
  }

  Widget _pageAt(int i) {
    final s = widget.session;
    final est = s.establishmentId;
    switch (i) {
      case 0:
        return DashboardPage(key: ValueKey('dash-$est'), session: s);
      case 1:
        return ReportsPage(key: ValueKey('rep-$est'), session: s);
      case 2:
        return OrganizationPage(key: const ValueKey('org'), session: s);
      case 3:
        return UsersPage(key: const ValueKey('users'), session: s);
      case 4:
        return PermissionsPage(key: const ValueKey('perms'), session: s);
      case 5:
        return CatalogPage(key: ValueKey('cat-$est'), session: s);
      case 6:
        return CustomersPage(key: ValueKey('cli-$est'), session: s);
      case 7:
        return RecipesPage(key: ValueKey('rec-$est'), session: s);
      case 8:
        return StockPage(key: ValueKey('stk-$est'), session: s);
      case 9:
        return InventoryPage(key: ValueKey('inv-$est'), session: s);
      case 10:
        return LossesPage(key: ValueKey('loss-$est'), session: s);
      case 11:
        return PurchasesPage(key: ValueKey('ach-$est'), session: s);
      case 12:
        return PosPage(key: const ValueKey('caisse'), session: s);
      case 13:
        return OrdersPage(key: ValueKey('ord-$est'), session: s);
      case 14:
        return KitchenPage(key: ValueKey('kit-$est'), session: s);
      case 15:
        return DeliveryPage(key: ValueKey('liv-$est'), session: s);
      case 16:
        return InvoicesPage(key: ValueKey('fac-$est'), session: s);
      case 17:
        return UpdatesPage(key: const ValueKey('upd'), session: s);
      case 18:
        return ConfigPage(key: const ValueKey('cfg'), session: s);
      case 19:
        return SyncCenterPage(key: const ValueKey('sync'), session: s);
      default:
        return SystemHealthPage(key: const ValueKey('sys'), session: s);
    }
  }

  Widget _keptPages() {
    final est = widget.session.establishmentId;
    if (_aliveEst != est) {
      _alive
        ..clear()
        ..[index] = _pageAt(index);
      _aliveEst = est;
    } else {
      _alive.putIfAbsent(index, () => _pageAt(index));
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        for (final entry in _alive.entries)
          Offstage(
            offstage: entry.key != index,
            child: TickerMode(
              enabled: entry.key == index,
              child: entry.value,
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    const items = [
      (Icons.dashboard_outlined, 'Tableau de bord'),
      (Icons.assessment_outlined, 'Rapports'),
      (Icons.storefront_outlined, 'Organisation'),
      (Icons.group_outlined, 'Utilisateurs'),
      (Icons.verified_user_outlined, 'Permissions'),
      (Icons.restaurant_menu, 'Catalogue'),
      (Icons.people_outline, 'Clients'),
      (Icons.menu_book, 'Recettes'),
      (Icons.inventory_2_outlined, 'Stock'),
      (Icons.fact_check_outlined, 'Inventaire'),
      (Icons.report_gmailerrorred_outlined, 'Pertes'),
      (Icons.local_shipping_outlined, 'Achats'),
      (Icons.point_of_sale, 'Caisse'),
      (Icons.receipt_long, 'Commandes'),
      (Icons.soup_kitchen_outlined, 'Cuisine'),
      (Icons.delivery_dining, 'Livraisons'),
      (Icons.picture_as_pdf_outlined, 'Factures'),
      (Icons.system_update_alt, 'Mises à jour'),
      (Icons.tune, 'Paramètres'),
      (Icons.sync, 'Synchronisation'),
      (Icons.health_and_safety_outlined, 'Système'),
    ];

    final compact = ndjoCompact(context);
    Widget navList({VoidCallback? onPick}) {
      return ListView.builder(
                itemCount: items.length,
                itemBuilder: (context, i) {
                  final selected = i == index;
                  return Semantics(
                    identifier: 'nav-${items[i].$2}',
                    button: true,
                    child: ListTile(
                    leading: Icon(items[i].$1, color: selected ? NdjoColors.primary : NdjoColors.muted),
                    title: Text(items[i].$2, style: TextStyle(color: selected ? NdjoColors.text : NdjoColors.muted, fontWeight: selected ? FontWeight.w700 : FontWeight.w500)),
                    selected: selected,
                    selectedTileColor: const Color(0xFF3A2A1C),
                    onTap: () {
                      _go(i);
                      onPick?.call();
                    },
                    ),
                  );
                },
              );
    }

    return OrderAlertHost(
      session: widget.session,
      kitchen: true,
      cashier: true,
      onOpenKitchen: () => _go(14),
      onOpenCashier: () => _go(12),
      onOpenDriver: () => _go(15),
      child: Scaffold(
      appBar: AppBar(
        title: Text(compact ? items[index].$2 : 'NDJO TACOS'),
        actions: [
            ListenableBuilder(
              listenable: widget.session,
              builder: (context, _) {
                if (localStore.pendingCount <= 0) return const SizedBox.shrink();
                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Center(child: Text('${localStore.pendingCount} op. en attente', style: const TextStyle(color: NdjoColors.accent, fontSize: 12))),
                );
              },
            ),
            if (!compact)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: DropdownButton<String>(
              value: widget.session.selectedEstablishmentId ?? widget.session.establishmentId,
              underline: const SizedBox.shrink(),
              hint: const Text('Établissement'),
              items: [
                if (widget.session.isAdmin)
                  const DropdownMenuItem(value: 'ALL', child: Text('Tous les établissements')),
                ...widget.session.establishments.map(
                  (item) => DropdownMenuItem(value: item['id'].toString(), child: Text(item['name'].toString())),
                ),
              ],
              onChanged: (value) {
                if (value != null) widget.session.selectEstablishment(value);
              },
            ),
          ),
          if (compact)
            PopupMenuButton<String>(
              icon: const Icon(Icons.storefront_outlined),
              onSelected: widget.session.selectEstablishment,
              itemBuilder: (context) => [
                if (widget.session.isAdmin)
                  const PopupMenuItem(value: 'ALL', child: Text('Tous les établissements')),
                ...widget.session.establishments.map(
                  (item) => PopupMenuItem(value: item['id'].toString(), child: Text(item['name'].toString())),
                ),
              ],
            ),
          IconButton(onPressed: widget.session.logout, icon: const Icon(Icons.logout)),
        ],
      ),
      drawer: compact
          ? Drawer(
              backgroundColor: NdjoColors.surface,
              child: SafeArea(child: navList(onPick: () => Navigator.pop(context))),
            )
          : null,
      body: compact
          ? _keptPages()
          : Row(
        children: [
          SizedBox(
            width: 220,
            child: Material(
              color: NdjoColors.surface,
              child: navList(),
            ),
          ),
          const VerticalDivider(width: 1, color: NdjoColors.line),
          Expanded(child: _keptPages()),
        ],
      ),
    ),
    );
  }
}

class RoleShell extends StatefulWidget {
  const RoleShell({
    super.key,
    required this.session,
    required this.title,
    required this.pages,
    this.kitchenAlerts = false,
    this.cashierAlerts = false,
    this.driverAlerts = false,
  });
  final Session session;
  final String title;
  final List<(IconData, String, Widget)> pages;
  final bool kitchenAlerts;
  final bool cashierAlerts;
  final bool driverAlerts;

  @override
  State<RoleShell> createState() => _RoleShellState();
}

class _RoleShellState extends State<RoleShell> {
  late int index;
  final Map<int, Widget> _alive = {};

  String get _shell => 'role-${widget.title}';

  @override
  void initState() {
    super.initState();
    final labels = widget.pages.map((item) => item.$2).toList();
    index = _navIndexFor(labels, _readNavMenu(_shell));
  }

  void _go(int i) {
    if (i < 0 || i >= widget.pages.length) return;
    setState(() => index = i);
    _writeNavMenu(_shell, widget.pages[i].$2);
  }

  int _pageIndex(String label) {
    final i = widget.pages.indexWhere((item) => item.$2 == label);
    return i >= 0 ? i : 0;
  }

  Widget _keptPages() {
    _alive.putIfAbsent(index, () => widget.pages[index].$3);
    if (widget.pages.length == 1) return _alive[index]!;
    return Stack(
      fit: StackFit.expand,
      children: [
        for (final entry in _alive.entries)
          Offstage(
            offstage: entry.key != index,
            child: TickerMode(
              enabled: entry.key == index,
              child: entry.value,
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final compact = ndjoCompact(context);
    return OrderAlertHost(
      session: widget.session,
      kitchen: widget.kitchenAlerts,
      cashier: widget.cashierAlerts,
      driver: widget.driverAlerts,
      onOpenKitchen: () => _go(_pageIndex('Cuisine')),
      onOpenCashier: () {
        final i = widget.pages.indexWhere((item) => item.$2 == 'Caisse');
        _go(i >= 0 ? i : _pageIndex('Commandes'));
      },
      onOpenDriver: () => _go(_pageIndex('Livraisons')),
      child: Scaffold(
      appBar: AppBar(
        title: Text('${widget.title} — NDJO TACOS'),
        actions: [IconButton(onPressed: widget.session.logout, icon: const Icon(Icons.logout))],
      ),
      body: compact || widget.pages.length == 1
          ? _keptPages()
          : Row(
              children: [
                NavigationRail(
                  selectedIndex: index,
                  onDestinationSelected: _go,
                  labelType: NavigationRailLabelType.all,
                  destinations: widget.pages.map((item) => NavigationRailDestination(icon: Icon(item.$1), label: Text(item.$2))).toList(),
                ),
                const VerticalDivider(width: 1, color: NdjoColors.line),
                Expanded(child: _keptPages()),
              ],
            ),
      bottomNavigationBar: compact && widget.pages.length > 1
          ? NavigationBar(
              selectedIndex: index,
              onDestinationSelected: _go,
              destinations: widget.pages
                  .map((item) => NavigationDestination(icon: Icon(item.$1), label: item.$2))
                  .toList(),
            )
          : null,
    ),
    );
  }
}

class ClientShell extends StatelessWidget {
  const ClientShell({super.key, required this.session});
  final Session session;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('NDJO TACOS'),
        actions: [
          if (session.user != null) IconButton(onPressed: session.logout, icon: const Icon(Icons.logout)),
          if (session.user == null) TextButton(onPressed: session.closeClientShop, child: const Text('Personnel')),
        ],
      ),
      body: ClientShopPage(session: session),
    );
  }
}
