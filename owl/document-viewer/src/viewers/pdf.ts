// No library — the browser's own native PDF renderer handles this.
//
// Cache-busts the iframe request: a browser that already cached this exact
// URL from before a header/config fix (or any other framing-relevant
// response change) would otherwise keep serving that stale cached response
// to the iframe indefinitely, silently reintroducing a "refused to
// connect" failure that a plain reload/re-fetch elsewhere wouldn't catch.
export async function renderPdf(url: string, container: HTMLElement) {
  const iframe = document.createElement('iframe');
  iframe.src = url + (url.includes('?') ? '&' : '?') + '_dv=' + Date.now();
  iframe.className = 'dv-pdf-frame';
  container.replaceChildren(iframe);
}
