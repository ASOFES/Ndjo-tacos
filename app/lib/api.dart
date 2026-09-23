import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class Api {
  static const appVersion = '1.0.0';
  static const appBuild = 6;
  static const prefsKey = 'ndjo_api_base';
  static String? _override;

  static String get baseUrl => _override ?? defaultBase();

  static const compiledApiBase = String.fromEnvironment('API_BASE');

  static String defaultBase() {
    if (compiledApiBase.isNotEmpty) return compiledApiBase;
    if (kIsWeb) {
      final host = Uri.base.host;
      if (host.isNotEmpty && host != 'localhost' && host != '127.0.0.1') {
        return 'http://$host:3000';
      }
      return 'http://localhost:3000';
    }
    return 'http://10.0.2.2:3000';
  }

  static String normalize(String raw) {
    var value = raw.trim();
    if (value.isEmpty) return defaultBase();
    if (!RegExp(r'^https?://', caseSensitive: false).hasMatch(value)) {
      if (!value.contains(':')) value = '$value:3000';
      value = 'http://$value';
    }
    if (value.endsWith('/')) value = value.substring(0, value.length - 1);
    return value;
  }

  static String _hostOf(String url) {
    try {
      return Uri.parse(url).host;
    } catch (_) {
      return '';
    }
  }

  static Future<void> restore() async {
    if (compiledApiBase.isNotEmpty) {
      _override = compiledApiBase;
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(prefsKey);
    if (kIsWeb) {
      final host = Uri.base.host;
      if (host.isNotEmpty && host != 'localhost' && host != '127.0.0.1') {
        final current = 'http://$host:3000';
        if (saved == null || saved.isEmpty || _hostOf(saved) != host) {
          _override = current;
          await prefs.setString(prefsKey, current);
          return;
        }
      }
    }
    if (saved != null && saved.isNotEmpty) {
      _override = saved;
    }
  }

  static Future<void> setBase(String raw) async {
    final prefs = await SharedPreferences.getInstance();
    final value = normalize(raw);
    _override = value;
    await prefs.setString(prefsKey, value);
  }

  String? token;
  String? refreshToken;
  Future<bool> Function()? onRefresh;
  Future<bool>? _refreshing;

  Map<String, String> _headers({bool auth = true}) {
    final value = token?.trim();
    return {
      'Content-Type': 'application/json',
      if (auth && value != null && value.isNotEmpty) 'Authorization': 'Bearer $value',
    };
  }

  Future<Map<String, dynamic>> getJson(String path) async {
    final response = await _send(() => http.get(Uri.parse('$baseUrl$path'), headers: _headers()));
    return _decode(response);
  }

  Future<List<dynamic>> getList(String path) async {
    final response = await _send(() => http.get(Uri.parse('$baseUrl$path'), headers: _headers()));
    final decoded = jsonDecode(response.body);
    if (response.statusCode >= 400) {
      throw ApiException(_message(decoded));
    }
    return decoded as List<dynamic>;
  }

  Future<Map<String, dynamic>> post(
    String path, [
    Map<String, dynamic>? body,
    bool skipRefresh = false,
  ]) async {
    final response = await _send(
      () => http.post(
          Uri.parse('$baseUrl$path'),
          headers: _headers(auth: !skipRefresh),
          body: jsonEncode(body ?? {}),
        ),
      skipRefresh: skipRefresh,
      timeout: path.contains('/sync/')
          ? const Duration(seconds: 30)
          : const Duration(seconds: 20),
    );
    return _decode(response);
  }

  Future<Map<String, dynamic>> put(String path, Map<String, dynamic> body) async {
    final response = await _send(() => http.put(
          Uri.parse('$baseUrl$path'),
          headers: _headers(),
          body: jsonEncode(body),
        ));
    return _decode(response);
  }

  Future<Map<String, dynamic>> delete(String path) async {
    final response = await _send(() => http.delete(
          Uri.parse('$baseUrl$path'),
          headers: _headers(),
        ));
    return _decode(response);
  }

  Future<({String name, List<int> bytes, String mime})> getFile(String path) async {
    final response = await _send(
      () => http.get(Uri.parse('$baseUrl$path'), headers: _headers()),
      timeout: const Duration(seconds: 60),
    );
    if (response.statusCode >= 400) {
      try {
        throw ApiException(_message(jsonDecode(response.body)));
      } catch (error) {
        if (error is ApiException) rethrow;
        throw ApiException('Extraction impossible');
      }
    }
    final mime = response.headers['content-type'] ?? 'application/octet-stream';
    final disposition = response.headers['content-disposition'] ?? '';
    final match = RegExp(r'filename="?([^"]+)"?').firstMatch(disposition);
    return (
      name: match?.group(1) ?? 'ndjo-export',
      bytes: response.bodyBytes,
      mime: mime.split(';').first,
    );
  }

  Future<http.Response> _send(
    Future<http.Response> Function() request, {
    bool skipRefresh = false,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    try {
      var response = await request().timeout(timeout);
      if (response.statusCode == 401 && onRefresh != null && !skipRefresh) {
        final ok = await _refreshOnce();
        if (ok) response = await request().timeout(timeout);
      }
      return response;
    } on TimeoutException {
      throw ApiException('Serveur injoignable');
    } catch (error) {
      if (error is ApiException) rethrow;
      throw ApiException('Serveur injoignable');
    }
  }

  Future<bool> _refreshOnce() async {
    final pending = _refreshing;
    if (pending != null) return pending;
    final started = onRefresh!();
    _refreshing = started;
    try {
      return await started;
    } finally {
      if (identical(_refreshing, started)) _refreshing = null;
    }
  }

  Map<String, dynamic> _decode(http.Response response) {
    final decoded = jsonDecode(response.body);
    if (response.statusCode >= 400) {
      throw ApiException(_message(decoded));
    }
    if (decoded is Map<String, dynamic>) return decoded;
    return {'data': decoded};
  }

  String _message(dynamic decoded) {
    if (decoded is Map && decoded['message'] is List) {
      return (decoded['message'] as List).join(', ');
    }
    if (decoded is Map) return decoded['message']?.toString() ?? 'Erreur serveur';
    return 'Erreur serveur';
  }
}

class ApiException implements Exception {
  ApiException(this.message);
  final String message;

  @override
  String toString() => message;
}
