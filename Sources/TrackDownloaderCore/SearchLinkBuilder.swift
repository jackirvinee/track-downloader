import Foundation

public enum SearchLinkBuilder {
    public static func terms(from fileURL: URL) -> String {
        var value = fileURL.deletingPathExtension().lastPathComponent
        value = value.replacingOccurrences(
            of: #"\s*\[[^\]]+\]\s*$"#,
            with: "",
            options: .regularExpression
        )
        value = value.replacingOccurrences(of: " - ", with: " ")
        value = value.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func urls(for terms: String) -> [URL] {
        let basic = encoded(terms)
        let lossless = encoded("\(terms) lossless wav flac aiff download")
        return [
            URL(string: "https://bandcamp.com/search?q=\(basic)"),
            URL(string: "https://www.beatport.com/search?q=\(basic)"),
            URL(string: "https://soundcloud.com/search?q=\(basic)"),
            URL(string: "https://www.google.com/search?q=\(lossless)")
        ].compactMap { $0 }
    }

    private static func encoded(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
