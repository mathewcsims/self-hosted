// Best-effort tier, already flagged to and accepted by the user as the
// lowest-confidence renderer. If this throws, modal.ts's generic catch
// degrades to "Preview failed — download instead" rather than a broken
// view.
export async function renderPptx(url: string, container: HTMLElement) {
  const { init } = await import('pptx-preview');
  const resp = await fetch(url);
  const arrayBuffer = await resp.arrayBuffer();
  const target = document.createElement('div');
  target.style.cssText = 'width:100%;height:100%;overflow:auto';
  container.replaceChildren(target);
  const viewer = init(target, { width: 960, height: 540 });
  await viewer.preview(arrayBuffer);
}
