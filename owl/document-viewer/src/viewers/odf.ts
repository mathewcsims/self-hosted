// Best-effort tier. No actively-maintained client-side ODF renderer is as
// mature as docx-preview/Univer.js, so this is a minimal custom XML
// extraction rather than a full layout-preserving renderer: ODF is a
// documented, open, XML-in-zip format (same shape as DOCX/XLSX), so this
// unzips content.xml and pulls readable text out of it — genuine native
// parsing of the real file, just lower fidelity than the stable-tier
// viewers. Degrades to the modal's generic "download instead" on failure.
export async function renderOdf(url: string, filename: string, container: HTMLElement) {
  const { unzipSync, strFromU8 } = await import('fflate');
  const resp = await fetch(url);
  const buf = new Uint8Array(await resp.arrayBuffer());
  const files = unzipSync(buf, { filter: (f) => f.name === 'content.xml' });
  const xmlBytes = files['content.xml'];
  if (!xmlBytes) throw new Error('No content.xml found in ODF container');

  const xml = strFromU8(xmlBytes);
  const parser = new DOMParser();
  const doc = parser.parseFromString(xml, 'application/xml');
  const paragraphs = Array.from(doc.getElementsByTagNameNS('*', 'p'));

  const target = document.createElement('div');
  target.style.cssText = 'padding:16px 24px;overflow:auto';
  if (paragraphs.length === 0) {
    target.textContent = `Could not extract readable text from ${filename}.`;
  } else {
    for (const p of paragraphs) {
      const line = document.createElement('p');
      line.textContent = p.textContent ?? '';
      target.appendChild(line);
    }
  }
  container.replaceChildren(target);
}
