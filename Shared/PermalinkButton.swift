import SwiftUI

/// One external URL affordance for Activity rows and detail pages.
///
/// Same `link` glyph everywhere — menubar rows, iPhone lists, and the detail
/// chrome — so opening the source is one habit instead of per-service arrows
/// and "Open in …" link rows.
struct PermalinkButton: View {
    let url: URL?
    /// Spoken / hover label. Defaults to a neutral "Open".
    var help: String = HeadroomCopy.openPermalink

    var body: some View {
        if let url {
            Link(destination: url) {
                Image(systemName: "link")
            }
            #if os(macOS)
            .buttonStyle(.borderless)
            #endif
            .help(help)
            .accessibilityLabel(help)
        }
    }
}

enum Permalink {
    /// Parse a host-supplied URL, accepting bare hosts (`example.com/x`).
    static func url(from raw: String?) -> URL? {
        guard let raw, !raw.isEmpty else { return nil }
        return URL(string: raw.contains("://") ? raw : "https://\(raw)")
    }

    static func localServer(_ server: LocalServer) -> URL? {
        guard let port = server.port else { return nil }
        return URL(string: "http://127.0.0.1:\(port)")
    }

    static func activity(_ item: ActivityItem) -> URL? {
        url(from: item.inspectorURL ?? item.url)
    }
}

extension View {
    /// iPhone: inline title + trailing permalink. Mac popover: inset list;
    /// the Back bar owns the permalink there.
    func serviceDetailChrome(title: String, permalink: URL? = nil) -> some View {
        #if os(iOS)
        self
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    PermalinkButton(url: permalink)
                }
            }
        #else
        _ = title
        _ = permalink
        return self.listStyle(.inset)
        #endif
    }
}
