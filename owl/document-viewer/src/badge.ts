import type { Tier } from './format-detect';

// A REAL button (not a CSS pseudo-element) so it can have its own click
// handler, separate from the row's native download behavior. Sized and
// styled to sit as an ordinary flex sibling next to Memos' own
// DownloadIcon inside its attachment row — main.ts inserts it into that
// exact flex container (`row.insertBefore(badge, row.lastElementChild)`)
// rather than absolutely positioning it, so it participates in the same
// gap/alignment the row already has instead of floating on top of
// existing content.
export function createPreviewBadge(tier: Tier, onClick: (e: MouseEvent) => void): HTMLButtonElement {
  const btn = document.createElement('button');
  btn.type = 'button';
  btn.className = 'dv-preview-badge';
  btn.dataset.dvTier = tier;
  btn.setAttribute('aria-label', tier === 'experimental' ? 'Preview (experimental)' : 'Preview');
  btn.innerHTML =
    '<svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2">' +
    '<path d="M1 12s4-8 11-8 11 8 11 8-4 8-11 8-11-8-11-8z"/><circle cx="12" cy="12" r="3"/></svg>';
  btn.addEventListener('click', (e) => {
    e.preventDefault();
    e.stopPropagation();
    onClick(e);
  });
  return btn;
}
