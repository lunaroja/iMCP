import Foundation

enum FindMyPeopleRows {
    private static let coarseLabels: Set<String> = ["Home", "Work", "School", "Nearby"]

    private static let usRegions: Set<String> = [
        "AL", "AK", "AZ", "AR", "CA", "CO", "CT", "DE", "DC", "FL", "GA", "HI", "ID",
        "IL", "IN", "IA", "KS", "KY", "LA", "ME", "MD", "MA", "MI", "MN", "MS", "MO",
        "MT", "NE", "NV", "NH", "NJ", "NM", "NY", "NC", "ND", "OH", "OK", "OR", "PA",
        "RI", "SC", "SD", "TN", "TX", "UT", "VT", "VA", "WA", "WV", "WI", "WY", "PR",
    ]
    private static let streetWords: Set<String> = [
        "alley", "ave", "avenue", "boulevard", "blvd", "court", "ct", "drive", "dr",
        "highway", "hwy", "lane", "ln", "parkway", "pkwy", "rd", "road", "st", "street", "way",
    ]

    // Vision's normalized bounds are converted to window points with a top-left origin.
    struct Line {
        let text: String
        let bounds: CGRect
        let confidence: Float
    }

    struct Match {
        let name: Line
        let detail: Line
        let tabs: CGRect
        let result: [String: String]
    }

    static func normalizedName(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
            .lowercased()
    }

    static func match(lines: [Line], person: String) -> Match? {
        let trustedLines = lines.filter { $0.confidence >= 0.8 }.sorted { $0.bounds.minY < $1.bounds.minY }
        guard
            let people = trustedLines.first(where: { $0.text == "People" && $0.bounds.midY < 180 }),
            let devices = trustedLines.first(where: {
                $0.text == "Devices" && $0.bounds.minX > people.bounds.maxX
                    && abs($0.bounds.midY - people.bounds.midY) < 12
            }),
            let items = trustedLines.first(where: {
                $0.text == "Items" && $0.bounds.minX > devices.bounds.maxX
                    && abs($0.bounds.midY - people.bounds.midY) < 12
            })
        else { return nil }
        let tabs = people.bounds.union(devices.bounds).union(items.bounds)
        let right = min(tabs.maxX + 40, 380)
        let sidebar = lines.filter {
            $0.bounds.minX >= 35 && $0.bounds.maxX < right && $0.bounds.minY > tabs.maxY + 6
        }
        let matches = sidebar.filter { normalizedName($0.text) == normalizedName(person) }
        guard matches.count == 1, let name = matches.first, name.confidence >= 0.8 else { return nil }
        func nextLine(after line: Line) -> Line? {
            let candidates = sidebar.filter {
                abs($0.bounds.minX - name.bounds.minX) <= 6
                    && $0.bounds.minY >= line.bounds.maxY - 2
                    && $0.bounds.minY <= line.bounds.maxY + 9
            }
            guard candidates.count == 1, let candidate = candidates.first, candidate.confidence >= 0.8 else {
                return nil
            }
            return candidate
        }
        guard let detail = nextLine(after: name) else { return nil }
        if let result = result(for: detail.text) {
            return Match(name: name, detail: detail, tabs: tabs, result: result)
        }

        // In the selected People row, Find My displays Nearby, the precise
        // place, and the freshness as separate lines. Return only the badge.
        guard detail.text == "Nearby", let address = nextLine(after: detail),
            !address.text.isEmpty, let age = nextLine(after: address),
            let result = result(place: "Nearby", age: age.text)
        else { return nil }
        return Match(name: name, detail: age, tabs: tabs, result: result)
    }

    private static func result(for text: String) -> [String: String]? {
        switch text.trimmingCharacters(in: .whitespaces).lowercased() {
        case "paused":
            return ["status": "paused"]
        case "no location found", "location not available":
            return ["status": "unavailable"]
        default:
            break
        }
        let fields = text.split(omittingEmptySubsequences: false) { $0 == "•" || $0 == "·" }
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard fields.count == 2, !fields[0].isEmpty else { return nil }
        return result(place: fields[0], age: fields[1])
    }

    private static func result(place: String, age: String) -> [String: String]? {
        // Find My can keep the previous place on the row while sharing is paused.
        if age == "Paused" {
            return ["status": "paused"]
        }
        let agePattern =
            #"\A[0-9]{1,4} (?:sec\.?|secs\.?|seconds?|min\.?|mins\.?|minutes?|hr\.?|hrs\.?|hours?|days?|weeks?) ago\z"#
        guard
            ["Now", "Live"].contains(age)
                || age.range(of: agePattern, options: .regularExpression) != nil
        else { return nil }

        if coarseLabels.contains(place) || isCityAndRegion(place) {
            return ["status": "reported", "place": place, "lastSeen": age]
        }
        return ["status": "place_withheld", "lastSeen": age]
    }

    private static func isCityAndRegion(_ place: String) -> Bool {
        let parts = place.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, usRegions.contains(parts[1]),
            parts[0].range(of: #"\A\p{L}[\p{L}\p{M} .’'-]{0,59}\z"#, options: .regularExpression) != nil
        else { return false }
        let words = parts[0].lowercased().split { !$0.isLetter }
        return words.allSatisfy { !streetWords.contains(String($0)) }
    }
}
