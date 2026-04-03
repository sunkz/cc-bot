import Foundation

func stripMarkdown(_ text: String) -> String {
    text
        .replacingOccurrences(of: #"[*_`~>#]+"#, with: "", options: .regularExpression)
        .replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
}
