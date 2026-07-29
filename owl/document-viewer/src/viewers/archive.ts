// Best-effort tier. Deliberately lists entries only — never extracts or
// previews entry contents — so this stays a simple, low-risk feature.
export async function renderArchive(url: string, filename: string, container: HTMLElement) {
  const ext = filename.split('.').pop()?.toLowerCase() ?? '';
  const resp = await fetch(url);
  const buf = new Uint8Array(await resp.arrayBuffer());

  const entries = ext === 'zip' ? await listZipEntries(buf) : await listTarEntries(buf, ext);

  const table = document.createElement('table');
  table.className = 'dv-archive-table';
  table.innerHTML = '<thead><tr><th>Name</th><th>Size</th></tr></thead>';
  const tbody = document.createElement('tbody');
  for (const e of entries) {
    const tr = document.createElement('tr');
    tr.innerHTML = `<td>${escapeHtml(e.name)}</td><td>${e.size.toLocaleString()} bytes</td>`;
    tbody.appendChild(tr);
  }
  table.appendChild(tbody);

  const wrap = document.createElement('div');
  wrap.style.cssText = 'padding:8px 16px;overflow:auto';
  wrap.appendChild(table);
  container.replaceChildren(wrap);
}

async function listZipEntries(buf: Uint8Array): Promise<{ name: string; size: number }[]> {
  const { unzipSync } = await import('fflate');
  const files = unzipSync(buf);
  return Object.entries(files).map(([name, data]) => ({ name, size: data.length }));
}

// .tar / .tar.gz / .tgz: gzip is decompressed via fflate if needed, then
// the tar format itself (512-byte header blocks, name at offset 0/100
// bytes, octal size at offset 124/12 bytes) is simple enough to walk
// directly without pulling in a dedicated tar library.
async function listTarEntries(buf: Uint8Array, ext: string): Promise<{ name: string; size: number }[]> {
  let data = buf;
  if (ext === 'gz' || ext === 'tgz') {
    const { gunzipSync } = await import('fflate');
    data = gunzipSync(buf);
  }
  const entries: { name: string; size: number }[] = [];
  let offset = 0;
  while (offset + 512 <= data.length) {
    const header = data.subarray(offset, offset + 512);
    if (header.every((b) => b === 0)) break; // end-of-archive padding block
    const name = readCString(header, 0, 100);
    const sizeOctal = readCString(header, 124, 12).trim();
    const size = sizeOctal ? parseInt(sizeOctal, 8) : 0;
    if (name) entries.push({ name, size });
    const contentBlocks = Math.ceil(size / 512);
    offset += 512 + contentBlocks * 512;
  }
  return entries;
}

function readCString(buf: Uint8Array, start: number, len: number): string {
  const slice = buf.subarray(start, start + len);
  const zeroIdx = slice.indexOf(0);
  const trimmed = zeroIdx >= 0 ? slice.subarray(0, zeroIdx) : slice;
  return new TextDecoder().decode(trimmed);
}

function escapeHtml(s: string): string {
  const div = document.createElement('div');
  div.textContent = s;
  return div.innerHTML;
}
