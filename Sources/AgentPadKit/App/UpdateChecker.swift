import Foundation

/// Polls GitHub's `releases/latest` endpoint and compares its `tag_name`
/// against `AgentPadApp.displayVersion`. Manual-only for now (Help → Check
/// for Updates…); no startup poll, no Settings toggle.
enum UpdateChecker {
    enum Outcome {
        case upToDate(current: String)
        case newer(latest: String, url: URL, releaseNotes: String)
        case failed(String)
    }

    private struct LatestRelease: Decodable {
        let tagName: String
        let htmlUrl: String
        let body: String?
        let assets: [Asset]?
        struct Asset: Decodable {
            let name: String
            let browserDownloadUrl: String
            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadUrl = "browser_download_url"
            }
        }
        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlUrl = "html_url"
            case body
            case assets
        }
    }

    static func check(currentVersion: String = AgentPadApp.displayVersion) async -> Outcome {
        var request = URLRequest(url: AgentPadApp.releasesAPIURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failed("No response from GitHub.")
            }
            guard http.statusCode == 200 else {
                return .failed("GitHub returned HTTP \(http.statusCode).")
            }
            let release = try JSONDecoder().decode(LatestRelease.self, from: data)
            // Prefer the attached .dmg asset so clicking "update" triggers an
            // immediate browser download instead of detouring through the
            // release page (one extra click, plus the user has to find the
            // DMG in the assets list). Fall back to the release page URL if
            // a release ships without a DMG (e.g. source-only).
            let dmgAsset = release.assets?.first { $0.name.lowercased().hasSuffix(".dmg") }
            let urlString = dmgAsset?.browserDownloadUrl ?? release.htmlUrl
            guard let url = URL(string: urlString) else {
                return .failed("Couldn't parse release URL.")
            }
            let latest = Version.stripLeadingV(release.tagName)
            if Version.compare(latest, currentVersion) == .orderedDescending {
                let notes = release.body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return .newer(latest: latest, url: url, releaseNotes: notes)
            }
            return .upToDate(current: currentVersion)
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
