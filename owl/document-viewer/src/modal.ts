import type { ViewerKind, Tier } from './format-detect';

// Appended as a sibling of React's root (document.body), never inside it —
// React never reconciles this subtree, so there's no fight over DOM
// ownership the way there would be if we tried to mutate Memos' own
// attachment-list markup beyond the badge's data attributes.
export function openViewer(kind: ViewerKind, tier: Tier, url: string, filename: string) {
  const overlay = document.createElement('div');
  overlay.className = 'dv-overlay';
  overlay.innerHTML = `
    <div class="dv-modal" role="dialog" aria-modal="true">
      <div class="dv-header">
        <span class="dv-filename">${escapeHtml(filename)}</span>
        ${tier === 'experimental' ? '<span class="dv-experimental-tag">experimental preview</span>' : ''}
        <button class="dv-close" aria-label="Close">&times;</button>
      </div>
      <div class="dv-body"><div class="dv-loading">Loading…</div></div>
    </div>`;
  document.body.appendChild(overlay);

  const close = () => overlay.remove();
  overlay.querySelector('.dv-close')!.addEventListener('click', close);
  overlay.addEventListener('click', (e) => {
    if (e.target === overlay) close();
  });
  document.addEventListener('keydown', function onKey(e) {
    if (e.key === 'Escape') {
      close();
      document.removeEventListener('keydown', onKey);
    }
  });

  const body = overlay.querySelector('.dv-body') as HTMLElement;
  render(kind, url, filename, body).catch((err) => {
    console.error('document-viewer render failed', err);
    body.innerHTML = `<p class="dv-error">Preview failed — <a href="${url}" download>download instead</a>.</p>`;
  });
}

async function render(kind: ViewerKind, url: string, filename: string, body: HTMLElement) {
  switch (kind) {
    case 'pdf': {
      const { renderPdf } = await import('./viewers/pdf');
      return renderPdf(url, body);
    }
    case 'html': {
      const { renderHtml } = await import('./viewers/html');
      return renderHtml(url, body);
    }
    case 'docx': {
      const { renderDocx } = await import('./viewers/docx');
      return renderDocx(url, body);
    }
    case 'xlsx': {
      const { renderXlsx } = await import('./viewers/xlsx');
      return renderXlsx(url, body);
    }
    case 'text': {
      const { renderText } = await import('./viewers/text');
      return renderText(url, filename, body);
    }
    case 'pptx': {
      const { renderPptx } = await import('./viewers/pptx');
      return renderPptx(url, body);
    }
    case 'epub': {
      const { renderEpub } = await import('./viewers/epub');
      return renderEpub(url, body);
    }
    case 'rtf': {
      const { renderRtf } = await import('./viewers/rtf');
      return renderRtf(url, body);
    }
    case 'odf': {
      const { renderOdf } = await import('./viewers/odf');
      return renderOdf(url, filename, body);
    }
    case 'archive': {
      const { renderArchive } = await import('./viewers/archive');
      return renderArchive(url, filename, body);
    }
  }
}

function escapeHtml(s: string): string {
  const div = document.createElement('div');
  div.textContent = s;
  return div.innerHTML;
}
