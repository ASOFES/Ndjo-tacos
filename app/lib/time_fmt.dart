import 'package:flutter/material.dart';

import 'theme.dart';

const _whenKeys = [
  'createdAt',
  'updatedAt',
  'occurredAt',
  'entryDate',
  'shippedAt',
  'receivedAt',
  'countedAt',
  'queuedAt',
  'paidAt',
  'syncedAt',
  'pickedUpAt',
  'departedAt',
  'arrivedAt',
  'deliveredAt',
  'recordedAt',
  'publishedAt',
  'submittedAt',
  'validatedAt',
  'otpSentAt',
  'otpVerifiedAt',
  'lastSeenAt',
  'timestamp',
  'at',
  'date',
  'created_at',
  'updated_at',
];

DateTime? parseWhen(dynamic value, [int depth = 0]) {
  if (value == null || depth > 4) return null;
  if (value is DateTime) return value.toLocal();
  if (value is num) {
    final n = value.round();
    if (n > 100000000000) {
      return DateTime.fromMillisecondsSinceEpoch(n, isUtc: true).toLocal();
    }
    if (n > 1000000000) {
      return DateTime.fromMillisecondsSinceEpoch(n * 1000, isUtc: true).toLocal();
    }
    return null;
  }
  if (value is Map) {
    for (final key in _whenKeys) {
      if (!value.containsKey(key) || value[key] == null) continue;
      final hit = parseWhen(value[key], depth + 1);
      if (hit != null) return hit;
    }
    for (final key in const ['order', 'invoice', 'lot', 'product', 'session', 'purchase', 'movement']) {
      final nested = value[key];
      if (nested == null) continue;
      final hit = parseWhen(nested, depth + 1);
      if (hit != null) return hit;
    }
    return null;
  }
  final text = value.toString().trim();
  if (text.isEmpty || text == 'null' || text == '—') return null;
  return DateTime.tryParse(text)?.toLocal();
}

String formatLocalDateTime(dynamic value) {
  final parsed = parseWhen(value);
  if (parsed == null) return '—';
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(parsed.day)}/${two(parsed.month)}/${parsed.year} à ${two(parsed.hour)}:${two(parsed.minute)}';
}

String formatRecordWhen(dynamic item) => formatLocalDateTime(item);

String withMovementWhen(dynamic item, String rest) {
  final when = formatRecordWhen(item);
  if (when == '—') return rest;
  if (rest.contains(when)) return rest;
  if (rest.trim().isEmpty) return when;
  return '$when · $rest';
}

class NdjoWhenText extends StatelessWidget {
  const NdjoWhenText(this.item, {super.key, this.align = TextAlign.left});
  final dynamic item;
  final TextAlign align;

  @override
  Widget build(BuildContext context) {
    return Text(
      formatRecordWhen(item),
      textAlign: align,
      style: const TextStyle(
        color: NdjoColors.accent,
        fontWeight: FontWeight.w800,
        fontSize: 13,
      ),
    );
  }
}
