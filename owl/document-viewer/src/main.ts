import { detect } from './format-detect';
import { createPreviewBadge } from './badge';
import { openViewer } from './modal';
import inlineStyles from './styles.css';

function injectBaseStyles() {
  if (document.getElementById('dv-base-styles')) return;
  const style = document.createElement('style');
  style.id = 'dv-base-styles';
  style.textContent = inlineStyles;
  document.head.appendChild(style);
}

function decorate(anchor: HTMLAnchorElement) {
  const filename = anchor.getAttribute('download') || anchor.href.split('/').pop() || '';
  const result = detect(filename);
  // Unrecognized types (including Apple iWork and legacy binary Office,
  // which are deliberately absent from format-detect's map) get no badge
  // and no click handler at all — native force-download behavior for
  // these is completely unchanged, no code path below touches them.
  if (!result) return;

  // Memos' DocumentItem markup (confirmed against the pinned Memos
  // version's own source) is: <a download><div class="...flex
  // justify-between..."><div icon/text /><DownloadIcon /></div></a> — a
  // two-child flex row (`justify-between`) as the anchor's only child.
  // Inserting the badge as a normal THIRD flex child broke that
  // distribution (justify-between spread three items unpredictably
  // depending on filename length) and risked React's reconciliation
  // fighting over the DownloadIcon's exact position on re-render. Instead
  // the badge is absolutely positioned *within* the row (which stays a
  // completely untouched two-child flex row) so it floats just left of
  // the DownloadIcon without touching Memos' own DOM nodes or layout at
  // all — position:absolute removes it from flex flow entirely.
  const row = anchor.firstElementChild;
  if (!row || !(row instanceof HTMLElement)) return;

  // Idempotent against React re-rendering the row's children (which would
  // otherwise wipe an injected node): re-check on every call rather than
  // relying on a persistent flag, since the anchor/row may be reused by
  // React while their children get replaced.
  if (row.querySelector('.dv-preview-badge')) return;

  if (getComputedStyle(row).position === 'static') {
    row.style.position = 'relative';
  }

  const { kind, tier } = result;
  const badge = createPreviewBadge(tier, () => {
    openViewer(kind, tier, anchor.href, filename);
  });
  row.appendChild(badge);
  // Deliberately NOT touching anchor.title, the row's other children, or
  // adding a click listener to the anchor itself — clicking anywhere else
  // on the row (including Memos' own download icon) must keep behaving
  // exactly as native Memos does today. Only the badge button opens the
  // preview modal.
}

function scan(root: ParentNode) {
  root.querySelectorAll<HTMLAnchorElement>('a[download]').forEach(decorate);
}

function init() {
  injectBaseStyles();
  scan(document);

  // Memos is an SPA — attachments load/unload without full page
  // navigation, and React may recreate or reuse the anchor at any time —
  // so this re-scans on every DOM change rather than once at load.
  new MutationObserver((mutations) => {
    for (const m of mutations) {
      m.addedNodes.forEach((n) => {
        if (n instanceof HTMLElement) {
          if (n.matches?.('a[download]')) decorate(n as HTMLAnchorElement);
          scan(n);
        }
      });
    }
  }).observe(document.body, { childList: true, subtree: true });
}

if (document.body) {
  init();
} else {
  document.addEventListener('DOMContentLoaded', init);
}
