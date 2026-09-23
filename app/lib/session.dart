import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'offline/sync_service.dart';

class Session extends ChangeNotifier {
  Session(this.api, [this.sync]);

  final Api api;
  final SyncService? sync;
  /// Bump without rebuilding the app shell — pages listen and refresh silently.
  final ValueNotifier<int> dataRevision = ValueNotifier(0);
  Map<String, dynamic>? user;
  Map<String, dynamic>? establishment;
  Map<String, dynamic>? appUpdate;
  List<dynamic> establishments = [];
  String? selectedEstablishmentId;
  bool ready = false;
  bool clientMode = false;
  Timer? _hb;

  String? get role => user?['role']?.toString();

  String? get establishmentId {
    if (selectedEstablishmentId == 'ALL') return null;
    return selectedEstablishmentId ??
        user?['establishmentId'] as String? ??
        establishment?['id'] as String?;
  }

  bool get isAdmin =>
      const {'SUPER_ADMIN', 'ADMIN', 'GESTIONNAIRE'}.contains(role);

  void invalidateData() {
    dataRevision.value++;
  }

  void _onSyncQueue() {
    notifyListeners();
    invalidateData();
  }

  Future<void> boot() async {
    await Api.restore();
    final prefs = await SharedPreferences.getInstance();
    api.token = prefs.getString('token');
    api.refreshToken = prefs.getString('refreshToken');
    api.onRefresh = _refreshTokens;
    _restoreLocal(prefs);
    appUpdate = {'updateAvailable': false};
    sync?.onQueueChanged = _onSyncQueue;
    sync?.startWatcher();
    ready = true;
    notifyListeners();
    unawaited(_hydrateFromApi(prefs));
    _startHeartbeatLoop();
  }

  Future<void> _hydrateFromApi(SharedPreferences prefs) async {
    try {
      appUpdate = await api.getJson('/updates/app?platform=web&build=${Api.appBuild}');
      notifyListeners();
    } catch (_) {
      appUpdate = {'updateAvailable': false};
    }
    if (api.token == null) return;
    try {
      user = await api.getJson('/auth/me');
      establishment = user?['establishment'] as Map<String, dynamic>?;
      selectedEstablishmentId ??= establishment?['id']?.toString();
      await _loadEstablishments();
      await _persist(prefs);
      await sync?.flush();
      final id = establishmentId;
      if (id != null) await sync?.pull(id);
      await _heartbeat();
      notifyListeners();
    } catch (_) {
      if (user == null) {
        api.token = null;
        await prefs.remove('token');
        notifyListeners();
      }
    }
  }

  Future<void> login(String username, String password) async {
    final result = await api.post('/auth/login', {
      'username': username,
      'password': password,
    });
    api.token = result['token'] as String;
    api.refreshToken = result['refreshToken'] as String?;
    api.onRefresh = _refreshTokens;
    user = result['user'] as Map<String, dynamic>;
    establishment = user?['establishment'] as Map<String, dynamic>?;
    selectedEstablishmentId = establishment?['id']?.toString();
    clientMode = role == 'CLIENT';
    await _loadEstablishments();
    final prefs = await SharedPreferences.getInstance();
    await _persist(prefs);
    await sync?.flush();
    final id = establishmentId;
    if (id != null) await sync?.pull(id);
    await _heartbeat();
    sync?.onQueueChanged = _onSyncQueue;
    sync?.startWatcher();
    _startHeartbeatLoop();
    notifyListeners();
  }

  void _restoreLocal(SharedPreferences prefs) {
    final rawUser = prefs.getString('user');
    if (rawUser != null) {
      user = jsonDecode(rawUser) as Map<String, dynamic>;
    }
    final rawEst = prefs.getString('establishment');
    if (rawEst != null) {
      establishment = jsonDecode(rawEst) as Map<String, dynamic>;
    }
    selectedEstablishmentId = prefs.getString('establishmentId') ?? selectedEstablishmentId;
    final rawPlaces = prefs.getString('establishments');
    if (rawPlaces != null) {
      establishments = jsonDecode(rawPlaces) as List<dynamic>;
    }
    clientMode = role == 'CLIENT';
  }

  Future<void> _persist(SharedPreferences prefs) async {
    if (api.token != null) await prefs.setString('token', api.token!);
    if (api.refreshToken != null) {
      await prefs.setString('refreshToken', api.refreshToken!);
    }
    if (user != null) await prefs.setString('user', jsonEncode(user));
    if (establishment != null) {
      await prefs.setString('establishment', jsonEncode(establishment));
    }
    if (selectedEstablishmentId != null) {
      await prefs.setString('establishmentId', selectedEstablishmentId!);
    }
    await prefs.setString('establishments', jsonEncode(establishments));
  }

  Future<void> _heartbeat() async {
    final id = establishmentId;
    if (id == null || sync == null || api.token == null) return;
    await sync!.heartbeat(
      establishmentId: id,
      deviceName: '${role ?? 'POSTE'}-${user?['username'] ?? 'anon'}',
      role: role ?? 'INCONNU',
    );
  }

  void _startHeartbeatLoop() {
    _hb?.cancel();
    _hb = Timer.periodic(const Duration(seconds: 40), (_) {
      if (user != null) unawaited(_heartbeat());
    });
  }

  Future<void> _loadEstablishments() async {
    try {
      establishments = await api.getList('/establishments');
    } catch (_) {
      try {
        establishments = await api.getList('/public/establishments');
      } catch (_) {
        if (establishments.isEmpty) establishments = [];
      }
    }
  }

  void selectEstablishment(String id) {
    selectedEstablishmentId = id;
    if (id == 'ALL') {
      establishment = {'id': 'ALL', 'name': 'Tous les établissements'};
    } else {
      final match = establishments.where((item) => item['id'] == id);
      if (match.isNotEmpty) {
        establishment = Map<String, dynamic>.from(match.first as Map);
      }
    }
    SharedPreferences.getInstance().then(_persist);
    final eid = establishmentId;
    if (eid != null) unawaited(sync?.pull(eid));
    notifyListeners();
  }

  void refreshUi() => notifyListeners();

  void openClientShop() {
    clientMode = true;
    notifyListeners();
  }

  void closeClientShop() {
    clientMode = false;
    notifyListeners();
  }

  Future<void> logout() async {
    _hb?.cancel();
    _hb = null;
    if (api.refreshToken != null) {
      try {
        await api.post('/auth/logout', {'refreshToken': api.refreshToken});
      } catch (_) {}
    }
    api.token = null;
    api.refreshToken = null;
    user = null;
    establishment = null;
    selectedEstablishmentId = null;
    clientMode = false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('token');
    await prefs.remove('refreshToken');
    await prefs.remove('user');
    await prefs.remove('establishment');
    await prefs.remove('establishmentId');
    notifyListeners();
  }

  Future<List<dynamic>> cachedList(String path, String key) {
    if (sync != null) return sync!.cachedOrFetch(path, key);
    return api.getList(path);
  }

  Future<Map<String, dynamic>> cachedJson(String path, String key) {
    if (sync != null) return sync!.cachedOrFetchJson(path, key);
    return api.getJson(path);
  }

  List<dynamic> peekList(String key) => sync?.store.readList(key) ?? [];

  Map<String, dynamic> peekMap(String key) => sync?.store.readMap(key) ?? {};

  Future<bool> _refreshTokens() async {
    final current = api.refreshToken;
    if (current == null) return false;
    try {
      final result = await api.post('/auth/refresh', {'refreshToken': current}, true);
      api.token = result['token'] as String?;
      api.refreshToken = result['refreshToken'] as String? ?? current;
      final prefs = await SharedPreferences.getInstance();
      await _persist(prefs);
      return api.token != null;
    } catch (_) {
      return false;
    }
  }
}
