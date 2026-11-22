import WidgetKit
import SwiftUI
import CryptoKit

private let groupID = AppGroup.id

struct AtriumItem: Codable, Identifiable {
    var id: String
    var title: String
    var subtitle: String?
    var image: String?
    var progress: Double?
    var url: String?
}

struct AtriumSnapshot: Codable {
    var continueWatching: [AtriumItem] = []
    var discover: [AtriumItem] = []
    var library: [AtriumItem] = []
    var nowPlaying: AtriumItem?
}

struct AtriumEntry: TimelineEntry {
    let date: Date
    let data: AtriumSnapshot
    let diagnostic: String
    var art: [String: UIImage] = [:]
}

// MARK: pictures
// A widget cannot load pictures while it is on screen, so the stills are fetched when the timeline is made,
// made small (the widget's memory is tight) and kept in the shared folder for the next time.
enum ArtCache {
    private static var folder: URL? {
        guard let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) else { return nil }
        let dir = base.appendingPathComponent("widget-art", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private static func file(for url: String) -> URL? {
        let name = SHA256.hash(data: Data(url.utf8)).map { String(format: "%02x", $0) }.joined()
        return folder?.appendingPathComponent(name + ".jpg")
    }
    static func image(_ address: String?) async -> UIImage? {
        guard let address, let url = URL(string: address), url.scheme == "https", let path = file(for: address) else { return nil }
        if let data = try? Data(contentsOf: path), let img = UIImage(data: data) { return img }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        guard let (data, _) = try? await URLSession.shared.data(for: request), let full = UIImage(data: data) else { return nil }
        let width: CGFloat = 520
        let scale = min(1, width / max(1, full.size.width))
        let size = CGSize(width: (full.size.width * scale).rounded(), height: (full.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let small = UIGraphicsImageRenderer(size: size, format: format).image { _ in full.draw(in: CGRect(origin: .zero, size: size)) }
        if let jpg = small.jpegData(compressionQuality: 0.8) { try? jpg.write(to: path) }
        prune()
        return small
    }
    // Keeps the 80 most recent pictures.
    private static func prune() {
        guard let dir = folder, let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]),
              files.count > 80 else { return }
        let dated = files.map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        dated.sorted { $0.1 > $1.1 }.dropFirst(80).forEach { try? FileManager.default.removeItem(at: $0.0) }
    }
}

struct AtriumProvider: TimelineProvider {
    let kind: AtriumKind
    func placeholder(in context: Context) -> AtriumEntry { AtriumEntry(date: .now, data: AtriumSnapshot(), diagnostic: "PREVIEW") }
    func getSnapshot(in context: Context, completion: @escaping (AtriumEntry) -> Void) {
        Task { completion(await withArt(load())) }
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<AtriumEntry>) -> Void) {
        Task { completion(Timeline(entries: [await withArt(load())], policy: .after(Date().addingTimeInterval(1800)))) }
    }
    private func withArt(_ entry: AtriumEntry) async -> AtriumEntry {
        var e = entry
        let wanted = kind.items(in: entry.data).prefix(4).compactMap { $0.image }
        await withTaskGroup(of: (String, UIImage?).self) { group in
            for address in Set(wanted) { group.addTask { (address, await ArtCache.image(address)) } }
            for await (address, image) in group { if let image { e.art[address] = image } }
        }
        return e
    }
    private func load() -> AtriumEntry {
        let groupContainer = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)
        let defaults = UserDefaults(suiteName: groupID)
        let data = defaults?.data(forKey: "snapshot")
        let decoded = data.flatMap { try? JSONDecoder().decode(AtriumSnapshot.self, from: $0) }
        let diagnostic = groupContainer == nil ? "GROUP ENTITLEMENT MISSING" : defaults == nil ? "GROUP UNAVAILABLE"
            : data == nil ? "NO SHARED DATA" : decoded == nil ? "DECODE FAILED" : "DATA OK"
        return AtriumEntry(date: .now, data: decoded ?? AtriumSnapshot(), diagnostic: diagnostic)
    }
}

enum AtriumKind: String, CaseIterable {
    case continueWatching = "atrium.continue"
    case discover = "atrium.discover"
    case library = "atrium.library"
    case nowPlaying = "atrium.now"
    var title: String {
        switch self {
        case .continueWatching: return "Continue watching"
        case .discover: return "Popular now"
        case .library: return "My list"
        case .nowPlaying: return "Now playing"
        }
    }
    var gallery: String {
        switch self {
        case .continueWatching: return "Continue watching"
        case .discover: return "Discover"
        case .library: return "My list"
        case .nowPlaying: return "Now playing"
        }
    }
    func items(in data: AtriumSnapshot) -> [AtriumItem] {
        switch self {
        case .continueWatching: return data.continueWatching
        case .discover: return data.discover
        case .library: return data.library
        case .nowPlaying: return data.nowPlaying.map { [$0] } ?? []
        }
    }
}

// MARK: design: Atrium's dark screens, red accent, wide stills with the title over a shade

private let atriumRed = Color(red: 0.90, green: 0.04, blue: 0.08)
private let ink = Color(red: 0.043, green: 0.043, blue: 0.051)

private struct Still: View {
    let item: AtriumItem
    let art: UIImage?
    var body: some View {
        ZStack {
            Color.white.opacity(0.08)
            if let art {
                Image(uiImage: art).resizable().aspectRatio(contentMode: .fill)
            } else {
                Text(item.title).font(.system(size: 13, weight: .heavy)).multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.75)).padding(8)
            }
        }
        .clipped()
    }
}

private struct ProgressLine: View {
    let value: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.25))
                Capsule().fill(atriumRed).frame(width: max(4, g.size.width * min(1, max(0, value))))
            }
        }
        .frame(height: 3)
    }
}

// A wide card: the still, a shade at the foot, the title and the line under it, the progress bar.
private struct Tile: View {
    let item: AtriumItem
    let art: UIImage?
    var big = false
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Still(item: item, art: art)
            LinearGradient(colors: [.clear, .black.opacity(0.35), .black.opacity(0.92)], startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.system(size: big ? 17 : 12, weight: .bold)).lineLimit(big ? 2 : 1)
                if let sub = item.subtitle, !sub.isEmpty {
                    Text(sub).font(.system(size: big ? 12 : 10, weight: .medium)).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                }
                if let p = item.progress { ProgressLine(value: p).padding(.top, 3) }
            }
            .padding(.horizontal, big ? 12 : 8).padding(.bottom, big ? 10 : 7)
        }
        .foregroundStyle(.white)
        .clipShape(RoundedRectangle(cornerRadius: big ? 14 : 10, style: .continuous))
    }
}

// One line of a list: a small wide still on the left, the words on the right.
private struct Line: View {
    let item: AtriumItem
    let art: UIImage?
    var body: some View {
        HStack(spacing: 10) {
            Still(item: item, art: art)
                .frame(width: 80, height: 45)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                if let sub = item.subtitle, !sub.isEmpty {
                    Text(sub).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                }
                if let p = item.progress { ProgressLine(value: p).padding(.top, 2) }
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
    }
}

struct AtriumWidgetView: View {
    let entry: AtriumEntry
    let kind: AtriumKind
    @Environment(\.widgetFamily) private var family

    private var items: [AtriumItem] { kind.items(in: entry.data) }
    private func art(_ item: AtriumItem) -> UIImage? { item.image.flatMap { entry.art[$0] } }
    private func link(_ item: AtriumItem) -> URL { URL(string: item.url ?? "") ?? URL(string: "atrium://home")! }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("ATRIUM").font(.system(size: 13, weight: .black, design: .default)).tracking(0.5).foregroundStyle(atriumRed)
            Text(kind.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    var body: some View {
        content
            .padding(family == .systemSmall && !items.isEmpty ? 0 : 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .containerBackground(for: .widget) {
                LinearGradient(colors: [Color(red: 0.09, green: 0.09, blue: 0.11), ink], startPoint: .top, endPoint: .bottom)
            }
            .widgetURL(URL(string: "atrium://home"))
    }

    @ViewBuilder private var content: some View {
        if items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                header
                Spacer(minLength: 0)
                Text(emptyMessage).font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.7)).lineLimit(3)
                if entry.diagnostic != "DATA OK" {
                    Text(entry.diagnostic).font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundStyle(.orange).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        } else {
            switch family {
            case .systemSmall:
                // The first title, edge to edge.
                Link(destination: link(items[0])) { Tile(item: items[0], art: art(items[0])) }
            case .systemMedium:
                VStack(alignment: .leading, spacing: 8) {
                    header
                    HStack(spacing: 8) {
                        ForEach(Array(items.prefix(2))) { item in
                            Link(destination: link(item)) { Tile(item: item, art: art(item)) }
                        }
                        if items.count == 1 { Color.clear }
                    }
                }
            default:
                VStack(alignment: .leading, spacing: 10) {
                    header
                    Link(destination: link(items[0])) { Tile(item: items[0], art: art(items[0]), big: true) }
                        .frame(maxHeight: 150)
                    ForEach(Array(items.dropFirst().prefix(3))) { item in
                        Link(destination: link(item)) { Line(item: item, art: art(item)) }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var emptyMessage: String {
        switch kind {
        case .continueWatching: return "What you are watching shows up here."
        case .discover: return "Open Atrium to see what is popular."
        case .library: return "Your saved titles show up here."
        case .nowPlaying: return "Nothing is playing right now."
        }
    }
}

struct AtriumWidget: Widget {
    let kind: AtriumKind
    init() { kind = .continueWatching }
    init(kind: AtriumKind) { self.kind = kind }
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind.rawValue, provider: AtriumProvider(kind: kind)) { entry in
            AtriumWidgetView(entry: entry, kind: kind)
        }
        .configurationDisplayName(kind.gallery)
        .description("Your Atrium titles, at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

@main
struct AtriumWidgets: WidgetBundle {
    var body: some Widget {
        AtriumWidget(kind: .continueWatching)
        AtriumWidget(kind: .discover)
        AtriumWidget(kind: .library)
        AtriumWidget(kind: .nowPlaying)
    }
}
