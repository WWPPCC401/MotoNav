import UIKit
import MediaPlayer

/// 专辑封面：优先系统媒体封面 / Apple Music 本地封面，其次 iTunes Search API。
/// 居中裁方缩到 200×200，编码成 RGB565 小端（80KB），走 bulk type 5 发给圆屏。
/// 老固件不认识 type 5 会直接丢弃，安全。
///
/// v0.15.3：网易云/QQ 音乐会把「作曲: xxx」「纯音乐，请欣赏」这类歌词/提示语
/// 写进 AMS 的 Title 字段。用脏 Title 搜 iTunes 会拿到完全无关的封面，而
/// v0.15.2 的「匹配不上就取第一张」兜底会把它直接推上圆屏。现在改为：
///   1) 优先用 AMS 的 Album 字段（干净）搜 entity=album，直接拿专辑封面；
///   2) Title 疑似歌词/提示语时不参与搜索；
///   3) 只接受可靠匹配（分数 >= 8），匹配不上宁可保持当前封面，绝不取第一张凑数。
final class CoverArt {
    static let shared = CoverArt()
    private var lastKey = ""
    private var lastAt = Date.distantPast
    private var id = 1

    private struct Candidate: Sendable {
        let term: String, entity: String, nameKey: String, label: String, target: String
    }

    /// 换歌时调用；同一张专辑 30 秒内不重复查，force 可强制重查
    func update(title: String, artist: String, album: String, force: Bool = false) {
        let t = Self.cleanText(title)
        let a = Self.cleanText(album)
        let who = Self.cleanText(artist)
        let titleOK = !t.isEmpty && !Self.isLyrics(t)
        let albumOK = !a.isEmpty && !Self.isLyrics(a)

        guard titleOK || albumOK else {
            let hint = Self.brief(t.isEmpty ? title : t)
            DispatchQueue.main.async {
                BleLink.shared.coverStatus = "歌名是歌词/提示语，跳过查询 [\(hint)]"
            }
            return
        }

        // 用专辑名做去重键：歌词每几秒就换一句，不能用脏 Title 当 key
        let anchor = albumOK ? a : t
        let key = anchor + "|" + who
        if !force && key == lastKey && Date().timeIntervalSince(lastAt) < 30 { return }
        lastKey = key
        lastAt = Date()
        let myId = id
        id = (id + 1) & 0xFF

        var candidates: [Candidate] = []
        if albumOK {
            candidates.append(Candidate(term: a, entity: "album", nameKey: "collectionName", label: "专辑名", target: a))
            candidates.append(Candidate(term: a, entity: "song", nameKey: "collectionName", label: "专辑名", target: a))
            if !who.isEmpty {
                candidates.append(Candidate(term: a + " " + who, entity: "album", nameKey: "collectionName", label: "专辑名", target: a))
            }
        }
        if titleOK {
            candidates.append(Candidate(term: t + " " + who, entity: "song", nameKey: "trackName", label: "歌名", target: t))
            candidates.append(Candidate(term: t, entity: "song", nameKey: "trackName", label: "歌名", target: t))
        }

        let hint = Self.brief(anchor)
        Task.detached {
            DispatchQueue.main.async { BleLink.shared.coverStatus = "查询中：\(hint)" }
            guard let hit = await Self.fetchEncoded(candidates: candidates, artist: who) else {
                DispatchQueue.main.async { BleLink.shared.coverStatus = "无可靠匹配，保持当前封面 [\(hint)]" }
                return
            }
            let data = hit.0, label = hit.1
            DispatchQueue.main.async {
                BleLink.shared.coverStatus = "\(label) ✓ 已发送 \(data.count / 1024) KB [\(hint)]"
                BleLink.shared.sendBulk(type: 5, id: myId, data: data)
            }
        }
    }

    /// 返回 (RGB565 数据, 来源标签)
    private static func fetchEncoded(candidates: [Candidate], artist: String) async -> (Data, String)? {
        // 1) Apple Music 本地封面
        if MPMediaLibrary.authorizationStatus() == .authorized {
            let item: MPMediaItem? = await MainActor.run { MPMusicPlayerController.systemMusicPlayer.nowPlayingItem }
            if let art = item?.artwork,
               let img = art.image(at: CGSize(width: 300, height: 300)),
               let d = encode(img) { return (d, "本地封面") }
        }
        // 2) 系统正在播放的媒体封面（若系统允许跨 App 读取，这是最精确的一张）
        let systemArt: Data? = await MainActor.run {
            guard let info = MPNowPlayingInfoCenter.default().nowPlayingInfo,
                  let art = info[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork,
                  let img = art.image(at: CGSize(width: 300, height: 300)) else { return nil }
            return encode(img)
        }
        if let d = systemArt { return (d, "系统媒体封面") }

        // 3) iTunes Search API（中国区无曲库，走 us / jp / tw）
        let na = norm(artist)
        var requests = 0
        for c in candidates {
            for country in ["us", "jp", "tw"] {
                if requests >= 10 { return nil }
                requests += 1
                var comps = URLComponents(string: "https://itunes.apple.com/search")
                comps?.queryItems = [
                    URLQueryItem(name: "term", value: c.term),
                    URLQueryItem(name: "entity", value: c.entity),
                    URLQueryItem(name: "limit", value: "12"),
                    URLQueryItem(name: "country", value: country)
                ]
                guard let url = comps?.url else { continue }
                var req = URLRequest(url: url, timeoutInterval: 7)
                req.setValue("Mozilla/5.0 (iPhone)", forHTTPHeaderField: "User-Agent")
                guard let (raw, resp) = try? await URLSession.shared.data(for: req),
                      (resp as? HTTPURLResponse)?.statusCode == 200,
                      let json = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
                      let results = json["results"] as? [[String: Any]], !results.isEmpty else { continue }

                let target = norm(c.target)
                var bestURL: String? = nil, bestScore = 0, bestLen = Int.max
                for r in results {
                    guard let u = r["artworkUrl100"] as? String else { continue }
                    let name = (r[c.nameKey] as? String)
                        ?? (r["trackName"] as? String)
                        ?? (r["collectionName"] as? String) ?? ""
                    let n = norm(name)
                    var s = 0
                    if !target.isEmpty && n == target { s = 20 }          // 完全同名最优先
                    else if !target.isEmpty && n.contains(target) { s = 10 }
                    else if !target.isEmpty && !n.isEmpty && target.contains(n) { s = 8 }
                    else if !target.isEmpty {
                        let p = target.prefix(min(4, target.count))
                        if !p.isEmpty && n.hasPrefix(String(p)) { s = 5 }
                    }
                    // 歌手只加分、不硬过滤：iTunes 常用英文名（Eason Chan / Mao Bu Yi）
                    if !na.isEmpty, let a = r["artistName"] as? String {
                        let ra = norm(a)
                        if ra.contains(na) || na.contains(ra) { s += 2 }
                    }
                    // 同分选名称更短的，避开 Remixes / B-Sides / Vol.2 之类衍生版
                    if s > bestScore || (s == bestScore && s > 0 && n.count < bestLen) {
                        bestScore = s; bestLen = n.count; bestURL = u
                    }
                }
                // 只接受可靠匹配；绝不用「第一张」凑数，避免张冠李戴
                guard bestScore >= 8, let u = bestURL,
                      let imageData = await download(u),
                      let img = UIImage(data: imageData), let out = encode(img) else { continue }
                return (out, "\(c.label)(\(country))")
            }
        }
        return nil
    }

    private static func download(_ u: String) async -> Data? {
        let big = u.replacingOccurrences(of: "100x100", with: "300x300")
        for s in [big, u] {
            guard let url = URL(string: s) else { continue }
            guard let (d, r) = try? await URLSession.shared.data(from: url),
                  (r as? HTTPURLResponse)?.statusCode == 200, !d.isEmpty else { continue }
            return d
        }
        return nil
    }

    // MARK: - 歌名卫生

    private static let junkWords = [
        "作曲", "作词", "编曲", "演唱", "词曲", "制作人", "出品", "监制",
        "纯音乐", "请欣赏", "暂无歌词", "歌词", "lrc", "伴奏", "试听",
        "op:", "sp:", "作曲:", "作词:"
    ]

    /// 判断这条「歌名」是不是被音乐 App 塞进来的歌词 / 歌曲信息 / 提示语
    static func isLyrics(_ s: String) -> Bool {
        let low = s.lowercased()
        if junkWords.contains(where: { low.contains($0) }) { return true }
        if s.count > 32 { return true }                 // 歌词行通常比歌名长
        if s.contains("，") || s.contains("、") { return true }
        return false
    }

    private static func cleanText(_ s: String) -> String {
        var t = s
        while t.hasSuffix("…") || t.hasSuffix("...") { t = String(t.dropLast()) }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func brief(_ s: String) -> String {
        s.count <= 14 ? s : String(s.prefix(14)) + "…"
    }

    /// 去掉括号里的版本说明、常见后缀，只留文字数字，方便中英混排比对
    private static func clean(_ s: String) -> String {
        var x = s.lowercased()
        x = x.replacingOccurrences(of: "\\s*[（(\\[【][^)）\\]】]*[)）\\]】]?\\s*", with: " ", options: .regularExpression)
        for junk in [" live", " remix", " 伴奏", " 纯音乐", " instrumental", " feat.", " ft.", " dj版", " 完整版", " 版"] {
            x = x.replacingOccurrences(of: junk, with: " ")
        }
        return x.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func norm(_ s: String) -> String {
        var out = ""
        for u in clean(s).unicodeScalars where CharacterSet.alphanumerics.contains(u) {
            out.unicodeScalars.append(u)
        }
        return out
    }

    /// 居中裁方 → 200×200 → RGB565 小端
    static func encode(_ image: UIImage) -> Data? {
        let n = 200
        guard let cg = image.cgImage else { return nil }
        let side = min(cg.width, cg.height)
        let crop = CGRect(x: (cg.width - side) / 2, y: (cg.height - side) / 2, width: side, height: side)
        guard let sq = cg.cropping(to: crop) else { return nil }
        guard let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(sq, in: CGRect(x: 0, y: 0, width: n, height: n))
        guard let buf = ctx.data else { return nil }
        let px = buf.assumingMemoryBound(to: UInt8.self)
        var out = Data(capacity: n * n * 2)
        for y in 0..<n {
            for x in 0..<n {
                let i = (y * n + x) * 4
                let v = (UInt16(px[i] >> 3) << 11) | (UInt16(px[i + 1] >> 2) << 5) | UInt16(px[i + 2] >> 3)
                out.append(UInt8(v & 0xFF))
                out.append(UInt8(v >> 8))
            }
        }
        return out
    }
}
