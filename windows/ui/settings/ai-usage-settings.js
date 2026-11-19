/**
 * Settings › AI › AI usage: which services the panel shows and the sign-in for each.
 * Claude, Gemini and Muse open a HoverPocket sign-in window; Codex reuses the chat's ChatGPT login.
 * Antigravity is read from the local Gemini Peer and has no sign-in here.
 */
export function createAiUsageSettings(root, request, on) {
  let usage = null;
  let english = false;
  const busy = new Map();
  root.innerHTML = `<h2 data-title></h2><p class="settings-note" data-note></p><div class="ai-usage-settings-list" data-list></div><p class="settings-note" data-privacy></p><p class="settings-status" role="status" data-status></p>`;
  const find = (name) => root.querySelector(`[data-${name}]`);
  const tx = (ja, en) => (english ? en : ja);

  on("aiUsage.changed", (payload) => { usage = payload; paint(); });
  // Show the last known state at once, but contact the services only while this section is on screen
  // (Settings shows one category at a time by toggling `hidden`).
  void load(false);
  new MutationObserver(() => { if (!root.hidden) void load(true); }).observe(root, { attributes: true, attributeFilter: ["hidden"] });

  async function load(refresh) {
    try {
      usage = await request("aiUsage.getState", refresh ? { refresh: true } : undefined);
      paint();
    } catch {
      find("status").textContent = tx("AI使用状況を読み込めませんでした。", "Could not load AI usage.");
    }
  }

  async function act(service, kind, method, params) {
    if (busy.has(service)) return;
    busy.set(service, kind);
    find("status").textContent = "";
    paint();
    try {
      usage = await request(method, { service, ...params });
    } catch {
      find("status").textContent = kind === "signIn"
        ? tx("サインインを完了できませんでした。もう一度お試しください。", "Sign-in did not finish. Please try again.")
        : tx("変更を保存できませんでした。", "Could not save the change.");
    } finally {
      busy.delete(service);
      paint();
    }
  }

  function paint() {
    find("title").textContent = tx("AI使用状況", "AI usage");
    find("note").textContent = tx(
      "パネルの「AI Usage」に、5時間・1週間・モデル別（ClaudeのFableなど）の使用率を表示します。表示するサービスを選び、サインインが要るものはサインインしてください。",
      "The AI Usage tool shows five-hour, weekly, and model-specific limits (such as Claude's Fable). Choose services and sign in where needed.");
    find("privacy").textContent = tx(
      "Claude・Claude Console・Gemini・MuseはHoverPocketの窓で、Codexは普段のブラウザーでOpenAIのログイン画面からサインインします（チャット・音声と共通の1つのログイン）。パスワードはHoverPocketに渡りません。ログイン状態はこのPCのHoverPocket専用の保存場所にサービスごとに残り、ColabだけはGeminiと同じGoogleのログインを使います。使用状況を読むために各サービスのページを画面に出さずに開き、パネルには使用率・リセット時刻・プラン名・枠の名前と、残高・期限・1時間あたりの消費だけを表示します。Antigravityは、このPCで動くGemini Peerから読みます（この欄でHoverPocketが接続するのはGemini Peerだけです）。",
      "Claude, Claude Console, Gemini and Muse sign in inside a HoverPocket window; Codex signs in on OpenAI's page in your usual browser (one login shared with the chat and voice). HoverPocket never receives your password. Each session stays in its own HoverPocket-only profile on this PC; Colab alone uses Gemini's Google sign-in. To read usage, HoverPocket opens each service's pages off screen, and the panel shows only percentages, reset times, plan and limit names, balances, expiry dates and hourly consumption. Antigravity is read from the Gemini Peer running on this PC (for it, HoverPocket connects only to the Gemini Peer).");
    const list = find("list");
    list.replaceChildren();
    for (const service of usage?.services ?? []) list.append(row(service));
  }

  function row(service) {
    const item = document.createElement("div");
    item.className = "ai-usage-settings-row";
    item.dataset.service = service.id;

    const toggle = document.createElement("label");
    toggle.className = "toggle-row";
    const name = document.createElement("span");
    name.className = "provider-title";
    name.textContent = service.name;
    const visible = document.createElement("input");
    visible.type = "checkbox";
    visible.checked = service.visible;
    visible.disabled = busy.has(service.id);
    visible.setAttribute("aria-label", tx(`${service.name}をパネルに表示`, `Show ${service.name} in the panel`));
    visible.onchange = () => act(service.id, "visible", "aiUsage.setVisible", { visible: visible.checked });
    toggle.append(name, visible);

    const status = document.createElement("span");
    status.className = "settings-status ai-usage-settings-state";
    status.textContent = statusText(service);

    const buttons = document.createElement("div");
    buttons.className = "settings-button-row";
    const pending = busy.get(service.id);
    if (service.signIn === "shared" || service.signIn === "peer") {
      // Colab reads with Gemini's Google sign-in; Antigravity is read from the Gemini Peer. No sign-in of their own.
    } else if (service.signIn === "codex") {
      if (service.status !== "ok") buttons.append(button(
        pending === "signIn" ? tx("ブラウザでログイン中…", "Signing in in your browser…") : tx("ChatGPTにログイン", "Sign in to ChatGPT"),
        () => act(service.id, "signIn", "aiUsage.signIn"), Boolean(pending)));
    } else {
      buttons.append(button(
        pending === "signIn" ? tx("サインイン画面で続けてください…", "Continue in the sign-in window…")
          : service.status === "ok" ? tx("サインインし直す", "Sign in again") : tx("サインイン", "Sign in"),
        () => act(service.id, "signIn", "aiUsage.signIn"), Boolean(pending)));
      // A shared sign-in (Gemini's Google profile also feeds Colab) can be signed out while either reads.
      const readsWithThis = (usage?.services ?? []).some((item) => item.sharedWith === service.id && (item.status === "ok" || item.status === "error"));
      if (service.status === "ok" || service.status === "error" || readsWithThis) buttons.append(button(
        pending === "signOut" ? tx("サインアウト中…", "Signing out…") : tx("サインアウト", "Sign out"),
        () => act(service.id, "signOut", "aiUsage.signOut"), Boolean(pending)));
    }
    item.append(toggle, status, buttons);

    const hint = serviceHint(service.id);
    if (hint) {
      const note = document.createElement("p");
      note.className = "settings-note";
      note.textContent = hint;
      item.append(note);
    }
    return item;
  }

  function statusText(service) {
    if (service.refreshing) return tx("確認中…", "Checking…");
    if (service.signIn === "peer" && service.status === "ok")
      return [tx("Gemini Peerから取得", "Read from Gemini Peer"), service.plan].filter(Boolean).join(" · ");
    switch (service.status) {
      case "ok": return [tx("サインイン済み", "Signed in"), service.plan].filter(Boolean).join(" · ");
      case "signedOut": return service.signIn === "shared"
        ? tx("未サインイン（Geminiでサインインしてください）", "Not signed in (sign in to Gemini)")
        : tx("未サインイン", "Not signed in");
      case "error": return tx("読み込みエラー（パネルに理由を表示）", "Read error (details in the panel)");
      default: return tx("未確認", "Not checked yet");
    }
  }

  function serviceHint(id) {
    switch (id) {
      case "codex": return tx("チャット・音声と同じ1つのChatGPTログインを使います。", "Uses the one ChatGPT login shared with the chat and voice.");
      case "gemini": return tx("Googleアカウントでgemini.google.comにサインインします。Colabもこのサインインを使います。", "Sign in to gemini.google.com with your Google account. Colab uses this sign-in too.");
      case "antigravity": return tx("Antigravity CLI（agy）のGeminiモデルの5時間と1週間の枠です。Geminiアプリの枠とは別です。このPCで動くGemini Peerが読み取るので、HoverPocketでのサインインは要りません。読み直すときはGemini Peerがagyの /usage を一度開くため、agyにログインしている必要があります（モデルへの依頼はしないので、枠は使いません）。",
        "Five-hour and weekly limits of Gemini models in the Antigravity CLI (agy), separate from the Gemini app's. The Gemini Peer on this PC reads them, so no sign-in is needed in HoverPocket. To re-read, the Gemini Peer opens agy's /usage once, so agy must be signed in (no model request, so no limit is used).");
      case "claude-api": return tx("Claude Console（platform.claude.com）にサインインします。Maxプランに毎月付くAPIクレジットは、プランにリンクしたConsoleの組織に付きます。", "Sign in to Claude Console (platform.claude.com). The Max plan's monthly API credits go to the Console organization linked to the plan.");
      case "colab": return tx("Geminiと同じGoogleアカウントのサインインを使い、Colabのコンピューティング ユニットの残高を表示します。Googleアカウントが複数あるときは、最初にサインインしたアカウントを読みます。", "Uses the Gemini Google sign-in to show Colab compute units. With several Google accounts, the first one signed in is read.");
      case "muse": return tx("muse.aiにサインインします。表示するのは1週間の枠です。", "Sign in to muse.ai. Muse reports a weekly limit.");
      default: return "";
    }
  }

  function button(text, onClick, disabled) {
    const node = document.createElement("button");
    node.type = "button";
    node.textContent = text;
    node.disabled = disabled;
    node.onclick = onClick;
    return node;
  }

  return {
    render(state) {
      english = state.settings.language === "en";
      paint();
    },
  };
}
