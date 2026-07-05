const dictionaries = {
  ja: {
    refresh: "更新",
    settings: "設定",
    aiStatusReady: "Calendar は Phase 2 で接続予定です。",
    aiPlaceholder: "今日の予定",
    aiSubmit: "送信",
    aiApprove: "承認",
    aiReject: "却下",
    aiPending: "承認待ち",
    aiLastResult: "結果",
    settingsTitle: "HoverPocket 設定",
    language: "言語",
    panelSize: "パネルサイズ",
    textSize: "文字サイズ",
    switchingMode: "Provider 切替",
    providerOrder: "Provider 表示と順序",
    stickyNotes: "Sticky Notes",
    stickyUndoToast: "Undo toast を表示",
    startWithWindows: "Windows 起動時に開始",
    resetDefaults: "既定値に戻す",
    click: "クリック",
    hover: "ホバー",
    up: "上へ",
    down: "下へ",
    visible: "表示",
    registered: "登録済み",
    off: "オフ",
    saved: "保存済み",
  },
  en: {
    refresh: "Refresh",
    settings: "Settings",
    aiStatusReady: "Calendar will be connected in Phase 2.",
    aiPlaceholder: "Today schedule",
    aiSubmit: "Submit",
    aiApprove: "Approve",
    aiReject: "Reject",
    aiPending: "Pending approval",
    aiLastResult: "Result",
    settingsTitle: "HoverPocket Settings",
    language: "Language",
    panelSize: "Panel size",
    textSize: "Text size",
    switchingMode: "Provider switching",
    providerOrder: "Provider visibility and order",
    stickyNotes: "Sticky Notes",
    stickyUndoToast: "Show Undo toast",
    startWithWindows: "Start with Windows",
    resetDefaults: "Reset defaults",
    click: "Click",
    hover: "Hover",
    up: "Up",
    down: "Down",
    visible: "Visible",
    registered: "Registered",
    off: "Off",
    saved: "Saved",
  },
};

let currentLanguage = "ja";

export function setLanguage(language) {
  currentLanguage = language === "en" ? "en" : "ja";
  document.documentElement.lang = currentLanguage;
}

export function t(key) {
  return dictionaries[currentLanguage]?.[key] ?? dictionaries.ja[key] ?? key;
}

export function labelForSize(size) {
  return size === "small" ? "S" : size === "large" ? "L" : "M";
}
