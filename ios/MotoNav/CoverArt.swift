import UIKit
import MediaPlayer

/// 专辑封面：优先 Apple Music 本地封面，其次 iTunes Search API（免费无 Key，网易云/QQ 上的歌基本都有）。
/// 居中裁方缩到 200×200，编码成 RGB565 小端（80KB），走 bulk type 5 发给圆屏。
/// 老固件不认识 type 5 会直接丢弃，安全。
final class CoverArt {
    static let shared = CoverArt()
    private var lastKey = ""
    private var lastAt = Date.distantPast
    private var id = 1
    private let n = 200

    /// 换歌时调用；同一首歌 10 分钟内不重复查
    func update(title: String, artist: String) {
        var t = title
        while t.hasSuffix("…") || t.hasSuffix("...") { t = String(t.dropLast()) }
        t = t.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        let key = t + "|" + artist
        if key == lastKey && Date().timeIntervalSince(lastAt) < 600 { return }
        lastKey = key
        lastAt = Date()
        let myId = id
        id = (id + 1) & 0xFF
        let query = t, who = artist
        Task.detached {
            guard let img = await Self.fetch(title: query, artist: who) else { return }
            guard let data = Self.encode(img) else { return }
            BleLink.shared.sendBulk(type: 5, id: myId, data: data)
        }
    }

    static func fetch(title: String, artist: String) async -> UIImage? {
        // 1) 系统播放器正在放的歌：直接拿本地封面（无需网络）
        let item = await MainActor.run { MPMusicPlayerController.systemMusicPlayer.nowPlayingItem }
        if let art = item?.artwork, let img = art.image(at: CGSize(width: 300, height: 300)) {
            return img
        }
        // 2) iTunes Search API
        var comps = URLComponents(string: "https://itunes.apple.com/search")
        comps?.queryItems = [
            URLQueryItem(name: "term", value: artist.isEmpty ? title : title + " " + artist),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "8"),
            URLQueryItem(name: "country", value: "CN")
        ]
        guard let url = comps?.url else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Mozilla/5.0 (iPhone)", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]], !results.isEmpty else { return nil }
        let lowTitle = title.lowercased().prefix(8)
        let lowArtist = artist.lowercased().prefix(6)
        for r in results {
            guard let name = r["trackName"] as? String else { continue }
            var match = name.lowercased().contains(lowTitle)
            if !match, let album = r["collectionName"] as? String { match = album.lowercased().contains(lowTitle) }
            guard match else { continue }
            if !lowArtist.isEmpty, let a = r["artistName"] as? String,
               !a.lowercased().contains(lowArtist) { continue }
            guard let u = r["artworkUrl100"] as? String,
                  let big = URL(string: u.replacingOccurrences(of: "100x100", with: "300x300")) else { continue }
            guard let (d, r2) = try? await URLSession.shared.data(from: big),
                  (r2 as? HTTPURLResponse)?.statusCode == 200,
                  let img = UIImage(data: d) else { continue }
            return img
        }
        return nil
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
