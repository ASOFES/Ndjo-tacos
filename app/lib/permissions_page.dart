import 'package:flutter/material.dart';

import 'session.dart';
import 'theme.dart';

class PermissionsPage extends StatefulWidget {
  const PermissionsPage({super.key, required this.session});
  final Session session;

  @override
  State<PermissionsPage> createState() => _PermissionsPageState();
}

class _PermissionsPageState extends State<PermissionsPage> {
  Map<String, dynamic>? matrix;
  String selectedRole = 'CAISSIER';
  Set<String> selected = {};
  String? error;
  bool loading = true;
  bool saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final cached = widget.session.peekMap('permissions');
    if (cached.isNotEmpty) {
      matrix = cached;
      loading = false;
    }
    try {
      final data = await widget.session.cachedJson('/permissions', 'permissions');
      final source = data.isNotEmpty ? data : cached;
      final roles = (source['roles'] as List<dynamic>? ?? []);
      final current = roles.cast<Map>().firstWhere(
        (row) => row['role'] == selectedRole,
        orElse: () => roles.isNotEmpty ? roles.first as Map : {'role': selectedRole, 'keys': []},
      );
      setState(() {
        matrix = source.isNotEmpty ? source : matrix;
        selectedRole = current['role']?.toString() ?? selectedRole;
        selected = {...((current['keys'] as List<dynamic>? ?? []).map((item) => item.toString()))};
        loading = false;
        error = null;
      });
    } catch (e) {
      setState(() {
        error = null;
        if (matrix == null) matrix = {'roles': [], 'permissions': []};
        loading = false;
      });
    }
  }

  void _selectRole(String role, List<dynamic> keys, bool locked) {
    setState(() {
      selectedRole = role;
      selected = {...keys.map((item) => item.toString())};
    });
  }

  Future<void> _save() async {
    setState(() => saving = true);
    try {
      await widget.session.api.put('/roles/$selectedRole/permissions', {
        'keys': selected.toList()..sort(),
      });
      await _load();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Permissions $selectedRole enregistrées en base')),
        );
      }
    } catch (e) {
      setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (loading) return const Center(child: CircularProgressIndicator());
    final permissions = (matrix?['permissions'] as List<dynamic>? ?? [])
        .where((item) => item['key'] != '*')
        .toList();
    final roles = matrix?['roles'] as List<dynamic>? ?? [];
    final current = roles.cast<Map>().firstWhere(
      (row) => row['role'] == selectedRole,
      orElse: () => {'locked': false},
    );
    final locked = current['locked'] == true || selectedRole == 'SUPER_ADMIN';

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const Text('Rôles & permissions', style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        const Text(
          'Les droits ne sont plus figés dans le code. Chaque rôle lit Permission / RolePermission en PostgreSQL.',
          style: TextStyle(color: NdjoColors.muted),
        ),
        if (error != null) ...[
          const SizedBox(height: 12),
          Text(error!, style: const TextStyle(color: NdjoColors.danger)),
        ],
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: roles.map((row) {
            final role = row['role'].toString();
            final active = role == selectedRole;
            return FilterChip(
              label: Text(role),
              selected: active,
              onSelected: (_) => _selectRole(
                role,
                row['keys'] as List<dynamic>? ?? [],
                row['locked'] == true,
              ),
            );
          }).toList(),
        ),
        const SizedBox(height: 16),
        if (locked)
          const Text(
            'SUPER_ADMIN conserve l’accès complet (*) et ne peut pas être réduit depuis cet écran.',
            style: TextStyle(color: NdjoColors.muted),
          )
        else
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton(
              onPressed: saving ? null : _save,
              child: Text(saving ? 'Enregistrement…' : 'Enregistrer $selectedRole'),
            ),
          ),
        const SizedBox(height: 16),
        ..._groups(permissions).entries.map((entry) {
          return Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(entry.key, style: const TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 8),
                  ...entry.value.map((item) {
                    final key = item['key'].toString();
                    return CheckboxListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      value: selected.contains('*') || selected.contains(key),
                      onChanged: locked
                          ? null
                          : (value) {
                              setState(() {
                                selected.remove('*');
                                if (value == true) {
                                  selected.add(key);
                                } else {
                                  selected.remove(key);
                                }
                              });
                            },
                      title: Text(item['label']?.toString() ?? key),
                      subtitle: Text(key, style: const TextStyle(color: NdjoColors.muted, fontSize: 12)),
                    );
                  }),
                ],
              ),
            ),
          );
        }),
      ],
    );
  }

  Map<String, List<Map<String, dynamic>>> _groups(List<dynamic> permissions) {
    final grouped = <String, List<Map<String, dynamic>>>{};
    for (final raw in permissions) {
      final item = Map<String, dynamic>.from(raw as Map);
      final key = item['key']?.toString() ?? '';
      final group = key.contains('.') ? key.split('.').first : 'autre';
      grouped.putIfAbsent(group, () => []).add(item);
    }
    return grouped;
  }
}
