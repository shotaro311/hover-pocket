import { renderAssetsProvider } from './providers/assets/assets.js';
import { request } from './js/bridge.js';
window.assetPane = renderAssetsProvider({container: document.getElementById('assets'), request,
  state: {settings: {language: window.assetConfiguration.language}, organizer: window.assetConfiguration.organizer, platform:'mac'}});
document.addEventListener('focusin', event => {
  if (event.target.matches('input,textarea,[contenteditable="true"]')) void request('panel.beginTextInput', {editing:true});
});
document.addEventListener('focusout', () => {
  setTimeout(() => { if (!document.activeElement?.matches('input,textarea,[contenteditable="true"]')) void request('panel.endTextInput'); }, 0);
});
document.addEventListener('keydown', event => {
  if (event.isComposing || event.repeat) return;
  if (event.metaKey && event.ctrlKey && event.key.toLowerCase() === 'f') {
    event.preventDefault(); event.stopImmediatePropagation(); document.querySelector('[data-action="fullscreen"]')?.click();
  }
  if (event.key === 'Backspace' && !event.target.closest('input,textarea,[contenteditable="true"]')) {
    event.preventDefault(); document.dispatchEvent(new KeyboardEvent('keydown', {key:'Delete',bubbles:true}));
  }
}, true);
document.addEventListener('dragover', event => event.preventDefault());
document.addEventListener('drop', event => event.preventDefault());
// Mac file imports are read from NSPasteboard by the native drop destination.
void request('assets.ready');
