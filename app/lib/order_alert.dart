import 'dart:async';

import 'package:flutter/material.dart';

import 'order_ring.dart';
import 'pages.dart';
import 'session.dart';
import 'theme.dart';

class OrderAlert {
  const OrderAlert({
    required this.orderId,
    required this.title,
    required this.number,
    required this.detail,
    required this.kind,
  });

  final String orderId;
  final String title;
  final String number;
  final String detail;
  final String kind;
}

class OrderAlertHost extends StatefulWidget {
  const OrderAlertHost({
    super.key,
    required this.session,
    required this.child,
    this.kitchen = false,
    this.cashier = false,
    this.driver = false,
    this.onOpenKitchen,
    this.onOpenCashier,
    this.onOpenDriver,
  });

  final Session session;
  final Widget child;
  final bool kitchen;
  final bool cashier;
  final bool driver;
  final VoidCallback? onOpenKitchen;
  final VoidCallback? onOpenCashier;
  final VoidCallback? onOpenDriver;

  @override
  State<OrderAlertHost> createState() => _OrderAlertHostState();
}

class _OrderAlertHostState extends State<OrderAlertHost> {
  final Map<String, String> _statusById = {};
  final Set<String> _acked = {};
  Timer? _poll;
  bool _primed = false;
  bool _busy = false;
  OrderAlert? _alert;
  String? _site;

  String get _id => widget.session.establishmentId ?? '';

  String _ackKey(String orderId, String status) => '$orderId#$status';

  @override
  void initState() {
    super.initState();
    NdjoOrderRing.unlock();
    widget.session.addListener(_onSession);
    if (!widget.kitchen && !widget.cashier && !widget.driver) return;
    _tick();
    _poll = Timer.periodic(const Duration(seconds: 4), (_) {
      if (mounted) _tick();
    });
  }

  void _onSession() {
    final next = _id;
    if (next == _site) return;
    _site = next;
    _primed = false;
    _statusById.clear();
    _acked.clear();
    if (mounted) _tick();
  }

  @override
  void dispose() {
    widget.session.removeListener(_onSession);
    _poll?.cancel();
    NdjoOrderRing.stop();
    super.dispose();
  }

  String _statusOf(Map<String, dynamic> order) => order['status']?.toString() ?? '';

  void _ingest(List<dynamic> list, Map<String, Map<String, dynamic>> byId) {
    for (final item in list) {
      if (item is! Map) continue;
      final map = Map<String, dynamic>.from(item);
      final id = map['id']?.toString();
      if (id == null) continue;
      final prev = byId[id];
      byId[id] = prev == null ? map : {...prev, ...map};
    }
  }

  Future<List<dynamic>> _safeList(String path) async {
    try {
      return await widget.session.api.getList(path);
    } catch (_) {
      return const [];
    }
  }

  Future<void> _tick() async {
    if (_id.isEmpty || _busy) return;
    if (_site != _id) {
      _site = _id;
      _primed = false;
      _statusById.clear();
      _acked.clear();
    }
    _busy = true;
    try {
      final byId = <String, Map<String, dynamic>>{};
      final fetches = <Future<void>>[];
      if (widget.kitchen) {
        fetches.add(_safeList('/orders?establishmentId=$_id&kitchen=1').then((list) => _ingest(list, byId)));
      }
      if (widget.cashier) {
        fetches.add(_safeList('/orders?establishmentId=$_id').then((list) => _ingest(list, byId)));
      }
      if (widget.driver) {
        fetches.add(_safeList('/delivery?establishmentId=$_id').then((list) => _ingest(list, byId)));
      }
      await Future.wait(fetches);
      if (widget.cashier) {
        _ingest(await _safeList('/orders?establishmentId=$_id&inbox=1'), byId);
      }
      if (!mounted) return;
      final orders = byId.values.toList();
      if (!_primed) {
        OrderAlert? waiting;
        for (final order in orders) {
          final id = order['id']?.toString();
          final status = _statusOf(order);
          if (id == null) continue;
          _statusById[id] = status;
          if (widget.cashier && status == 'EN_CAISSE') {
            waiting = _cashierAlert(order, fresh: true);
          }
        }
        _primed = true;
        if (waiting != null) _raise(waiting);
        return;
      }
      OrderAlert? next;
      for (final order in orders) {
        final alert = _match(order);
        if (alert != null) next = alert;
      }
      for (final order in orders) {
        final id = order['id']?.toString();
        if (id == null) continue;
        _statusById[id] = _statusOf(order);
      }
      if (next != null) _raise(next);
    } catch (_) {
    } finally {
      _busy = false;
    }
  }

  OrderAlert _cashierAlert(Map<String, dynamic> order, {required bool fresh}) {
    final shortage = orderShortageMessage(order);
    final who = order['customerName']?.toString() ?? order['user']?['name']?.toString() ?? '';
    final items = orderItemsLine(order);
    final detail = [
      if (shortage.isNotEmpty) shortage,
      if (who.isNotEmpty) who,
      if (items.isNotEmpty) items,
    ].join('\n');
    return OrderAlert(
      orderId: order['id'].toString(),
      title: shortage.isNotEmpty
          ? 'Produit en carence'
          : fresh
              ? 'Nouvelle commande caisse'
              : 'Commande en caisse',
      number: order['number']?.toString() ?? '',
      detail: detail,
      kind: 'cashier',
    );
  }

  OrderAlert? _match(Map<String, dynamic> order) {
    final id = order['id']?.toString();
    if (id == null) return null;
    final status = _statusOf(order);
    if (status == 'ANNULEE' || status == 'LIVREE' || status == 'CLOTUREE' || status == 'PAYEE') {
      return null;
    }
    final was = _statusById[id];
    if (was == status) return null;
    if (_acked.contains(_ackKey(id, status))) return null;

    final number = order['number']?.toString() ?? '';
    final who = order['customerName']?.toString() ?? order['user']?['name']?.toString() ?? '';
    final address = order['address']?.toString() ?? '';
    final items = orderItemsLine(order);
    final me = widget.session.user?['id']?.toString();
    final driverId = order['driverId']?.toString() ?? '';
    final detail = [
      if (who.isNotEmpty) who,
      if (address.isNotEmpty) address,
      if (items.isNotEmpty) items,
    ].join('\n');

    if (widget.driver && me != null && driverId == me && (was == null || was != status || driverId != me)) {
      return OrderAlert(
        orderId: id,
        title: was == null || (was != 'AFFECTEE' && was != 'EN_LIVRAISON') ? 'Course assignée' : 'Mise à jour livraison',
        number: number,
        detail: detail,
        kind: 'driver',
      );
    }

    if (widget.kitchen && status == 'NOUVELLE' && was != 'NOUVELLE') {
      return OrderAlert(
        orderId: id,
        title: 'Nouvelle commande cuisine',
        number: number,
        detail: detail,
        kind: 'kitchen',
      );
    }

    if (widget.cashier && status == 'EN_CAISSE') {
      return _cashierAlert(order, fresh: was == null);
    }

    if (widget.cashier && status == 'PRETE' && was != 'PRETE') {
      return OrderAlert(
        orderId: id,
        title: 'Cuisine terminée — retour caisse',
        number: number,
        detail: detail,
        kind: 'cashier',
      );
    }

    return null;
  }

  void _raise(OrderAlert alert) {
    if (_alert?.orderId == alert.orderId && _alert?.title == alert.title) return;
    if (_acked.contains(_ackKey(alert.orderId, _statusById[alert.orderId] ?? ''))) return;
    NdjoOrderRing.unlock();
    NdjoOrderRing.start();
    setState(() => _alert = alert);
  }

  void _dismiss({bool open = false}) {
    NdjoOrderRing.stop();
    final alert = _alert;
    if (alert != null) {
      final status = _statusById[alert.orderId] ?? '';
      _acked.add(_ackKey(alert.orderId, status));
    }
    final kind = alert?.kind;
    setState(() => _alert = null);
    if (!open) return;
    if (kind == 'kitchen') {
      widget.onOpenKitchen?.call();
    } else if (kind == 'driver') {
      widget.onOpenDriver?.call();
    } else {
      widget.onOpenCashier?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.deferToChild,
      onPointerDown: (_) => NdjoOrderRing.unlock(),
      child: Stack(
        children: [
          RepaintBoundary(child: widget.child),
          if (_alert != null) _banner(_alert!),
        ],
      ),
    );
  }

  Widget _banner(OrderAlert alert) {
    return Positioned.fill(
      child: Material(
        color: const Color(0xCC000000),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Card(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: const BorderSide(color: NdjoColors.primary, width: 2),
              ),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.notifications_active, size: 40, color: NdjoColors.primary),
                    const SizedBox(height: 12),
                    Text(alert.title, textAlign: TextAlign.center, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
                    const SizedBox(height: 6),
                    Text('#${alert.number}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: NdjoColors.accent)),
                    if (alert.detail.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Text(alert.detail, textAlign: TextAlign.center, style: const TextStyle(color: NdjoColors.muted)),
                    ],
                    const SizedBox(height: 20),
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton(
                            onPressed: () => _dismiss(open: true),
                            style: FilledButton.styleFrom(backgroundColor: NdjoColors.primary, padding: const EdgeInsets.symmetric(vertical: 14)),
                            child: const Text('Voir la commande'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        TextButton(
                          onPressed: _dismiss,
                          child: const Text('J’ai vu'),
                        ),
                      ],
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
