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
  final Map<String, String> _seen = {};
  Timer? _poll;
  bool _primed = false;
  OrderAlert? _alert;

  String get _id => widget.session.establishmentId ?? '';

  @override
  void initState() {
    super.initState();
    NdjoOrderRing.unlock();
    if (!widget.kitchen && !widget.cashier && !widget.driver) return;
    _tick();
    _poll = Timer.periodic(const Duration(seconds: 4), (_) {
      if (mounted) _tick();
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    NdjoOrderRing.stop();
    super.dispose();
  }

  String _fingerprint(Map<String, dynamic> order) {
    final items = order['items'] as List<dynamic>? ?? [];
    final foods = order['kitchenFoods'] as List<dynamic>? ?? [];
    final lines = items.map((item) {
      final map = item is Map ? Map<String, dynamic>.from(item) : <String, dynamic>{};
      return '${map['quantity']}:${map['name']}:${map['unitPrice']}';
    }).join('|');
    return [
      order['id'],
      order['status'],
      order['total'],
      foods.length,
      order['driverId'] ?? '',
      order['address'] ?? '',
      lines,
    ].join('#');
  }

  Future<void> _tick() async {
    if (_id.isEmpty) return;
    try {
      final byId = <String, Map<String, dynamic>>{};
      if (widget.kitchen || widget.cashier) {
        final list = await widget.session.api.getList('/orders?establishmentId=$_id');
        for (final item in list) {
          if (item is! Map) continue;
          final map = Map<String, dynamic>.from(item);
          final id = map['id']?.toString();
          if (id != null) byId[id] = map;
        }
      }
      if (widget.driver) {
        final list = await widget.session.api.getList('/delivery?establishmentId=$_id');
        for (final item in list) {
          if (item is! Map) continue;
          final map = Map<String, dynamic>.from(item);
          final id = map['id']?.toString();
          if (id == null) continue;
          byId[id] = {...?byId[id], ...map};
        }
      }
      if (!mounted) return;
      final orders = byId.values.toList();
      if (!_primed) {
        for (final order in orders) {
          final id = order['id']?.toString();
          if (id == null) continue;
          _seen[id] = _fingerprint(order);
        }
        _primed = true;
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
        _seen[id] = _fingerprint(order);
      }
      if (next != null) _raise(next);
    } catch (_) {}
  }

  OrderAlert? _match(Map<String, dynamic> order) {
    final id = order['id']?.toString();
    if (id == null) return null;
    final status = order['status']?.toString() ?? '';
    if (status == 'ANNULEE') return null;
    final print = _fingerprint(order);
    final previous = _seen[id];
    final changed = previous != print;
    if (!changed) return null;
    final previousParts = previous?.split('#') ?? const <String>[];
    final was = previousParts.length > 1 ? previousParts[1] : '';
    final wasDriver = previousParts.length > 5 ? previousParts[5] : '';
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

    if (widget.driver && me != null && driverId == me) {
      final assignedNow = wasDriver != me;
      if (assignedNow || previous == null) {
        return OrderAlert(
          orderId: id,
          title: 'Course assignée',
          number: number,
          detail: detail,
          kind: 'driver',
        );
      }
      return OrderAlert(
        orderId: id,
        title: 'Mise à jour livraison',
        number: number,
        detail: detail,
        kind: 'driver',
      );
    }

    if (widget.kitchen && (status == 'NOUVELLE' || status == 'EN_PREPARATION')) {
      final fresh = previous == null && status == 'NOUVELLE';
      return OrderAlert(
        orderId: id,
        title: fresh ? 'Nouvelle commande cuisine' : 'Mise à jour cuisine',
        number: number,
        detail: detail,
        kind: 'kitchen',
      );
    }

    if (widget.cashier && status == 'EN_CAISSE') {
      return OrderAlert(
        orderId: id,
        title: previous == null ? 'Nouvelle commande' : 'Mise à jour commande',
        number: number,
        detail: detail,
        kind: 'cashier',
      );
    }

    if (widget.cashier && status == 'PRETE' && (was == 'NOUVELLE' || was == 'EN_PREPARATION')) {
      return OrderAlert(
        orderId: id,
        title: 'Cuisine terminée — retour caisse',
        number: number,
        detail: detail,
        kind: 'cashier',
      );
    }

    if (widget.cashier && status == 'PRETE' && previous != null && was == 'PRETE') {
      return OrderAlert(
        orderId: id,
        title: 'Mise à jour commande',
        number: number,
        detail: detail,
        kind: 'cashier',
      );
    }

    return null;
  }

  void _raise(OrderAlert alert) {
    NdjoOrderRing.start();
    setState(() => _alert = alert);
  }

  void _dismiss({bool open = false}) {
    NdjoOrderRing.stop();
    final kind = _alert?.kind;
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
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => NdjoOrderRing.unlock(),
      child: Stack(
        children: [
          widget.child,
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
