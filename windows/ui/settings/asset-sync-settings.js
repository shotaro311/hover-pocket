export function createAssetSyncSettings(root, request) {
  let english = false, busy = false, status = null, lastConflicts = "", timer = null, stopped = false, revision = 0, actionError = null;
  root.innerHTML = '<h2 data-sync-title></h2><p class="settings-note" data-sync-note></p><div class="settings-button-row"><button type="button" data-sync-create></button><button type="button" data-sync-join></button></div><p class="settings-note" data-sync-path></p><label class="toggle-row"><span data-sync-enabled-label></span><input type="checkbox" data-sync-enabled></label><p class="settings-status" role="status" data-sync-status></p><div data-sync-conflicts></div>';
  const el = name => root.querySelector("[data-sync-" + name + "]");
  const text = (ja, en) => english ? en : ja;
  function paint() {
    el("title").textContent = text("ライブラリの同期", "Library sync");
    el("note").textContent = text("Syncthingで共有したHoverPocket専用フォルダを選びます。最初の端末で新規作成し、他の端末は参加してください。原本・分類・名前・お気に入り・ゴミ箱を同期します。", "Choose a dedicated HoverPocket folder shared by Syncthing. Create on the first device, then join on others. Originals, categories, names, favorites and trash are shared.");
    el("create").textContent = text("新規グループを作成…", "Create group…");
    el("join").textContent = text("既存グループに参加…", "Join group…");
    el("path").textContent = status?.transportPath ?? text("未設定", "Not configured");
    el("enabled-label").textContent = text("同期を有効にする", "Enable sync");
    el("enabled").checked = Boolean(status?.enabled);
    root.querySelectorAll("button,input").forEach(node => { node.disabled = busy; });
    el("enabled").disabled = busy || !status?.configured;
    el("create").disabled = busy || Boolean(status?.configured);
    if (status) el("status").textContent = actionError ?? status.error ?? (!status.configured
      ? text("専用フォルダを選んで開始します。", "Choose a dedicated folder to begin.")
      : !status.enabled ? text("一時停止中", "Paused")
      : text("送信待ち " + status.outgoing + "・到着待ち " + status.pending + "・競合 " + status.conflicts.length + "。端末間の転送状況はSyncthingで確認できます。",
        "Outgoing " + status.outgoing + " · waiting " + status.pending + " · conflicts " + status.conflicts.length + ". Check Syncthing for transfer progress."));
    const key = JSON.stringify([english, status?.conflicts ?? []]);
    if (key !== lastConflicts) {
      lastConflicts = key; el("conflicts").replaceChildren();
      for (const conflict of status?.conflicts ?? []) {
        const row = document.createElement("div"); row.className = "settings-spaced-row";
        const label = document.createElement("p");
        label.textContent = text("競合：" + (conflict.localName ?? "この端末に未登録") + " ／ 受信：" + conflict.name, "Conflict: " + (conflict.localName ?? "not on this device") + " / received: " + conflict.name);
        row.append(label);
        const actions = document.createElement("div"); actions.className = "settings-button-row";
        for (const useRemote of [false, true]) {
          const button = document.createElement("button"); button.type = "button";
          button.textContent = useRemote ? text("受信した内容を採用", "Use received version") : text("この端末の内容を採用", "Keep this device");
          button.onclick = () => act("assetSync.resolve", { revision: conflict.revision, useRemote });
          button.disabled = busy; actions.append(button);
        }
        row.append(actions); el("conflicts").append(row);
      }
    }
  }
  async function act(method, params) {
    if (busy) return;
    busy = true; revision++; actionError = null; paint();
    try { status = await request(method, params); paint(); }
    catch (error) { actionError = error?.message ?? text("同期を処理できません。再試行してください。", "Sync unavailable. Please retry."); el("status").textContent = actionError; }
    finally { busy = false; root.querySelectorAll("button,input").forEach(node => { node.disabled = false; }); el("enabled").disabled = !status?.configured; el("create").disabled = Boolean(status?.configured); }
  }
  async function refresh() {
    if (stopped) return;
    if (!busy) {
      const expected = revision;
      try { const next = await request("assetSync.status"); if (expected === revision && !busy) { status = next; paint(); } }
      catch { if (!busy) el("status").textContent = text("同期状態を取得できません。再試行しています。", "Sync status unavailable. Retrying."); }
    }
    if (!stopped) timer = setTimeout(refresh, 3000);
  }
  el("create").onclick = () => act("assetSync.configure", {createGroup:true});
  el("join").onclick = () => act("assetSync.configure", {createGroup:false});
  el("enabled").onchange = () => act("assetSync.enable", {enabled:el("enabled").checked});
  window.addEventListener("pagehide", () => { stopped = true; clearTimeout(timer); }, {once:true});
  void refresh();
  return { render(state) { english = state.settings.language === "en"; paint(); } };
}
