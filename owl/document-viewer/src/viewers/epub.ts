// Best-effort tier. epub.js parses the zip-based EPUB container and
// renders chapters into its own iframe-backed reader pane — no
// intermediate file conversion, just client-side parsing of the real
// EPUB (itself a documented, open, zip+XHTML format).
export async function renderEpub(url: string, container: HTMLElement) {
  const ePub = (await import('epubjs')).default;
  const target = document.createElement('div');
  target.style.cssText = 'width:100%;height:100%';
  container.replaceChildren(target);

  const resp = await fetch(url);
  const arrayBuffer = await resp.arrayBuffer();
  const book = ePub(arrayBuffer);
  const rendition = book.renderTo(target, { width: '100%', height: '100%' });
  await rendition.display();

  const nav = document.createElement('div');
  nav.style.cssText = 'position:absolute;bottom:8px;right:8px;display:flex;gap:8px';
  const prev = document.createElement('button');
  prev.textContent = '‹ Prev';
  prev.onclick = () => rendition.prev();
  const next = document.createElement('button');
  next.textContent = 'Next ›';
  next.onclick = () => rendition.next();
  nav.append(prev, next);
  container.appendChild(nav);
}
