//
//  IMEKit.swift
//  墨语 · 输入法内核
//
//  把词库、学习、引擎、短语、剪贴板历史和上下文联想组装到一起，界面层只和这一个对象打交道。
//

import Foundation

/// 输入法内核门面。
public final class IMEKit {

    public let dictionary: MoyuDictionary?
    public let learning: UserLearningStore
    public let engine: PinyinEngine
    public private(set) var phrases: PhraseLibrary
    public let clipboard: ClipboardHistory
    public let contextual: LocalSuggestionIndex

    private let store: SharedStore

    public init(store: SharedStore, clipboardEnabled: Bool = false) {
        self.store = store
        let learning = UserLearningStore(store: store)
        let dictionary = MoyuDictionary.shared
        self.dictionary = dictionary
        self.learning = learning
        self.engine = PinyinEngine(dictionary: dictionary, learning: learning)
        self.phrases = PhraseLibrary(store: store)
        self.clipboard = ClipboardHistory(store: store, enabled: clipboardEnabled)
        self.contextual = LocalSuggestionIndex(store: store)
        FuzzyPinyinSettings.shared.configure(store: store)
    }

    /// 重新读短语（可能刚在 App 里改过）。
    public func reloadPhrases() {
        phrases = PhraseLibrary(store: store)
    }

    /// 词条总数；词库没加载上时为 0。
    public var wordCount: Int { dictionary?.entryCount ?? 0 }
}
