// Builds the Owl document-viewer bundle. Entry chunk (main.js) is kept
// deliberately tiny — it runs unconditionally on every Owl page load via
// Memos' additionalScript hook. Each format-specific renderer under
// src/viewers/ is only pulled in via dynamic import() when a user actually
// opens that file type, so splitting: true + format: 'esm' produces
// separate lazy chunks (docx-*.js, xlsx-*.js, etc.) instead of one
// monolithic bundle. See SETUP.md's Owl section for the full rationale.
import * as esbuild from 'esbuild';

await esbuild.build({
  entryPoints: ['src/main.ts'],
  bundle: true,
  splitting: true,
  format: 'esm',
  outdir: 'dist',
  minify: true,
  sourcemap: false,
  target: ['es2020'],
  loader: { '.css': 'text' },
  logLevel: 'info',
});
