import SwiftUI

/// Only the confirmed owner can open a partition. Unconfirmed sessions never
/// display the last account's drafts, even when the website cookie is retained.
struct ForumDraftSnapshot: Codable {
    var replies: [String: String] = [:]
    var messages: [Int: String] = [:]
    var discussion = Discussion()
    var images: [String: [URL: MarkdownImageScale]] = [:]
    var messageMarkdown: [Int: Bool] = [:]

    init(replies: [String: String] = [:], messages: [Int: String] = [:],
         discussion: Discussion = Discussion(), images: [String: [URL: MarkdownImageScale]] = [:],
         messageMarkdown: [Int: Bool] = [:]) {
        self.replies = replies
        self.messages = messages
        self.discussion = discussion
        self.images = images
        self.messageMarkdown = messageMarkdown
    }

    private enum CodingKeys: String, CodingKey {
        case replies, messages, discussion, images, messageMarkdown
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        replies = try values.decodeIfPresent([String: String].self, forKey: .replies) ?? [:]
        messages = try values.decodeIfPresent([Int: String].self, forKey: .messages) ?? [:]
        discussion = try values.decodeIfPresent(Discussion.self, forKey: .discussion) ?? Discussion()
        images = try values.decodeIfPresent([String: [URL: MarkdownImageScale]].self, forKey: .images) ?? [:]
        // Existing v1 partitions predate the per-peer mode. Missing means the
        // previous Markdown default; decoding must not discard their drafts.
        messageMarkdown = try values.decodeIfPresent([Int: Bool].self, forKey: .messageMarkdown) ?? [:]
    }

    struct Discussion: Codable, Equatable {
        var title = ""
        var content = ""
        var category = ""
        var rank = 0
    }
}

@MainActor
final class NewDiscussionDraft: ObservableObject {
    @Published var title = "" { didSet { didChange?() } }
    @Published var content = "" { didSet { didChange?() } }
    @Published var category = "" { didSet { didChange?() } }
    @Published var rank = 0 { didSet { didChange?() } }
    let imageSizing = DraftImageSizing()
    var didChange: (() -> Void)?

    var snapshot: ForumDraftSnapshot.Discussion {
        .init(title: title, content: content, category: category, rank: rank)
    }

    func restore(_ value: ForumDraftSnapshot.Discussion) {
        title = value.title; content = value.content; category = value.category; rank = value.rank
    }

    func clear() {
        restore(.init())
        imageSizing.reset()
    }
}
