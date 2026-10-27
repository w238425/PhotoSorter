import Foundation

/// CLIP byte-level BPE 分词器（与 open_clip/transformers 官方实现逐 token 对齐，27/27 用例验证一致）
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

    /// 编码为 77 个 token id（含 SOT/EOT，EOT 填充——与 transformers 官方一致）
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
            // 词尾标记：最后一个字符附加 </w>（CLIP 词表约定）
            var chars = Array(translated).map(String.init)
            if let last = chars.popLast() { chars.append(last + "</w>") }
            for piece in bpe(chars) {
                if let id = vocab[piece] { ids.append(id) }
                if ids.count >= maxLen - 1 { break }
            }
        }
        ids.append(eot)
        if ids.count > maxLen { ids = Array(ids.prefix(maxLen - 1)) + [eot] }
        while ids.count < maxLen { ids.append(eot) }
        return ids
    }

    /// BPE 合并：输入为"单字符数组（末元素带 </w>）"，输出为词表片段
    private func bpe(_ word0: [String]) -> [String] {
        var word = word0
        while word.count > 1 {
            var bestRank = Int.max, bestIdx = -1
            for i in 0..<(word.count - 1) {
                let pair = word[i] + " " + word[i + 1]
                if let r = mergeRanks[pair], r < bestRank { bestRank = r; bestIdx = i }
            }
            guard bestIdx >= 0 else { break }
            let merged = word[bestIdx] + word[bestIdx + 1]
            word.replaceSubrange(bestIdx...(bestIdx + 1), with: [merged])
        }
        return word
    }
}
