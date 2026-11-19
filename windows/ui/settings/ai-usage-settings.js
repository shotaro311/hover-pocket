import { aiUsageBalanceName, aiUsageSectionServices, aiUsageSectionTitle } from "../providers/ai-usage/ai-usage.js";

/**
 * Settings › AI › AI usage: which services the panel shows and the sign-in for each.
 * Claude, Gemini and Muse open a HoverPocket sign-in window; Codex reuses the chat's ChatGPT login.
 * Antigravity is read from the local Gemini Peer and has no sign-in here.
 */
export function createAiUsageSettings(root, request, on) {
  let usage = null;
  let english = false;
  let reordering = false;
  const busy = new Map();
  root.innerHTML = `<h2 data-title></h2><p class="settings-note" data-note></p><div class="ai-usage-settings-list" data-list></div><p class="settings-note" data-privacy></p><p class="settings-status" role="status" data-status></p>`;
  const find = (name) => root.querySelector(`[data-${name}]`);
  const tx = (ja, en) => (english ? en : ja);

  on("aiUsage.changed", (payload) => { usage = payload; if (!reordering) paint(); });
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

  async function move(service, orderKey, offset) {
    if (reordering) return;
    const order = [...usage[orderKey]];
    const section = aiUsageSectionServices(usage, orderKey);
    const index = section.findIndex((item) => item.id === service);
    const other = section[index + offset];
    if (index < 0 || !other) return;
    const from = order.indexOf(service);
    const to = order.indexOf(other.id);
    [order[from], order[to]] = [order[to], order[from]];
    reordering = true;
    find("status").textContent = "";
    try {
      usage = await request("aiUsage.setPresentation", { [orderKey]: order });
    } catch {
      find("status").textContent = tx("変更を保存できませんでした。", "Could not save the change.");
    } finally {
      reordering = false;
      paint();
    }
  }

  function paint() {
    find("title").textContent = tx("AI使用状況", "AI usage");
    find("note").textContent = tx(
      "パネルの「AI Usage」に、5時間・1週間・モデル別（ClaudeのFableなど）の残りを表示します。表示するサービスと順番を選び、必要に応じてサインインしてください。",
      "The AI Usage tool shows what remains in five-hour, weekly, and model-specific limits (such as Claude's Fable). Choose and order services, then sign in where needed.");
    find("privacy").textContent = tx(
      "Claude・Claude Console・Gemini・MuseはHoverPocketの窓で、Codexは普段のブラウザーでOpenAIのログイン画面からサインインします（チャット・音声と共通の1つのログイン）。パスワードはHoverPocketに渡りません。ログイン状態はこのPCのHoverPocket専用の保存場所にサービスごとに残り、ColabだけはGeminiと同じGoogleのログインを使います。使用状況を読むために各サービスのページを画面に出さずに開き、パネルには残りの割合・リセット時刻・枠の名前と、残高・期限・1時間あたりの消費を表示します。Antigravityは、このPCで動くGemini Peerから読みます（この欄でHoverPocketが接続するのはGemini Peerだけです）。",
      "Claude, Claude Console, Gemini and Muse sign in inside a HoverPocket window; Codex signs in on OpenAI's page in your usual browser (one login shared with chat and voice). HoverPocket never receives your password. Each session stays in its own HoverPocket-only profile on this PC; Colab uses Gemini's Google sign-in. HoverPocket opens each service's pages off screen to read the remaining percentages, reset times, limit names, balances, expiry dates and hourly consumption shown in the panel. Antigravity is read from the Gemini Peer running on this PC.");
    const list = find("list");
    const active = document.activeElement;
    const focusRow = list.contains(active) && active.dataset.move ? active.closest("[data-service]") : null;
    const focusSection = focusRow?.parentElement.dataset.section;
    const focusDirection = focusRow ? active.dataset.move : null;
    list.replaceChildren();
    for (const orderKey of ["order", "balanceOrder"]) {
      const services = aiUsageSectionServices(usage, orderKey);
      if (!services.length) continue;
      const section = document.createElement("section");
      section.className = "ai-usage-settings-section";
      section.dataset.section = orderKey;
      const heading = document.createElement("h3");
      heading.className = "ai-usage-settings-section-title";
      heading.textContent = aiUsageSectionTitle(orderKey, english);
      section.append(heading);
      services.forEach((service, index) => section.append(row(service, orderKey, index, services.length)));
      list.append(section);
      if (focusSection === orderKey) {
        const item = [...section.children].find((node) => node.dataset.service === focusRow.dataset.service);
        (item?.querySelector(`[data-move="${focusDirection}"]:enabled`) ?? item?.querySelector("[data-move]:enabled"))?.focus();
      }
    }
  }

  function row(service, orderKey, index, count) {
    const item = document.createElement("div");
    item.className = "ai-usage-settings-row";
    item.dataset.service = service.id;

    const heading = document.createElement("div");
    heading.className = "ai-usage-settings-heading";
    const toggle = document.createElement("div");
    toggle.className = "toggle-row";
    const name = document.createElement("label");
    name.className = "provider-title";
    const codexCreditRow = orderKey === "balanceOrder" && service.id === "codex";
    const serviceName = orderKey === "balanceOrder" ? aiUsageBalanceName(service, english) : service.name;
    name.textContent = serviceName;
    const visible = document.createElement("input");
    visible.id = `ai-usage-visible-${orderKey}-${service.id}`;
    name.htmlFor = visible.id;
    visible.type = "checkbox";
    visible.checked = service.visible;
    visible.disabled = busy.has(service.id);
    const visibilityLabel = service.id === "codex"
      ? tx("Codexの利用枠とクレジットをパネルに表示", "Show Codex limits and credits in the panel")
      : tx(`${serviceName}をパネルに表示`, `Show ${serviceName} in the panel`);
    visible.setAttribute("aria-label", visibilityLabel);
    if (service.id === "codex") visible.title = visibilityLabel;
    visible.onchange = () => act(service.id, "visible", "aiUsage.setVisible", { visible: visible.checked });
    toggle.append(visible);
    const moves = document.createElement("div");
    moves.className = "ai-usage-settings-moves";
    moves.append(
      moveButton(service.id, orderKey, "up", -1, "↑", tx("上へ", "Move up"), index === 0),
      moveButton(service.id, orderKey, "down", 1, "↓", tx("下へ", "Move down"), index === count - 1));
    heading.append(name, moves, toggle);

    const status = document.createElement("span");
    status.className = "settings-status ai-usage-settings-state";
    status.textContent = statusText(service);
    item.append(heading, status);
    if (codexCreditRow) return item;

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
    if (buttons.childElementCount) item.append(buttons);

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

  function moveButton(service, orderKey, direction, offset, arrow, label, disabled) {
    const node = button(arrow, () => void move(service, orderKey, offset), disabled);
    node.dataset.move = direction;
    node.setAttribute("aria-label", label);
    node.title = label;
    return node;
  }

  return {
    render(state) {
      english = state.settings.language === "en";
      paint();
    },
  };
}
