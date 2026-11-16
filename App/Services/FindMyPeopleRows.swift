import Foundation

enum FindMyPeopleRows {
    private static let coarseLabels: Set<String> = ["Home", "Work", "School", "Nearby"]

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

    static func match(lines: [Line], person: String, places: Set<String>) -> Match? {
        let trustedLines = lines.filter { $0.confidence >= 0.8 }
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
        let details = sidebar.filter {
            abs($0.bounds.minX - name.bounds.minX) <= 6
                && $0.bounds.minY >= name.bounds.maxY - 2
                && $0.bounds.minY <= name.bounds.maxY + 9
        }
        guard details.count == 1, let detail = details.first, detail.confidence >= 0.8,
            let result = result(for: detail.text, places: places)
        else { return nil }
        return Match(name: name, detail: detail, tabs: tabs, result: result)
    }

    private static func result(for text: String, places: Set<String>) -> [String: String]? {
        if ["No location found", "Location not available"].contains(text) {
            return ["status": "unavailable"]
        }
        let fields = text.split(separator: "•", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard fields.count == 2, !fields[0].isEmpty else { return nil }
        let age = fields[1]
        let agePattern =
            #"\A[0-9]{1,4} (?:sec\.?|secs\.?|seconds?|min\.?|mins\.?|minutes?|hr\.?|hrs\.?|hours?|days?|weeks?) ago\z"#
        guard
            ["Now", "Live"].contains(age)
                || age.range(of: agePattern, options: .regularExpression) != nil
        else { return nil }

        let location = fields[0]
        if coarseLabels.contains(location), places.contains(location) {
            return ["status": "reported", "place": location, "lastSeen": age]
        }
        return ["status": "place_not_approved", "lastSeen": age]
    }
}
