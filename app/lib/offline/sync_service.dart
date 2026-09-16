import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:uuid/uuid.dart';

import '../api.dart';
import 'local_store.dart';

class SyncService {
  SyncService(this.api, this.store);

  final Api api;
  final LocalStore store;
  final _uuid = const Uuid();
  StreamSubscription<List<ConnectivityResult>>? _network;
  Timer? _retry;
  void Function()? onQueueChanged;

  void startWatcher() {
    _network?.cancel();
    _retry?.cancel();
    var skipBootEvent = true;
    _network = Connectivity().onConnectivityChanged.listen((results) async {
      if (skipBootEvent) {
        skipBootEvent = false;
        return;
      }
      if (results.any((item) => item != ConnectivityResult.none)) {
        await flush();
        onQueueChanged?.call();
      }
    });
    _retry = Timer.periodic(const Duration(seconds: 12), (_) async {
      if (store.pendingCount == 0) return;
      final before = store.pendingCount;
      await flush();
      if (store.pendingCount != before) onQueueChanged?.call();
    });
  }

  void dispose() {
    _network?.cancel();
    _retry?.cancel();
  }

  Future<List<dynamic>> products(String establishmentId) async {
    try {
      final list = await api
          .getList('/catalog/products?establishmentId=$establishmentId&kind=VENTE')
          .timeout(const Duration(seconds: 4));
      await store.cacheCatalog(establishmentId, list);
      return list;
    } catch (_) {
      return store.readCatalog(establishmentId);
    }
  }

  Future<List<dynamic>> cachedOrFetch(String path, String cacheKey) async {
    final cached = store.readList(cacheKey);
    try {
      final list = await api.getList(path).timeout(
        Duration(milliseconds: cached.isNotEmpty ? 1800 : 4000),
      );
      if (list.isNotEmpty || cached.isEmpty) {
        await store.cacheList(cacheKey, list);
      }
      return list.isNotEmpty ? list : cached;
    } catch (_) {
      return cached;
    }
  }

  Future<Map<String, dynamic>> cachedOrFetchJson(String path, String cacheKey) async {
    final cached = store.readMap(cacheKey);
    try {
      final data = await api.getJson(path).timeout(
        Duration(milliseconds: cached.isNotEmpty ? 1800 : 4000),
      );
      if (data.isNotEmpty || cached.isEmpty) {
        await store.cacheMap(cacheKey, data);
      }
      return data.isNotEmpty ? data : cached;
    } catch (_) {
      return cached;
    }
  }

  Map<String, dynamic> _localSale(Map<String, dynamic> payload, String clientUuid) {
    final items = (payload['items'] as List<dynamic>? ?? []).map((item) {
      final map = Map<String, dynamic>.from(item as Map);
      return {
        'productId': map['productId'],
        'name': map['name'] ?? map['productId'],
        'quantity': map['quantity'],
        'unitPrice': map['unitPrice'] ?? 0,
        'lineTotal': (map['unitPrice'] ?? 0) * (map['quantity'] ?? 0),
      };
    }).toList();
    return {
      'id': clientUuid,
      'number': 'LOCAL-${clientUuid.substring(0, 6).toUpperCase()}',
      'status': 'EN_ATTENTE_SYNC',
      'paymentStatus': 'EN_ATTENTE',
      'offline': true,
      'clientUuid': clientUuid,
      'type': payload['type'] ?? 'SUR_PLACE',
      'total': payload['total'] ?? 0,
      'items': items,
      'user': {'name': payload['queuedBy'] ?? 'Caisse'},
    };
  }

  Future<Map<String, dynamic>> createOrder(Map<String, dynamic> body) async {
    final clientUuid = body['clientUuid'] as String? ?? _uuid.v4();
    final payload = {...body, 'clientUuid': clientUuid};
    await store.enqueue({
      'clientUuid': clientUuid,
      'type': 'ORDER',
      'payload': payload,
      'queuedAt': DateTime.now().toIso8601String(),
      'status': 'EN_ATTENTE_SYNC',
    });
    final local = _localSale(payload, clientUuid);
    final establishmentId = payload['establishmentId']?.toString() ?? '';
    if (establishmentId.isNotEmpty) {
      await store.upsertRow('orders-$establishmentId', local);
      await store.upsertRow('kitchen-$establishmentId', {...local, 'status': 'NOUVELLE'});
    }
    try {
      final applied = await _pushOne(clientUuid, 'ORDER', payload);
      if (applied != null) return applied;
    } catch (_) {}
    return local;
  }

  Future<Map<String, dynamic>> stockExit(Map<String, dynamic> body) async {
    final result = await _queueThenPush('STOCK_EXIT', body);
    await _recordLocalMovement(body, result, 'SORTIE');
    return result;
  }

  Future<Map<String, dynamic>> stockEntry(Map<String, dynamic> body) async {
    final result = await _queueThenPush('STOCK_ENTRY', body);
    await _recordLocalMovement(body, result, 'ENTREE');
    return result;
  }

  Future<void> _recordLocalMovement(Map<String, dynamic> body, Map<String, dynamic> result, String type) async {
    final id = body['establishmentId']?.toString() ?? '';
    if (id.isEmpty) return;
    await store.upsertRow('stock-mov-$id', {
      'id': result['clientUuid'] ?? result['id'],
      'type': body['type'] ?? type,
      'motif': body['motif'] ?? type,
      'quantity': body['quantity'],
      'productId': body['productId'],
      'offline': result['offline'] == true,
      'createdAt': DateTime.now().toIso8601String(),
    });
  }

  Future<Map<String, dynamic>> kitchenStatus(String orderId, String status, String establishmentId) async {
    final result = await _queueThenPush('KITCHEN_STATUS', {
      'orderId': orderId,
      'status': status,
      'establishmentId': establishmentId,
    });
    await _patchStatus(establishmentId, orderId, status);
    return result;
  }

  Future<Map<String, dynamic>> deliveryEvent(String action, String orderId, String establishmentId, [Map<String, dynamic>? extra]) async {
    final result = await _queueThenPush('DELIVERY_EVENT', {
      'action': action,
      'orderId': orderId,
      'establishmentId': establishmentId,
      ...?extra,
    });
    final status = switch (action) {
      'assign' => 'AFFECTEE',
      'start' => 'EN_LIVRAISON',
      'arrive' => 'EN_LIVRAISON',
      'deliver' => 'LIVREE',
      'collect' => 'LIVREE',
      _ => null,
    };
    if (status != null) {
      await store.patchList('delivery-$establishmentId', (rows) {
        return rows.map((item) {
          if (item is! Map) return item;
          if (item['id']?.toString() != orderId && item['clientUuid']?.toString() != orderId) return item;
          return {...item, 'status': status};
        }).toList();
      });
      await _patchStatus(establishmentId, orderId, status);
    }
    return result;
  }

  Future<void> _patchStatus(String establishmentId, String orderId, String status) async {
    Future<void> patch(String key) {
      return store.patchList(key, (rows) {
        return rows.map((item) {
          if (item is! Map) return item;
          if (item['id']?.toString() != orderId && item['clientUuid']?.toString() != orderId) return item;
          return {...item, 'status': status};
        }).toList();
      });
    }
    await patch('kitchen-$establishmentId');
    await patch('orders-$establishmentId');
  }

  Future<Map<String, dynamic>> _queueThenPush(String type, Map<String, dynamic> payload) async {
    final clientUuid = _uuid.v4();
    await store.enqueue({
      'clientUuid': clientUuid,
      'type': type,
      'payload': payload,
      'queuedAt': DateTime.now().toIso8601String(),
      'status': 'EN_ATTENTE_SYNC',
    });
    try {
      final applied = await _pushOne(clientUuid, type, payload);
      if (applied != null) return applied;
    } on ApiException {
      rethrow;
    } catch (_) {}
    return {
      'offline': true,
      'clientUuid': clientUuid,
      'status': 'EN_ATTENTE_SYNC',
      'number': 'LOCAL-${clientUuid.substring(0, 6).toUpperCase()}',
    };
  }

  Future<Map<String, dynamic>?> _pushOne(String clientUuid, String type, Map<String, dynamic> payload) async {
    final result = await api.post('/sync/push', {
      'operations': [
        {'clientUuid': clientUuid, 'type': type, 'payload': payload},
      ],
    });
    final rows = result['results'] as List<dynamic>? ?? [];
    final first = rows.isNotEmpty ? Map<String, dynamic>.from(rows.first as Map) : null;
    final status = first?['status']?.toString();
    if (status == 'APPLIQUE' || status == 'DEJA_APPLIQUE') {
      await store.archive(clientUuid, status!);
      return {
        'id': first?['id'] ?? clientUuid,
        'number': first?['number'],
        'status': status,
        'clientUuid': clientUuid,
        'offline': false,
      };
    }
    if (status == 'REFUSE') {
      await store.archive(clientUuid, 'REFUSE', first?['error']?.toString());
      throw ApiException(first?['error']?.toString() ?? 'Opération refusée par le serveur');
    }
    if (status == 'ECHEC') {
      await store.markRetry(clientUuid, first?['error']?.toString() ?? 'Échec sync');
      return null;
    }
    return null;
  }

  Future<int> flush() async {
    final pending = store.pending();
    var sent = 0;
    for (final operation in pending) {
      final uuid = operation['clientUuid'] as String;
      if ((operation['retries'] as int? ?? 0) >= 8) {
        await store.markRetry(uuid, operation['error']?.toString() ?? 'Trop de tentatives — file conservée');
        continue;
      }
      try {
        final applied = await _pushOne(
          uuid,
          operation['type'] as String,
          Map<String, dynamic>.from(operation['payload'] as Map),
        );
        if (applied != null) sent++;
      } catch (error) {
        if (error is ApiException) {
          continue;
        }
        await store.markRetry(uuid, error.toString());
        break;
      }
    }
    return sent;
  }

  List<Map<String, dynamic>> pendingSales() {
    return store.pending().where((item) => item['type'] == 'ORDER').map((item) {
      final payload = item['payload'];
      final map = payload is Map ? Map<String, dynamic>.from(payload) : <String, dynamic>{};
      return _localSale(map, item['clientUuid'].toString());
    }).toList();
  }

  Future<void> pull(String establishmentId) async {
    try {
      final since = store.lastPull();
      final query = since == null
          ? '/sync/pull?establishmentId=$establishmentId'
          : '/sync/pull?establishmentId=$establishmentId&since=$since';
      final data = await api.getJson(query);
      final products = data['products'] as List<dynamic>? ?? [];
      if (products.isNotEmpty) {
        await store.cacheCatalog(establishmentId, products);
      }
      final lots = data['lots'] as List<dynamic>? ?? [];
      await store.cacheLots(establishmentId, lots);
      await store.cacheList('stock-lots-$establishmentId', lots);
      final orders = data['orders'] as List<dynamic>? ?? [];
      await store.cacheKitchen(establishmentId, orders);
      await store.cacheList('kitchen-$establishmentId', orders);
      await store.cacheList('orders-$establishmentId', orders);
      final recipes = data['recipes'] as List<dynamic>? ?? [];
      if (recipes.isNotEmpty) {
        await store.cacheList('recipes-$establishmentId', recipes);
      }
      await store.cachePullTime(data['serverTime']?.toString() ?? DateTime.now().toIso8601String());
    } catch (_) {}
    await snapshotExtras(establishmentId);
  }

  Future<void> snapshotExtras(String establishmentId) async {
    final jobs = <(String path, String key)>[
      ('/catalog/products?establishmentId=$establishmentId', 'catalog-$establishmentId-TOUS'),
      ('/catalog/products?establishmentId=$establishmentId&kind=VENTE', 'catalog-$establishmentId-VENTE'),
      ('/catalog/products?establishmentId=$establishmentId&kind=INGREDIENT', 'ingredients-$establishmentId'),
      ('/catalog/categories?establishmentId=$establishmentId', 'categories-$establishmentId'),
      ('/customers?establishmentId=$establishmentId', 'customers-$establishmentId'),
      ('/delivery-zones?establishmentId=$establishmentId', 'zones-$establishmentId'),
      ('/stock/summary?establishmentId=$establishmentId', 'stock-summary-$establishmentId'),
      ('/stock/movements?establishmentId=$establishmentId', 'stock-mov-$establishmentId'),
      ('/stock/transfers?establishmentId=$establishmentId', 'stock-tr-$establishmentId'),
      ('/stock/inventories?establishmentId=$establishmentId', 'inventories-$establishmentId'),
      ('/stock/losses?establishmentId=$establishmentId', 'losses-$establishmentId'),
      ('/delivery?establishmentId=$establishmentId', 'delivery-$establishmentId'),
      ('/delivery/drivers?establishmentId=$establishmentId', 'drivers-$establishmentId'),
      ('/orders/invoices?establishmentId=$establishmentId', 'invoices-$establishmentId'),
      ('/suppliers?establishmentId=$establishmentId', 'suppliers-$establishmentId'),
      ('/purchases?establishmentId=$establishmentId', 'purchases-$establishmentId'),
      ('/users?establishmentId=$establishmentId', 'users-$establishmentId'),
      ('/departments?establishmentId=$establishmentId', 'departments-$establishmentId'),
      ('/establishments', 'establishments'),
    ];
    await Future.wait(jobs.map((job) async {
      try {
        final list = await api.getList(job.$1).timeout(const Duration(seconds: 6));
        await store.cacheList(job.$2, list);
      } catch (_) {}
    }));
    try {
      final dash = await api.getJson('/admin/dashboard?establishmentId=$establishmentId').timeout(const Duration(seconds: 6));
      await store.cacheMap('dashboard-$establishmentId', dash);
      await store.cacheList('dashboard-$establishmentId', [dash]);
    } catch (_) {}
    try {
      final reports = await api.getJson('/reports?period=jour&establishmentId=$establishmentId').timeout(const Duration(seconds: 6));
      await store.cacheMap('reports-jour-$establishmentId', reports);
    } catch (_) {}
    try {
      final permissions = await api.getJson('/permissions').timeout(const Duration(seconds: 6));
      await store.cacheMap('permissions', permissions);
    } catch (_) {}
  }

  Future<void> heartbeat({
    required String establishmentId,
    required String deviceName,
    required String role,
  }) async {
    try {
      await api.post('/admin/ops/heartbeat', {
        'establishmentId': establishmentId,
        'deviceName': deviceName,
        'role': role,
        'appBuild': Api.appBuild,
        'pendingOps': store.pendingCount,
      });
    } catch (_) {}
  }
}
