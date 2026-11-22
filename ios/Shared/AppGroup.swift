import Foundation

/// The App Group the app and its widgets share. AltStore (and Sideloadly) rename App Groups when they
/// sign with a free Apple ID: "group.app.atrium.widgets" becomes "group.app.atrium.widgets.<TEAM ID>".
/// The real name is read from the provisioning profile the signing tool put in this bundle (the app's
/// or the widget's own), so both sides always open the same shared storage.
enum AppGroup {
    static let base = "group.app.atrium.widgets"
    static let id: String = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(from: data.subdata(in: start.lowerBound..<end.upperBound), format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any],
              let groups = entitlements["com.apple.security.application-groups"] as? [String],
              let group = groups.first(where: { $0 == base || $0.hasPrefix(base + ".") })
        else { return base }
        return group
    }()
}
