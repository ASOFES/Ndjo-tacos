import 'dart:convert';

import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'web_backup.dart';

class LocalStore {
  static const catalogBox = 'catalog';
  static const lotsBox = 'lots';
  static const kitchenBox = 'kitchen';
  static const queueBox = 'sync_queue';
  static const historyBox = 'sync_history';
  static const metaBox = 'meta';
  static const prefsQueueKey = 'ndjo_sync_queue';
  static const prefsCatalogKey = 'ndjo_catalog';
  static const prefsDbKey = 'ndjo_local_db';

  SharedPreferences? _prefs;
  List<Map<String, dynamic>> _memoryQueue = [];
  List<dynamic> _memoryCatalog = [];
  final Map<String, List<dynamic>> _memoryLists = {};
  final Map<String, Map<String, dynamic>> _memoryMaps = {};
  bool _queueReady = false;

  static Future<void> init() async {
    await Hive.initFlutter();
    await Future.wait([
      Hive.openBox(catalogBox),
      Hive.openBox(lotsBox),
      Hive.openBox(kitchenBox),
      Hive.openBox(queueBox),
      Hive.openBox(historyBox),
      Hive.openBox(metaBox),
    ]);
  }

  void restoreFromDom() {
    final restored = _merge([
      _decodeMaps(loadWebBackup(prefsQueueKey)),
      _decodeMaps(loadWebBackup('flutter.$prefsQueueKey')),
    ]);
    if (restored.isNotEmpty) {
      _memoryQueue = restored;
      _queueReady = true;
    }
    _ingestDb(loadWebBackup(prefsDbKey));
    _ingestDb(loadWebBackup('flutter.$prefsDbKey'));
    final catalogBackup = _decodeList(loadWebBackup(prefsCatalogKey));
    if (catalogBackup.isNotEmpty) _memoryCatalog = catalogBackup;
  }

  Future<void> hydrate() async {
    _prefs = await SharedPreferences.getInstance();
    _memoryQueue = _merge([
      _memoryQueue,
      _decodeMaps(loadWebBackup(prefsQueueKey)),
      _decodeMaps(loadWebBackup('flutter.$prefsQueueKey')),
      _decodeMaps(_prefs?.getString(prefsQueueKey)),
      _readHiveQueue(),
    ]);
    _queueReady = true;

    _memoryCatalog = _decodeList(_prefs?.getString(prefsCatalogKey));
    if (_memoryCatalog.isEmpty) {
      _memoryCatalog = _decodeList(loadWebBackup(prefsCatalogKey));
    }
    if (_memoryCatalog.isEmpty) {
      _memoryCatalog = readAnyCatalog();
    }

    if (_memoryQueue.isNotEmpty) {
      try {
        for (final operation in _memoryQueue) {
          final id = operation['clientUuid'];
          if (id == null) continue;
          await queue.put(id, jsonEncode(operation));
        }
        await queue.flush();
      } catch (_) {}
      await _persistQueue();
    }
    if (_memoryCatalog.isNotEmpty) {
      try {
        await catalog.put('cached', jsonEncode(_memoryCatalog));
        await catalog.flush();
      } catch (_) {}
      await _persistCatalog();
      _memoryLists.putIfAbsent('catalog-cached', () => List<dynamic>.from(_memoryCatalog));
    }
    _ingestDb(_prefs?.getString(prefsDbKey));
    try {
      for (final key in meta.keys) {
        final name = key.toString();
        if (name == 'lastPull' || name.startsWith('map:')) continue;
        final listKey = name.startsWith('list:') ? name.substring(5) : name;
        if (_memoryLists[listKey]?.isNotEmpty == true) continue;
        final hit = _asList(meta.get(key));
        if (hit.isNotEmpty) _memoryLists[listKey] = hit;
      }
      for (final key in meta.keys) {
        final name = key.toString();
        if (!name.startsWith('map:')) continue;
        final mapKey = name.substring(4);
        if (_memoryMaps[mapKey]?.isNotEmpty == true) continue;
        final hit = _asMap(meta.get(key));
        if (hit.isNotEmpty) _memoryMaps[mapKey] = hit;
      }
    } catch (_) {}
    if (_memoryLists.isNotEmpty || _memoryMaps.isNotEmpty) {
      await _persistDb();
    }
  }

  Box get catalog => Hive.box(catalogBox);
  Box get lots => Hive.box(lotsBox);
  Box get kitchen => Hive.box(kitchenBox);
  Box get queue => Hive.box(queueBox);
  Box get history => Hive.box(historyBox);
  Box get meta => Hive.box(metaBox);

  List<Map<String, dynamic>> _merge(List<List<Map<String, dynamic>>> sources) {
    final byId = <String, Map<String, dynamic>>{};
    for (final source in sources) {
      for (final item in source) {
        final id = item['clientUuid']?.toString();
        if (id == null || id.isEmpty) continue;
        byId.putIfAbsent(id, () => item);
      }
    }
    final rows = byId.values.toList();
    rows.sort((a, b) => (a['queuedAt'] ?? '').toString().compareTo((b['queuedAt'] ?? '').toString()));
    return rows;
  }

  List<Map<String, dynamic>> _decodeMaps(String? raw) {
    if (raw == null || raw.isEmpty || raw == '[]') return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return decoded.whereType<Map>().map(_asMap).toList();
    } catch (_) {
      return [];
    }
  }

  List<dynamic> _decodeList(String? raw) {
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      return decoded is List ? decoded : [];
    } catch (_) {
      return [];
    }
  }

  dynamic _unwrap(dynamic value) {
    if (value is String) {
      try {
        return jsonDecode(value);
      } catch (_) {
        return value;
      }
    }
    return value;
  }

  Map<String, dynamic> _asMap(dynamic value) {
    final decoded = _unwrap(value);
    if (decoded is! Map) return {};
    return decoded.map((key, item) => MapEntry(key.toString(), item));
  }

  List<dynamic> _asList(dynamic value) {
    final decoded = _unwrap(value);
    if (decoded is! List) return [];
    return decoded.map((item) => item is Map ? _asMap(item) : item).toList();
  }

  Future<void> _put(Box box, dynamic key, dynamic value) async {
    await box.put(key, jsonEncode(value));
    await box.flush();
  }

  Future<void> _persistQueue() async {
    final queueJson = jsonEncode(_memoryQueue);
    saveWebBackup(prefsQueueKey, queueJson);
    saveWebBackup('flutter.$prefsQueueKey', queueJson);
    final prefs = _prefs ?? await SharedPreferences.getInstance();
    _prefs = prefs;
    await prefs.setString(prefsQueueKey, queueJson);
  }

  Future<void> _persistCatalog() async {
    final catalogJson = jsonEncode(_memoryCatalog);
    saveWebBackup(prefsCatalogKey, catalogJson);
    final prefs = _prefs ?? await SharedPreferences.getInstance();
    _prefs = prefs;
    await prefs.setString(prefsCatalogKey, catalogJson);
  }

  Future<void> cacheCatalog(String establishmentId, List<dynamic> products) async {
    _memoryCatalog = products;
    await _put(catalog, establishmentId.isEmpty ? 'cached' : establishmentId, products);
    await _persistCatalog();
    if (establishmentId.isNotEmpty) {
      await cacheList('catalog-$establishmentId', products);
      await cacheList('catalog-$establishmentId-TOUS', products);
    }
  }

  List<dynamic> readCatalog(String establishmentId) {
    if (establishmentId.isNotEmpty) {
      final hit = _asList(catalog.get(establishmentId));
      if (hit.isNotEmpty) {
        _memoryCatalog = hit;
        return hit;
      }
    }
    final any = readAnyCatalog();
    if (any.isNotEmpty) return any;
    return List<dynamic>.from(_memoryCatalog);
  }

  List<dynamic> readAnyCatalog() {
    for (final key in catalog.keys) {
      final hit = _asList(catalog.get(key));
      if (hit.isNotEmpty) {
        _memoryCatalog = hit;
        return hit;
      }
    }
    return List<dynamic>.from(_memoryCatalog);
  }

  Future<void> cacheLots(String establishmentId, List<dynamic> rows) async {
    await _put(lots, establishmentId, rows);
    if (establishmentId.isNotEmpty) {
      await cacheList('stock-lots-$establishmentId', rows);
    }
  }

  List<dynamic> readLots(String establishmentId) => _asList(lots.get(establishmentId));

  Future<void> cacheKitchen(String establishmentId, List<dynamic> rows) {
    return _put(kitchen, establishmentId, rows);
  }

  List<dynamic> readKitchen(String establishmentId) => _asList(kitchen.get(establishmentId));

  Future<void> _persistDb() async {
    final blob = jsonEncode({'lists': _memoryLists, 'maps': _memoryMaps});
    saveWebBackup(prefsDbKey, blob);
    saveWebBackup('flutter.$prefsDbKey', blob);
    final prefs = _prefs ?? await SharedPreferences.getInstance();
    _prefs = prefs;
    await prefs.setString(prefsDbKey, blob);
  }

  void _ingestDb(String? raw) {
    if (raw == null || raw.isEmpty || raw == '{}') return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      final lists = decoded['lists'];
      if (lists is Map) {
        lists.forEach((key, value) {
          if (value is! List || value.isEmpty) return;
          _memoryLists.putIfAbsent(key.toString(), () => value);
        });
      }
      final maps = decoded['maps'];
      if (maps is Map) {
        maps.forEach((key, value) {
          if (value is! Map || value.isEmpty) return;
          _memoryMaps.putIfAbsent(key.toString(), () => _asMap(value));
        });
      }
    } catch (_) {}
  }

  Future<void> cacheList(String key, List<dynamic> rows) async {
    _memoryLists[key] = rows;
    try {
      await _put(meta, 'list:$key', rows);
      await _put(meta, key, rows);
    } catch (_) {}
    await _persistDb();
  }

  List<dynamic> readList(String key) {
    final memory = _memoryLists[key];
    if (memory != null && memory.isNotEmpty) return List<dynamic>.from(memory);
    try {
      final hit = _asList(meta.get('list:$key'));
      if (hit.isNotEmpty) {
        _memoryLists[key] = hit;
        return hit;
      }
      final legacy = _asList(meta.get(key));
      if (legacy.isNotEmpty) {
        _memoryLists[key] = legacy;
        return legacy;
      }
    } catch (_) {}
    if (key.contains('catalog') || key.contains('ingredient')) {
      return _filterCatalog(allCachedProducts(), key);
    }
    if (key.contains('stock-summary')) {
      return localStockSummary();
    }
    if (key.contains('stock-lots')) {
      final id = key.contains('stock-lots-') ? key.split('stock-lots-').last : '';
      return allCachedLots(id);
    }
    return [];
  }

  List<dynamic> allCachedProducts() {
    final byId = <String, dynamic>{};
    void addAll(List<dynamic> rows) {
      for (final item in rows) {
        if (item is! Map) continue;
        final map = _asMap(item);
        final id = map['id']?.toString();
        if (id == null || id.isEmpty) continue;
        byId.putIfAbsent(id, () => map);
      }
    }

    addAll(_memoryCatalog);
    addAll(readAnyCatalog());
    for (final entry in Map<String, List<dynamic>>.from(_memoryLists).entries) {
      if (entry.key.contains('catalog') || entry.key.contains('ingredient')) {
        addAll(entry.value);
      }
    }
    final list = byId.values.toList();
    list.sort((a, b) {
      final aid = a is Map ? a['id']?.toString() ?? '' : '';
      final bid = b is Map ? b['id']?.toString() ?? '' : '';
      return aid.compareTo(bid);
    });
    return list;
  }

  List<dynamic> _filterCatalog(List<dynamic> rows, String key) {
    if (rows.isEmpty) return rows;
    if (key.contains('INGREDIENT') || key.contains('ingredients')) {
      return rows.where((item) => item is Map && item['kind']?.toString() == 'INGREDIENT').toList();
    }
    if (key.contains('VENTE')) {
      return rows.where((item) => item is Map && item['kind']?.toString() != 'INGREDIENT').toList();
    }
    return rows;
  }

  List<dynamic> allCachedLots([String establishmentId = '']) {
    final byId = <String, Map<String, dynamic>>{};
    void add(dynamic item, [Map<String, dynamic>? product]) {
      if (item is! Map) return;
      final map = _asMap(item);
      if (product != null) {
        map['product'] ??= {'id': product['id'], 'name': product['name']};
        map['number'] ??= map['lotNumber'] ?? map['id'];
      }
      final id = map['id']?.toString() ?? map['number']?.toString();
      if (id == null || id.isEmpty) return;
      byId.putIfAbsent(id, () => map);
    }

    if (establishmentId.isNotEmpty) {
      for (final row in _asList(lots.get(establishmentId))) {
        add(row);
      }
      try {
        for (final row in _asList(meta.get('list:stock-lots-$establishmentId'))) {
          add(row);
        }
        for (final row in _asList(meta.get('stock-lots-$establishmentId'))) {
          add(row);
        }
      } catch (_) {}
    }
    try {
      for (final key in lots.keys) {
        for (final row in _asList(lots.get(key))) {
          add(row);
        }
      }
    } catch (_) {}
    for (final product in allCachedProducts()) {
      if (product is! Map) continue;
      final p = _asMap(product);
      final nested = p['lots'];
      if (nested is List) {
        for (final lot in nested) {
          add(lot, p);
        }
      }
    }
    return byId.values.toList();
  }

  List<dynamic> localStockSummary() {
    final products = allCachedProducts();
    if (products.isEmpty) return [];
    return products.map((item) {
      final map = _asMap(item);
      num qty = map['stockQty'] is num ? map['stockQty'] as num : 0;
      if (map['lots'] is List) {
        final fromLots = (map['lots'] as List).fold<num>(0, (sum, lot) {
          if (lot is! Map) return sum;
          return sum + ((lot['qtyCurrent'] as num?) ?? 0);
        });
        if (fromLots > 0) qty = fromLots;
      }
      final alert = (map['stockAlert'] as num?) ?? 0;
      return {
        ...map,
        'stockQty': qty,
        'stockAlert': alert,
        'lowStock': qty <= alert,
        'unit': map['unit'] ?? '',
        'category': map['category'] is Map ? map['category'] : {'name': map['category']?.toString() ?? ''},
      };
    }).toList();
  }

  Future<void> cacheMap(String key, Map<String, dynamic> data) async {
    _memoryMaps[key] = data;
    try {
      await _put(meta, 'map:$key', data);
    } catch (_) {}
    await _persistDb();
  }

  Map<String, dynamic> readMap(String key) {
    final memory = _memoryMaps[key];
    if (memory != null && memory.isNotEmpty) return Map<String, dynamic>.from(memory);
    try {
      final hit = _asMap(meta.get('map:$key'));
      if (hit.isNotEmpty) {
        _memoryMaps[key] = hit;
        return hit;
      }
    } catch (_) {}
    return {};
  }

  Future<void> patchList(String key, List<dynamic> Function(List<dynamic> rows) update) {
    return cacheList(key, update(readList(key)));
  }

  Future<void> upsertRow(String key, Map<String, dynamic> row, [String idField = 'id']) async {
    final id = row[idField] ?? row['clientUuid'];
    final next = [
      row,
      ...readList(key).where((item) {
        if (item is! Map) return true;
        return item[idField] != id && item['clientUuid'] != id && item['id'] != id;
      }),
    ];
    await cacheList(key, next);
  }

  Map<String, int> snapshotCounts() {
    final counts = <String, int>{};
    _memoryLists.forEach((key, value) {
      if (value.isNotEmpty) counts[key] = value.length;
    });
    try {
      for (final key in meta.keys) {
        final name = key.toString();
        if (name == 'lastPull' || name.startsWith('map:')) continue;
        final listKey = name.startsWith('list:') ? name.substring(5) : name;
        counts.putIfAbsent(listKey, () => _asList(meta.get(key)).length);
      }
    } catch (_) {}
    counts.removeWhere((key, value) => value == 0);
    return counts;
  }

  Future<void> enqueue(Map<String, dynamic> operation) async {
    final row = {
      ...operation,
      'status': operation['status'] ?? 'EN_ATTENTE_SYNC',
      'retries': operation['retries'] ?? 0,
    };
    _queueReady = true;
    _memoryQueue = [
      ...pending().where((item) => item['clientUuid'] != row['clientUuid']),
      row,
    ];
    await _persistQueue();
    try {
      await _put(queue, row['clientUuid'], row);
    } catch (_) {}
  }

  List<Map<String, dynamic>> _readHiveQueue() {
    try {
      final rows = queue.values.map(_asMap).where((item) => item['clientUuid'] != null).toList();
      rows.sort((a, b) => (a['queuedAt'] ?? '').toString().compareTo((b['queuedAt'] ?? '').toString()));
      return rows;
    } catch (_) {
      return [];
    }
  }

  List<Map<String, dynamic>> pending() {
    if (_queueReady) return List<Map<String, dynamic>>.from(_memoryQueue);
    _memoryQueue = _merge([
      _memoryQueue,
      _decodeMaps(loadWebBackup(prefsQueueKey)),
      _decodeMaps(loadWebBackup('flutter.$prefsQueueKey')),
      _decodeMaps(_prefs?.getString(prefsQueueKey)),
      _readHiveQueue(),
    ]);
    _queueReady = true;
    return List<Map<String, dynamic>>.from(_memoryQueue);
  }

  Future<void> markRetry(String clientUuid, String error) async {
    final current = pending().firstWhere(
      (item) => item['clientUuid'] == clientUuid,
      orElse: () => {'clientUuid': clientUuid},
    );
    current['retries'] = (current['retries'] as int? ?? 0) + 1;
    current['error'] = error;
    current['status'] = 'EN_ATTENTE_SYNC';
    _memoryQueue = [
      ...pending().where((item) => item['clientUuid'] != clientUuid),
      current,
    ];
    await _persistQueue();
    try {
      await _put(queue, clientUuid, current);
    } catch (_) {}
  }

  Future<void> archive(String clientUuid, String status, [String? error]) async {
    final current = pending().firstWhere(
      (item) => item['clientUuid'] == clientUuid,
      orElse: () => <String, dynamic>{'clientUuid': clientUuid},
    );
    current['status'] = status;
    current['error'] = error;
    current['syncedAt'] = DateTime.now().toIso8601String();
    try {
      await _put(history, clientUuid, current);
      await queue.delete(clientUuid);
      await queue.flush();
    } catch (_) {}
    _memoryQueue = pending().where((item) => item['clientUuid'] != clientUuid).toList();
    await _persistQueue();
  }

  List<Map<String, dynamic>> historyRows() {
    try {
      final rows = history.values.map(_asMap).toList();
      rows.sort((a, b) => (b['syncedAt'] ?? '').toString().compareTo((a['syncedAt'] ?? '').toString()));
      return rows;
    } catch (_) {
      return [];
    }
  }

  Future<void> remove(String clientUuid) async {
    try {
      await queue.delete(clientUuid);
      await queue.flush();
    } catch (_) {}
    _memoryQueue = pending().where((item) => item['clientUuid'] != clientUuid).toList();
    await _persistQueue();
  }

  Future<void> cachePullTime(String iso) => _put(meta, 'lastPull', iso);

  String? lastPull() {
    try {
      final value = _unwrap(meta.get('lastPull'));
      return value?.toString();
    } catch (_) {
      return null;
    }
  }

  int get pendingCount => pending().length;

  /// Vide catalogue / commandes / file sync de cet appareil (pas le compte serveur).
  Future<void> clearBusinessData() async {
    _memoryQueue = [];
    _memoryCatalog = [];
    _memoryLists.clear();
    _memoryMaps.clear();
    _queueReady = true;
    for (final box in [catalog, lots, kitchen, queue, history, meta]) {
      try {
        await box.clear();
        await box.flush();
      } catch (_) {}
    }
    final prefs = _prefs ?? await SharedPreferences.getInstance();
    _prefs = prefs;
    await prefs.remove(prefsQueueKey);
    await prefs.remove(prefsCatalogKey);
    await prefs.remove(prefsDbKey);
    for (final key in [
      prefsQueueKey,
      'flutter.$prefsQueueKey',
      prefsCatalogKey,
      'flutter.$prefsCatalogKey',
      prefsDbKey,
      'flutter.$prefsDbKey',
    ]) {
      clearWebBackup(key);
    }
    clearAllNdjoWebStorage();
  }
}
