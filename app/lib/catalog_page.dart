import 'dart:async';

import 'package:flutter/material.dart';

import 'pages.dart';
import 'session.dart';
import 'theme.dart';

const ndjoPackSizes = [1, 3, 6, 12, 20, 22, 24];

int ndjoPackCount(String? raw) {
  final text = (raw ?? '').trim().toLowerCase();
  if (text.isEmpty || text == 'unitaire' || text == 'vrac') return 1;
  if (RegExp(r'\d+\s*(g|kg|ml|cl|l)\b').hasMatch(text)) return 1;
  final match = RegExp(r'(\d+)').firstMatch(text);
  if (match == null) return 1;
  final count = int.tryParse(match.group(1)!) ?? 1;
  return count < 1 ? 1 : count;
}

String ndjoPackLabel(int count) {
  if (count <= 1) return 'Unitaire';
  return '$count / carton';
}

class CatalogPage extends StatefulWidget {
  const CatalogPage({super.key, required this.session});
  final Session session;

  @override
  State<CatalogPage> createState() => _CatalogPageState();
}

class _CatalogPageState extends State<CatalogPage> {
  List<dynamic> products = [];
  List<dynamic> categories = [];
  List<dynamic> ingredients = [];
  List<dynamic> components = [];
  List<dynamic> published = [];
  String? publishedVersion;
  String? error;
  bool loading = true;
  String kind = 'TOUS';
  String? openId;
  String query = '';
  String _dataFp = '';
  Timer? _poll;
  int _seenRevision = -1;
  bool _loadingRemote = false;

  String get _id =>
      widget.session.establishmentId ??
      (widget.session.establishments.isNotEmpty ? widget.session.establishments.first['id'].toString() : '');

  String _fingerprint(List<dynamic> rows) {
    final maps = rows.whereType<Map>().toList()
      ..sort((a, b) => (a['id']?.toString() ?? '').compareTo(b['id']?.toString() ?? ''));
    final out = StringBuffer();
    for (final item in maps) {
      final composition = item['composition'] as List? ?? item['recipe']?['items'] as List? ?? const [];
      out.write(item['id']);
      out.write(':');
      out.write(item['name']);
      out.write(':');
      out.write(item['code']);
      out.write(':');
      out.write(item['status']);
      out.write(':');
      out.write(item['kind']);
      out.write(':');
      out.write(item['priceBuy']);
      out.write(':');
      out.write(item['priceSell']);
      out.write(':');
      out.write(composition.length);
      out.write(';');
    }
    return out.toString();
  }

  List<dynamic> _stableProducts(List<dynamic> rows) {
    final list = rows
        .where((item) => item is Map && item['status']?.toString() != 'SUPPRIME')
        .toList();
    list.sort((a, b) {
      final am = a as Map;
      final bm = b as Map;
      final byName = (am['name']?.toString() ?? '').toLowerCase().compareTo((bm['name']?.toString() ?? '').toLowerCase());
      if (byName != 0) return byName;
      return (am['id']?.toString() ?? '').compareTo(bm['id']?.toString() ?? '');
    });
    return list;
  }

  @override
  void initState() {
    super.initState();
    _seenRevision = widget.session.dataRevision.value;
    widget.session.dataRevision.addListener(_onDataRevision);
    _poll = Timer.periodic(const Duration(seconds: 45), (_) {
      if (mounted) _load(silent: true);
    });
    _load();
  }

  @override
  void dispose() {
    _poll?.cancel();
    widget.session.dataRevision.removeListener(_onDataRevision);
    super.dispose();
  }

  void _onDataRevision() {
    final next = widget.session.dataRevision.value;
    if (next == _seenRevision) return;
    _seenRevision = next;
    if (mounted) _load(silent: true);
  }

  @override
  void didUpdateWidget(covariant CatalogPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session.establishmentId != widget.session.establishmentId) {
      openId = null;
      _dataFp = '';
      _load();
    }
  }

  Future<void> _load({bool silent = false}) async {
    if (_loadingRemote && silent) return;
    final store = widget.session.sync?.store;
    final kindQuery = kind == 'TOUS' ? '' : '&kind=$kind';
    var local = store?.allCachedProducts() ?? [];
    if (kind == 'VENTE') {
      local = local.where((item) => item is Map && item['kind']?.toString() != 'INGREDIENT').toList();
    } else if (kind == 'INGREDIENT') {
      local = local.where((item) => item is Map && item['kind']?.toString() == 'INGREDIENT').toList();
    }
    local = _stableProducts(local);
    final localCategories = widget.session.peekList('categories-$_id');
    var localIngredients = (store?.allCachedProducts() ?? []).where((item) => item is Map && item['kind']?.toString() == 'INGREDIENT').toList();
    if (localIngredients.isEmpty) localIngredients = widget.session.peekList('ingredients-$_id');
    var localComponents = [
      ...((store?.allCachedProducts() ?? []).where((item) => item is Map && item['status']?.toString() != 'SUPPRIME')),
    ];
    if (localComponents.isEmpty) {
      localComponents = [
        ...local,
        ...localIngredients,
      ];
    }
    if (products.isEmpty && local.isNotEmpty && mounted) {
      final fp = _fingerprint(local);
      setState(() {
        products = local;
        categories = localCategories.isNotEmpty ? localCategories : categories;
        ingredients = localIngredients.isNotEmpty ? localIngredients : ingredients;
        components = localComponents;
        _dataFp = fp;
        loading = false;
        error = null;
      });
    } else if (!silent && mounted && products.isEmpty) {
      setState(() => loading = true);
    }
    _loadingRemote = true;
    try {
      final loaded = await Future.wait([
        widget.session.cachedList('/catalog/products?establishmentId=$_id$kindQuery', 'catalog-$_id-$kind'),
        widget.session.cachedList('/catalog/categories?establishmentId=$_id', 'categories-$_id'),
        widget.session.cachedList('/catalog/products?establishmentId=$_id&kind=INGREDIENT', 'ingredients-$_id'),
        widget.session.cachedList('/catalog/products?establishmentId=$_id', 'catalog-$_id-TOUS'),
      ]);
      Map<String, dynamic> live = widget.session.peekMap('catalog-pub-$_id');
      try {
        live = await widget.session.cachedJson('/updates/catalog?establishmentId=$_id', 'catalog-pub-$_id');
      } catch (_) {}
      if (!mounted) return;
      var next = loaded[0].isNotEmpty ? loaded[0] : local;
      if (next.isEmpty) next = store?.allCachedProducts() ?? [];
      next = _stableProducts(next);
      final allProducts = loaded[3].isNotEmpty
          ? loaded[3]
          : [
              ...next,
              ...loaded[2],
            ];
      final nextCategories = loaded[1].isNotEmpty ? loaded[1] : categories;
      final nextIngredients = loaded[2].isNotEmpty ? loaded[2] : ingredients;
      final nextComponents = allProducts
          .where((item) => item is Map && item['status']?.toString() != 'SUPPRIME')
          .toList();
      final nextPublished = (live['products'] as List<dynamic>?) ?? published;
      final nextVersion = live['version']?.toString() ?? publishedVersion;
      final fp = _fingerprint(next);
      final same = fp == _dataFp &&
          nextCategories.length == categories.length &&
          nextVersion == publishedVersion &&
          !loading;
      if (same) return;
      final stillOpen = openId != null && next.any((item) => item is Map && item['id']?.toString() == openId);
      setState(() {
        products = next;
        categories = nextCategories;
        ingredients = nextIngredients;
        components = nextComponents;
        published = nextPublished;
        publishedVersion = nextVersion;
        _dataFp = fp;
        if (!stillOpen) openId = null;
        error = null;
        loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      if (products.isNotEmpty) {
        if (loading) setState(() => loading = false);
        return;
      }
      final fallback = store?.allCachedProducts() ?? products;
      setState(() {
        products = fallback.isNotEmpty ? fallback : products;
        components = fallback.isNotEmpty ? fallback : components;
        error = null;
        loading = false;
      });
    } finally {
      _loadingRemote = false;
    }
  }

  Future<void> _afterMutation() async {
    widget.session.invalidateData();
    _seenRevision = widget.session.dataRevision.value;
    await _load(silent: true);
  }

  Future<void> _retry() async {
    final id = _id;
    if (id.isNotEmpty) {
      try {
        await widget.session.sync?.pull(id);
      } catch (_) {}
    }
    await _load(silent: products.isNotEmpty);
  }

  Future<void> _publish() async {
    final draft = await widget.session.api.post('/admin/publications', {
      'establishmentId': _id,
      'type': 'CATALOGUE',
    });
    await widget.session.api.post('/admin/publications/${draft['id']}/publish');
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Catalogue ${draft['code']} publié. Les caisses recevront la fiche complète.')),
    );
    await _afterMutation();
  }

  Future<void> _edit([Map<String, dynamic>? current]) async {
    final saved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _ProductSheet(
        session: widget.session,
        establishmentId: _id,
        categories: categories,
        ingredients: ingredients,
        components: components,
        product: current,
      ),
    );
    if (saved == true) await _afterMutation();
  }

  Future<void> _delete(Map<String, dynamic> product) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Supprimer le produit'),
        content: Text(
          'Supprimer « ${product['name']} » (${product['code']}) sur tous les établissements ?\n\n'
          'Le stock de chaque site reste intact : la suppression est refusée s’il reste du stock quelque part.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuler')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: NdjoColors.danger),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Supprimer'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await widget.session.api.delete('/catalog/products/${product['id']}');
      if (!mounted) return;
      setState(() {
        if (openId == product['id']?.toString()) openId = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Produit ${product['code']} supprimé sur tous les établissements.')),
      );
      await _afterMutation();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  Future<void> _deleteComposition(Map<String, dynamic> product) async {
    final id = product['id']?.toString();
    if (id == null || id.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Supprimer la composition'),
        content: Text(
          'Supprimer la composition de « ${product['name']} » sur tous les établissements ?\n\n'
          'Le produit reste au catalogue.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuler')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: NdjoColors.danger),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Supprimer'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await widget.session.api.delete('/recipes/$id');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Composition de ${product['name']} supprimée.')),
      );
      await _afterMutation();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (loading && products.isEmpty) return const Center(child: CircularProgressIndicator());
    if (error != null) return _ErrorBox(error: error!, onRetry: _retry);
    final selected = products.whereType<Map>().map((item) => Map<String, dynamic>.from(item)).where((item) => item['id'] == openId);
    final sheet = selected.isEmpty ? null : selected.first;
    final compact = ndjoCompact(context);

    if (compact && sheet != null) {
      return Column(
        children: [
          Material(
            color: NdjoColors.surface,
            child: ListTile(
              leading: IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () => setState(() => openId = null),
              ),
              title: Text(sheet['name']?.toString() ?? 'Fiche produit'),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(onPressed: () => _edit(sheet), icon: const Icon(Icons.edit), tooltip: 'Modifier'),
                  IconButton(
                    onPressed: () => _delete(sheet),
                    icon: const Icon(Icons.delete_outline, color: NdjoColors.danger),
                    tooltip: 'Supprimer',
                  ),
                ],
              ),
            ),
          ),
          const Divider(height: 1, color: NdjoColors.line),
          Expanded(
            child: _ProductPreview(
              product: sheet,
              onEdit: () => _edit(sheet),
              onEditComposition: () => _edit(sheet),
              onDeleteComposition: () => _deleteComposition(sheet),
              onDelete: () => _delete(sheet),
            ),
          ),
        ],
      );
    }

    final list = ListView(
            padding: const EdgeInsets.all(24),
            children: [
              if (compact)
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Catalogue produits', style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
                    const Text('Fiche + composition partagées sur tous les établissements. Les lots restent locaux (Stock).', style: TextStyle(color: NdjoColors.muted)),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        OutlinedButton.icon(onPressed: () => _edit(), icon: const Icon(Icons.add), label: const Text('Ajouter un produit')),
                        ndjoExportButtons(
                          onExcel: () => downloadNdjoExport(context, widget.session, kind: 'catalog', format: 'xls'),
                          onPdf: () => downloadNdjoExport(context, widget.session, kind: 'catalog', format: 'pdf'),
                        ),
                        FilledButton.icon(
                          onPressed: _publish,
                          icon: const Icon(Icons.publish),
                          label: const Text('Publier'),
                          style: FilledButton.styleFrom(backgroundColor: NdjoColors.primary),
                        ),
                      ],
                    ),
                  ],
                )
              else
              Row(
                children: [
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Catalogue produits', style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
                        Text('Fiche + composition partagées sur tous les établissements. Les lots restent locaux (Stock).', style: TextStyle(color: NdjoColors.muted)),
                      ],
                    ),
                  ),
                  OutlinedButton.icon(onPressed: () => _edit(), icon: const Icon(Icons.add), label: const Text('Ajouter un produit')),
                  const SizedBox(width: 8),
                  ndjoExportButtons(
                    onExcel: () => downloadNdjoExport(context, widget.session, kind: 'catalog', format: 'xls'),
                    onPdf: () => downloadNdjoExport(context, widget.session, kind: 'catalog', format: 'pdf'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: _publish,
                    icon: const Icon(Icons.publish),
                    label: const Text('Publier'),
                    style: FilledButton.styleFrom(backgroundColor: NdjoColors.primary),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (compact)
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    ChoiceChip(label: const Text('Tous'), selected: kind == 'TOUS', onSelected: (_) { setState(() => kind = 'TOUS'); _load(); }),
                    ChoiceChip(label: const Text('Vente'), selected: kind == 'VENTE', onSelected: (_) { setState(() => kind = 'VENTE'); _load(); }),
                    ChoiceChip(label: const Text('Ingrédients'), selected: kind == 'INGREDIENT', onSelected: (_) { setState(() => kind = 'INGREDIENT'); _load(); }),
                  ],
                )
              else
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'TOUS', label: Text('Tous')),
                  ButtonSegment(value: 'VENTE', label: Text('Vente')),
                  ButtonSegment(value: 'INGREDIENT', label: Text('Ingrédients')),
                ],
                selected: {kind},
                onSelectionChanged: (value) {
                  setState(() => kind = value.first);
                  _load();
                },
              ),
              const SizedBox(height: 12),
              NdjoSearchBar(
                hint: 'Rechercher un produit (nom, code, catégorie…)',
                onChanged: (value) => setState(() => query = value),
              ),
              const SizedBox(height: 8),
              Text(
                publishedVersion == null
                    ? 'Aucune publication : les appareils voient encore le brouillon.'
                    : 'Version publiée : $publishedVersion',
                style: const TextStyle(color: NdjoColors.accent),
              ),
              const SizedBox(height: 16),
              Card(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: DataTable(
                    showCheckboxColumn: false,
                    columns: const [
                      DataColumn(label: Text('Code')),
                      DataColumn(label: Text('Nom')),
                      DataColumn(label: Text('Catégorie')),
                      DataColumn(label: Text('Sous-cat.')),
                      DataColumn(label: Text('Format')),
                      DataColumn(label: Text('Volume')),
                      DataColumn(label: Text('Unité')),
                      DataColumn(label: Text('Achat')),
                      DataColumn(label: Text('Vente')),
                      DataColumn(label: Text('Type')),
                      DataColumn(label: Text('Statut')),
                      DataColumn(label: Text('Recette')),
                      DataColumn(label: Text('')),
                    ],
                    rows: ndjoFilterList(products, query).map((item) {
                      final product = Map<String, dynamic>.from(item as Map);
                      final lines = (product['composition'] as List<dynamic>? ?? []).length;
                      final recipeLabel = product['kind'] == 'INGREDIENT'
                          ? 'Matière première'
                          : lines == 0
                              ? 'Aucune'
                              : '$lines ingrédients';
                      return DataRow(
                        key: ValueKey(product['id']?.toString() ?? product['code']?.toString() ?? product['name']),
                        selected: product['id'] == openId,
                        onSelectChanged: (_) => setState(() => openId = product['id'].toString()),
                        cells: [
                          DataCell(Text(product['code']?.toString() ?? '')),
                          DataCell(Text(product['name'].toString(), style: const TextStyle(fontWeight: FontWeight.w700))),
                          DataCell(Text(product['category']?['name']?.toString() ?? '')),
                          DataCell(Text(product['subcategory']?.toString() ?? '—')),
                          DataCell(Text(product['format']?.toString() ?? '—')),
                          DataCell(Text(product['volume']?.toString() ?? '—')),
                          DataCell(Text(product['unit']?.toString() ?? '—')),
                          DataCell(Text(fc(product['priceBuy'] as num? ?? 0))),
                          DataCell(Text(fc(product['priceSell'] as num? ?? 0), style: const TextStyle(color: NdjoColors.accent, fontWeight: FontWeight.bold))),
                          DataCell(Text(product['kind'] == 'INGREDIENT' ? 'Ingrédient' : 'Vente')),
                          DataCell(Text(product['status']?.toString() ?? '')),
                          DataCell(Text(recipeLabel)),
                          DataCell(
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(onPressed: () => _edit(product), icon: const Icon(Icons.edit), tooltip: 'Modifier'),
                                IconButton(
                                  onPressed: () => _delete(product),
                                  icon: const Icon(Icons.delete_outline, color: NdjoColors.danger),
                                  tooltip: 'Supprimer',
                                ),
                              ],
                            ),
                          ),
                        ],
                      );
                    }).toList(),
                  ),
                ),
              ),
              const SizedBox(height: 24),
              const Text('Snapshot publié (caisses / client)', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              if (published.isEmpty)
                const Text('Pas encore de snapshot publié.', style: TextStyle(color: NdjoColors.muted))
              else
                ...published.take(8).map((item) {
                  final product = item as Map<String, dynamic>;
                  return Card(
                    child: ListTile(
                      title: Text('${product['code'] ?? ''} · ${product['name']}'),
                      subtitle: Text('${product['category']?['name'] ?? ''} · ${product['format'] ?? product['unit'] ?? ''}'),
                      trailing: Text(fc(product['priceSell'] as num? ?? 0)),
                    ),
                  );
                }),
            ],
          );

    if (compact) return list;

    return Row(
      children: [
        Expanded(flex: 3, child: list),
        const VerticalDivider(width: 1, color: NdjoColors.line),
        SizedBox(
          width: 420,
          child: sheet == null
              ? const Center(child: Text('Sélectionnez un produit pour voir la fiche, les lots et la recette.', textAlign: TextAlign.center, style: TextStyle(color: NdjoColors.muted)))
              : _ProductPreview(
                  product: sheet,
                  onEdit: () => _edit(sheet),
                  onEditComposition: () => _edit(sheet),
                  onDeleteComposition: () => _deleteComposition(sheet),
                  onDelete: () => _delete(sheet),
                ),
        ),
      ],
    );
  }
}

class _ProductPreview extends StatelessWidget {
  const _ProductPreview({
    required this.product,
    required this.onEdit,
    required this.onEditComposition,
    required this.onDeleteComposition,
    required this.onDelete,
  });
  final Map<String, dynamic> product;
  final VoidCallback onEdit;
  final VoidCallback onEditComposition;
  final VoidCallback onDeleteComposition;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final lots = (product['lots'] as List<dynamic>? ?? []);
    final composition = (product['composition'] as List<dynamic>? ?? []);
    final photo = product['photoUrl']?.toString();
    final description = product['description']?.toString() ?? '';
    final cost = (product['recipeCost'] as num?) ?? 0;
    final buy = (product['priceBuy'] as num?) ?? 0;
    final sell = (product['priceSell'] as num?) ?? 0;
    final margin = (product['recipeMargin'] as num?) ?? (sell - cost);
    final stockQty = (product['stockQty'] as num?) ?? lots.fold<num>(0, (sum, item) => sum + ((item as Map)['qtyCurrent'] as num? ?? 0));
    final isIngredient = product['kind'] == 'INGREDIENT';
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text(product['name'].toString(), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
        Text(
          '${product['code']} · ${isIngredient ? 'Ingrédient / matière première' : 'Produit de vente'}',
          style: const TextStyle(color: NdjoColors.muted),
        ),
        const SizedBox(height: 12),
        if (photo != null && photo.isNotEmpty)
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Image.network(photo, height: 140, fit: BoxFit.cover, errorBuilder: (_, __, ___) => const SizedBox.shrink()),
          )
        else
          Container(
            height: 88,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: NdjoColors.card, borderRadius: BorderRadius.circular(12), border: Border.all(color: NdjoColors.line)),
            child: const Text('Photo non renseignée', style: TextStyle(color: NdjoColors.muted)),
          ),
        const SizedBox(height: 16),
        _heading('Identité du produit'),
        _kv('Nom', product['name']?.toString() ?? '—'),
        _kv('Code produit', product['code']?.toString() ?? '—'),
        _kv('Description', description.isEmpty ? '—' : description),
        _kv('Statut', product['status']?.toString() ?? '—'),
        const SizedBox(height: 14),
        _heading('Classification'),
        _kv('Catégorie', product['category']?['name']?.toString() ?? '—'),
        _kv('Sous-catégorie', product['subcategory']?.toString() ?? '—'),
        _kv('Unité', product['unit']?.toString() ?? '—'),
        _kv('Poids / volume', product['volume']?.toString() ?? '—'),
        _kv('Format d’emballage', product['format']?.toString() ?? '—'),
        const SizedBox(height: 14),
        _heading('Tarifs, alerte et fournisseur'),
        _kv('Prix d’achat catalogue', fc(buy)),
        _kv('Prix de vente', fc(sell)),
        _kv('Seuil d’alerte', '${product['stockAlert'] ?? '—'}'),
        _kv('Fournisseur principal', product['supplier']?.toString() ?? '—'),
        _kv('Stock actuel (somme des lots)', '$stockQty ${product['unit'] ?? ''}'),
        if (!isIngredient) ...[
          const SizedBox(height: 18),
          Row(
            children: [
              const Expanded(child: Text('Composition / menu', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800))),
              TextButton(onPressed: onEditComposition, child: const Text('Modifier')),
              if (composition.isNotEmpty)
                TextButton(
                  onPressed: onDeleteComposition,
                  child: const Text('Supprimer', style: TextStyle(color: NdjoColors.danger)),
                ),
            ],
          ),
          const Text(
            'Ingrédients et/ou produits de vente associés (ex. menu enfant). Distinct des lots Stock.',
            style: TextStyle(color: NdjoColors.muted, fontSize: 12),
          ),
          const SizedBox(height: 8),
          if (composition.isEmpty)
            const Text('Aucune composition. Cliquez sur Modifier pour ajouter des composants.', style: TextStyle(color: NdjoColors.danger))
          else
            Card(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                child: Column(
                  children: [
                    for (final item in composition)
                      _ingredientRow(item as Map<String, dynamic>),
                  ],
                ),
              ),
            ),
          if (composition.isNotEmpty) ...[
            const SizedBox(height: 12),
            _heading('Coût et marge (calculés)'),
            _kv('Coût théorique de revient', fc(cost)),
            _kv('Prix de vente', fc(sell)),
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                'Marge théorique : ${fc(margin)}',
                style: TextStyle(color: margin >= 0 ? NdjoColors.success : NdjoColors.danger, fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ] else ...[
          const SizedBox(height: 14),
          const Text(
            'Matière première : pas de recette. Le stock se gère uniquement par lots.',
            style: TextStyle(color: NdjoColors.muted, fontSize: 13),
          ),
        ],
        const SizedBox(height: 18),
        _heading('Lots liés (module Stock)'),
        const Text('Les séries vivent ici, pas dans la recette.', style: TextStyle(color: NdjoColors.muted, fontSize: 12)),
        const SizedBox(height: 8),
        if (lots.isEmpty)
          const Text('Aucun lot. Créez une entrée dans Stock.', style: TextStyle(color: NdjoColors.muted))
        else
          ...lots.map((item) {
            final lot = item as Map<String, dynamic>;
            return Card(
              child: ListTile(
                dense: true,
                title: Text(lot['number']?.toString() ?? ''),
                subtitle: Text(
                  'Entrée ${lot['entryDate']?.toString().split('T').first ?? '—'} · Péremption ${lot['expiryDate']?.toString().split('T').first ?? '—'}\n'
                  'Achat lot ${fc(lot['priceBuy'] as num? ?? 0)} · Vente lot ${fc(lot['priceSell'] as num? ?? 0)}',
                ),
                isThreeLine: true,
                trailing: Text('${lot['qtyCurrent']} / ${lot['qtyInitial']}'),
              ),
            );
          }),
        const SizedBox(height: 16),
        FilledButton(onPressed: onEdit, child: const Text('Modifier la fiche')),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: onDelete,
          icon: const Icon(Icons.delete_outline, color: NdjoColors.danger),
          label: const Text('Supprimer (tous les établissements)'),
          style: OutlinedButton.styleFrom(foregroundColor: NdjoColors.danger),
        ),
      ],
    );
  }

  Widget _heading(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
    );
  }

  Widget _kv(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final stacked = !constraints.hasBoundedWidth || constraints.maxWidth < 340;
          final labelText = Text(label, style: const TextStyle(color: NdjoColors.muted, fontSize: 13));
          final valueText = Text(value, style: const TextStyle(fontWeight: FontWeight.w600));
          if (stacked) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [labelText, const SizedBox(height: 2), valueText],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(width: 150, child: labelText),
              Expanded(child: valueText),
            ],
          );
        },
      ),
    );
  }

  Widget _ingredientRow(Map<String, dynamic> line) {
    final kind = line['kind']?.toString() == 'VENTE' ? 'Vente' : 'Ingrédient';
    final qty = line['displayQty'] ?? '${line['qtyShown'] ?? line['quantity']} ${line['unitShown'] ?? line['unit'] ?? ''}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '$qty · ${line['name'] ?? ''}',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          Text(kind, style: const TextStyle(color: NdjoColors.muted, fontSize: 12)),
          const SizedBox(width: 8),
          Text(fc((line['cost'] as num?) ?? 0), style: const TextStyle(color: NdjoColors.accent)),
        ],
      ),
    );
  }
}

class _ProductSheet extends StatefulWidget {
  const _ProductSheet({
    required this.session,
    required this.establishmentId,
    required this.categories,
    required this.ingredients,
    required this.components,
    this.product,
  });

  final Session session;
  final String establishmentId;
  final List<dynamic> categories;
  final List<dynamic> ingredients;
  final List<dynamic> components;
  final Map<String, dynamic>? product;

  @override
  State<_ProductSheet> createState() => _ProductSheetState();
}

class _ProductSheetState extends State<_ProductSheet> {
  late final TextEditingController code;
  late final TextEditingController name;
  late final TextEditingController description;
  late final TextEditingController subcategory;
  late final TextEditingController format;
  late final TextEditingController packCustom;
  late final TextEditingController volume;
  late final TextEditingController unit;
  late final TextEditingController priceBuy;
  late final TextEditingController priceSell;
  late final TextEditingController stockAlert;
  late final TextEditingController supplier;
  late final TextEditingController photoUrl;
  late String kind;
  late String status;
  late int packChoice;
  String? categoryId;
  String? error;
  bool saving = false;
  late List<dynamic> categories;
  final lines = <_RecipeLine>[];

  @override
  void initState() {
    super.initState();
    final p = widget.product;
    code = TextEditingController(text: p?['code']?.toString() ?? '');
    name = TextEditingController(text: p?['name']?.toString() ?? '');
    description = TextEditingController(text: p?['description']?.toString() ?? '');
    subcategory = TextEditingController(text: p?['subcategory']?.toString() ?? '');
    format = TextEditingController(text: p?['format']?.toString() ?? 'Unitaire');
    final parsedPack = ndjoPackCount(p?['format']?.toString());
    packChoice = ndjoPackSizes.contains(parsedPack) ? parsedPack : 0;
    packCustom = TextEditingController(text: packChoice == 0 ? '$parsedPack' : '');
    volume = TextEditingController(text: p?['volume']?.toString() ?? '');
    unit = TextEditingController(text: p?['unit']?.toString() ?? 'pièce');
    priceBuy = TextEditingController(text: '${p?['priceBuy'] ?? 0}');
    priceSell = TextEditingController(text: '${p?['priceSell'] ?? 0}');
    stockAlert = TextEditingController(text: '${p?['stockAlert'] ?? 5}');
    supplier = TextEditingController(text: p?['supplier']?.toString() ?? '');
    photoUrl = TextEditingController(text: p?['photoUrl']?.toString() ?? '');
    kind = p?['kind']?.toString() ?? 'VENTE';
    status = p?['status']?.toString() ?? 'ACTIF';
    categories = [...widget.categories];
    categoryId = p?['categoryId']?.toString() ?? (categories.isNotEmpty ? categories.first['id'].toString() : null);
    final existing = (p?['composition'] as List<dynamic>?) ?? (p?['recipe']?['items'] as List<dynamic>?) ?? [];
    for (final item in existing) {
      final map = item as Map<String, dynamic>;
      final qty = map['unit'] == 'kg' && map['displayQty'] != null
          ? ((map['quantity'] as num?) ?? 0) * 1000
          : (map['quantity'] as num?) ?? 0;
      lines.add(_RecipeLine(
        ingredientId: (map['ingredientId'] ?? map['ingredient']?['id'])?.toString() ?? '',
        quantity: qty == qty.roundToDouble() ? '${qty.round()}' : '$qty',
        unit: map['unit'] == 'kg' ? 'g' : (map['unit']?.toString() ?? 'g'),
      ));
    }
  }

  @override
  void dispose() {
    code.dispose();
    name.dispose();
    description.dispose();
    subcategory.dispose();
    format.dispose();
    packCustom.dispose();
    volume.dispose();
    unit.dispose();
    priceBuy.dispose();
    priceSell.dispose();
    stockAlert.dispose();
    supplier.dispose();
    photoUrl.dispose();
    for (final line in lines) {
      line.quantity.dispose();
    }
    super.dispose();
  }

  List<Map<String, dynamic>> get _recipeOptions {
    final selfId = widget.product?['id']?.toString();
    final seen = <String>{};
    final rows = <Map<String, dynamic>>[];
    for (final item in [...widget.components, ...widget.ingredients]) {
      if (item is! Map) continue;
      final map = Map<String, dynamic>.from(item);
      final id = map['id']?.toString() ?? '';
      if (id.isEmpty || id == selfId || map['status']?.toString() == 'SUPPRIME') continue;
      if (!seen.add(id)) continue;
      rows.add(map);
    }
    rows.sort((a, b) {
      final ka = '${a['kind'] == 'VENTE' ? '0' : '1'}${a['name']}';
      final kb = '${b['kind'] == 'VENTE' ? '0' : '1'}${b['name']}';
      return ka.compareTo(kb);
    });
    return rows;
  }

  Future<void> _addCategory() async {
    final controller = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Nouvelle catégorie'),
        content: TextField(controller: controller, decoration: const InputDecoration(labelText: 'Nom')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Créer')),
        ],
      ),
    );
    if (ok != true || controller.text.trim().isEmpty) return;
    final created = await widget.session.api.post('/catalog/categories', {
      'name': controller.text.trim(),
      'establishmentId': widget.establishmentId,
    });
    setState(() {
      categories.add(created);
      categoryId = created['id'].toString();
    });
  }

  Future<void> _save() async {
    if (name.text.trim().isEmpty || code.text.trim().isEmpty || categoryId == null) {
      setState(() => error = 'Code, nom et catégorie sont obligatoires.');
      return;
    }
    setState(() {
      saving = true;
      error = null;
    });
    final body = {
      'establishmentId': widget.establishmentId,
      'code': code.text.trim(),
      'name': name.text.trim(),
      'description': description.text.trim(),
      'categoryId': categoryId,
      'subcategory': subcategory.text.trim(),
      'format': ndjoPackLabel(packChoice == 0 ? (int.tryParse(packCustom.text.trim()) ?? 1) : packChoice),
      'volume': volume.text.trim(),
      'unit': unit.text.trim(),
      'priceBuy': int.tryParse(priceBuy.text) ?? 0,
      'priceSell': int.tryParse(priceSell.text) ?? 0,
      'stockAlert': int.tryParse(stockAlert.text) ?? 5,
      'supplier': supplier.text.trim(),
      'photoUrl': photoUrl.text.trim(),
      'kind': kind,
      'status': status,
    };
    try {
      final saved = widget.product == null
          ? await widget.session.api.post('/catalog/products', body)
          : await widget.session.api.put('/catalog/products/${widget.product!['id']}', body);
      final productId = saved['id']?.toString() ?? widget.product?['id']?.toString();
      if (kind == 'VENTE' && productId != null) {
        await widget.session.api.post('/recipes', {
          'establishmentId': widget.establishmentId,
          'productId': productId,
          'items': lines
              .where((line) => line.ingredientId.isNotEmpty && line.quantity.text.trim().isNotEmpty)
              .map((line) {
                final qty = num.tryParse(line.quantity.text.replaceAll(',', '.')) ?? 0;
                return {
                  'ingredientId': line.ingredientId,
                  'quantity': line.unit == 'g' ? qty / 1000 : qty,
                  'unit': line.unit == 'g' ? 'kg' : line.unit,
                };
              })
              .toList(),
        });
      }
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      setState(() {
        error = e.toString();
        saving = false;
      });
    }
  }

  InputDecoration _dec({String? hint, IconData? icon}) {
    return InputDecoration(
      hintText: hint,
      prefixIcon: icon == null ? null : Icon(icon, size: 18, color: NdjoColors.muted),
      filled: true,
      fillColor: const Color(0xFF191511),
      isDense: false,
      floatingLabelBehavior: FloatingLabelBehavior.never,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      hintStyle: const TextStyle(color: Color(0xFF7A6B5C), fontSize: 13),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: NdjoColors.line)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: NdjoColors.line)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: NdjoColors.primary, width: 1.4)),
    );
  }

  Widget _packPicker() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final size in ndjoPackSizes)
              ChoiceChip(
                label: Text(size == 1 ? 'Unitaire' : '$size'),
                selected: packChoice == size,
                onSelected: (_) => setState(() => packChoice = size),
              ),
            ChoiceChip(
              label: const Text('Libre'),
              selected: packChoice == 0,
              onSelected: (_) => setState(() => packChoice = 0),
            ),
          ],
        ),
        if (packChoice == 0) ...[
          const SizedBox(height: 10),
          TextField(
            controller: packCustom,
            keyboardType: TextInputType.number,
            decoration: _dec(hint: 'Ex. 15 poulets ou 8 poissons / carton'),
          ),
        ],
      ],
    );
  }

  Widget _labeled(String label, Widget field) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(color: Color(0xFFD4C4B4), fontSize: 12, fontWeight: FontWeight.w600, height: 1.2)),
        const SizedBox(height: 8),
        field,
      ],
    );
  }

  Widget _section(String title, String subtitle, List<Widget> children) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 8),
      decoration: BoxDecoration(
        color: const Color(0xFF241E19),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFF3A312A)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800, letterSpacing: 0.2)),
          const SizedBox(height: 4),
          Text(subtitle, style: const TextStyle(color: NdjoColors.muted, fontSize: 12, height: 1.35)),
          const SizedBox(height: 16),
          ...children,
        ],
      ),
    );
  }

  Widget _gap(Widget child) {
    return Padding(padding: const EdgeInsets.only(bottom: 14), child: child);
  }

  Widget _pair(Widget left, Widget right) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (!constraints.hasBoundedWidth || constraints.maxWidth < 520) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [left, const SizedBox(height: 14), right],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: left),
              const SizedBox(width: 14),
              Expanded(child: right),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final creating = widget.product == null;
    final compact = ndjoCompact(context);
    return Dialog(
      backgroundColor: NdjoColors.surface,
      insetPadding: EdgeInsets.symmetric(horizontal: compact ? 8 : 28, vertical: compact ? 8 : 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 880, maxHeight: MediaQuery.sizeOf(context).height * (compact ? 0.96 : 0.9)),
        child: Column(
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(28, 22, 20, 18),
              decoration: const BoxDecoration(
                borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
                gradient: LinearGradient(
                  colors: [Color(0xFF3A2416), Color(0xFF221C18)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
              child: Row(
                children: [
                  Container(
                    width: 46,
                    height: 46,
                    decoration: BoxDecoration(
                      color: NdjoColors.primary.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: const Icon(Icons.restaurant_menu, color: NdjoColors.accent),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(creating ? 'Nouvelle fiche produit' : 'Modifier la fiche produit', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
                        const SizedBox(height: 4),
                        const Text('Identification du produit et composition de la recette sur la même fiche.', style: TextStyle(color: NdjoColors.muted, fontSize: 13)),
                      ],
                    ),
                  ),
                  IconButton(onPressed: () => Navigator.pop(context, false), icon: const Icon(Icons.close)),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
                child: Column(
                  children: [
                    _section('Identification', 'Code interne, nom affiché et description commerciale.', [
                      _pair(
                        _labeled('Code produit', TextField(controller: code, textCapitalization: TextCapitalization.characters, decoration: _dec(hint: 'TAC-POU-500', icon: Icons.qr_code_2))),
                        _labeled('Nom du produit', TextField(controller: name, decoration: _dec(hint: 'Tacos poulet', icon: Icons.sell_outlined))),
                      ),
                      _gap(_labeled('Description', TextField(controller: description, maxLines: 3, decoration: _dec(hint: 'Composition, allergènes, mention client…')))),
                    ]),
                    _section('Classification', 'Catégorie de menu et sous-famille.', [
                      _pair(
                        _labeled(
                          'Catégorie',
                          DropdownButtonFormField<String>(
                            initialValue: categoryId,
                            isExpanded: true,
                            items: categories
                                .map((item) => DropdownMenuItem(value: item['id'].toString(), child: Text(item['name'].toString(), overflow: TextOverflow.ellipsis)))
                                .toList(),
                            onChanged: (value) => setState(() => categoryId = value),
                            decoration: _dec(icon: Icons.category_outlined),
                          ),
                        ),
                        _labeled('Sous-catégorie', TextField(controller: subcategory, decoration: _dec(hint: 'Poulet, Gazeuse…'))),
                      ),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(onPressed: _addCategory, icon: const Icon(Icons.add, size: 18), label: const Text('Nouvelle catégorie')),
                      ),
                    ]),
                    _section('Vente & quantité', 'Boisson : unitaire, 6 ou 12 / carton. Poulet et poisson : indiquez le nombre par carton.', [
                      _gap(_labeled('Format d’emballage', _packPicker())),
                      _pair(
                        _labeled('Poids / volume', TextField(controller: volume, decoration: _dec(hint: '330 ml, 1 kg…'))),
                        _labeled('Unité de mesure', TextField(controller: unit, decoration: _dec(hint: 'pièce, kg, L, portion'))),
                      ),
                    ]),
                    _section('Tarification, stock & fournisseur', 'Prix catalogue. Le prix d’un lot peut différer dans Stock.', [
                      _pair(
                        _labeled('Prix d’achat (FC)', TextField(controller: priceBuy, keyboardType: TextInputType.number, decoration: _dec(icon: Icons.shopping_bag_outlined))),
                        _labeled('Prix de vente (FC)', TextField(controller: priceSell, keyboardType: TextInputType.number, decoration: _dec(icon: Icons.payments_outlined))),
                      ),
                      _pair(
                        _labeled('Seuil d’alerte', TextField(controller: stockAlert, keyboardType: TextInputType.number, decoration: _dec())),
                        _labeled('Fournisseur principal', TextField(controller: supplier, decoration: _dec())),
                      ),
                      _gap(_labeled('Photo (URL)', TextField(controller: photoUrl, decoration: _dec(hint: 'https://…', icon: Icons.image_outlined)))),
                    ]),
                    if (kind == 'VENTE')
                      _section(
                        'Composition / recette',
                        'Associez des ingrédients et/ou d’autres produits de vente (ex. menu enfant = 1 Fanta + 1 frites). Le stock consomme chaque composant (et sa propre recette si besoin).',
                        [
                        ...lines.asMap().entries.map((entry) {
                          final index = entry.key;
                          final line = entry.value;
                          final options = _recipeOptions;
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: LayoutBuilder(
                              builder: (context, constraints) {
                                final ingredientField = DropdownButtonFormField<String>(
                                    initialValue: options.any((item) => item['id'] == line.ingredientId) ? line.ingredientId : null,
                                    isExpanded: true,
                                    items: options
                                        .map((item) {
                                          final tag = item['kind']?.toString() == 'VENTE' ? 'Vente' : 'Ingrédient';
                                          return DropdownMenuItem(
                                            value: item['id'].toString(),
                                            child: Text('$tag · ${item['name']}', overflow: TextOverflow.ellipsis),
                                          );
                                        })
                                        .toList(),
                                    onChanged: (value) => setState(() {
                                      line.ingredientId = value ?? '';
                                      final selected = options.where((item) => item['id']?.toString() == value);
                                      if (selected.isNotEmpty && selected.first['kind']?.toString() == 'VENTE') {
                                        line.unit = 'pièce';
                                        if (line.quantity.text.trim().isEmpty) line.quantity.text = '1';
                                      }
                                    }),
                                    decoration: _dec(hint: 'Composant'),
                                  );
                                final qtyField = TextField(controller: line.quantity, keyboardType: TextInputType.number, decoration: _dec(hint: 'Qté'));
                                final unitField = DropdownButtonFormField<String>(
                                    initialValue: line.unit,
                                    items: const [
                                      DropdownMenuItem(value: 'g', child: Text('g')),
                                      DropdownMenuItem(value: 'pièce', child: Text('pièce')),
                                      DropdownMenuItem(value: 'kg', child: Text('kg')),
                                    ],
                                    onChanged: (value) => setState(() => line.unit = value ?? line.unit),
                                    decoration: _dec(),
                                  );
                                final remove = IconButton(
                                  onPressed: () => setState(() {
                                    line.quantity.dispose();
                                    lines.removeAt(index);
                                  }),
                                  icon: const Icon(Icons.remove_circle_outline, color: NdjoColors.danger),
                                );
                                if (constraints.maxWidth < 480) {
                                  return Column(
                                    children: [
                                      ingredientField,
                                      const SizedBox(height: 8),
                                      Row(
                                        children: [
                                          Expanded(child: qtyField),
                                          const SizedBox(width: 8),
                                          Expanded(child: unitField),
                                          remove,
                                        ],
                                      ),
                                    ],
                                  );
                                }
                                return Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(flex: 5, child: ingredientField),
                                const SizedBox(width: 10),
                                SizedBox(width: 90, child: qtyField),
                                const SizedBox(width: 10),
                                SizedBox(width: 90, child: unitField),
                                remove,
                              ],
                            );
                              },
                            ),
                          );
                        }),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                            onPressed: () => setState(() {
                              final options = _recipeOptions;
                              lines.add(_RecipeLine(
                                ingredientId: options.isNotEmpty ? options.first['id'].toString() : '',
                                quantity: options.isNotEmpty && options.first['kind']?.toString() == 'VENTE' ? '1' : '150',
                                unit: options.isNotEmpty && options.first['kind']?.toString() == 'VENTE' ? 'pièce' : 'g',
                              ));
                            }),
                            icon: const Icon(Icons.add, size: 18),
                            label: const Text('Ajouter un composant'),
                          ),
                        ),
                      ]),
                    _section('Gestion', 'Type métier et visibilité dans le catalogue publié.', [
                      _pair(
                        _labeled(
                          'Type de produit',
                          DropdownButtonFormField<String>(
                            initialValue: kind,
                            isExpanded: true,
                            items: const [
                              DropdownMenuItem(value: 'VENTE', child: Text('Produit de vente')),
                              DropdownMenuItem(value: 'INGREDIENT', child: Text('Ingrédient / matière première')),
                            ],
                            onChanged: (value) => setState(() => kind = value ?? kind),
                            decoration: _dec(),
                          ),
                        ),
                        _labeled(
                          'Statut',
                          DropdownButtonFormField<String>(
                            initialValue: status,
                            isExpanded: true,
                            items: const [
                              DropdownMenuItem(value: 'ACTIF', child: Text('Actif')),
                              DropdownMenuItem(value: 'INACTIF', child: Text('Inactif')),
                            ],
                            onChanged: (value) => setState(() => status = value ?? status),
                            decoration: _dec(),
                          ),
                        ),
                      ),
                    ]),
                    if (error != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(error!, style: const TextStyle(color: NdjoColors.danger)),
                      ),
                  ],
                ),
              ),
            ),
            Container(
              padding: EdgeInsets.fromLTRB(compact ? 16 : 24, 14, compact ? 16 : 24, 18),
              decoration: const BoxDecoration(
                border: Border(top: BorderSide(color: NdjoColors.line)),
              ),
              child: compact
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Text('Enregistrer n’envoie pas encore aux caisses : publiez le catalogue ensuite.', style: TextStyle(color: NdjoColors.muted, fontSize: 12)),
                        const SizedBox(height: 10),
                        FilledButton(
                          onPressed: saving ? null : _save,
                          style: FilledButton.styleFrom(backgroundColor: NdjoColors.primary, padding: const EdgeInsets.symmetric(vertical: 14)),
                          child: Text(saving ? 'Enregistrement…' : 'Enregistrer la fiche'),
                        ),
                        TextButton(onPressed: saving ? null : () => Navigator.pop(context, false), child: const Text('Annuler')),
                      ],
                    )
                  : Row(
                children: [
                  const Expanded(child: Text('Enregistrer n’envoie pas encore aux caisses : publiez le catalogue ensuite.', style: TextStyle(color: NdjoColors.muted, fontSize: 12))),
                  TextButton(onPressed: saving ? null : () => Navigator.pop(context, false), child: const Text('Annuler')),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: saving ? null : _save,
                    style: FilledButton.styleFrom(backgroundColor: NdjoColors.primary, padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14)),
                    child: Text(saving ? 'Enregistrement…' : 'Enregistrer la fiche'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RecipeLine {
  _RecipeLine({required this.ingredientId, required String quantity, required this.unit})
      : quantity = TextEditingController(text: quantity);

  String ingredientId;
  String unit;
  final TextEditingController quantity;
}

class _ErrorBox extends StatelessWidget {
  const _ErrorBox({required this.error, required this.onRetry});
  final String error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(error, style: const TextStyle(color: NdjoColors.danger)),
          const SizedBox(height: 12),
          FilledButton(onPressed: onRetry, child: const Text('Réessayer')),
        ],
      ),
    );
  }
}
