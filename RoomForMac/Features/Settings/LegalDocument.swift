import Foundation

/// The legal texts Settings → About lists. `LICENSE`, `NOTICE` and `CREDITS.md` are copied from
/// the repository root into Contents/Resources (project.yml). Mole's licence ships inside the
/// engine, at Contents/Resources/engine/LICENSE (Ruling 13); Sparkle's ships from
/// ThirdParty/Sparkle/LICENSE, as Contents/Resources/ThirdParty/Sparkle/LICENSE.
enum LegalDocument: String, CaseIterable, Identifiable, Sendable {
    case license, notice, credits, moleLicense, sparkleLicense

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .license: "RoomForMac License"
        case .notice: "Notice"
        case .credits: "Credits"
        case .moleLicense: "Engine License (Mole)"
        case .sparkleLicense: "Updates License (Sparkle)"
        }
    }

    /// The file inside `bundle`, or nil when the bundle does not have it.
    func url(in bundle: Bundle) -> URL? {
        switch self {
        case .license: bundle.url(forResource: "LICENSE", withExtension: nil)
        case .notice: bundle.url(forResource: "NOTICE", withExtension: nil)
        case .credits: bundle.url(forResource: "CREDITS", withExtension: "md")
        case .moleLicense: bundle.url(forResource: "LICENSE", withExtension: nil, subdirectory: "engine")
        case .sparkleLicense: bundle.url(forResource: "LICENSE", withExtension: nil, subdirectory: "ThirdParty/Sparkle")
        }
    }

    /// The document's UTF-8 text. Nil when the file is missing, unreadable or blank, so the
    /// viewer can say it is missing instead of showing an empty page.
    func text(in bundle: Bundle) -> String? {
        guard let url = url(in: bundle),
              let text = try? String(contentsOf: url, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }
        return text
    }

    /// The body of the `## <heading>` section of a Markdown text: the lines up to the next
    /// heading of level 1 or 2, trimmed. Nil when the section is missing or empty.
    /// About reads the photo credits from `CREDITS.md` this way.
    static func section(_ heading: String, in markdown: String) -> String? {
        var body: [Substring] = []
        var inSection = false
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("# ") || line.hasPrefix("## ") {
                if inSection {
                    break
                }
                inSection = line == "## \(heading)"
                continue
            }
            if inSection {
                body.append(line)
            }
        }
        let text = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
