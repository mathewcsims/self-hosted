export async function renderDocx(url: string, container: HTMLElement) {
  const { renderAsync } = await import('docx-preview');
  const resp = await fetch(url);
  const blob = await resp.blob();
  const target = document.createElement('div');
  container.replaceChildren(target);
  await renderAsync(blob, target, undefined, { inWrapper: true, ignoreWidth: false });
}
