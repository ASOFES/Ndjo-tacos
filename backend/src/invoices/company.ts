export const COMPANY = {
  brand: 'NDJO TACOS',
  legalName: 'INSTITUTS DE PREPARATION ET D’INTEGRATION PROFESSIONNELLE — IPIP SARLU',
  address:
    '13, avenue Moero, quartier Makutano, commune de Lubumbashi, ville de Lubumbashi, Haut-Katanga, RDC',
  rccm: 'CD/KNG/RCCM/20-B-01352',
  idNat: '01-P8501-N65708S',
  nif: 'A2045094N',
  phone: '+243 999 988 867',
};

export function companyPdfLines() {
  return [
    COMPANY.brand,
    `Telephone : ${COMPANY.phone}`,
    `ID. NAT. : ${COMPANY.idNat}`,
    `NIF : ${COMPANY.nif}`,
  ];
}

export function companyPublic() {
  return {
    brand: COMPANY.brand,
    idNat: COMPANY.idNat,
    nif: COMPANY.nif,
    phone: COMPANY.phone,
  };
}
