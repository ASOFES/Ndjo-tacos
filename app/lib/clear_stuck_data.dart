import 'package:flutter/material.dart';

import 'offline/web_backup.dart';
import 'session.dart';
import 'theme.dart';

/// Recharge les données serveur puis la page web (sans vider le cache).
class NdjoRefreshButton extends StatefulWidget {
  const NdjoRefreshButton({
    super.key,
    required this.session,
    this.iconOnly = false,
  });

  final Session session;
  final bool iconOnly;

  @override
  State<NdjoRefreshButton> createState() => _NdjoRefreshButtonState();
}

class _NdjoRefreshButtonState extends State<NdjoRefreshButton> {
  bool busy = false;

  Future<void> _run() async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await widget.session.sync?.flush();
      final id = widget.session.establishmentId;
      if (id != null && id.isNotEmpty) {
        await widget.session.sync?.pull(id);
      }
      widget.session.invalidateData();
      widget.session.refreshUi();
    } catch (_) {}
    reloadAppPage();
  }

  @override
  Widget build(BuildContext context) {
    final icon = busy
        ? const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
          )
        : const Icon(Icons.refresh);
    if (widget.iconOnly) {
      return IconButton(
        onPressed: busy ? null : _run,
        tooltip: 'Actualiser',
        icon: busy
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2, color: NdjoColors.accent),
              )
            : const Icon(Icons.refresh),
      );
    }
    return FilledButton.icon(
      onPressed: busy ? null : _run,
      icon: icon,
      label: Text(busy ? 'Actualisation…' : 'Actualiser'),
      style: FilledButton.styleFrom(backgroundColor: NdjoColors.primary),
    );
  }
}
