import WidgetKit
import SwiftUI

private let groupID = "group.app.atrium.widgets"

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
}

struct AtriumProvider: TimelineProvider {
    func placeholder(in context: Context) -> AtriumEntry { AtriumEntry(date: .now, data: AtriumSnapshot(), diagnostic: "PREVIEW") }
    func getSnapshot(in context: Context, completion: @escaping (AtriumEntry) -> Void) { completion(load()) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<AtriumEntry>) -> Void) {
        completion(Timeline(entries: [load()], policy: .after(Date().addingTimeInterval(1800))))
    }
    private func load() -> AtriumEntry {
        let groupContainer = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)
        let defaults = UserDefaults(suiteName: groupID)
        let data = defaults?.data(forKey: "snapshot")
        let snapshot = data.flatMap { try? JSONDecoder().decode(AtriumSnapshot.self, from: $0) } ?? AtriumSnapshot()
        let diagnostic: String
        if groupContainer == nil {
            diagnostic = "GROUP ENTITLEMENT MISSING"
        } else if defaults == nil {
            diagnostic = "GROUP UNAVAILABLE"
        } else if data == nil {
            diagnostic = "NO SHARED DATA"
        } else if data.flatMap({ try? JSONDecoder().decode(AtriumSnapshot.self, from: $0) }) == nil {
            diagnostic = "DECODE FAILED"
        } else {
            diagnostic = "DATA OK"
        }
        return AtriumEntry(date: .now, data: snapshot, diagnostic: diagnostic)
    }
}

enum AtriumKind: String, CaseIterable {
    case continueWatching = "atrium.continue"
    case discover = "atrium.discover"
    case library = "atrium.library"
    case nowPlaying = "atrium.now"
    var title: String {
        switch self {
        case .continueWatching: return "CONTINUE WATCHING"
        case .discover: return "DISCOVER"
        case .library: return "MY LIBRARY"
        case .nowPlaying: return "NOW PLAYING"
        }
    }
    var symbol: String {
        switch self {
        case .continueWatching: return "play.rectangle.fill"
        case .discover: return "sparkles.tv"
        case .library: return "bookmark.fill"
        case .nowPlaying: return "play.circle.fill"
        }
    }
}

struct AtriumWidgetView: View {
    let entry: AtriumEntry
    let kind: AtriumKind
    @Environment(\.widgetFamily) private var family

    private var items: [AtriumItem] {
        switch kind {
        case .continueWatching: return entry.data.continueWatching
        case .discover: return entry.data.discover
        case .library: return entry.data.library
        case .nowPlaying: return entry.data.nowPlaying.map { [$0] } ?? []
        }
    }
    private var capacity: Int {
        switch family {
        case .systemSmall: return 1
        case .systemMedium: return 2
        default: return 4
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: kind.symbol).foregroundStyle(Color(red: 0.25, green: 0.88, blue: 0.82))
                Text(kind.title).font(.system(size: 11, weight: .bold, design: .rounded)).tracking(1)
                Spacer(minLength: 0)
                Text("ATRIUM").font(.system(size: 9, weight: .semibold)).foregroundStyle(.gray)
            }
            if items.isEmpty {
                Spacer()
                Image(systemName: kind.symbol).font(.system(size: 30)).foregroundStyle(.gray)
                Text(emptyMessage).font(.system(size: 12)).foregroundStyle(.gray).lineLimit(3)
                Text(entry.diagnostic).font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundStyle(.orange).lineLimit(1)
                Spacer()
            } else {
                ForEach(Array(items.prefix(capacity))) { item in
                    Link(destination: URL(string: item.url ?? "atrium://home") ?? URL(string: "atrium://home")!) {
                        HStack(spacing: 10) {
                            RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.12))
                                .frame(width: 36, height: 45)
                                .overlay(Image(systemName: "film").font(.system(size: 16)).foregroundStyle(.gray))
                            VStack(alignment: .leading, spacing: 5) {
                                Text(item.title).font(.system(size: 12, weight: .semibold)).lineLimit(2)
                                if let subtitle = item.subtitle {
                                    Text(subtitle).font(.system(size: 10)).foregroundStyle(.gray).lineLimit(1)
                                }
                                if let progress = item.progress {
                                    ProgressView(value: min(1, max(0, progress))).tint(.red)
                                }
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.gray)
                        }
                    }
                    .foregroundStyle(.white)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(.white)
        .containerBackground(for: .widget) {
            Color(red: 0.075, green: 0.086, blue: 0.12)
        }
        .widgetURL(URL(string: "atrium://home"))
    }

    private var emptyMessage: String {
        switch kind {
        case .continueWatching: return "Your recently watched titles will appear here."
        case .discover: return "Open Atrium to discover your next watch."
        case .library: return "Your saved titles will appear here."
        case .nowPlaying: return "Nothing playing right now."
        }
    }
}

struct AtriumWidget: Widget {
    let kind: AtriumKind
    init() { kind = .continueWatching }
    init(kind: AtriumKind) { self.kind = kind }
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind.rawValue, provider: AtriumProvider()) { entry in
            AtriumWidgetView(entry: entry, kind: kind)
        }
        .configurationDisplayName(kind.title.capitalized)
        .description("Your Atrium entertainment, at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
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
