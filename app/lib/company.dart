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
        legalName,
        'Adresse physique : $address',
        'RCCM : $rccm',
        'ID. NAT. : $idNat',
        'NIF : $nif',
        'Téléphone : $phone',
      ];
}

String ndjoCompanyHtml() {
  String esc(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');
  return '''
  <div class="letterhead">
    <div class="brand">${esc(NdjoCompany.brand)}</div>
    <div class="legal">${esc(NdjoCompany.legalName)}</div>
    <div>${esc(NdjoCompany.address)}</div>
    <div>RCCM : ${esc(NdjoCompany.rccm)}</div>
    <div>ID. NAT. : ${esc(NdjoCompany.idNat)}</div>
    <div>NIF : ${esc(NdjoCompany.nif)}</div>
    <div>Téléphone : ${esc(NdjoCompany.phone)}</div>
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
          const Text(NdjoCompany.legalName, style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12, height: 1.35)),
          const SizedBox(height: 6),
          const Text(NdjoCompany.address, style: TextStyle(color: NdjoColors.muted, fontSize: 12, height: 1.35)),
          const SizedBox(height: 8),
          const Text('RCCM : ${NdjoCompany.rccm}', style: TextStyle(fontSize: 12)),
          const Text('ID. NAT. : ${NdjoCompany.idNat}', style: TextStyle(fontSize: 12)),
          const Text('NIF : ${NdjoCompany.nif}', style: TextStyle(fontSize: 12)),
          const Text('Téléphone : ${NdjoCompany.phone}', style: TextStyle(fontSize: 12)),
        ],
      ),
    ),
  );
}
