import Foundation

func stripMarkdown(_ text: String) -> String {
    text
        .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        .replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
        .replacingOccurrences(of: #"[*_`~>#]+"#, with: "", options: .regularExpression)
        .replacingOccurrences(of: #"(?m)^\d+\.\s+"#, with: "", options: .regularExpression)
        .replacingOccurrences(of: #"(?m)^[-+]\s+"#, with: "", options: .regularExpression)
        .replacingOccurrences(of: #"(?m)^-{3,}$"#, with: "", options: .regularExpression)
}
