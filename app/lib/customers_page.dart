import 'package:flutter/material.dart';

import 'pages.dart';
import 'session.dart';
import 'theme.dart';
import 'time_fmt.dart';

class CustomersPage extends StatefulWidget {
  const CustomersPage({super.key, required this.session});
  final Session session;

  @override
  State<CustomersPage> createState() => _CustomersPageState();
}

class _CustomersPageState extends State<CustomersPage> {
  List<dynamic> customers = [];
  List<dynamic> zones = [];
  String? openId;
  String? error;
  bool loading = true;
  String tab = 'clients';
  String query = '';

  String get _id =>
      widget.session.establishmentId ??
      (widget.session.establishments.isNotEmpty ? widget.session.establishments.first['id'].toString() : '');

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant CustomersPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session.establishmentId != widget.session.establishmentId) {
      _load();
    }
  }

  Future<void> _load() async {
    final cachedCustomers = widget.session.peekList('customers-$_id');
    final cachedZones = widget.session.peekList('zones-$_id');
    if (cachedCustomers.isNotEmpty || cachedZones.isNotEmpty) {
      customers = cachedCustomers;
      zones = cachedZones;
      loading = false;
    }
    if (mounted) setState(() => loading = customers.isEmpty && loading);
    try {
      final loaded = await Future.wait([
        widget.session.cachedList('/customers?establishmentId=$_id', 'customers-$_id'),
        widget.session.cachedList('/delivery-zones?establishmentId=$_id', 'zones-$_id'),
      ]);
      setState(() {
        customers = loaded[0].isNotEmpty ? loaded[0] : cachedCustomers;
        zones = loaded[1].isNotEmpty ? loaded[1] : cachedZones;
        error = null;
        loading = false;
      });
    } catch (e) {
      setState(() {
        customers = customers.isEmpty ? cachedCustomers : customers;
        zones = zones.isEmpty ? cachedZones : zones;
        error = null;
        loading = false;
      });
    }
  }

  Map<String, dynamic>? get sheet {
    final match = customers.where((item) => item['id'] == openId);
    return match.isEmpty ? null : Map<String, dynamic>.from(match.first as Map);
  }

  Future<void> _editCustomer([Map<String, dynamic>? current]) async {
    final name = TextEditingController(text: current?['name']?.toString() ?? '');
    final phone = TextEditingController(text: current?['phone']?.toString() ?? '');
    final email = TextEditingController(text: current?['email']?.toString() ?? '');
    final notes = TextEditingController(text: current?['notes']?.toString() ?? '');
    var status = current?['status']?.toString() ?? 'ACTIF';
    var category = current?['category']?.toString() ?? 'STANDARD';
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: Text(current == null ? 'Nouveau client' : 'Modifier le client'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(controller: name, decoration: const InputDecoration(labelText: 'Nom')),
                TextField(controller: phone, decoration: const InputDecoration(labelText: 'Téléphone')),
                TextField(controller: email, decoration: const InputDecoration(labelText: 'E-mail')),
                TextField(controller: notes, decoration: const InputDecoration(labelText: 'Notes')),
                DropdownButtonFormField<String>(
                  initialValue: category,
                  items: const [
                    DropdownMenuItem(value: 'STANDARD', child: Text('Standard (pas de remise)')),
                    DropdownMenuItem(value: 'REUNION', child: Text('Réunion / entreprise (jusqu’à 15%)')),
                    DropdownMenuItem(value: 'PROMOTION', child: Text('Promotion (jusqu’à 25%)')),
                  ],
                  onChanged: (value) => setLocal(() => category = value ?? category),
                  decoration: const InputDecoration(labelText: 'Catégorie tarifaire'),
                ),
                DropdownButtonFormField<String>(
                  initialValue: status,
                  items: const [
                    DropdownMenuItem(value: 'ACTIF', child: Text('Actif')),
                    DropdownMenuItem(value: 'INACTIF', child: Text('Inactif')),
                  ],
                  onChanged: (value) => setLocal(() => status = value ?? status),
                  decoration: const InputDecoration(labelText: 'Statut'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuler')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Enregistrer')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final payload = {
      'establishmentId': _id,
      'name': name.text.trim(),
      'phone': phone.text.trim(),
      'email': email.text.trim(),
      'notes': notes.text.trim(),
      'status': status,
      'category': category,
    };
    if (current == null) {
      await widget.session.api.post('/customers', payload);
    } else {
      await widget.session.api.put('/customers/${current['id']}', payload);
    }
    await _load();
  }

  Future<void> _editAddress(Map<String, dynamic> customer, [Map<String, dynamic>? current]) async {
    final label = TextEditingController(text: current?['label']?.toString() ?? 'Maison');
    final address = TextEditingController(text: current?['address']?.toString() ?? '');
    String? zoneId = current?['zoneId']?.toString() ?? (zones.isNotEmpty ? zones.first['id'].toString() : null);
    var isDefault = current?['isDefault'] == true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: Text(current == null ? 'Nouvelle adresse' : 'Modifier l’adresse'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(controller: label, decoration: const InputDecoration(labelText: 'Libellé (Maison, Travail…)')),
                TextField(controller: address, maxLines: 2, decoration: const InputDecoration(labelText: 'Adresse')),
                DropdownButtonFormField<String>(
                  initialValue: zoneId,
                  items: zones
                      .map((item) => DropdownMenuItem(
                            value: item['id'].toString(),
                            child: Text('${item['name']} · ${fc(item['fee'] as num)}'),
                          ))
                      .toList(),
                  onChanged: (value) => setLocal(() => zoneId = value),
                  decoration: const InputDecoration(labelText: 'Zone de livraison'),
                ),
                SwitchListTile(
                  value: isDefault,
                  onChanged: (value) => setLocal(() => isDefault = value),
                  title: const Text('Adresse par défaut'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuler')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Enregistrer')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final payload = {
      'label': label.text.trim(),
      'address': address.text.trim(),
      'zoneId': zoneId,
      'isDefault': isDefault,
    };
    if (current == null) {
      await widget.session.api.post('/customers/${customer['id']}/addresses', payload);
    } else {
      await widget.session.api.put('/addresses/${current['id']}', payload);
    }
    await _load();
  }

  Future<void> _editZone([Map<String, dynamic>? current]) async {
    final code = TextEditingController(text: current?['code']?.toString() ?? '');
    final name = TextEditingController(text: current?['name']?.toString() ?? '');
    final fee = TextEditingController(text: current?['fee']?.toString() ?? '2000');
    var status = current?['status']?.toString() ?? 'ACTIF';
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: Text(current == null ? 'Nouvelle zone' : 'Modifier la zone'),
          content: SizedBox(
            width: 380,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(controller: code, decoration: const InputDecoration(labelText: 'Code (Z1, Z2…)')),
                TextField(controller: name, decoration: const InputDecoration(labelText: 'Nom (Centre-ville, Kenya…)')),
                TextField(controller: fee, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Frais (FC)')),
                DropdownButtonFormField<String>(
                  initialValue: status,
                  items: const [
                    DropdownMenuItem(value: 'ACTIF', child: Text('Active')),
                    DropdownMenuItem(value: 'INACTIF', child: Text('Inactive')),
                  ],
                  onChanged: (value) => setLocal(() => status = value ?? status),
                  decoration: const InputDecoration(labelText: 'Statut'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuler')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Enregistrer')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final payload = {
      'establishmentId': _id,
      'code': code.text.trim(),
      'name': name.text.trim(),
      'fee': int.tryParse(fee.text) ?? 0,
      'status': status,
    };
    if (current == null) {
      await widget.session.api.post('/delivery-zones', payload);
    } else {
      await widget.session.api.put('/delivery-zones/${current['id']}', payload);
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    if (loading && customers.isEmpty) return const Center(child: CircularProgressIndicator());
    if (error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(error!, style: const TextStyle(color: NdjoColors.danger)),
            TextButton(onPressed: _load, child: const Text('Réessayer')),
          ],
        ),
      );
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
          child: Row(
            children: [
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'clients', label: Text('Clients')),
                  ButtonSegment(value: 'zones', label: Text('Zones de livraison')),
                ],
                selected: {tab},
                onSelectionChanged: (value) => setState(() {
                  tab = value.first;
                  query = '';
                }),
              ),
              const Spacer(),
              FilledButton.icon(
                onPressed: tab == 'clients' ? () => _editCustomer() : () => _editZone(),
                icon: const Icon(Icons.add),
                label: Text(tab == 'clients' ? 'Nouveau client' : 'Nouvelle zone'),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
          child: NdjoSearchBar(
            key: ValueKey('search-$tab'),
            hint: tab == 'clients' ? 'Rechercher un client (nom, téléphone…)' : 'Rechercher une zone…',
            onChanged: (value) => setState(() => query = value),
          ),
        ),
        Expanded(child: tab == 'clients' ? _clientsView() : _zonesView()),
      ],
    );
  }

  Widget _clientsView() {
    final filtered = ndjoFilterList(customers, query);
    return Row(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              const Text('Clients', style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
              const Text('Fiche client + plusieurs adresses. Les frais viennent de la zone, pas d’un montant saisi à la caisse.', style: TextStyle(color: NdjoColors.muted)),
              const SizedBox(height: 16),
              if (filtered.isEmpty)
                const Text('Aucun client trouvé.', style: TextStyle(color: NdjoColors.muted)),
              ...filtered.map((item) {
                final customer = item as Map<String, dynamic>;
                final addresses = customer['addresses'] as List<dynamic>? ?? [];
                return Card(
                  color: customer['id'] == openId ? const Color(0xFF3A2A1C) : null,
                  child: ListTile(
                    title: Text(customer['name'].toString(), style: const TextStyle(fontWeight: FontWeight.w700)),
                    subtitle: Text('${customer['phone']} · ${customer['category'] ?? 'STANDARD'} · ${addresses.length} adresse(s)\n${formatRecordWhen(customer)}'),
                    isThreeLine: true,
                    trailing: Text(customer['status']?.toString() ?? ''),
                    onTap: () => setState(() => openId = customer['id'].toString()),
                    onLongPress: () => _editCustomer(customer),
                  ),
                );
              }),
            ],
          ),
        ),
        const VerticalDivider(width: 1, color: NdjoColors.line),
        SizedBox(
          width: 420,
          child: sheet == null
              ? const Center(child: Text('Sélectionnez un client.', style: TextStyle(color: NdjoColors.muted)))
              : _CustomerSheet(
                  customer: sheet!,
                  onEdit: () => _editCustomer(sheet),
                  onAddAddress: () => _editAddress(sheet!),
                  onEditAddress: (address) => _editAddress(sheet!, address),
                ),
        ),
      ],
    );
  }

  Widget _zonesView() {
    final filtered = ndjoFilterList(zones, query);
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const Text('Zones de livraison', style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
        const Text('Les frais sont appliqués automatiquement à la commande selon la zone de l’adresse.', style: TextStyle(color: NdjoColors.muted)),
        const SizedBox(height: 16),
        if (filtered.isEmpty)
          const Text('Aucune zone trouvée.', style: TextStyle(color: NdjoColors.muted))
        else
          DataTable(
            columns: const [
              DataColumn(label: Text('Code')),
              DataColumn(label: Text('Nom')),
              DataColumn(label: Text('Frais')),
              DataColumn(label: Text('Date')),
              DataColumn(label: Text('Statut')),
              DataColumn(label: Text('')),
            ],
            rows: filtered.map((item) {
              final zone = item as Map<String, dynamic>;
              return DataRow(cells: [
                DataCell(Text(zone['code']?.toString() ?? '')),
                DataCell(Text(zone['name']?.toString() ?? '')),
                DataCell(Text(fc(zone['fee'] as num? ?? 0), style: const TextStyle(color: NdjoColors.accent, fontWeight: FontWeight.bold))),
                DataCell(NdjoWhenText(zone)),
                DataCell(Text(zone['status']?.toString() ?? '')),
                DataCell(IconButton(onPressed: () => _editZone(zone), icon: const Icon(Icons.edit))),
              ]);
            }).toList(),
          ),
      ],
    );
  }
}

class _CustomerSheet extends StatelessWidget {
  const _CustomerSheet({
    required this.customer,
    required this.onEdit,
    required this.onAddAddress,
    required this.onEditAddress,
  });

  final Map<String, dynamic> customer;
  final VoidCallback onEdit;
  final VoidCallback onAddAddress;
  final void Function(Map<String, dynamic> address) onEditAddress;

  @override
  Widget build(BuildContext context) {
    final addresses = (customer['addresses'] as List<dynamic>? ?? []);
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text(customer['name'].toString(), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
        Text('${customer['phone']} · ${customer['email'] ?? 'sans e-mail'}', style: const TextStyle(color: NdjoColors.muted)),
        const SizedBox(height: 8),
        Text('Statut : ${customer['status']}', style: const TextStyle(fontWeight: FontWeight.w600)),
        NdjoWhenText(customer),
        if ((customer['notes']?.toString() ?? '').isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(customer['notes'].toString()),
        ],
        const SizedBox(height: 16),
        Row(
          children: [
            const Expanded(child: Text('Adresses', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800))),
            TextButton(onPressed: onAddAddress, child: const Text('Ajouter')),
          ],
        ),
        if (addresses.isEmpty)
          const Text('Aucune adresse. Ajoutez Maison / Travail / Autre.', style: TextStyle(color: NdjoColors.muted))
        else
          ...addresses.map((item) {
            final address = item as Map<String, dynamic>;
            final zone = address['zone'] as Map<String, dynamic>?;
            return Card(
              child: ListTile(
                title: Text('${address['label']} · ${address['address']}'),
                subtitle: Text(
                  zone == null
                      ? 'Zone non définie — les frais ne pourront pas être calculés'
                      : '${zone['name']} · ${fc(zone['fee'] as num)}',
                ),
                trailing: address['isDefault'] == true ? const Text('Défaut') : NdjoWhenText(address),
                onTap: () => onEditAddress(address),
              ),
            );
          }),
        const SizedBox(height: 16),
        FilledButton(onPressed: onEdit, child: const Text('Modifier la fiche')),
      ],
    );
  }
}
