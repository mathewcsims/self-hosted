// No packaged Univer.js xlsx import-facade exists in the open/free tier
// (confirmed by searching npm at implementation time — only paid
// @univerjs-pro packages offer bundled xlsx import). So this uses SheetJS
// Community Edition (`xlsx`, MIT-licensed) for exactly what its free tier
// still does — reading real cell values/structure out of the actual .xlsx
// file, no conversion to another file format — and hands that data to
// Univer's own rendering engine to actually draw the grid. Univer does the
// rendering; SheetJS only extracts values. Cell style/merge/chart fidelity
// is lower than a full paid import would give (SheetJS CE strips most
// formatting), which is why XLSX stays worth noting as not pixel-perfect,
// but this is still genuine native parsing + native in-browser rendering,
// not a conversion pipeline.
//
// NOTE: the installed @univerjs/core version (0.4.2) exposes the older
// `new Univer({...}).registerPlugin(...)` API, not the newer `createUniver`
// facade some Univer docs describe — pinned deliberately to this API shape;
// if the package version ever moves, re-check this against the installed
// types before assuming the calls below still match.
export async function renderXlsx(url: string, container: HTMLElement) {
  const [XLSX, { Univer, LocaleType }, { defaultTheme }] = await Promise.all([
    import('xlsx'),
    import('@univerjs/core'),
    import('@univerjs/design'),
  ]);
  const { UniverSheetsPlugin } = await import('@univerjs/sheets');
  const { UniverSheetsUIPlugin } = await import('@univerjs/sheets-ui');
  const { UniverUIPlugin } = await import('@univerjs/ui');
  const { UniverRenderEnginePlugin } = await import('@univerjs/engine-render');
  const { UniverFormulaEnginePlugin } = await import('@univerjs/engine-formula');

  const target = document.createElement('div');
  target.style.cssText = 'width:100%;height:100%';
  container.replaceChildren(target);

  const resp = await fetch(url);
  const arrayBuffer = await resp.arrayBuffer();
  const wb = XLSX.read(arrayBuffer, { type: 'array' });

  const sheets: Record<string, any> = {};
  wb.SheetNames.forEach((name, idx) => {
    const ws = wb.Sheets[name];
    const ref = ws['!ref'];
    const range = ref ? XLSX.utils.decode_range(ref) : { s: { r: 0, c: 0 }, e: { r: 0, c: 0 } };
    const cellData: Record<number, Record<number, any>> = {};
    for (const cellAddr of Object.keys(ws)) {
      if (cellAddr.startsWith('!')) continue;
      const cell = ws[cellAddr];
      const pos = XLSX.utils.decode_cell(cellAddr);
      cellData[pos.r] ??= {};
      cellData[pos.r][pos.c] = { v: cell.v, t: cell.t === 'n' ? 2 : cell.t === 'b' ? 3 : 1 };
    }
    sheets[`sheet-${idx}`] = {
      id: `sheet-${idx}`,
      name,
      cellData,
      rowCount: Math.max(range.e.r + 1, 50),
      columnCount: Math.max(range.e.c + 1, 20),
    };
  });

  const univer = new Univer({
    theme: defaultTheme,
    locale: LocaleType.EN_US,
  });

  univer.registerPlugin(UniverRenderEnginePlugin);
  univer.registerPlugin(UniverFormulaEnginePlugin);
  univer.registerPlugin(UniverUIPlugin, { container: target });
  univer.registerPlugin(UniverSheetsPlugin);
  univer.registerPlugin(UniverSheetsUIPlugin);

  univer.createUniverSheet({
    id: 'dv-workbook',
    sheetOrder: wb.SheetNames.map((_, idx) => `sheet-${idx}`),
    sheets,
  });
}
