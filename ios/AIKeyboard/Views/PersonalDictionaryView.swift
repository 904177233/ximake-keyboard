//
//  PersonalDictionaryView.swift
//  墨语 App · 个人词库
//
//  键盘记下的「这个拼音选过哪个词」都在这里：看、搜、加、删、清空。
//  清空只能在这里做，键盘里不放这个按钮，免得误点。
//

import SwiftUI

@MainActor
final class PersonalDictionaryModel: ObservableObject {
    @Published private(set) var entries: [UserLearningStore.Entry] = []
    private let store = UserLearningStore(store: .shared)

    var isShared: Bool { SharedBlob.shared.isShared }

    func reload() {
        store.reloadIfChanged()
        entries = store.allEntries()
    }

    func add(text: String, pinyin: String) {
        store.addEntry(text: text, key: pinyin)
        reload()
    }

    func remove(_ entry: UserLearningStore.Entry) {
        store.removeEntry(text: entry.text, key: entry.key)
        reload()
    }

    func clear() {
        store.reset()
        reload()
    }

    /// 汉字转不带声调的拼音，比如「墨语」-> moyu。
    static func pinyin(of text: String) -> String {
        let mutable = NSMutableString(string: text)
        CFStringTransform(mutable, nil, kCFStringTransformToLatin, false)
        CFStringTransform(mutable, nil, kCFStringTransformStripDiacritics, false)
        return (mutable as String).lowercased().filter { $0.isASCII && $0.isLetter }
    }
}

@MainActor
struct PersonalDictionaryView: View {
    @Environment(\.palette) private var palette
    @StateObject private var model = PersonalDictionaryModel()
    @State private var search = ""
    @State private var newText = ""
    @State private var newPinyin = ""
    @State private var confirmsClear = false

    private var filtered: [UserLearningStore.Entry] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return model.entries }
        return model.entries.filter { $0.text.contains(query) || $0.key.hasPrefix(query) }
    }

    var body: some View {
        List {
            if !model.isShared {
                Section {
                    Text("这台手机上 App 和键盘没打通：这里看不到键盘记下的词，在这里加的词键盘也用不上。")
                        .font(.system(size: 13))
                        .foregroundColor(palette.secondary.color)
                }
            }

            Section {
                TextField("词，比如「墨语」", text: $newText)
                    .onChange(of: newText) { value in
                        newPinyin = PersonalDictionaryModel.pinyin(of: value)
                    }
                HStack {
                    TextField("拼音（自动填好，多音字可以改）", text: $newPinyin)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("加上") {
                        model.add(text: newText, pinyin: newPinyin)
                        newText = ""
                        newPinyin = ""
                    }
                    .disabled(newText.trimmingCharacters(in: .whitespaces).isEmpty || newPinyin.isEmpty)
                }
            } header: {
                Text("自己加一个词")
            } footer: {
                Text("加上以后打这个拼音，它排第一个。")
            }

            Section {
                if filtered.isEmpty {
                    Text(model.entries.isEmpty ? "还没有记下的词。用键盘打字时选过的词会出现在这里。" : "没找到")
                        .font(.system(size: 14))
                        .foregroundColor(palette.secondary.color)
                }
                ForEach(filtered.prefix(500)) { entry in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.text)
                                .font(.system(size: 16))
                                .foregroundColor(palette.text.color)
                            Text(entry.key)
                                .font(.system(size: 12))
                                .foregroundColor(palette.secondary.color)
                        }
                        Spacer()
                        Text(entry.count > 0 ? "选过 \(entry.count) 次" : "短语")
                            .font(.system(size: 12))
                            .foregroundColor(palette.secondary.color)
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            model.remove(entry)
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
            } header: {
                Text("记下的词（\(model.entries.count)）")
            } footer: {
                Text("左滑可以删。选得越多的排得越前。")
            }

            if !model.entries.isEmpty {
                Section {
                    Button("清空个人词库", role: .destructive) { confirmsClear = true }
                }
            }
        }
        .searchable(text: $search, prompt: "搜词或拼音")
        .navigationTitle("个人词库")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { model.reload() }
        .confirmationDialog("清空后，打过的词不再排前面，也不能恢复。", isPresented: $confirmsClear, titleVisibility: .visible) {
            Button("清空", role: .destructive) { model.clear() }
            Button("取消", role: .cancel) {}
        }
    }
}
