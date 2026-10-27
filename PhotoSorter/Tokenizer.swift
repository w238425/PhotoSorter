import Foundation

/// CLIP byte-level BPE 分词器（与 open_clip 一致，纯 Swift 实现）
final class CLIPTokenizer {
    private var vocab: [String: Int] = [:]
    private var mergeRanks: [String: Int] = [:]
    private let byteEncoder: [UInt8: String]
    private let regex: NSRegularExpression
    private let sot = 49406, eot = 49407, maxLen = 77

    init?(vocabData: Data, mergesData: Data) {
        // bytes_to_unicode 映射
        var bs: [Int] = []
        for b in 33...126 { bs.append(b) }
        for b in 161...172 { bs.append(b) }
        for b in 174...255 { bs.append(b) }
        var cs = bs
        var n = 256
        for b in 0..<256 where !bs.contains(b) {
            bs.append(b); cs.append(n); n += 1
        }
        var enc: [UInt8: String] = [:]
        for (i, b) in bs.enumerated() {
            enc[UInt8(b)] = String(UnicodeScalar(cs[i])!)
        }
        byteEncoder = enc

        guard let vo = try? JSONSerialization.jsonObject(with: vocabData) as? [String: Int] else { return nil }
        vocab = vo
        let mergesText = String(data: mergesData, encoding: .utf8) ?? ""
        var rank = 0
        for line in mergesText.split(separator: "\n") {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.isEmpty || l.hasPrefix("#") || l.hasPrefix("version") { continue }
            let parts = l.split(separator: " ").map(String.init)
            if parts.count == 2 {
                let key = parts[0] + " " + parts[1]
                if mergeRanks[key] == nil { mergeRanks[key] = rank; rank += 1 }
            }
        }
        regex = try! NSRegularExpression(
            pattern: "<\\|startoftext\\|>|<\\|endoftext\\|>|'s|'t|'re|'ve|'m|'ll|'d|[\\p{L}]+|[\\p{N}]|[^\\s\\p{L}\\p{N}]+"
        )
    }

    /// 编码为 77 个 token id（含 SOT/EOT，0 填充）
    func encode(_ text: String) -> [Int] {
        var ids = [sot]
        let clean = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(clean.startIndex..., in: clean)
        var words: [String] = []
        regex.enumerateMatches(in: clean, range: range) { m, _, _ in
            if let m, let r = Range(m.range, in: clean) { words.append(String(clean[r])) }
        }
        for w in words {
            if ids.count >= maxLen - 1 { break }
            if w == "<|startoftext|>" { ids.append(sot); continue }
            if w == "<|endoftext|>" { ids.append(eot); continue }
            var translated = ""
            for b in w.utf8 { translated += byteEncoder[b] ?? "" }
            for piece in bpe(translated) {
                if let id = vocab[piece] { ids.append(id) }
                if ids.count >= maxLen - 1 { break }
            }
        }
        ids.append(eot)
        if ids.count > maxLen { ids = Array(ids.prefix(maxLen - 1)) + [eot] }
        while ids.count < maxLen { ids.append(0) }
        return ids
    }

    private func bpe(_ token: String) -> [String] {
        var word = Array(token)
        guard word.count > 1 else { return [token] }
        while word.count > 1 {
            var bestRank = Int.max, bestIdx = -1
            for i in 0..<(word.count - 1) {
                let pair = String(word[i]) + " " + String(word[i + 1])
                if let r = mergeRanks[pair], r < bestRank { bestRank = r; bestIdx = i }
            }
            guard bestIdx >= 0 else { break }
            let merged = String(word[bestIdx]) + String(word[bestIdx + 1])
            word.replaceSubrange(bestIdx...(bestIdx + 1), with: Array(merged))
        }
        return word.map(String.init)
    }
}
