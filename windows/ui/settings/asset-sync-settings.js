export function createAssetSyncSettings(root, request) {
  let english = false, busy = false, status = null, lastConflicts = "", lastDevices = "", timer = null, stopped = false, revision = 0, actionError = null;
  let pairing = { available: false, session: { phase: "idle" }, devices: [] }, joining = false;
  root.innerHTML = `<div class="settings-action-row"><h2 data-sync-title></h2><span class="sync-badge" data-sync-badge></span></div>
    <p class="settings-note" data-sync-note></p>
    <label class="toggle-row"><span data-sync-enabled-label></span><input type="checkbox" data-sync-enabled></label>
    <div data-sync-devices></div>
    <div class="settings-button-row settings-spaced-row"><button type="button" data-sync-invite></button><button type="button" data-sync-enter></button></div>
    <div class="pairing-box" data-sync-join-box hidden><label><span data-sync-code-label></span> <input type="text" data-sync-code-input inputmode="numeric" maxlength="24" autocomplete="off" spellcheck="false" placeholder="123-12345678"></label><div class="settings-button-row settings-spaced-row"><button type="button" data-sync-connect></button><button type="button" data-sync-join-cancel></button></div></div>
    <div class="pairing-box" data-sync-session hidden><p data-sync-session-label></p><output class="pairing-code" data-sync-code></output><p class="settings-note" data-sync-peer></p><p class="settings-note" data-sync-expiry></p><div class="settings-button-row"><button type="button" data-sync-approve hidden></button><button type="button" data-sync-cancel></button></div></div>
    <p class="settings-status" role="status" data-sync-status></p><p class="settings-status" role="status" data-sync-connection-status></p><div data-sync-conflicts></div>
    <details class="settings-details" data-sync-advanced><summary data-sync-details-label></summary><p class="settings-note" data-sync-security></p><p class="settings-note" data-sync-path></p><div class="settings-button-row"><button type="button" data-sync-create></button><button type="button" data-sync-join></button></div></details>`;
  const el = name => root.querySelector("[data-sync-" + name + "]");
  const text = (ja, en) => english ? en : ja;
  const active = () => ["starting", "waiting", "peer", "applying"].includes(pairing.session?.phase);
  function paint() {
    const session = pairing.session ?? {phase:"idle"};
    el("title").textContent = text("ライブラリの同期", "Library sync");
    el("note").textContent = text("写真・動画・名前・分類・お気に入り・ゴミ箱を、接続した端末で共有します。", "Share media, names, categories, favorites and trash across connected devices.");
    el("badge").textContent = !status?.configured ? text("未接続", "Not connected") : !status.enabled ? text("一時停止", "Paused") : text("同期オン", "Sync on");
    el("enabled-label").textContent = text("同期する", "Sync library");
    el("enabled").checked = Boolean(status?.enabled); el("enabled").disabled = busy || active() || !status?.configured;
    el("invite").textContent = text("端末を追加", "Add a device");
    el("enter").textContent = text("コードで接続", "Enter a code");
    for (const name of ["invite", "enter"]) el(name).disabled = busy || active() || !pairing.available;
    el("join-box").hidden = !joining || active();
    el("code-label").textContent = text("連携コード", "Pairing code"); el("code-input").setAttribute("aria-label",text("連携コード", "Pairing code"));
    el("connect").textContent = text("接続する", "Connect"); el("connect").disabled = busy || !el("code-input").value.trim();
    el("join-cancel").textContent = text("キャンセル", "Cancel");
    el("session").hidden = !active();
    el("code").textContent = session.code ?? ""; el("code").hidden = !session.code;
    el("session-label").textContent = session.phase === "waiting" ? text("もう一台のHoverPocketにこのコードを入力", "Enter this code on your other HoverPocket")
      : session.phase === "peer" && pairing.role === "invite" ? text("この端末との同期を許可しますか？", "Allow this device to sync your library?")
      : session.phase === "peer" ? text("相手の端末で接続を許可してください", "Approve the connection on your other device")
      : session.phase === "applying" ? text("接続を設定しています…", "Setting up the connection…") : text("安全な接続を準備しています…", "Preparing a secure connection…");
    el("peer").textContent = session.peerName ? `${session.peerName} · ${session.platform === "macos" ? "Mac" : "Windows"}${session.verification ? text(" ／ 確認番号 ", " / Verification ") + session.verification : ""}` : "";
    const seconds = session.expiresAt ? Math.max(0, Math.ceil((new Date(session.expiresAt).getTime() - Date.now()) / 1000)) : 0;
    el("expiry").textContent = text(`残り ${Math.floor(seconds / 60)}分${seconds % 60}秒・1回限り有効`, `Expires in ${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2,"0")} · single use`);
    el("approve").hidden = session.phase !== "peer" || pairing.role !== "invite";
    el("approve").textContent = text("接続を許可", "Allow connection"); el("approve").disabled = busy || seconds === 0;
    el("cancel").textContent = text("キャンセル", "Cancel"); el("cancel").disabled = busy;
    el("connection-status").textContent = actionError ?? session.error ?? (session.phase === "complete" ? text("接続しました。素材の同期を開始します。", "Connected. Your library will now sync.") : pairing.error === "syncthing_unavailable" ? text("端末連携にはSyncthingの起動が必要です。", "Start Syncthing to connect devices.") : pairing.error === "helper_missing" ? text("アプリを更新すると端末連携を利用できます。", "Update HoverPocket to enable device pairing.") : pairing.error ?? "");
    el("details-label").textContent = text("接続の詳細", "Connection details");
    el("security").textContent = text("端末の連携にはSyncthingが必要です。コードは5分で失効します。外部の仲介サービスには画像や復号用の鍵を送りません。解除後も相手が受信済みの素材は残ります。", "Syncthing is required on each device. Codes expire in 5 minutes. The external rendezvous receives neither media nor decryption keys. Removing a device does not erase copies it already received.");
    el("path").textContent = status?.transportPath ?? text("接続時に保存先を自動設定します。", "The sync location is set up automatically.");
    el("create").textContent = text("手動で共有先を作成…", "Create a share manually…"); el("join").textContent = text("手動で共有先を選ぶ…", "Select a share manually…");
    el("create").disabled = busy || active() || Boolean(status?.configured); el("join").disabled = busy || active();
    el("status").textContent = status?.error ?? (!status?.configured ? "" : !status.enabled ? text("一時停止中", "Paused")
      : status.pending || status.outgoing || status.conflicts.length ? text(`送信待ち ${status.outgoing}・到着待ち ${status.pending}・要確認 ${status.conflicts.length}`, `Outgoing ${status.outgoing} · waiting ${status.pending} · needs attention ${status.conflicts.length}`)
      : text("処理待ちの変更はありません。", "No changes waiting to be processed."));
    const deviceKey = JSON.stringify([english, pairing.devices, active(), busy]);
    if (deviceKey !== lastDevices) {
      lastDevices = deviceKey; el("devices").replaceChildren();
      for (const device of pairing.devices ?? []) {
        const row = document.createElement("div"); row.className = "sync-device";
        const name = document.createElement("span"); name.className = "sync-device-name"; name.textContent = device.name + (device.connected ? text(" · 接続中", " · online") : text(" · オフライン", " · offline"));
        const button = document.createElement("button"); button.type = "button"; button.textContent = text("解除", "Remove"); button.disabled = active() || busy;
        button.onclick = () => { button.textContent = text("この端末の共有を解除", "Confirm removal"); button.onclick = () => pair("pairing.remove", {deviceId:device.id}); };
        row.append(name,button); el("devices").append(row);
      }
    }
    const key = JSON.stringify([english, status?.conflicts ?? [], busy]);
    if (key !== lastConflicts) {
      lastConflicts = key; el("conflicts").replaceChildren();
      for (const conflict of status?.conflicts ?? []) {
        const row = document.createElement("div"); row.className = "settings-spaced-row";
        const label = document.createElement("p"); label.textContent = text("競合：", "Conflict: ") + (conflict.localName ?? "—") + " / " + conflict.name; row.append(label);
        const actions = document.createElement("div"); actions.className = "settings-button-row";
        for (const useRemote of [false, true]) {
          const button = document.createElement("button"); button.type = "button";
          button.textContent = useRemote ? text("受信した内容を採用", "Use received version") : text("この端末の内容を採用", "Keep this device");
          button.onclick = () => act("assetSync.resolve", {revision:conflict.revision,useRemote}); button.disabled = busy; actions.append(button);
        }
        row.append(actions); el("conflicts").append(row);
      }
    }
  }
  async function perform(action) {
    if (busy) return; busy = true; revision++; actionError = null; paint();
    try { await action(); }
    catch (error) { actionError = error?.message ?? text("処理できませんでした。再試行してください。", "Please retry."); }
    finally { busy = false; paint(); }
  }
  const act = (method, params) => perform(async () => { status = await request(method,params); });
  const pair = (method, params) => perform(async () => {
    const response = await request(method,params);
    if (response.session) pairing = response;
    else { pairing.session = response; if(method === "pairing.invite") pairing.role="invite"; if(method === "pairing.join") pairing.role="join"; }
    joining = false; el("code-input").value = "";
  });
  async function refresh() {
    if (stopped) return;
    if (!busy) {
      const expected = revision;
      const results = await Promise.allSettled([request("assetSync.status"), request("pairing.status")]);
      if (expected === revision && !busy) {
        if (results[0].status === "fulfilled") status = results[0].value;
        if (results[1].status === "fulfilled") pairing = results[1].value;
        paint();
      }
    }
    if (!stopped) timer = setTimeout(refresh, active() ? 1000 : 3000);
  }
  el("invite").onclick = () => pair("pairing.invite");
  el("enter").onclick = () => { joining = !joining; paint(); if(joining) el("code-input").focus(); };
  el("join-cancel").onclick = () => { joining=false; el("code-input").value=""; paint(); };
  el("code-input").oninput = () => { el("connect").disabled = busy || !el("code-input").value.trim(); };
  el("connect").onclick = () => pair("pairing.join", {code:el("code-input").value.trim()});
  el("code-input").onkeydown = event => { if(event.key === "Enter") el("connect").click(); };
  el("approve").onclick = () => pair("pairing.approve", {approvalId:pairing.session.approvalId});
  el("cancel").onclick = () => pair("pairing.cancel");
  el("create").onclick = () => act("assetSync.configure", {createGroup:true});
  el("join").onclick = () => act("assetSync.configure", {createGroup:false});
  el("enabled").onchange = () => act("assetSync.enable", {enabled:el("enabled").checked});
  window.addEventListener("pagehide", () => { stopped = true; clearTimeout(timer); }, {once:true});
  void refresh();
  return { render(state) { english = state.settings.language === "en"; paint(); } };
}
