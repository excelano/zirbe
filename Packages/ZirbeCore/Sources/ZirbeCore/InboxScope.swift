// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)

import Foundation

@MainActor
public enum InboxScope {
    case account(InboxModel)
    case allInboxes([InboxModel])

    public var models: [InboxModel] {
        switch self {
        case .account(let model): [model]
        case .allInboxes(let models): models
        }
    }

    public var isAllInboxes: Bool {
        if case .allInboxes = self { true } else { false }
    }

    public var summaries: [ThreadSummary] {
        switch self {
        case .account(let model): model.summaries
        case .allInboxes(let models): Self.merged(models.map(\.summaries))
        }
    }

    public var isSyncing: Bool { models.contains(where: \.isSyncing) }
    public var hasSynced: Bool { models.allSatisfy(\.hasSynced) }
    public var errorMessage: String? { models.lazy.compactMap(\.errorMessage).first }

    public func model(for summary: ThreadSummary) -> InboxModel? {
        models.first { $0.account.id == summary.accountID }
    }

    public func loadCached() async {
        for model in models { await model.loadCached() }
    }

    public func refresh() async {
        await withTaskGroup(of: Void.self) { group in
            for model in models { group.addTask { await model.refresh() } }
        }
    }

    public func startLiveRefresh() {
        for model in models { model.startLiveRefresh() }
    }

    public func stopLiveRefresh() async {
        for model in models { await model.stopLiveRefresh() }
    }

    public func search(_ query: String) async -> [ThreadSummary] {
        var lists: [[ThreadSummary]] = []
        for model in models { lists.append(await model.search(query)) }
        return Self.merged(lists)
    }

    public func searchServer(_ query: String) async -> [ThreadSummary]? {
        var lists: [[ThreadSummary]] = []
        for model in models {
            if let hits = await model.searchServer(query) { lists.append(hits) }
        }
        return lists.isEmpty ? nil : Self.merged(lists)
    }

    public func perform(
        on summaries: [ThreadSummary],
        _ action: (InboxModel, [String]) async -> Void
    ) async {
        for (accountID, group) in Dictionary(grouping: summaries, by: \.accountID) {
            guard let model = models.first(where: { $0.account.id == accountID }) else { continue }
            await action(model, group.map(\.id))
        }
    }

    static func merged(_ lists: [[ThreadSummary]]) -> [ThreadSummary] {
        lists.joined().sorted { a, b in
            if a.isPinned != b.isPinned { return a.isPinned }
            return (a.lastActivity ?? .distantPast) > (b.lastActivity ?? .distantPast)
        }
    }
}
