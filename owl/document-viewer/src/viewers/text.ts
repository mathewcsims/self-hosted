const MARKDOWN_EXT = new Set(['md', 'markdown']);

export async function renderText(url: string, filename: string, container: HTMLElement) {
  const resp = await fetch(url);
  const text = await resp.text();
  const ext = filename.split('.').pop()?.toLowerCase() ?? '';

  if (MARKDOWN_EXT.has(ext)) {
    const { marked } = await import('marked');
    const DOMPurify = (await import('dompurify')).default;
    const raw = await marked.parse(text);
    const clean = DOMPurify.sanitize(raw);
    const div = document.createElement('div');
    div.className = 'dv-markdown';
    div.innerHTML = clean;
    container.replaceChildren(div);
    return;
  }

  const hljs = (await import('highlight.js')).default;
  const pre = document.createElement('pre');
  pre.className = 'dv-text-pre';
  const code = document.createElement('code');
  code.textContent = text;
  pre.appendChild(code);
  container.replaceChildren(pre);
  try {
    hljs.highlightElement(code);
  } catch {
    // Highlighting is a nicety, not the point — fall back to plain text
    // rather than failing the whole preview if a language guess throws.
  }
}
