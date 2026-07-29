export type ViewerKind =
  | 'pdf' | 'html' | 'docx' | 'xlsx' | 'text'
  | 'pptx' | 'epub' | 'rtf' | 'odf' | 'archive';

export type Tier = 'stable' | 'experimental';

export interface DetectResult {
  kind: ViewerKind;
  tier: Tier;
}

// High-confidence: mature, well-tested libraries (or no library at all).
// Best-effort: newer/less battle-tested renderers, accepted as lower
// fidelity by design. Apple iWork (.pages/.numbers/.key) and legacy binary
// Office (.doc/.xls/.ppt) are deliberately absent — no viable client-side
// renderer exists for either, so they fall through to `null` (download-only,
// completely untouched by this script).
const EXT_MAP: Record<string, DetectResult> = {
  pdf: { kind: 'pdf', tier: 'stable' },
  html: { kind: 'html', tier: 'stable' },
  htm: { kind: 'html', tier: 'stable' },
  docx: { kind: 'docx', tier: 'stable' },
  xlsx: { kind: 'xlsx', tier: 'stable' },

  txt: { kind: 'text', tier: 'stable' },
  md: { kind: 'text', tier: 'stable' },
  markdown: { kind: 'text', tier: 'stable' },
  csv: { kind: 'text', tier: 'stable' },
  json: { kind: 'text', tier: 'stable' },
  xml: { kind: 'text', tier: 'stable' },
  yaml: { kind: 'text', tier: 'stable' },
  yml: { kind: 'text', tier: 'stable' },
  py: { kind: 'text', tier: 'stable' },
  js: { kind: 'text', tier: 'stable' },
  ts: { kind: 'text', tier: 'stable' },
  tsx: { kind: 'text', tier: 'stable' },
  jsx: { kind: 'text', tier: 'stable' },
  sh: { kind: 'text', tier: 'stable' },
  go: { kind: 'text', tier: 'stable' },
  rs: { kind: 'text', tier: 'stable' },
  java: { kind: 'text', tier: 'stable' },
  c: { kind: 'text', tier: 'stable' },
  cpp: { kind: 'text', tier: 'stable' },
  css: { kind: 'text', tier: 'stable' },
  toml: { kind: 'text', tier: 'stable' },
  ini: { kind: 'text', tier: 'stable' },
  log: { kind: 'text', tier: 'stable' },

  pptx: { kind: 'pptx', tier: 'experimental' },
  epub: { kind: 'epub', tier: 'experimental' },
  rtf: { kind: 'rtf', tier: 'experimental' },
  odt: { kind: 'odf', tier: 'experimental' },
  ods: { kind: 'odf', tier: 'experimental' },
  odp: { kind: 'odf', tier: 'experimental' },
  zip: { kind: 'archive', tier: 'experimental' },
  tar: { kind: 'archive', tier: 'experimental' },
  gz: { kind: 'archive', tier: 'experimental' },
  tgz: { kind: 'archive', tier: 'experimental' },
};

export function detect(filename: string): DetectResult | null {
  const ext = filename.split('.').pop()?.toLowerCase() ?? '';
  return EXT_MAP[ext] ?? null;
}
