import 'package:flutter/material.dart';

import 'theme.dart';

class NdjoCompany {
  static const brand = 'NDJO TACOS';
  static const legalName =
      'INSTITUTS DE PRÉPARATION ET D’INTÉGRATION PROFESSIONNELLE — IPIP SARLU';
  static const address =
      '13, avenue Moero, quartier Makutano, commune de Lubumbashi, ville de Lubumbashi, Haut-Katanga, RDC';
  static const rccm = 'CD/KNG/RCCM/20-B-01352';
  static const idNat = '01-P8501-N65708S';
  static const nif = 'A2045094N';
  static const phone = '+243 999 988 867';

  static List<String> get printLines => [
        brand,
        'Téléphone : $phone',
        'ID. NAT. : $idNat',
        'NIF : $nif',
      ];
}

String ndjoCompanyHtml({bool compact = false}) {
  String esc(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');
  if (compact) {
    return '''
  <div class="letterhead">
    <div class="brand">${esc(NdjoCompany.brand)}</div>
    <div>${esc(NdjoCompany.phone)}</div>
  </div>
''';
  }
  return '''
  <div class="letterhead">
    <div class="brand">${esc(NdjoCompany.brand)}</div>
    <div>Téléphone : ${esc(NdjoCompany.phone)}</div>
    <div>ID. NAT. : ${esc(NdjoCompany.idNat)} · NIF : ${esc(NdjoCompany.nif)}</div>
  </div>
''';
}

Widget ndjoLetterhead({bool compact = false}) {
  return Card(
    child: Padding(
      padding: EdgeInsets.all(compact ? 12 : 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(NdjoCompany.brand, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: NdjoColors.accent)),
          const SizedBox(height: 6),
          const Text('Téléphone : ${NdjoCompany.phone}', style: TextStyle(fontSize: 12)),
          if (!compact) ...[
            const Text('ID. NAT. : ${NdjoCompany.idNat} · NIF : ${NdjoCompany.nif}', style: TextStyle(fontSize: 12)),
          ],
        ],
      ),
    ),
  );
}
