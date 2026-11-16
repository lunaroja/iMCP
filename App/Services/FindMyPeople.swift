import AppKit
import ScreenCaptureKit
import Vision

final class FindMyPeopleService: Service {
    static let shared = FindMyPeopleService()
    static let toolName = "find_my_person"
    static let enabledKey = "findMyPeopleEnabled"
    static let personKey = "findMyPeopleApprovedName"
    static let placesKey = "findMyPeopleApprovedPlaces"

    @MainActor private static var lookupInProgress = false

    var tools: [Tool] {
        Tool(
            name: Self.toolName,
            description:
                "Read one locally approved person's shared Find My location. Open Find My on People with the row visible and confirm the preview on this Mac.",
            inputSchema: .object(
                properties: ["person": .string(description: "Exact approved name as shown in Find My.")],
                required: ["person"],
                additionalProperties: false
            ),
            annotations: .init(title: "Look Up a Find My Person", readOnlyHint: true, openWorldHint: false)
        ) { arguments in
            guard arguments.count == 1, let person = arguments["person"]?.stringValue else {
                throw LookupError.notApproved
            }
            return try await Self.lookup(person: person)
        }
    }

    @MainActor
    private static func lookup(person: String) async throws -> [String: String] {
        let settings = UserDefaults.standard
        let approved = settings.string(forKey: personKey) ?? ""
        let configuredPlaces = settings.string(forKey: placesKey) ?? ""
        let normalized = FindMyPeopleRows.normalizedName(person)
        guard isEnabled(settings),
            person.utf8.count <= 256, !normalized.isEmpty,
            normalized == FindMyPeopleRows.normalizedName(approved)
        else { throw LookupError.notApproved }
        guard CGPreflightScreenCaptureAccess() else { throw LookupError.permission }
        guard !lookupInProgress, NSApp.modalWindow == nil else { throw LookupError.busy }
        lookupInProgress = true
        defer { lookupInProgress = false }

        let places = Set(
            configuredPlaces.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && $0.count <= 80 }
        )
        let preview = try await readWindow(person: approved, places: places)
        try Task.checkCancellation()
        guard isEnabled(settings),
            settings.string(forKey: personKey) == approved,
            (settings.string(forKey: placesKey) ?? "") == configuredPlaces
        else { throw LookupError.notApproved }
        guard confirm(preview: preview) else { throw LookupError.cancelled }
        try Task.checkCancellation()
        guard isEnabled(settings),
            settings.string(forKey: personKey) == approved,
            (settings.string(forKey: placesKey) ?? "") == configuredPlaces,
            CGPreflightScreenCaptureAccess()
        else { throw LookupError.notApproved }
        return preview.result
    }

    private static func isEnabled(_ settings: UserDefaults) -> Bool {
        guard settings.bool(forKey: enabledKey),
            settings.object(forKey: "isEnabled") as? Bool ?? true
        else { return false }
        let disabled = settings.data(forKey: "disabledTools") ?? Data()
        let tools = (try? JSONDecoder().decode(Set<String>.self, from: disabled)) ?? []
        return !tools.contains(toolName)
    }

    private struct Preview: Sendable {
        let tabs: CGImage
        let row: CGImage
        let result: [String: String]
    }

    private static func readWindow(person: String, places: Set<String>) async throws -> Preview {
        let image: CGImage
        let windowSize: CGSize
        do {
            let content = try await SCShareableContent.getAvailableContent()
            let windows = content.windows.filter {
                $0.owningApplication?.bundleIdentifier == "com.apple.findmy"
                    && $0.isOnScreen && $0.windowLayer == 0
            }
            guard windows.count == 1, let window = windows.first,
                (320 ... 8192).contains(window.frame.width),
                (220 ... 8192).contains(window.frame.height)
            else { throw LookupError.window }
            windowSize = window.frame.size
            let configuration = SCStreamConfiguration()
            let scale = min(2, 3072 / windowSize.width, 2304 / windowSize.height)
            configuration.width = Int(windowSize.width * scale)
            configuration.height = Int(windowSize.height * scale)
            configuration.capturesAudio = false
            configuration.showsCursor = false
            image = try await CaptureService.captureImage(
                filter: SCContentFilter(desktopIndependentWindow: window),
                configuration: configuration
            )
        } catch let error as LookupError {
            throw error
        } catch {
            throw LookupError.window
        }

        try Task.checkCancellation()
        let request = VNRecognizeTextRequest()
        request.recognitionLanguages = ["en-US"]
        request.recognitionLevel = .accurate
        do {
            try VNImageRequestHandler(cgImage: image).perform([request])
        } catch {
            throw LookupError.row
        }
        let lines = (request.results ?? []).flatMap { observation -> [FindMyPeopleRows.Line] in
            guard let candidate = observation.topCandidates(1).first else { return [] }
            let text = candidate.string
            let pills = text.split(whereSeparator: \.isWhitespace)
            if pills == ["People", "Devices", "Items"] || pills == ["Me", "People", "Devices", "Items"] {
                return pills.compactMap { pill in
                    guard let range = text.range(of: pill),
                        let box = try? candidate.boundingBox(for: range)?.boundingBox
                    else { return nil }
                    return line(String(pill), box: box, size: windowSize, confidence: candidate.confidence)
                }
            }
            return [line(text, box: observation.boundingBox, size: windowSize, confidence: candidate.confidence)]
        }
        guard let match = FindMyPeopleRows.match(lines: lines, person: person, places: places) else {
            throw LookupError.row
        }

        let scale = CGAffineTransform(
            scaleX: CGFloat(image.width) / windowSize.width,
            y: CGFloat(image.height) / windowSize.height
        )
        let tabRect = match.tabs.insetBy(dx: -12, dy: -8).applying(scale).integral
        let rowRect = match.name.bounds.union(match.detail.bounds)
            .insetBy(dx: -5, dy: -3).applying(scale).integral
        guard let tabs = image.cropping(to: tabRect), let row = image.cropping(to: rowRect) else {
            throw LookupError.row
        }
        return Preview(tabs: tabs, row: row, result: match.result)
    }

    private static func line(
        _ text: String,
        box: CGRect,
        size: CGSize,
        confidence: Float
    ) -> FindMyPeopleRows.Line {
        .init(
            text: text,
            bounds: CGRect(
                x: box.minX * size.width,
                y: (1 - box.maxY) * size.height,
                width: box.width * size.width,
                height: box.height * size.height
            ),
            confidence: confidence
        )
    }

    @MainActor
    private static func confirm(preview: Preview) -> Bool {
        guard NSApp.modalWindow == nil else { return false }
        let alert = NSAlert()
        alert.messageText = "Share this Find My lookup with the requesting client?"
        alert.informativeText =
            "Verify that People is selected and this is the approved person's row. The client may keep the answer."
        let cancel = alert.addButton(withTitle: "Cancel")
        let share = alert.addButton(withTitle: "Share Result")
        cancel.keyEquivalent = "\u{1b}"
        share.keyEquivalent = ""

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        for image in [preview.tabs, preview.row] {
            let view = NSImageView(image: NSImage(cgImage: image, size: .zero))
            view.imageScaling = .scaleProportionallyDown
            view.widthAnchor.constraint(equalToConstant: min(420, CGFloat(image.width) / 2)).isActive = true
            view.heightAnchor.constraint(equalToConstant: CGFloat(image.height) / 2).isActive = true
            stack.addArrangedSubview(view)
        }
        let summary = [preview.result["place"], preview.result["lastSeen"]].compactMap { $0 }.joined(separator: " · ")
        stack.addArrangedSubview(
            NSTextField(labelWithString: summary.isEmpty ? "No location will be shared." : summary)
        )
        stack.frame.size = stack.fittingSize
        alert.accessoryView = stack

        NSApp.activate()
        let deadline = Date.now.addingTimeInterval(30)
        let timer = Timer(timeInterval: 1, repeats: true) { [weak alert] _ in
            MainActor.assumeIsolated {
                if Date.now >= deadline, let alert, NSApp.modalWindow === alert.window {
                    NSApp.abortModal()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .modalPanel)
        defer { timer.invalidate() }
        return alert.runModal() == .alertSecondButtonReturn && Date.now < deadline
    }

    private enum LookupError: String, LocalizedError {
        case notApproved, permission, busy, window, row, cancelled

        var errorDescription: String? {
            switch self {
            case .notApproved: "Find My is disabled or the requested person is not approved."
            case .permission: "iMCP needs Screen Recording approval for Find My."
            case .busy: "Another lookup or confirmation is already open."
            case .window: "Open one Find My window in an unlocked desktop session."
            case .row: "Open People and make the approved row fully visible. iMCP could not read it reliably."
            case .cancelled: "Find My lookup was not confirmed."
            }
        }
    }
}
