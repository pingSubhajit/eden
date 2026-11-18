import Foundation

// Shield's rules for YouTube's ads (Shield.swift): requests its player makes
// for an ad, blocked like any tracker. The Mac app's YouTubeAds adds the
// scripts that skip what still plays.

public enum YouTubeRules {
    /// Shield's rules for YouTube: where its player reports ads and fetches
    /// them, never the video. Each path is anchored on YouTube's own hosts;
    /// Google's ad hosts that are third parties on YouTube are already in
    /// Shield's list (doubleclick.net, googlesyndication.com…).
    public static let paths = [
        "/api/stats/ads", "/pagead/", "/ptracking", "/get_midroll_info",
        "/youtubei/v1/player/ad_break", "/pcs/activeview",
    ]

    public static func filter(path: String) -> String {
        "^https?://([^/]+\\.)?youtube\\.com" + path.replacingOccurrences(of: ".", with: "\\.")
    }

    public static var rules: [[String: Any]] {
        var rules: [[String: Any]] = paths.map { path in
            ["trigger": ["url-filter": filter(path: path)], "action": ["type": "block"]]
        }
        // The player's quality reports for an ad, never the video's own.
        rules.append([
            "trigger": ["url-filter": "^https?://([^/]+\\.)?youtube\\.com/api/stats/qoe\\?.*adformat="],
            "action": ["type": "block"],
        ])
        // Google's own ad paths and the video ads SDK, only from YouTube's
        // pages: other sites' players may need the SDK to play at all.
        let youtube = ["*youtube.com", "*youtube-nocookie.com"]
        for filter in ["^https?://([^/]+\\.)?google\\.com/pagead/", "^https?://imasdk\\.googleapis\\.com/"] {
            rules.append([
                "trigger": ["url-filter": filter, "if-domain": youtube],
                "action": ["type": "block"],
            ])
        }
        return rules
    }
}
