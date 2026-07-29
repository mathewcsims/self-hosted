// Best-effort tier. Reads the RTF control-word stream directly and
// renders it into the DOM in-browser — same "parse the real file, render
// natively, no intermediate file or server round-trip" pattern as
// docx-preview, just applied to RTF's simpler (and less visually precise)
// spec.
export async function renderRtf(url: string, container: HTMLElement) {
  const { RTFJS } = await import('rtf.js');
  const resp = await fetch(url);
  const arrayBuffer = await resp.arrayBuffer();
  const doc = new RTFJS.Document(arrayBuffer, {});
  const htmlElements = await doc.render();
  const target = document.createElement('div');
  target.style.cssText = 'padding:16px;overflow:auto';
  htmlElements.forEach((el: HTMLElement) => target.appendChild(el));
  container.replaceChildren(target);
}
