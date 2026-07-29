// Sandboxed iframe, "allow-popups" ONLY. Deliberately does NOT include
// allow-scripts or allow-same-origin (that combination together would
// defeat the isolation) — this is untrusted, user-uploaded HTML being
// previewed on a page that also holds the viewer's own session, so no
// script execution and no access to Owl's cookies/session is allowed.
//
// Memos itself serves .html attachments with Content-Disposition: attachment
// and Content-Type: application/octet-stream (confirmed live, unlike PDFs —
// only images/PDF are exempted from Memos' own forced-download handling; for
// every other type, including HTML, this is a deliberate anti-XSS measure so
// a direct navigation to the raw URL never executes as same-origin HTML).
// Pointing iframe.src straight at that URL makes the browser attempt a
// download instead of rendering it, leaving the frame blank. fetch()ing the
// body and injecting it via srcdoc sidesteps Content-Disposition/Content-Type
// entirely (neither applies to fetch reads or to how srcdoc content is
// interpreted) — the sandbox attribute still applies identically to srcdoc
// content as it would to a normal navigation.
export async function renderHtml(url: string, container: HTMLElement) {
  const resp = await fetch(url);
  const html = await resp.text();
  const iframe = document.createElement('iframe');
  iframe.className = 'dv-html-frame';
  iframe.setAttribute('sandbox', 'allow-popups');
  iframe.srcdoc = html;
  container.replaceChildren(iframe);
}
