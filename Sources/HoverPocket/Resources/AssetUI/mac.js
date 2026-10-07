import { renderAssetsProvider } from './providers/assets/assets.js';
import { request } from './js/bridge.js';
window.assetPane = renderAssetsProvider({container: document.getElementById('assets'), request,
  state: {settings: {language: window.assetConfiguration.language}, organizer: window.assetConfiguration.organizer, platform:'mac'}});
let interactionHeld = false;
let dialogHeld = false;
function syncInteractionHold() {
  const dialog = !!document.querySelector('dialog[open]');
  const editing = dialog || !!document.activeElement?.matches('input,textarea,[contenteditable="true"]');
  if (editing === interactionHeld && dialog === dialogHeld) return;
  interactionHeld = editing;
  dialogHeld = dialog;
  void request(editing ? 'panel.beginTextInput' : 'panel.endTextInput', {editing,dialog});
}
document.addEventListener('focusin', syncInteractionHold);
document.addEventListener('focusout', () => setTimeout(syncInteractionHold, 0));
// A modal must keep the hover panel open after its launcher loses text focus.
new MutationObserver(syncInteractionHold).observe(document.body, {subtree:true,childList:true,attributes:true,attributeFilter:['open']});
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
