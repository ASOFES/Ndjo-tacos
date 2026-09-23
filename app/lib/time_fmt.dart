String formatLocalDateTime(dynamic value) {
  if (value == null) return '—';
  final parsed = DateTime.tryParse(value.toString());
  if (parsed == null) {
    final text = value.toString();
    return text.contains('T') ? text.replaceFirst('T', ' ').split('.').first : text;
  }
  final local = parsed.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} ${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
}

String formatRecordWhen(dynamic item) {
  if (item is! Map) return '—';
  return formatLocalDateTime(
    item['createdAt'] ??
        item['updatedAt'] ??
        item['occurredAt'] ??
        item['entryDate'] ??
        item['shippedAt'] ??
        item['receivedAt'] ??
        item['countedAt'] ??
        item['queuedAt'] ??
        item['paidAt'] ??
        item['syncedAt'],
  );
}

String withMovementWhen(dynamic item, String rest) {
  final when = formatRecordWhen(item);
  if (when == '—') return rest;
  if (rest.contains(when)) return rest;
  if (rest.trim().isEmpty) return when;
  return '$when · $rest';
}
