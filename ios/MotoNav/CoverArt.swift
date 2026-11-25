import UIKit
import MediaPlayer

/// 专辑封面：优先 Apple Music 本地封面，其次 iTunes Search API（免费无 Key）。
/// 居中裁方缩到 200×200，编码成 RGB565 小端（80KB），走 bulk type 5 发给圆屏。
/// 老固件不认识 type 5 会直接丢弃，安全。
/// v0.15.2 修复：iTunes 中国区已无曲库（country=CN 恒 0 结果）→ 改走 us/jp/tw；
/// 歌手名中英不一致（陈奕迅 vs Eason Chan）不再把结果全部过滤掉；
/// 匹配失败时退回第一张可用封面；查询状态显示在 App 调试信息里，方便定位。
final class CoverArt {
    static let shared = CoverArt()
    private var lastKey = ""
    private var lastAt = Date.distantPast
    private var id = 1

    /// 换歌时调用；同一首歌 30 秒内不重复查，force 可强制重查
    func update(title: String, artist: String, force: Bool = false) {
        var t = title
        while t.hasSuffix("…") || t.hasSuffix("...") { t = String(t.dropLast()) }
        t = t.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        let key = t + "|" + artist
        if !force && key == lastKey && Date().timeIntervalSince(lastAt) < 30 { return }
        lastKey = key
        lastAt = Date()
        let myId = id
        id = (id + 1) & 0xFF
        let query = t, who = artist
        Task.detached {
            DispatchQueue.main.async { BleLink.shared.coverStatus = "查询中：\(query)" }
            guard let hit = await Self.fetchEncoded(title: query, artist: who) else {
                DispatchQueue.main.async { BleLink.shared.coverStatus = "未找到封面：\(query)（us/jp/tw）" }
                return
            }
            let data = hit.0, label = hit.1
            DispatchQueue.main.async {
                BleLink.shared.coverStatus = "\(label) ✓ 已发送 \(data.count / 1024) KB"
                BleLink.shared.sendBulk(type: 5, id: myId, data: data)
            }
        }
    }

    /// 返回 (RGB565 数据, 来源标签)
    static func fetchEncoded(title: String, artist: String) async -> (Data, String)? {
        // 1) 系统播放器正在放的歌：直接拿本地封面（无需网络）
        if MPMediaLibrary.authorizationStatus() == .authorized {
            let item: MPMediaItem? = await MainActor.run { MPMusicPlayerController.systemMusicPlayer.nowPlayingItem }
            if let art = item?.artwork,
               let img = art.image(at: CGSize(width: 300, height: 300)),
               let d = encode(img) { return (d, "本地封面") }
        }
        // 2) iTunes Search API：中国区 iTunes Store 不卖歌，改走 us / jp / tw
        let nt = norm(title)
        let na = norm(artist)
        let terms = [clean(title) + " " + clean(artist), clean(title)]
        for country in ["us", "jp", "tw"] {
            for term in terms where !term.isEmpty {
                var comps = URLComponents(string: "https://itunes.apple.com/search")
                comps?.queryItems = [
                    URLQueryItem(name: "term", value: term),
                    URLQueryItem(name: "entity", value: "song"),
                    URLQueryItem(name: "limit", value: "12"),
                    URLQueryItem(name: "country", value: country)
                ]
                guard let url = comps?.url else { continue }
                var req = URLRequest(url: url, timeoutInterval: 8)
                req.setValue("Mozilla/5.0 (iPhone)", forHTTPHeaderField: "User-Agent")
                guard let (raw, resp) = try? await URLSession.shared.data(for: req),
                      (resp as? HTTPURLResponse)?.statusCode == 200,
                      let json = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
                      let results = json["results"] as? [[String: Any]], !results.isEmpty else { continue }
                var bestURL: String? = nil, bestScore = 0
                for r in results {
                    guard let u = r["artworkUrl100"] as? String else { continue }
                    let rn = norm(r["trackName"] as? String ?? "")
                    var s = 0
                    if !nt.isEmpty && rn.contains(nt) { s = 10 }
                    else if !nt.isEmpty && !rn.isEmpty && nt.contains(rn) { s = 8 }
                    else if !nt.isEmpty {
                        let p = nt.prefix(min(3, nt.count))
                        if !p.isEmpty && rn.hasPrefix(String(p)) { s = 5 }
                    }
                    // 歌手只加分、不再硬过滤：iTunes 元数据常用英文名（Eason Chan / Mao Bu Yi）
                    if !na.isEmpty, let a = r["artistName"] as? String {
                        let ra = norm(a)
                        if ra.contains(na) || na.contains(ra) { s += 2 }
                    }
                    if s > bestScore { bestScore = s; bestURL = u }
                }
                // 兜底：完全匹配不上也拿第一张，总比内置黑胶强
                if bestURL == nil { bestURL = results.compactMap { $0["artworkUrl100"] as? String }.first }
                guard let u = bestURL, let imageData = await download(u) else { continue }
                guard let img = UIImage(data: imageData), let out = encode(img) else { continue }
                return (out, bestScore >= 8 ? "iTunes(\(country)) 精确" : "iTunes(\(country)) 近似")
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
