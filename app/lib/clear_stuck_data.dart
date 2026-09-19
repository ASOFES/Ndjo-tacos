import 'package:flutter/material.dart';

import 'offline/web_backup.dart';
import 'session.dart';
import 'theme.dart';

/// Bouton unique pour supprimer les données locales bloquées (cache navigateur / Hive).
class NdjoClearStuckDataButton extends StatefulWidget {
  const NdjoClearStuckDataButton({super.key, required this.session});

  final Session session;

  @override
  State<NdjoClearStuckDataButton> createState() => _NdjoClearStuckDataButtonState();
}

class _NdjoClearStuckDataButtonState extends State<NdjoClearStuckDataButton> {
  bool busy = false;

  Future<void> _run() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Supprimer les données bloquées'),
        content: const Text(
          'Efface immédiatement le cache local (commandes LOCAL-, catalogue, stock, file hors ligne) '
          'sur cet appareil, puis recharge la page. La base serveur n’est pas touchée.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuler')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: NdjoColors.danger),
            child: const Text('Supprimer'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => busy = true);
    try {
      await widget.session.sync?.store.clearBusinessData();
      widget.session.refreshUi();
      reloadAppPage();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Données locales supprimées.')),
      );
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FilledButton.icon(
      onPressed: busy ? null : _run,
      icon: busy
          ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
          : const Icon(Icons.delete_forever),
      label: Text(busy ? 'Suppression…' : 'Supprimer données bloquées'),
      style: FilledButton.styleFrom(backgroundColor: NdjoColors.danger),
    );
  }
}
