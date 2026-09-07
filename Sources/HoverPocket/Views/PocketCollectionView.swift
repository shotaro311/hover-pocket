import SwiftUI

struct PocketCollectionView: View {
    @ObservedObject var model: PocketSurfaceHostModel
    let collectionID: String
    let titleField: String
    @State private var snapshot: PocketCollectionSnapshot?
    @State private var selectedID: String?
    @State private var draft: [String: PocketJSONValue] = [:]
    @State private var isEditing = false
    @State private var errorText: String?
    @State private var search = ""
    @State private var pendingDelete: PocketCollectionRecord?
    @FocusState private var focusedField: String?
    @Environment(\.panelTextSize) private var panelTextSize

    private var schema: PocketCollectionSchema? { model.collectionSchemas[collectionID] }
    private var fieldKeys: [String] {
        (schema?.fields.keys.sorted() ?? []).sorted { ($0 == titleField ? 0 : 1) < ($1 == titleField ? 0 : 1) }
    }
    private var visibleRecords: [PocketCollectionRecord] {
        (snapshot?.records ?? []).filter { record in
            search.isEmpty || record.fields.values.contains {
                if case .string(let value) = $0 { return value.localizedCaseInsensitiveContains(search) }
                return false
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(schema?.title ?? model.packageName).font(.system(size: panelTextSize.scaled(13), weight: .semibold))
                Spacer()
                Button { reload() } label: { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel("最新の記録を読み込む")
                Button("追加", systemImage: "plus") { beginEditing(nil) }
                    .disabled(snapshot == nil)
            }
            if let errorText { Text(errorText).foregroundStyle(.red).font(.system(size: panelTextSize.scaled(11))) }
            if isEditing {
                ScrollView { editor.padding(.trailing, 2) }
                HStack {
                    Button("キャンセル") { isEditing = false }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("保存") { save() }.keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent).tint(Color(red: 0.98, green: 0.76, blue: 0.25))
                }
            } else {
                TextField("検索", text: $search).textFieldStyle(.roundedBorder)
                if visibleRecords.isEmpty {
                    Text(search.isEmpty ? "まだ記録がありません。追加して使い始められます。" : "一致する記録がありません。")
                        .foregroundStyle(.secondary).padding(.vertical, 16)
                }
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(visibleRecords) { record in
                            HStack(alignment: .top, spacing: 10) {
                                Button { beginEditing(record) } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(display(record.fields[titleField]).isEmpty ? "名前なし" : display(record.fields[titleField]))
                                            .fontWeight(.semibold).lineLimit(2)
                                        ForEach(Array(fieldKeys.filter { $0 != titleField }.prefix(2)), id: \.self) { key in
                                            if let value = record.fields[key] {
                                                Text("\(schema?.fields[key]?.title ?? key): \(display(value))")
                                                    .font(.system(size: panelTextSize.scaled(10))).foregroundStyle(.secondary)
                                            }
                                        }
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                        .contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                Button { pendingDelete = record } label: { Image(systemName: "trash") }
                                    .accessibilityLabel("記録を削除")
                            }.padding(9).background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                        }
                        }
                }
            }
        }
        .font(.system(size: panelTextSize.scaled(12)))
        .foregroundStyle(.white.opacity(0.9))
        .controlSize(.small)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { reload() }
        .alert("この記録を削除しますか？", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("キャンセル", role: .cancel) { pendingDelete = nil }
            Button("削除", role: .destructive) {
                if let record = pendingDelete, let snapshot {
                    perform { self.snapshot = try model.deleteCollectionRecord(collectionID, recordID: record.id, revision: snapshot.revision) }
                }
                pendingDelete = nil
            }
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(fieldKeys, id: \.self) { key in
                if let field = schema?.fields[key] {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(field.title + (field.required ? " *" : ""))
                            Spacer()
                            if !field.required {
                                Button("未入力にする") { draft.removeValue(forKey: key) }.font(.system(size: panelTextSize.scaled(10)))
                            }
                            if field.nullable {
                                Button("値なし") { draft[key] = .null }.font(.system(size: panelTextSize.scaled(10)))
                            }
                        }
                        if field.type == "boolean" {
                            Toggle(field.title, isOn: Binding(get: { draft[key] == .bool(true) }, set: { draft[key] = .bool($0) }))
                                .labelsHidden()
                        } else if field.type == "enum" {
                            Picker(field.title, selection: stringBinding(key)) {
                                Text("選択してください").tag("")
                                ForEach(field.choices, id: \.self) { Text($0).tag($0) }
                            }.labelsHidden()
                        } else {
                            TextField(field.type == "date" ? "YYYY-MM-DD" : field.title, text: stringBinding(key))
                                .textFieldStyle(.roundedBorder)
                                .focused($focusedField, equals: key)
                        }
                        if draft[key] == nil { Text("未入力").font(.system(size: panelTextSize.scaled(10))).foregroundStyle(.secondary) }
                        else if draft[key] == .null { Text("値なし").font(.system(size: panelTextSize.scaled(10))).foregroundStyle(.secondary) }
                    }
                }
            }
        }
    }

    private func stringBinding(_ key: String) -> Binding<String> {
        Binding(get: { display(draft[key]) }, set: { draft[key] = .string($0) })
    }

    private func display(_ value: PocketJSONValue?) -> String {
        switch value {
        case .string(let value): value
        case .number(let value): value.formatted(.number.grouping(.never))
        case .bool(let value): value ? "はい" : "いいえ"
        case .null: ""
        default: ""
        }
    }

    private func beginEditing(_ record: PocketCollectionRecord?) {
        selectedID = record?.id
        draft = record?.fields ?? [:]
        if record == nil {
            for (key, field) in schema?.fields ?? [:] where field.required && field.type == "boolean" {
                draft[key] = .bool(false)
            }
        }
        errorText = nil
        isEditing = true
        focusedField = titleField
    }

    private func save() {
        guard let snapshot, let schema else { return }
        perform {
            var fields = draft
            for (key, field) in schema.fields where field.type == "number" {
                if case .string(let text)? = fields[key] {
                    guard let number = Double(text), number.isFinite else { throw PocketCollectionError.invalidRecord }
                    fields[key] = .number(number)
                }
            }
            self.snapshot = try model.writeCollection(collectionID, recordID: selectedID, fields: fields, revision: snapshot.revision)
            isEditing = false
        }
    }

    private func reload() { perform { snapshot = try model.collectionSnapshot(collectionID) } }

    private func perform(_ body: () throws -> Void) {
        do { try body(); errorText = nil }
        catch PocketCollectionError.revisionConflict {
            errorText = "別の画面で記録が更新されました。最新の記録を読み込み、内容を確認してから保存してください。"
        } catch PocketCollectionError.invalidRecord {
            errorText = "必須項目、数値、日付、選択肢を確認してください。"
        } catch {
            errorText = "記録を読み込み・保存できませんでした。入力内容はこの画面に残っています。"
        }
    }
}
