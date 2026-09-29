bool isNdjoDrink(dynamic item) {
  if (item is! Map) return false;
  final map = Map<String, dynamic>.from(item);
  final category = map['category'];
  final categoryName = category is Map ? category['name']?.toString() ?? '' : map['categoryName']?.toString() ?? '';
  final code = (map['code'] ?? '').toString().toUpperCase();
  final blob = [
    categoryName,
    map['subcategory'],
    map['name'],
    map['kind'],
    code,
  ].where((part) => part != null).join(' ').toLowerCase();
  final folded = blob.replaceAll(RegExp(r'[éèê]'), 'e').replaceAll('ö', 'o');
  if (code.startsWith('BOI-') || code.startsWith('BEV-')) return true;
  const needles = [
    'boisson',
    'soda',
    'fanta',
    'coca',
    'sprite',
    'eau miner',
    'jus ',
    ' jus',
    'biere',
    'bière',
    'limonade',
    'malta',
    'energy',
    'drink',
  ];
  if (needles.any(folded.contains)) return true;
  return folded == 'eau' || folded.trim() == 'eau';
}

List<Map<String, dynamic>> orderLineMaps(Map<String, dynamic> order) {
  final items = order['items'] as List<dynamic>? ?? [];
  return [
    for (final item in items)
      if (item is Map) Map<String, dynamic>.from(item),
  ];
}

List<Map<String, dynamic>> orderKitchenItems(Map<String, dynamic> order) {
  final tagged = order['kitchenItems'];
  if (tagged is List && tagged.isNotEmpty) {
    return [for (final item in tagged) if (item is Map) Map<String, dynamic>.from(item)];
  }
  return orderLineMaps(order).where((item) => !isNdjoDrink(item)).toList();
}

List<Map<String, dynamic>> orderCounterDrinks(Map<String, dynamic> order) {
  final tagged = order['counterItems'];
  if (tagged is List) {
    return [for (final item in tagged) if (item is Map) Map<String, dynamic>.from(item)];
  }
  return orderLineMaps(order).where(isNdjoDrink).toList();
}

bool orderNeedsKitchen(Map<String, dynamic> order) => orderKitchenItems(order).isNotEmpty;

String orderSplitLines(List<Map<String, dynamic>> items) {
  if (items.isEmpty) return '';
  return items.map((item) => '${item['quantity'] ?? 1} × ${item['name'] ?? ''}').join(', ');
}
