import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'api.dart';
import 'company.dart';
import 'open_link.dart';
import 'pages.dart';
import 'product_kind.dart';
import 'session.dart';
import 'theme.dart';

String? whatsappDigits(String? raw) {
  if (raw == null || raw.trim().isEmpty) return null;
  var digits = raw.replaceAll(RegExp(r'[^\d+]'), '');
  if (digits.startsWith('+')) digits = digits.substring(1);
  if (digits.startsWith('00')) digits = digits.substring(2);
  if (digits.startsWith('0') && digits.length == 10) digits = '243${digits.substring(1)}';
  if (digits.length == 9 && RegExp(r'^[89]').hasMatch(digits)) digits = '243$digits';
  if (digits.length < 9) return null;
  return digits;
}

String ticketShopName(Session session, Map<String, dynamic> order) {
  return order['establishment']?['name']?.toString() ??
      session.establishment?['name']?.toString() ??
      'NDJO TACOS';
}

String? ticketPhone(Map<String, dynamic> order) {
  return order['customerPhone']?.toString() ??
      order['customer']?['phone']?.toString() ??
      order['order']?['customerPhone']?.toString() ??
      order['order']?['customer']?['phone']?.toString();
}

List<Map<String, dynamic>> ticketItems(Map<String, dynamic> order) {
  final items = order['items'] as List<dynamic>? ?? order['order']?['items'] as List<dynamic>? ?? [];
  return [
    for (final item in items)
      if (item is Map) Map<String, dynamic>.from(item),
  ];
}

Map<String, dynamic>? ticketInvoiceOf(Map<String, dynamic> order) {
  final invoice = order['invoice'];
  if (invoice is Map) return Map<String, dynamic>.from(invoice);
  if (order['verifyToken'] != null || order['pdfPath'] != null) return order;
  return null;
}

String? ticketPdfUrl(Map<String, dynamic> order) {
  final invoice = ticketInvoiceOf(order);
  final token = invoice?['verifyToken']?.toString() ?? order['verifyToken']?.toString();
  if (token == null || token.isEmpty) return null;
  return '${Api.baseUrl}/invoices/verify/$token/pdf';
}

String ticketTypeLabel(String? type) {
  switch (type) {
    case 'LIVRAISON':
      return 'Livraison';
    case 'A_EMPORTER':
      return 'À emporter';
    default:
      return 'Sur place';
  }
}

String ticketMessage(Session session, Map<String, dynamic> order, {required bool invoice}) {
  final shop = ticketShopName(session, order);
  final number = invoice
      ? (ticketInvoiceOf(order)?['number'] ?? order['number'] ?? '')
      : (order['number'] ?? '');
  final title = invoice ? 'Facture $number' : 'Bon de commande $number';
  final items = ticketItems(order);
  final kitchen = orderKitchenItems(order);
  final drinks = orderCounterDrinks(order);
  final listed = kitchen.isEmpty && drinks.isEmpty ? items : [...kitchen, ...drinks];
  final lines = <String>[
    if (kitchen.isNotEmpty) 'Nourriture :',
    ...((kitchen.isNotEmpty ? kitchen : (drinks.isEmpty ? listed : <Map<String, dynamic>>[])).map((item) => '• ${item['quantity'] ?? 1} × ${item['name'] ?? ''} — ${fc((item['lineTotal'] as num?) ?? ((item['unitPrice'] as num? ?? 0) * (item['quantity'] as num? ?? 1)))}')),
    if (drinks.isNotEmpty) 'Boissons (interne) :',
    ...drinks.map((item) => '• ${item['quantity'] ?? 1} × ${item['name'] ?? ''} — ${fc((item['lineTotal'] as num?) ?? ((item['unitPrice'] as num? ?? 0) * (item['quantity'] as num? ?? 1)))}'),
  ];
  final pdf = ticketPdfUrl(order);
  return [
    NdjoCompany.brand,
    NdjoCompany.legalName,
    'Tél. ${NdjoCompany.phone}',
    if (shop.isNotEmpty) 'Établissement : $shop',
    title,
    if ((order['customerName'] ?? order['customer']?['name']) != null)
      'Client : ${order['customerName'] ?? order['customer']?['name']}',
    if (lines.isNotEmpty) lines.join('\n'),
    if (((order['subtotal'] as num?) ?? 0) > 0) 'Sous-total : ${fc(order['subtotal'] as num)}',
    if (((order['discountAmount'] as num?) ?? 0) > 0)
      'Remise ${order['discountPercent'] ?? ''}% (${order['discountMotif'] ?? '—'}) : −${fc(order['discountAmount'] as num)}',
    if (((order['deliveryFee'] as num?) ?? 0) > 0) 'Livraison : ${fc(order['deliveryFee'] as num)}',
    'Total net : ${fc((order['total'] as num?) ?? (ticketInvoiceOf(order)?['total'] as num?) ?? 0)}',
    'Paiement : ${orderPayLabel(order['order'] is Map ? Map<String, dynamic>.from(order['order'] as Map) : order)}',
    if (invoice && pdf != null) 'PDF : $pdf',
    '',
    'Envoyé depuis WhatsApp du restaurant (API WhatsApp Business pas encore branchée).',
  ].join('\n');
}

String ticketHtml(Session session, Map<String, dynamic> order, {required bool invoice}) {
  final shop = ticketShopName(session, order);
  final invoiceMap = ticketInvoiceOf(order);
  final number = invoice ? (invoiceMap?['number'] ?? order['number'] ?? '') : (order['number'] ?? '');
  final title = invoice ? 'FACTURE' : 'BON DE COMMANDE';
  final customer = order['customerName'] ?? order['customer']?['name'] ?? order['order']?['customerName'] ?? '—';
  final phone = ticketPhone(order) ?? '—';
  final type = ticketTypeLabel((order['type'] ?? order['order']?['type'])?.toString());
  final pay = orderPayLabel(order['order'] is Map ? Map<String, dynamic>.from(order['order'] as Map) : order);
  final address = order['address']?.toString() ?? order['order']?['address']?.toString() ?? '';
  final items = ticketItems(order);
  final kitchen = orderKitchenItems(order);
  final drinks = orderCounterDrinks(order);
  String rowsOf(List<Map<String, dynamic>> rows) => rows.map((item) {
    final qty = item['quantity'] ?? 1;
    final name = _esc('${item['name'] ?? ''}');
    final pu = fc((item['unitPrice'] as num?) ?? 0);
    final line = fc((item['lineTotal'] as num?) ?? ((item['unitPrice'] as num? ?? 0) * (item['quantity'] as num? ?? 1)));
    return '<tr><td>$qty</td><td>$name</td><td>$pu</td><td>$line</td></tr>';
  }).join();
  final sections = StringBuffer();
  if (kitchen.isNotEmpty) {
    sections.writeln('<p><b>Nourriture (cuisine)</b></p><table><thead><tr><th>Qté</th><th>Désignation</th><th>PU</th><th>Montant</th></tr></thead><tbody>${rowsOf(kitchen)}</tbody></table>');
  }
  if (drinks.isNotEmpty) {
    sections.writeln('<p><b>Boissons (gestion interne)</b></p><table><thead><tr><th>Qté</th><th>Désignation</th><th>PU</th><th>Montant</th></tr></thead><tbody>${rowsOf(drinks)}</tbody></table>');
  }
  if (kitchen.isEmpty && drinks.isEmpty) {
    sections.writeln('<table><thead><tr><th>Qté</th><th>Désignation</th><th>PU</th><th>Montant</th></tr></thead><tbody>${rowsOf(items)}</tbody></table>');
  }
  final subtotal = (order['subtotal'] as num?) ?? 0;
  final discountAmount = (order['discountAmount'] as num?) ?? 0;
  final discountPercent = order['discountPercent'];
  final discountMotif = '${order['discountMotif'] ?? ''}';
  final deliveryFee = (order['deliveryFee'] as num?) ?? 0;
  final total = fc((order['total'] as num?) ?? (invoiceMap?['total'] as num?) ?? 0);
  final totalsHtml = StringBuffer();
  if (subtotal > 0) {
    totalsHtml.writeln('<p>Sous-total : ${_esc(fc(subtotal))}</p>');
  }
  if (discountAmount > 0) {
    final pct = discountPercent == null ? '' : ' $discountPercent%';
    final motif = discountMotif.isEmpty ? '—' : discountMotif;
    totalsHtml.writeln('<p>Remise$pct ($motif) : −${_esc(fc(discountAmount))}</p>');
  }
  if (deliveryFee > 0) {
    totalsHtml.writeln('<p>Livraison : ${_esc(fc(deliveryFee))}</p>');
  }
  totalsHtml.writeln('<p class="total">Total net $total</p>');
  final pdf = ticketPdfUrl(order);
  final shopPhone = session.establishment?['phone']?.toString() ?? order['establishment']?['phone']?.toString() ?? '';
  final shopAddress = session.establishment?['address']?.toString() ?? order['establishment']?['address']?.toString() ?? '';
  return '''
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>$title $number</title>
<style>
  body { font-family: Arial, sans-serif; color: #111; padding: 16px; max-width: 720px; margin: 0 auto; }
  h1 { font-size: 22px; margin: 0 0 4px; }
  h2 { font-size: 16px; margin: 12px 0 16px; letter-spacing: 1px; }
  p, td, th { font-size: 13px; }
  table { width: 100%; border-collapse: collapse; margin: 12px 0 16px; }
  th, td { text-align: left; padding: 6px 4px; border-bottom: 1px solid #ddd; }
  th:last-child, td:last-child { text-align: right; }
  .total { font-size: 18px; font-weight: 800; }
  .muted { color: #555; }
  .letterhead { border-bottom: 2px solid #111; padding-bottom: 12px; margin-bottom: 16px; font-size: 12px; line-height: 1.45; }
  .letterhead .brand { font-size: 22px; font-weight: 800; margin-bottom: 4px; }
  .letterhead .legal { font-weight: 700; margin-bottom: 6px; }
  @media print { .noprint { display: none; } body { padding: 0; } }
</style>
</head>
<body>
  ${ndjoCompanyHtml()}
  <div class="muted">Établissement : ${_esc(shop)}${shopAddress.isEmpty ? '' : ' · ${_esc(shopAddress)}'}${shopPhone.isEmpty ? '' : ' · ${_esc(shopPhone)}'}</div>
  <h2>$title ${_esc('$number')}</h2>
  <p>Client : ${_esc('$customer')}<br>
  Téléphone : ${_esc(phone)}<br>
  Type : ${_esc(type)} · Paiement : ${_esc(pay)}
  ${address.isEmpty ? '' : '<br>Adresse : ${_esc(address)}'}</p>
  $sections
  $totalsHtml
  ${invoice && pdf != null ? '<p class="muted">Vérification : ${_esc(pdf)}</p>' : ''}
  <p class="muted">${invoice ? 'Facture à conserver / à imprimer.' : 'Bon de commande interne et client — à imprimer localement.'}</p>
  <script>setTimeout(function(){ try { window.focus(); window.print(); } catch (e) {} }, 350);</script>
</body>
</html>
''';
}

String _esc(String value) {
  return value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');
}

Map<String, dynamic> ticketOrderFromInvoice(Map<String, dynamic> invoice) {
  final nested = invoice['order'] is Map ? Map<String, dynamic>.from(invoice['order'] as Map) : <String, dynamic>{};
  return {
    ...nested,
    'invoice': invoice,
    'total': nested['total'] ?? invoice['total'],
  };
}

Future<Map<String, dynamic>?> ensureInvoice(Session session, Map<String, dynamic> order) async {
  final id = order['id']?.toString() ?? order['orderId']?.toString() ?? order['order']?['id']?.toString();
  if (id == null || order['offline'] == true) return ticketInvoiceOf(order);
  return session.api.post('/invoices/issue/$id', {});
}

Future<void> showTicketSheet(
  BuildContext context, {
  required Session session,
  required Map<String, dynamic> order,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    isDismissible: true,
    enableDrag: true,
    backgroundColor: NdjoColors.surface,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (context) => _TicketSheet(session: session, order: Map<String, dynamic>.from(order)),
  );
}

class _TicketSheet extends StatefulWidget {
  const _TicketSheet({required this.session, required this.order});
  final Session session;
  final Map<String, dynamic> order;

  @override
  State<_TicketSheet> createState() => _TicketSheetState();
}

class _TicketSheetState extends State<_TicketSheet> {
  late Map<String, dynamic> order;
  bool busy = false;

  @override
  void initState() {
    super.initState();
    order = widget.order;
  }

  Future<void> _issueIfNeeded() async {
    setState(() => busy = true);
    try {
      final invoice = await ensureInvoice(widget.session, order);
      if (!mounted) return;
      if (invoice != null) {
        final nested = invoice['order'] is Map ? Map<String, dynamic>.from(invoice['order'] as Map) : <String, dynamic>{};
        setState(() {
          order = {
            ...order,
            ...nested,
            'items': nested['items'] ?? order['items'],
            'invoice': invoice,
            'id': order['id'] ?? nested['id'],
          };
        });
      }
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Facture : ${e.message}')));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _whatsApp({required bool invoice}) async {
    if (invoice) await _issueIfNeeded();
    if (!mounted) return;
    var phone = whatsappDigits(ticketPhone(order));
    if (phone == null) {
      final typed = TextEditingController();
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          insetPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 24),
          title: const Text('Numéro WhatsApp du client'),
          content: TextField(
            controller: typed,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(labelText: 'Téléphone (243…)'),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuler')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Ouvrir WhatsApp')),
          ],
        ),
      );
      if (ok != true) return;
      phone = whatsappDigits(typed.text);
    }
    if (phone == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Numéro WhatsApp invalide.')));
      return;
    }
    final text = ticketMessage(widget.session, order, invoice: invoice);
    await openExternal('https://wa.me/$phone?text=${Uri.encodeComponent(text)}');
  }

  Future<void> _print({required bool invoice}) async {
    if (invoice) await _issueIfNeeded();
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TicketPrintPreview(
          session: widget.session,
          order: order,
          invoice: invoice,
        ),
      ),
    );
  }

  Future<void> _copy() async {
    await _issueIfNeeded();
    final text = ticketMessage(widget.session, order, invoice: true);
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Message copié. Collez-le dans WhatsApp si besoin.')));
  }

  @override
  Widget build(BuildContext context) {
    final compact = ndjoCompact(context);
    final number = order['number']?.toString() ?? ticketInvoiceOf(order)?['number']?.toString() ?? 'Ticket';
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, 12, 16, compact ? 16 : 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(number, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                ),
                IconButton(
                  tooltip: 'Fermer',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '${ticketTypeLabel(order['type']?.toString())} · ${orderPayLabel(order)} · ${fc((order['total'] as num?) ?? 0)}',
              style: const TextStyle(color: NdjoColors.muted),
            ),
            const SizedBox(height: 8),
            const Text(
              'Pas d’API WhatsApp Business : le message s’ouvre dans WhatsApp de cet appareil. L’impression utilise l’imprimante locale (ou PDF).',
              style: TextStyle(color: NdjoColors.muted, fontSize: 12),
            ),
            const SizedBox(height: 16),
            if (busy) const LinearProgressIndicator(),
            FilledButton.icon(
              onPressed: busy ? null : () => _whatsApp(invoice: true),
              icon: const Icon(Icons.chat),
              label: const Text('WhatsApp — facture au client'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: busy ? null : () => _whatsApp(invoice: false),
              icon: const Icon(Icons.chat_bubble_outline),
              label: const Text('WhatsApp — bon de commande'),
            ),
            const SizedBox(height: 8),
            FilledButton.tonalIcon(
              onPressed: busy ? null : () => _print(invoice: true),
              icon: const Icon(Icons.print),
              label: const Text('Imprimer la facture'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: busy ? null : () => _print(invoice: false),
              icon: const Icon(Icons.receipt_long),
              label: const Text('Imprimer le bon de commande'),
            ),
            TextButton(onPressed: busy ? null : _copy, child: const Text('Copier le message')),
            const SizedBox(height: 4),
            OutlinedButton.icon(
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.close),
              label: const Text('Fermer / Annuler'),
            ),
          ],
        ),
      ),
    );
  }
}

class TicketPrintPreview extends StatefulWidget {
  const TicketPrintPreview({
    super.key,
    required this.session,
    required this.order,
    required this.invoice,
  });
  final Session session;
  final Map<String, dynamic> order;
  final bool invoice;

  @override
  State<TicketPrintPreview> createState() => _TicketPrintPreviewState();
}

class _TicketPrintPreviewState extends State<TicketPrintPreview> {
  bool sending = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _sendToPrinter());
  }

  Future<void> _sendToPrinter() async {
    setState(() => sending = true);
    try {
      await printHtml(
        ticketHtml(widget.session, widget.order, invoice: widget.invoice),
        pdfUrl: widget.invoice ? ticketPdfUrl(widget.order) : null,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Fenêtre d’impression ouverte. Choisissez l’imprimante ou Enregistrer en PDF.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Impression : $e')));
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final order = widget.order;
    final kitchen = orderKitchenItems(order);
    final drinks = orderCounterDrinks(order);
    final items = kitchen.isEmpty && drinks.isEmpty ? ticketItems(order) : <Map<String, dynamic>>[];
    final title = widget.invoice ? 'FACTURE' : 'BON DE COMMANDE';
    final number = widget.invoice
        ? (ticketInvoiceOf(order)?['number'] ?? order['number'] ?? '')
        : (order['number'] ?? '');
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: Colors.black87,
        title: Text('$title $number'),
        actions: [
          IconButton(
            tooltip: 'Imprimer',
            onPressed: sending ? null : _sendToPrinter,
            icon: const Icon(Icons.print),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          ndjoLetterhead(),
          const SizedBox(height: 12),
          Text('$title $number', style: const TextStyle(color: Colors.black, fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          Text(
            'Client : ${order['customerName'] ?? order['customer']?['name'] ?? '—'}\n'
            'Tél. : ${ticketPhone(order) ?? '—'}\n'
            '${ticketTypeLabel(order['type']?.toString())} · ${orderPayLabel(order)}',
            style: const TextStyle(color: Colors.black87, height: 1.4),
          ),
          const SizedBox(height: 16),
          if (kitchen.isNotEmpty) ...[
            const Text('Nourriture (cuisine)', style: TextStyle(color: Colors.black, fontWeight: FontWeight.w800)),
            ...kitchen.map((item) => _printLine(item)),
            const SizedBox(height: 8),
          ],
          if (drinks.isNotEmpty) ...[
            const Text('Boissons (gestion interne)', style: TextStyle(color: Colors.black, fontWeight: FontWeight.w800)),
            ...drinks.map((item) => _printLine(item)),
            const SizedBox(height: 8),
          ],
          ...items.map((item) => _printLine(item)),
          const Divider(color: Colors.black26),
          Text(
            'Total net ${fc((order['total'] as num?) ?? (ticketInvoiceOf(order)?['total'] as num?) ?? 0)}',
            style: const TextStyle(color: Colors.black, fontSize: 20, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 16),
          if (sending) const LinearProgressIndicator(),
          FilledButton.icon(
            onPressed: sending ? null : _sendToPrinter,
            icon: const Icon(Icons.print),
            label: Text(widget.invoice ? 'Imprimer / PDF facture' : 'Imprimer le bon'),
          ),
        ],
      ),
    );
  }

  Widget _printLine(Map<String, dynamic> item) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '${item['quantity'] ?? 1} × ${item['name'] ?? ''}',
              style: const TextStyle(color: Colors.black87),
            ),
          ),
          Text(
            fc((item['lineTotal'] as num?) ?? ((item['unitPrice'] as num? ?? 0) * (item['quantity'] as num? ?? 1))),
            style: const TextStyle(color: Colors.black, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}
