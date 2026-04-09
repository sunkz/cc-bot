import Foundation

private let markdownPatterns: [(NSRegularExpression, String)] = {
    let specs: [(String, String)] = [
        (#"<[^>]+>"#, ""),
        (#"\[([^\]]+)\]\([^)]+\)"#, "$1"),
        (#"[*_`~>#]+"#, ""),
        (#"(?m)^\d+\.\s+"#, ""),
        (#"(?m)^[-+]\s+"#, ""),
        (#"(?m)^-{3,}$"#, ""),
    ]
    return specs.map { (try! NSRegularExpression(pattern: $0.0), $0.1) }
}()

func stripMarkdown(_ text: String) -> String {
    var result = text
    for (regex, template) in markdownPatterns {
        let range = NSRange(result.startIndex..<result.endIndex, in: result)
        result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: template)
    }
    return result
}
