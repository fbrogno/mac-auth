import AuthCore
import Foundation

enum AccountSearch {
    private static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    /// Keeps accounts matching every word of `query` (issuer, name, group, note); best hits first
    /// (prefix before contains, issuer before name). Without a query the order is unchanged.
    static func filter(_ accounts: [Account], query: String, groupName: (UUID?) -> String?) -> [Account] {
        let words = fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return accounts }
        var scored: [(account: Account, score: Int, position: Int)] = []
        for (position, account) in accounts.enumerated() {
            let issuer = fold(account.issuer), name = fold(account.name)
            let group = fold(groupName(account.groupID) ?? ""), note = fold(account.note)
            var total = 0
            var matchesAll = true
            for word in words {
                let score: Int?
                if issuer.hasPrefix(word) { score = 0 }
                else if name.hasPrefix(word) { score = 1 }
                else if issuer.contains(word) { score = 2 }
                else if name.contains(word) { score = 3 }
                else if group.contains(word) { score = 4 }
                else if note.contains(word) { score = 5 }
                else { score = nil }
                guard let score else { matchesAll = false; break }
                total += score
            }
            if matchesAll { scored.append((account, total, position)) }
        }
        return scored.sorted { ($0.score, $0.position) < ($1.score, $1.position) }.map(\.account)
    }
}
