import 'package:flutter/material.dart';

import 'company.dart';
import 'pages.dart';
import 'session.dart';
import 'theme.dart';
import 'time_fmt.dart';

class ReportsPage extends StatefulWidget {
  const ReportsPage({super.key, required this.session});
  final Session session;

  @override
  State<ReportsPage> createState() => _ReportsPageState();
}

class _ReportsPageState extends State<ReportsPage> {
  Map<String, dynamic>? report;
  String period = 'jour';
  String tab = 'ventes';
  String? error;
  bool loading = true;

  String get _id => widget.session.establishmentId ?? '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant ReportsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session.establishmentId != widget.session.establishmentId) {
      _load();
    }
  }

  Future<void> _load() async {
    final cached = widget.session.peekMap('reports-$period-$_id');
    if (cached.isNotEmpty) {
      report = cached;
      loading = false;
    } else if (report == null && mounted) {
      setState(() => loading = true);
    }
    try {
      final query = _id.isEmpty
          ? '/reports?period=$period'
          : '/reports?period=$period&establishmentId=$_id';
      final data = await widget.session.cachedJson(query, 'reports-$period-$_id');
      setState(() {
        report = data.isNotEmpty ? data : (cached.isNotEmpty ? cached : report);
        error = null;
        loading = false;
      });
    } catch (e) {
      setState(() {
        error = null;
        loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (loading && report == null) return const Center(child: CircularProgressIndicator());
    if (report == null) {
      return ListView(
        padding: const EdgeInsets.all(24),
        children: [
          ndjoLetterhead(),
          const SizedBox(height: 16),
          const Text('Rapports', style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          Text('Aucun rapport en copie locale. Les totaux seront visibles après une ouverture en ligne.', style: TextStyle(color: NdjoColors.muted)),
        ],
      );
    }
    final data = report!;
    final sales = data['sales'] as Map<String, dynamic>;
    final stock = data['stock'] as Map<String, dynamic>;
    final delivery = data['delivery'] as Map<String, dynamic>;
    final finance = data['finance'] as Map<String, dynamic>;
    final payments = finance['payments'] as Map<String, dynamic>;
    final byProduct = sales['byProduct'] as List<dynamic>? ?? [];
    final byCategory = sales['byCategory'] as List<dynamic>? ?? [];
    final productQty = byProduct.fold<num>(0, (sum, item) => sum + ((item as Map)['qty'] as num? ?? 0));
    final productCa = byProduct.fold<num>(0, (sum, item) => sum + ((item as Map)['revenue'] as num? ?? 0));
    final productExpenseTotal = byProduct.fold<num>(0, (sum, item) => sum + (((item as Map)['expense'] ?? item['cost'] ?? 0) as num));
    final productProfitTotal = byProduct.fold<num>(0, (sum, item) => sum + (((item as Map)['profit'] ?? item['margin'] ?? 0) as num));
    final categoryCa = byCategory.fold<num>(0, (sum, item) => sum + ((item as Map)['revenue'] as num? ?? 0));
    final categoryExpenseTotal = byCategory.fold<num>(0, (sum, item) => sum + (((item as Map)['expense'] ?? item['cost'] ?? 0) as num));
    final categoryProfitTotal = byCategory.fold<num>(0, (sum, item) => sum + (((item as Map)['profit'] ?? ((item['revenue'] as num? ?? 0) - (item['cost'] as num? ?? 0))) as num));
    final totalProfit = (sales['profit'] as num?) ?? (finance['profit'] as num?) ?? productProfitTotal;
    final compact = ndjoCompact(context);
    return ListView(
      padding: EdgeInsets.all(compact ? 16 : 24),
      children: [
        ndjoLetterhead(compact: compact),
        const SizedBox(height: 16),
        const Text('Rapports', style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
        Text(
          '${data['period']} · ${data['from']?.toString().split('T').first} → ${data['to']?.toString().split('T').first}',
          style: const TextStyle(color: NdjoColors.muted),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            const Text('Ventes', style: TextStyle(fontWeight: FontWeight.w700)),
            ndjoExportButtons(
              onExcel: () => downloadNdjoExport(context, widget.session, kind: 'sales', format: 'xls', period: period),
              onPdf: () => downloadNdjoExport(context, widget.session, kind: 'sales', format: 'pdf', period: period),
            ),
            const Text('Rapport', style: TextStyle(fontWeight: FontWeight.w700)),
            ndjoExportButtons(
              onExcel: () => downloadNdjoExport(context, widget.session, kind: 'reports', format: 'xls', period: period),
              onPdf: () => downloadNdjoExport(context, widget.session, kind: 'reports', format: 'pdf', period: period),
            ),
          ],
        ),
        const SizedBox(height: 12),
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'jour', label: Text('Jour')),
            ButtonSegment(value: 'semaine', label: Text('Semaine')),
            ButtonSegment(value: 'mois', label: Text('Mois')),
          ],
          selected: {period},
          onSelectionChanged: (value) {
            setState(() => period = value.first);
            _load();
          },
        ),
        const SizedBox(height: 12),
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'ventes', label: Text('Ventes')),
            ButtonSegment(value: 'stock', label: Text('Stock')),
            ButtonSegment(value: 'livraison', label: Text('Livraison')),
            ButtonSegment(value: 'finance', label: Text('Finance')),
          ],
          selected: {tab},
          onSelectionChanged: (value) => setState(() => tab = value.first),
        ),
        const SizedBox(height: 20),
        if (tab == 'ventes') ...[
          Wrap(spacing: 12, runSpacing: 12, children: [
            _tile('CA brut', fc(sales['grossRevenue'] as num? ?? ((sales['revenue'] as num? ?? 0) + (sales['discounts'] as num? ?? 0)))),
            _tile('Remises', fc(sales['discounts'] as num? ?? 0)),
            _tile('CA net', fc(sales['revenue'] as num? ?? 0)),
            _tile('CA payé', fc(sales['paidRevenue'] as num? ?? sales['revenue'] as num? ?? 0)),
            _tile('Dépense produits', fc(sales['productExpense'] as num? ?? 0)),
            _tile('Total bénéfice', fc(totalProfit)),
            _tile('Commandes', '${sales['orders']}'),
            _tile('Payées', '${sales['paid']}'),
          ]),
          const SizedBox(height: 12),
          _profitTotal(totalProfit),
          const SizedBox(height: 8),
          const Text(
            'CA net = après remises. Le prix catalogue ne change pas. La dépense et le bénéfice suivent le prix d’achat de chaque lot sorti.',
            style: TextStyle(color: NdjoColors.muted, fontSize: 12),
          ),
          if ((sales['discountsByMotif'] as List<dynamic>? ?? []).isNotEmpty) ...[
            const SizedBox(height: 16),
            _table(
              'Remises par motif',
              ['Motif', 'Nb', 'Montant'],
              (sales['discountsByMotif'] as List<dynamic>).map((item) {
                final row = Map<String, dynamic>.from(item as Map);
                return [
                  '${row['motif'] ?? '—'}',
                  '${row['count'] ?? 0}',
                  fc((row['amount'] as num?) ?? 0),
                ];
              }),
            ),
          ],
          const SizedBox(height: 16),
          _section('Par jour', (sales['byDay'] as List<dynamic>).map((item) => '${item['date']} · ${fc(item['total'] as num)}')),
          _table(
            'Par produit',
            ['Produit', 'Qté', 'CA', 'Dépense', 'Bénéfice'],
            [
              ...byProduct.map((item) => [
                    item['name'],
                    '${item['qty']}',
                    fc(item['revenue'] as num),
                    fc((item['expense'] ?? item['cost'] ?? 0) as num),
                    fc((item['profit'] ?? item['margin'] ?? 0) as num),
                  ]),
              if (byProduct.isNotEmpty)
                ['TOTAL', '$productQty', fc(productCa), fc(productExpenseTotal), fc(productProfitTotal)],
            ],
            hasTotal: byProduct.isNotEmpty,
          ),
          _table(
            'Par catégorie',
            ['Catégorie', 'CA', 'Dépense', 'Bénéfice'],
            [
              ...byCategory.map((item) => [
                    item['name'],
                    fc(item['revenue'] as num),
                    fc((item['expense'] ?? item['cost'] ?? 0) as num),
                    fc((item['profit'] ?? ((item['revenue'] as num? ?? 0) - (item['cost'] as num? ?? 0))) as num),
                  ]),
              if (byCategory.isNotEmpty)
                ['TOTAL', fc(categoryCa), fc(categoryExpenseTotal), fc(categoryProfitTotal)],
            ],
            hasTotal: byCategory.isNotEmpty,
          ),
          _table('Par caissier', ['Caissier', 'Commandes', 'CA'], (sales['byCashier'] as List<dynamic>).map((item) => [item['name'], '${item['orders']}', fc(item['revenue'] as num)])),
          _table('Par établissement', ['Établissement', 'Commandes', 'CA'], (sales['byEstablishment'] as List<dynamic>).map((item) => [item['name'], '${item['orders']}', fc(item['revenue'] as num)])),
        ],
        if (tab == 'stock') ...[
          Wrap(spacing: 12, runSpacing: 12, children: [
            _tile('Valeur stock', fc(stock['value'] as num? ?? 0)),
            _tile('Ruptures', '${stock['rupture']}'),
            _tile('Péremption ≤ 7 j', '${stock['expiring']}'),
            _tile('Coût lots cuisine', fc(stock['kitchenCost'] as num? ?? 0)),
            _tile('Sorties magasin → cuisine', fc(stock['kitchenExtraCost'] as num? ?? 0)),
            _tile('Transferts', '${(stock['transfers'] as Map?)?['count'] ?? 0}'),
            _tile('Transferts sortis', fc(((stock['transfers'] as Map?)?['valueOut'] as num?) ?? 0)),
            _tile('Transferts reçus', fc(((stock['transfers'] as Map?)?['valueIn'] as num?) ?? 0)),
            _tile('À réceptionner', '${(stock['transfers'] as Map?)?['pendingReceive'] ?? 0}'),
          ]),
          const SizedBox(height: 8),
          const Text(
            'Chaque sortie cuisine est un lot (date d’entrée + prix d’achat). Les recettes vendues sont déjà dans le bénéfice ; les sorties magasin→cuisine et les transferts inter-sites apparaissent ici pour le journal stock (hors bénéfice).',
            style: TextStyle(color: NdjoColors.muted, fontSize: 12),
          ),
          const SizedBox(height: 16),
          _table(
            'Journal sorties cuisine (par lot)',
            ['Heure', 'Produit', 'Lot', 'Entrée lot', 'Qté', 'Coût', 'Type'],
            [
              ...(stock['kitchenExits'] as List<dynamic>? ?? []).map((item) {
                final row = item as Map;
                final type = switch (row['type']?.toString()) {
                  'CONSOMMATION' => 'Recette',
                  'SORTIE' => 'Magasin',
                  'VENTE' => 'Vente',
                  _ => row['type']?.toString() ?? '',
                };
                return [
                  formatLocalDateTime(row['createdAt']),
                  row['product']?.toString() ?? '',
                  row['lot']?.toString() ?? '—',
                  row['entryDate']?.toString().split('T').first ?? '—',
                  '${row['quantity']} ${row['unit'] ?? ''}',
                  fc(row['cost'] as num? ?? 0),
                  type,
                ];
              }),
              if ((stock['kitchenExits'] as List<dynamic>? ?? []).isNotEmpty)
                ['TOTAL', '', '', '', '', fc(stock['kitchenCost'] as num? ?? 0), ''],
            ],
            hasTotal: (stock['kitchenExits'] as List<dynamic>? ?? []).isNotEmpty,
          ),
          _table(
            'Transferts inter-sites',
            ['N°', 'Statut', 'Produit', 'Qté', 'Source → Dest', 'Valeur', 'Expédié', 'Reçu'],
            [
              ...(((stock['transfers'] as Map?)?['lines'] as List<dynamic>?) ?? []).map((item) {
                final row = Map<String, dynamic>.from(item as Map);
                return [
                  '${row['number'] ?? ''}',
                  '${row['status'] ?? ''}',
                  '${row['product'] ?? ''}',
                  '${row['quantity'] ?? ''} ${row['unit'] ?? ''}',
                  '${row['source'] ?? ''} → ${row['dest'] ?? ''}',
                  fc((row['cost'] as num?) ?? 0),
                  formatLocalDateTime(row['shippedAt']),
                  formatLocalDateTime(row['receivedAt']),
                ];
              }),
              if ((((stock['transfers'] as Map?)?['lines'] as List<dynamic>?) ?? []).isNotEmpty)
                [
                  'TOTAL',
                  '',
                  '',
                  '${(stock['transfers'] as Map?)?['quantity'] ?? 0}',
                  '',
                  fc((((stock['transfers'] as Map?)?['valueOut'] as num?) ?? 0) + (((stock['transfers'] as Map?)?['valueIn'] as num?) ?? 0)),
                  '',
                  '',
                ],
            ],
            hasTotal: (((stock['transfers'] as Map?)?['lines'] as List<dynamic>?) ?? []).isNotEmpty,
          ),
          if ((((stock['transfers'] as Map?)?['bySite'] as List<dynamic>?) ?? []).isNotEmpty)
            _table(
              'Transferts par trajet',
              ['Trajet', 'Nb sortis', 'Qté', 'Valeur sortie', 'Nb reçus', 'Valeur reçue'],
              (((stock['transfers'] as Map?)?['bySite'] as List<dynamic>? ?? []).map((item) {
                final row = Map<String, dynamic>.from(item as Map);
                return [
                  '${row['name'] ?? ''}',
                  '${row['outCount'] ?? 0}',
                  '${row['outQty'] ?? 0}',
                  fc((row['outValue'] as num?) ?? 0),
                  '${row['inCount'] ?? 0}',
                  fc((row['inValue'] as num?) ?? 0),
                ];
              })),
            ),
          _section('Stock bas', (stock['low'] as List<dynamic>).map((item) => '${item['name']} · ${item['qty']} ${item['unit']} (seuil ${item['alert']})')),
          _section('Pertes de la période', (stock['losses'] as List<dynamic>).map((item) => '${formatLocalDateTime(item['createdAt'] ?? item['occurredAt'])} · ${item['number']} · ${item['product']} · ${item['quantity']} ${item['unit']} · ${item['status']}')),
          _section('Inventaires', (stock['inventories'] as List<dynamic>).map((item) => '${formatLocalDateTime(item['createdAt'] ?? item['countedAt'])} · ${item['number']} · ${item['status']} · ${item['countedBy']}')),
          _section(
            'Mouvements (dont transferts)',
            (stock['movements'] as List<dynamic>).take(30).map((item) {
              final type = item['type']?.toString() ?? '';
              final motif = item['motif']?.toString() ?? '';
              final tag = type == 'TRANSFERT' || motif.contains('transfert') ? ' · transfert' : '';
              return '${formatLocalDateTime(item['createdAt'])} · ${item['number']} · $type$tag · ${item['product']} · lot ${item['lot'] ?? '—'} · ${item['quantity']}';
            }),
          ),
        ],
        if (tab == 'livraison') ...[
          Wrap(spacing: 12, runSpacing: 12, children: [
            _tile('Livraisons', '${delivery['count']}'),
            _tile('Livrées', '${delivery['delivered']}'),
            _tile('COD en attente', '${delivery['cashOnDelivery']}'),
            _tile('Annulées', '${delivery['cancelled']}'),
            _tile('Temps moyen', delivery['avgMinutes'] == null ? '—' : '${delivery['avgMinutes']} min'),
          ]),
          const SizedBox(height: 8),
          Text(delivery['avgNote']?.toString() ?? '', style: const TextStyle(color: NdjoColors.muted, fontSize: 12)),
          const SizedBox(height: 16),
          _table('Par livreur', ['Livreur', 'Courses'], (delivery['byDriver'] as List<dynamic>).map((item) => [item['name'], '${item['count']}'])),
        ],
        if (tab == 'finance') ...[
          Wrap(spacing: 12, runSpacing: 12, children: [
            _tile('CA brut', fc(finance['grossRevenue'] as num? ?? ((finance['revenue'] as num? ?? 0) + (finance['discounts'] as num? ?? 0)))),
            _tile('Remises', fc(finance['discounts'] as num? ?? 0)),
            _tile('CA net', fc(finance['revenue'] as num? ?? 0)),
            _tile('Dépense produits vendus', fc(finance['productExpense'] as num? ?? finance['materialCost'] as num? ?? 0)),
            _tile('Pertes valorisées', fc(finance['lossValue'] as num? ?? 0)),
            _tile('Sorties → cuisine', fc(finance['kitchenExtraCost'] as num? ?? 0)),
            _tile('Transferts sortis', fc(((stock['transfers'] as Map?)?['valueOut'] as num?) ?? 0)),
            _tile('Transferts reçus', fc(((stock['transfers'] as Map?)?['valueIn'] as num?) ?? 0)),
            _tile('Total bénéfice', fc(finance['profit'] as num? ?? 0)),
            _tile('CA payé', fc(finance['paidRevenue'] as num? ?? 0)),
            _tile('Achats (entrées)', fc(finance['purchases'] as num? ?? 0)),
          ]),
          const SizedBox(height: 8),
          Text(finance['expensesNote']?.toString() ?? '', style: const TextStyle(color: NdjoColors.muted, fontSize: 12)),
          const SizedBox(height: 12),
          _profitTotal(finance['profit'] as num? ?? 0),
          const SizedBox(height: 16),
          _table('Compte de résultat', ['Ligne', 'Montant'], [
            for (final row in (finance['result'] as List<dynamic>? ?? [
              {'label': 'CA brut (avant remise)', 'amount': finance['grossRevenue'] ?? ((finance['revenue'] as num? ?? 0) + (finance['discounts'] as num? ?? 0))},
              {'label': 'Remises accordées', 'amount': -((finance['discounts'] as num?) ?? 0)},
              {'label': 'Chiffre d’affaires net', 'amount': finance['revenue']},
              {'label': 'Dépense produits vendus', 'amount': -((finance['productExpense'] ?? finance['materialCost'] ?? 0) as num)},
              {'label': 'Pertes valorisées', 'amount': -((finance['lossValue'] ?? 0) as num)},
              {'label': 'Total bénéfice', 'amount': finance['profit']},
            ]))
              _resultRow(Map<String, dynamic>.from(row as Map)),
          ], hasTotal: true),
          if ((finance['discountsByMotif'] as List<dynamic>? ?? []).isNotEmpty) ...[
            const SizedBox(height: 16),
            _table(
              'Remises par motif',
              ['Motif', 'Nb', 'Montant'],
              (finance['discountsByMotif'] as List<dynamic>).map((item) {
                final row = Map<String, dynamic>.from(item as Map);
                return [
                  '${row['motif'] ?? '—'}',
                  '${row['count'] ?? 0}',
                  fc((row['amount'] as num?) ?? 0),
                ];
              }),
            ),
          ],
          const SizedBox(height: 8),
          _table('Paiements encaissés', ['Mode', 'Montant'], [
            ['Espèces', fc(payments['ESPECES'] as num? ?? 0)],
            ['Mobile Money', fc(payments['MOBILE_MONEY'] as num? ?? 0)],
            ['Carte', fc(payments['CARTE'] as num? ?? 0)],
            ['Virement', fc(payments['VIREMENT'] as num? ?? 0)],
          ]),
        ],
      ],
    );
  }

  List<String> _resultRow(Map<String, dynamic> map) {
    final label = map['label'].toString();
    return [
      label == 'Bénéfice' ? 'Total bénéfice' : label,
      fc((map['amount'] as num?) ?? 0),
    ];
  }

  Widget _profitTotal(num amount) {
    return Card(
      color: const Color(0xFF3A2A1C),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Total bénéfice', style: TextStyle(color: NdjoColors.muted, fontSize: 13)),
            const SizedBox(height: 4),
            Text(fc(amount), style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800, color: NdjoColors.accent)),
            const SizedBox(height: 4),
            const Text('CA ventes − coût réel des lots sortis − pertes valorisées', style: TextStyle(color: NdjoColors.muted, fontSize: 12)),
          ],
        ),
      ),
    );
  }

  Widget _tile(String label, String value) {
    return SizedBox(
      width: 200,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: const TextStyle(color: NdjoColors.muted, fontSize: 12)),
              const SizedBox(height: 6),
              Text(value, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: NdjoColors.accent)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _section(String title, Iterable<String> lines) {
    final items = lines.toList();
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          if (items.isEmpty)
            const Text('Aucune donnée sur cette période.', style: TextStyle(color: NdjoColors.muted))
          else
            ...items.map((line) => Card(child: ListTile(dense: true, title: Text(line)))),
        ],
      ),
    );
  }

  Widget _table(String title, List<String> headers, Iterable<List<String>> rows, {bool hasTotal = false}) {
    final data = rows.toList();
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          if (data.isEmpty)
            const Text('Aucune donnée sur cette période.', style: TextStyle(color: NdjoColors.muted))
          else
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                columns: headers.map((header) => DataColumn(label: Text(header))).toList(),
                rows: [
                  for (var i = 0; i < data.length; i++)
                    DataRow(
                      color: hasTotal && i == data.length - 1
                          ? const WidgetStatePropertyAll(Color(0xFF3A2A1C))
                          : null,
                      cells: data[i]
                          .map(
                            (cell) => DataCell(
                              Text(
                                cell,
                                style: hasTotal && i == data.length - 1
                                    ? const TextStyle(fontWeight: FontWeight.w800, color: NdjoColors.accent)
                                    : null,
                              ),
                            ),
                          )
                          .toList(),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
