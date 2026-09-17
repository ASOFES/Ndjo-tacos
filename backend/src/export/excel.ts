function xml(value: unknown) {
  return String(value ?? '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

export type ExcelSheet = {
  name: string;
  headers: string[];
  rows: unknown[][];
};

export function buildExcel(sheets: ExcelSheet[]) {
  const worksheets = sheets.map((sheet) => {
    const header = `<Row>${sheet.headers
      .map((cell) => `<Cell><Data ss:Type="String">${xml(cell)}</Data></Cell>`)
      .join('')}</Row>`;
    const body = sheet.rows
      .map(
        (row) =>
          `<Row>${row
            .map((cell) => {
              const numeric = typeof cell === 'number' && Number.isFinite(cell);
              return `<Cell><Data ss:Type="${numeric ? 'Number' : 'String'}">${xml(cell)}</Data></Cell>`;
            })
            .join('')}</Row>`,
      )
      .join('');
    return `<Worksheet ss:Name="${xml(sheet.name.slice(0, 31))}"><Table>${header}${body}</Table></Worksheet>`;
  });
  return Buffer.from(
    `\uFEFF<?xml version="1.0" encoding="UTF-8"?>
<?mso-application progid="Excel.Sheet"?>
<Workbook xmlns="urn:schemas-microsoft-com:office:spreadsheet"
 xmlns:ss="urn:schemas-microsoft-com:office:spreadsheet">
${worksheets.join('\n')}
</Workbook>`,
    'utf8',
  );
}
