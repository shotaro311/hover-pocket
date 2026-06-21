import Foundation

enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case japanese
    case english

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .japanese:
            return "日本語"
        case .english:
            return "English"
        }
    }

    var locale: Locale {
        switch self {
        case .japanese:
            return Locale(identifier: "ja_JP")
        case .english:
            return Locale(identifier: "en_US")
        }
    }

    func formattedDate(_ date: Date, template: String) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }
}

enum AppTextKey: String, Sendable {
    case addEvent
    case allDay
    case calendar
    case calendarAccessOff
    case calendarConfigMissing
    case calendarConfigMissingDetail
    case calendarConnectionChecking
    case calendarConnectionConnected
    case calendarConnectionConnecting
    case calendarConnectionNotConnected
    case calendarConnectionReconnect
    case calendarConnectionReconnectDetail
    case calendarConnectionSignInDetail
    case calendarConnectionSignedOutDetail
    case calendarConnectChecking
    case calendarConnectConnecting
    case calendarConnectOpenLogin
    case calendarConnectReconnect
    case calendarEvents
    case calendarRead
    case calendarSectionTitle
    case calendarWrite
    case cancel
    case checkForUpdates
    case chooseIntendedAction
    case clipboard
    case clipboardClearHistory
    case clipboardDragImage
    case clipboardDragText
    case clipboardEmptyText
    case clipboardImages
    case clipboardNoImages
    case clipboardNoText
    case clipboardPaused
    case clipboardText
    case clipboardWatching
    case controls
    case controlsBack10
    case controlsDisplays
    case controlsExternalDisplay
    case controlsForward10
    case controlsInternalDisplay
    case controlsMaxBrightness
    case controlsMedia
    case controlsMinBrightness
    case controlsMute
    case controlsNoDisplays
    case controlsNoMedia
    case controlsNowPlaying
    case controlsPause
    case controlsPlay
    case controlsUnmute
    case controlsUnsupported
    case controlsVolume
    case clearSelectedDay
    case click
    case color
    case copyImage
    case copyText
    case date
    case defaultPanel
    case delete
    case deleteEventAlertTitle
    case disconnect
    case displayAll
    case displayAllDetail
    case displayMain
    case displayMainDetail
    case displaySecondary
    case displaySecondaryDetail
    case displayPickerTitle
    case displaySectionTitle
    case editEvent
    case end
    case entryPointSectionTitle
    case english
    case googleCalendar
    case handleChevronDetail
    case handleIcon
    case handleIconHiddenDetail
    case handleNone
    case handleNoneDetail
    case handlePocketDetail
    case hover
    case iconSwitching
    case iconSwitchingClickDetail
    case iconSwitchingHoverDetail
    case language
    case location
    case mirror
    case mirrorCameraAccessOff
    case mirrorCameraAccessOffDetail
    case mirrorCameraFailed
    case mirrorCameraNotFound
    case mirrorCameraNotFoundDetail
    case mirrorCameraPermission
    case mirrorCameraRestricted
    case mirrorCameraRestrictedDetail
    case mirrorEnableMic
    case mirrorMicCheck
    case mirrorOpenCameraSettings
    case mirrorOpenMicrophoneSettings
    case mirrorPlayMicSample
    case mirrorRecordMicSample
    case mirrorStartCamera
    case mirrorStopPlaybackAndClear
    case mirrorStopRecording
    case moveLeft
    case moveRight
    case newEvent
    case nextMonth
    case noEvents
    case noProviders
    case noProvidersDetail
    case notLoaded
    case notes
    case openHoverPocket
    case openLastUsedPanel
    case panelSize
    case panelSizeAccessibility
    case panelSizeHelp
    case panelSizeLarge
    case panelSizeLargeDetail
    case panelSizeMedium
    case panelSizeMediumDetail
    case panelSizeSmall
    case panelSizeSmallDetail
    case panelsSectionTitle
    case previousMonth
    case readOnly
    case readCalendar
    case save
    case settings
    case settingsWindowTitle
    case showMicrophoneTest
    case showMirrorOnSecondaryDisplays
    case showMirrorOnSecondaryDisplaysDetail
    case showSideHandle
    case showStickyNoteUndo
    case start
    case statusApprovalRequired
    case statusCanceled
    case statusCommandCouldNotBePlanned
    case statusCouldNotMap
    case statusDone
    case statusPlanning
    case statusRunning
    case stickyArchive
    case stickyArchived
    case stickyBlue
    case stickyDeleted
    case stickyDontShow
    case stickyDoubleClickCreate
    case stickyDone
    case stickyEdit
    case stickyHideUndoToast
    case stickyLavender
    case stickyMint
    case stickyNewNote
    case stickyNoNotes
    case stickyNoteSuggestedName
    case stickyNotes
    case stickyPink
    case stickyUntitledNote
    case stickyUndo
    case stickyYellow
    case title
    case untitledEvent
    case updates
    case updateAvailable
    case updateChecking
    case updateFeedMissing
    case updateReady
    case updateUnavailable
    case updated
    case dateTimeInputHelp
    case quitHoverPocket
    case providerOrderHint
    case providersSectionTitle
    case microphoneTestDetail
}

enum AppText {
    static func text(_ key: AppTextKey, language: AppLanguage) -> String {
        switch language {
        case .japanese:
            return japaneseText(key)
        case .english:
            return englishText(key)
        }
    }

    static func providerTitle(for id: PluginID, fallback: String, language: AppLanguage) -> String {
        switch id.rawValue {
        case "mirror":
            return text(.mirror, language: language)
        case "google-calendar":
            return text(.calendar, language: language)
        case "clipboard-history":
            return text(.clipboard, language: language)
        case "sticky-notes":
            return text(.stickyNotes, language: language)
        case "controls":
            return text(.controls, language: language)
        default:
            return fallback
        }
    }

    private static func japaneseText(_ key: AppTextKey) -> String {
        switch key {
        case .addEvent: return "予定を追加"
        case .allDay: return "終日"
        case .calendar: return "カレンダー"
        case .calendarAccessOff: return "読み取り専用"
        case .calendarConfigMissing: return "Google OAuth が未設定です"
        case .calendarConfigMissingDetail: return "GOOGLE_SIGN_IN_CLIENT_ID を設定してからアプリを起動してください。"
        case .calendarConnectionChecking: return "保存済みの Google アカウントを確認中"
        case .calendarConnectionConnected: return "接続済み"
        case .calendarConnectionConnecting: return "Google ログイン待ち"
        case .calendarConnectionNotConnected: return "未接続"
        case .calendarConnectionReconnect: return "編集を許可するには再接続してください"
        case .calendarConnectionReconnectDetail: return "予定の読み込みと編集のため、Google カレンダーへ再接続してください。"
        case .calendarConnectionSignInDetail: return "ブラウザで Google ログインを完了してください。"
        case .calendarConnectionSignedOutDetail: return "Google ログインを開くと予定を読み込めます。"
        case .calendarConnectChecking: return "確認中"
        case .calendarConnectConnecting: return "接続中"
        case .calendarConnectOpenLogin: return "Google ログインを開く"
        case .calendarConnectReconnect: return "Google に再接続"
        case .calendarEvents: return "件の予定"
        case .calendarRead: return "カレンダー読み取り"
        case .calendarSectionTitle: return "Google カレンダー"
        case .calendarWrite: return "カレンダー書き込み"
        case .cancel: return "キャンセル"
        case .checkForUpdates: return "アップデートを確認"
        case .chooseIntendedAction: return "実行する操作を選択"
        case .clipboard: return "クリップボード"
        case .clipboardClearHistory: return "クリップボード履歴を消去"
        case .clipboardDragImage: return "画像を他のアプリへドラッグ"
        case .clipboardDragText: return "テキストを他のアプリへドラッグ"
        case .clipboardEmptyText: return "空のテキスト"
        case .clipboardImages: return "画像"
        case .clipboardNoImages: return "画像はまだありません"
        case .clipboardNoText: return "テキストはまだありません"
        case .clipboardPaused: return "監視を停止中"
        case .clipboardText: return "テキスト"
        case .clipboardWatching: return "クリップボードを監視中"
        case .controls: return "コントロール"
        case .controlsBack10: return "10秒戻す"
        case .controlsDisplays: return "ディスプレイ"
        case .controlsExternalDisplay: return "外部"
        case .controlsForward10: return "10秒送る"
        case .controlsInternalDisplay: return "内蔵"
        case .controlsMaxBrightness: return "最大輝度にする"
        case .controlsMedia: return "メディア"
        case .controlsMinBrightness: return "最小輝度にする"
        case .controlsMute: return "ミュート"
        case .controlsNoDisplays: return "ディスプレイを取得できません"
        case .controlsNoMedia: return "再生中のメディアはありません"
        case .controlsNowPlaying: return "再生中"
        case .controlsPause: return "一時停止"
        case .controlsPlay: return "再生"
        case .controlsUnmute: return "ミュート解除"
        case .controlsUnsupported: return "非対応"
        case .controlsVolume: return "音量"
        case .clearSelectedDay: return "選択日を解除"
        case .click: return "クリック"
        case .color: return "色"
        case .copyImage: return "画像をコピー"
        case .copyText: return "テキストをコピー"
        case .date: return "日付"
        case .defaultPanel: return "標準パネル"
        case .delete: return "削除"
        case .deleteEventAlertTitle: return "予定を削除しますか？"
        case .disconnect: return "接続解除"
        case .displayAll: return "すべて"
        case .displayAllDetail: return "各ディスプレイ上部に起点を表示します。ノッチがない画面では控えめなミニバーで表示します。"
        case .displayMain: return "メイン"
        case .displayMainDetail: return "常に macOS のメインディスプレイに表示します。"
        case .displaySecondary: return "サブ"
        case .displaySecondaryDetail: return "サブディスプレイが接続されている場合は、そちらに表示します。"
        case .displayPickerTitle: return "表示先"
        case .displaySectionTitle: return "表示"
        case .editEvent: return "予定を編集"
        case .end: return "終了"
        case .entryPointSectionTitle: return "起点表示"
        case .english: return "英語"
        case .googleCalendar: return "Google カレンダー"
        case .handleChevronDetail: return "小さな下向きマークを表示します。"
        case .handleIcon: return "ハンドルアイコン"
        case .handleIconHiddenDetail: return "オフの場合、ノッチ横には何も表示せず、ノッチ本体側の透明な反応領域だけを残します。"
        case .handleNone: return "なし"
        case .handleNoneDetail: return "マークなしで、ノッチに合わせた形だけを表示します。"
        case .handlePocketDetail: return "ポケット形状の小さなマークを表示します。"
        case .hover: return "ホバー"
        case .iconSwitching: return "機能切り替え"
        case .iconSwitchingClickDetail: return "アイコンをクリックしたときにパネルを切り替えます。"
        case .iconSwitchingHoverDetail: return "アイコンにポインタを重ねるだけでパネルを切り替えます。"
        case .language: return "言語"
        case .location: return "場所"
        case .mirror: return "ミラー"
        case .mirrorCameraAccessOff: return "カメラ権限がオフです"
        case .mirrorCameraAccessOffDetail: return "システム設定でカメラの使用を許可してください。"
        case .mirrorCameraFailed: return "カメラを起動できません"
        case .mirrorCameraNotFound: return "カメラが見つかりません"
        case .mirrorCameraNotFoundDetail: return "利用できる Mac のカメラを検出できませんでした。"
        case .mirrorCameraPermission: return "カメラ権限を確認中"
        case .mirrorCameraRestricted: return "カメラが制限されています"
        case .mirrorCameraRestrictedDetail: return "macOS によりカメラの使用が制限されています。"
        case .mirrorEnableMic: return "マイク許可"
        case .mirrorMicCheck: return "マイク確認"
        case .mirrorOpenCameraSettings: return "カメラ設定を開く"
        case .mirrorOpenMicrophoneSettings: return "マイク設定を開く"
        case .mirrorPlayMicSample: return "録音した音声を再生"
        case .mirrorRecordMicSample: return "一時的にマイク音声を録音"
        case .mirrorStartCamera: return "カメラ起動中"
        case .mirrorStopPlaybackAndClear: return "再生を停止して消去"
        case .mirrorStopRecording: return "録音を停止"
        case .moveLeft: return "左へ移動"
        case .moveRight: return "右へ移動"
        case .newEvent: return "新しい予定"
        case .nextMonth: return "翌月"
        case .noEvents: return "予定なし"
        case .noProviders: return "機能がありません"
        case .noProvidersDetail: return "機能レジストリは準備済みです。"
        case .notLoaded: return "未読み込み"
        case .notes: return "メモ"
        case .openHoverPocket: return "ホバーポケットを開く"
        case .openLastUsedPanel: return "最後に使ったパネルを開く"
        case .panelSize: return "パネルサイズ"
        case .panelSizeAccessibility: return "パネルサイズ"
        case .panelSizeHelp: return "パネルサイズ"
        case .panelSizeLarge: return "大"
        case .panelSizeLargeDetail: return "予定やクリップ履歴を少し広く表示します。"
        case .panelSizeMedium: return "中"
        case .panelSizeMediumDetail: return "現在の標準サイズです。"
        case .panelSizeSmall: return "小"
        case .panelSizeSmallDetail: return "コンパクトに表示します。"
        case .panelsSectionTitle: return "パネル"
        case .previousMonth: return "前月"
        case .readOnly: return "読み取り専用"
        case .readCalendar: return "カレンダーを確認"
        case .save: return "保存"
        case .settings: return "設定"
        case .settingsWindowTitle: return "設定"
        case .showMicrophoneTest: return "ミラー下にマイクテストを表示"
        case .showMirrorOnSecondaryDisplays: return "サブディスプレイでもミラーを表示"
        case .showMirrorOnSecondaryDisplaysDetail: return "オフの場合、サブディスプレイから開いたホバーポケットではミラーを表示しません。"
        case .showSideHandle: return "メインノッチ左のアイコンエリアを表示"
        case .showStickyNoteUndo: return "付箋操作後に Undo を表示"
        case .start: return "開始"
        case .statusApprovalRequired: return "承認が必要です。"
        case .statusCanceled: return "キャンセルしました。"
        case .statusCommandCouldNotBePlanned: return "コマンドを解析できませんでした。"
        case .statusCouldNotMap: return "この入力に対応する操作を見つけられませんでした。"
        case .statusDone: return "完了しました。"
        case .statusPlanning: return "解析中..."
        case .statusRunning: return "実行中..."
        case .stickyArchive: return "アーカイブ"
        case .stickyArchived: return "アーカイブしました"
        case .stickyBlue: return "ブルー"
        case .stickyDeleted: return "削除しました"
        case .stickyDontShow: return "今後表示しない"
        case .stickyDoubleClickCreate: return "ダブルクリックで作成"
        case .stickyDone: return "完了"
        case .stickyEdit: return "編集"
        case .stickyHideUndoToast: return "今後 Undo 表示を出しません"
        case .stickyLavender: return "ラベンダー"
        case .stickyMint: return "ミント"
        case .stickyNewNote: return "新しい付箋"
        case .stickyNoNotes: return "付箋はまだありません"
        case .stickyNoteSuggestedName: return "付箋"
        case .stickyNotes: return "付箋"
        case .stickyPink: return "ピンク"
        case .stickyUntitledNote: return "無題の付箋"
        case .stickyUndo: return "元に戻す"
        case .stickyYellow: return "イエロー"
        case .title: return "タイトル"
        case .untitledEvent: return "無題の予定"
        case .updates: return "アップデート"
        case .updateAvailable: return "アップデートがあります"
        case .updateChecking: return "アップデートを確認中"
        case .updateFeedMissing: return "アップデート配信が未設定です"
        case .updateReady: return "アップデート確認を使用できます"
        case .updateUnavailable: return "アップデートはありません"
        case .updated: return "更新"
        case .dateTimeInputHelp: return "数値を入力、または左右にドラッグして調整できます。"
        case .quitHoverPocket: return "ホバーポケットを終了"
        case .providerOrderHint: return "ヘッダーの機能アイコンはドラッグ&ドロップでも並べ替えできます。"
        case .providersSectionTitle: return "機能"
        case .microphoneTestDetail: return "マイクはテストボタンを押したときだけ起動します。"
        }
    }

    private static func englishText(_ key: AppTextKey) -> String {
        switch key {
        case .addEvent: return "Add event"
        case .allDay: return "All day"
        case .calendar: return "Calendar"
        case .calendarAccessOff: return "Read only"
        case .calendarConfigMissing: return "Google OAuth is not configured"
        case .calendarConfigMissingDetail: return "Set GOOGLE_SIGN_IN_CLIENT_ID before running the app."
        case .calendarConnectionChecking: return "Checking saved Google account"
        case .calendarConnectionConnected: return "Connected"
        case .calendarConnectionConnecting: return "Waiting for Google sign-in"
        case .calendarConnectionNotConnected: return "Not connected"
        case .calendarConnectionReconnect: return "Reconnect to allow editing"
        case .calendarConnectionReconnectDetail: return "Reconnect Google Calendar to load and edit events."
        case .calendarConnectionSignInDetail: return "Complete Google sign-in in the browser."
        case .calendarConnectionSignedOutDetail: return "Open Google login to load your calendar."
        case .calendarConnectChecking: return "Checking"
        case .calendarConnectConnecting: return "Connecting"
        case .calendarConnectOpenLogin: return "Open Google Login"
        case .calendarConnectReconnect: return "Reconnect Google"
        case .calendarEvents: return "events"
        case .calendarRead: return "Calendar read"
        case .calendarSectionTitle: return "Google Calendar"
        case .calendarWrite: return "Calendar write"
        case .cancel: return "Cancel"
        case .checkForUpdates: return "Check for Updates"
        case .chooseIntendedAction: return "Choose the intended action"
        case .clipboard: return "Clipboard"
        case .clipboardClearHistory: return "Clear clipboard history"
        case .clipboardDragImage: return "Drag to drop image into another app"
        case .clipboardDragText: return "Drag to drop text into another app"
        case .clipboardEmptyText: return "Empty text"
        case .clipboardImages: return "Images"
        case .clipboardNoImages: return "No images yet"
        case .clipboardNoText: return "No text yet"
        case .clipboardPaused: return "Clipboard paused"
        case .clipboardText: return "Text"
        case .clipboardWatching: return "Watching clipboard"
        case .controls: return "Controls"
        case .controlsBack10: return "Back 10 seconds"
        case .controlsDisplays: return "Displays"
        case .controlsExternalDisplay: return "External"
        case .controlsForward10: return "Forward 10 seconds"
        case .controlsInternalDisplay: return "Internal"
        case .controlsMaxBrightness: return "Set maximum brightness"
        case .controlsMedia: return "Media"
        case .controlsMinBrightness: return "Set minimum brightness"
        case .controlsMute: return "Mute"
        case .controlsNoDisplays: return "No displays found"
        case .controlsNoMedia: return "No active media"
        case .controlsNowPlaying: return "Now Playing"
        case .controlsPause: return "Pause"
        case .controlsPlay: return "Play"
        case .controlsUnmute: return "Unmute"
        case .controlsUnsupported: return "Unsupported"
        case .controlsVolume: return "Volume"
        case .clearSelectedDay: return "Clear selected day"
        case .click: return "Click"
        case .color: return "Color"
        case .copyImage: return "Copy image"
        case .copyText: return "Copy text"
        case .date: return "Date"
        case .defaultPanel: return "Default panel"
        case .delete: return "Delete"
        case .deleteEventAlertTitle: return "Delete event?"
        case .disconnect: return "Disconnect"
        case .displayAll: return "All"
        case .displayAllDetail: return "Shows an entry point on every display. Notchless displays use the subtle mini bar."
        case .displayMain: return "Main"
        case .displayMainDetail: return "Always uses the primary macOS display."
        case .displaySecondary: return "Sub"
        case .displaySecondaryDetail: return "Uses a secondary display when one is connected."
        case .displayPickerTitle: return "Display"
        case .displaySectionTitle: return "Display"
        case .editEvent: return "Edit event"
        case .end: return "End"
        case .entryPointSectionTitle: return "Entry Point"
        case .english: return "English"
        case .googleCalendar: return "Google Calendar"
        case .handleChevronDetail: return "Shows the compact downward mark."
        case .handleIcon: return "Handle icon"
        case .handleIconHiddenDetail: return "When off, nothing is drawn beside the notch; only the transparent notch trigger remains."
        case .handleNone: return "None"
        case .handleNoneDetail: return "Shows only the notch-shaped base without a mark."
        case .handlePocketDetail: return "Shows the compact pocket-shaped mark."
        case .hover: return "Hover"
        case .iconSwitching: return "Icon switching"
        case .iconSwitchingClickDetail: return "Switches panels when you click an icon."
        case .iconSwitchingHoverDetail: return "Switches panels when the pointer hovers over an icon."
        case .language: return "Language"
        case .location: return "Location"
        case .mirror: return "Mirror"
        case .mirrorCameraAccessOff: return "Camera access is off"
        case .mirrorCameraAccessOffDetail: return "Enable camera access in System Settings."
        case .mirrorCameraFailed: return "Camera failed"
        case .mirrorCameraNotFound: return "Camera not found"
        case .mirrorCameraNotFoundDetail: return "No available Mac camera was detected."
        case .mirrorCameraPermission: return "Camera permission"
        case .mirrorCameraRestricted: return "Camera is restricted"
        case .mirrorCameraRestrictedDetail: return "macOS is blocking camera access."
        case .mirrorEnableMic: return "Enable Mic"
        case .mirrorMicCheck: return "Mic Check"
        case .mirrorOpenCameraSettings: return "Open Camera Settings"
        case .mirrorOpenMicrophoneSettings: return "Open Microphone Privacy Settings"
        case .mirrorPlayMicSample: return "Play temporary mic sample"
        case .mirrorRecordMicSample: return "Record a temporary mic sample"
        case .mirrorStartCamera: return "Starting camera"
        case .mirrorStopPlaybackAndClear: return "Stop playback and clear"
        case .mirrorStopRecording: return "Stop recording"
        case .moveLeft: return "Move Left"
        case .moveRight: return "Move Right"
        case .newEvent: return "New event"
        case .nextMonth: return "Next month"
        case .noEvents: return "No events"
        case .noProviders: return "No providers"
        case .noProvidersDetail: return "Provider registry is ready."
        case .notLoaded: return "Not loaded"
        case .notes: return "Notes"
        case .openHoverPocket: return "Open HoverPocket"
        case .openLastUsedPanel: return "Open last used panel"
        case .panelSize: return "Panel size"
        case .panelSizeAccessibility: return "Panel size"
        case .panelSizeHelp: return "Panel size"
        case .panelSizeLarge: return "Large"
        case .panelSizeLargeDetail: return "Shows events and clipboard history with a little more room."
        case .panelSizeMedium: return "Medium"
        case .panelSizeMediumDetail: return "Current standard size."
        case .panelSizeSmall: return "Small"
        case .panelSizeSmallDetail: return "Shows panels compactly."
        case .panelsSectionTitle: return "Panels"
        case .previousMonth: return "Previous month"
        case .readOnly: return "Read only"
        case .readCalendar: return "Read calendar"
        case .save: return "Save"
        case .settings: return "Settings"
        case .settingsWindowTitle: return "Settings"
        case .showMicrophoneTest: return "Show microphone test under mirror"
        case .showMirrorOnSecondaryDisplays: return "Show Mirror on secondary displays"
        case .showMirrorOnSecondaryDisplaysDetail: return "When off, Mirror is hidden when HoverPocket is opened from a secondary display."
        case .showSideHandle: return "Show icon area beside the main notch"
        case .showStickyNoteUndo: return "Show undo after note actions"
        case .start: return "Start"
        case .statusApprovalRequired: return "Approval required."
        case .statusCanceled: return "Canceled."
        case .statusCommandCouldNotBePlanned: return "The command could not be planned."
        case .statusCouldNotMap: return "I could not map that to a Phase 1 action."
        case .statusDone: return "Done."
        case .statusPlanning: return "Planning..."
        case .statusRunning: return "Running..."
        case .stickyArchive: return "Archive"
        case .stickyArchived: return "Archived"
        case .stickyBlue: return "Blue"
        case .stickyDeleted: return "Deleted"
        case .stickyDontShow: return "Don't show"
        case .stickyDoubleClickCreate: return "double-click to create"
        case .stickyDone: return "Done"
        case .stickyEdit: return "Edit"
        case .stickyHideUndoToast: return "Hide undo toast from now on"
        case .stickyLavender: return "Lavender"
        case .stickyMint: return "Mint"
        case .stickyNewNote: return "New note"
        case .stickyNoNotes: return "No notes"
        case .stickyNoteSuggestedName: return "Sticky Note"
        case .stickyNotes: return "Sticky Notes"
        case .stickyPink: return "Pink"
        case .stickyUntitledNote: return "Untitled note"
        case .stickyUndo: return "Undo"
        case .stickyYellow: return "Yellow"
        case .title: return "Title"
        case .untitledEvent: return "Untitled event"
        case .updates: return "Updates"
        case .updateAvailable: return "Update available"
        case .updateChecking: return "Checking for updates"
        case .updateFeedMissing: return "Update feed is not configured"
        case .updateReady: return "Update checks are available"
        case .updateUnavailable: return "No update available"
        case .updated: return "Updated"
        case .dateTimeInputHelp: return "Type a value, or drag left/right to adjust."
        case .quitHoverPocket: return "Quit HoverPocket"
        case .providerOrderHint: return "You can also reorder header icons with drag and drop."
        case .providersSectionTitle: return "Providers"
        case .microphoneTestDetail: return "Microphone starts only when you press the test button."
        }
    }
}

extension AppSettings {
    func text(_ key: AppTextKey) -> String {
        AppText.text(key, language: appLanguage)
    }
}

extension PluginManifest {
    func title(language: AppLanguage) -> String {
        AppText.providerTitle(for: id, fallback: title, language: language)
    }
}
