import AppKit

enum MessageSend {
    static let toolName = "messages_send"
    static let enabledKey = "messageSendEnabled"

    @MainActor private static var inProgress = false

    typealias UnattendedAuthorization = @MainActor @Sendable () -> Bool

    static let tool = makeTool()

    static func makeTool(allowsUnattended: @escaping UnattendedAuthorization = { false }) -> Tool {
        Tool(
            name: toolName,
            description:
                "Send one text-only iMessage to an existing one-to-one conversation. Requires confirmation on this Mac unless this client has permission to send without it.",
            inputSchema: .object(
                properties: [
                    "chatId": .string(
                        description: "An existing direct iMessage conversation @id from messages_fetch."
                    ),
                    "text": .string(description: "Exact text to send, up to 3,500 characters."),
                ],
                required: ["chatId", "text"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Send iMessage",
                readOnlyHint: false,
                destructiveHint: true,
                idempotentHint: false,
                openWorldHint: true
            )
        ) { arguments in
            guard arguments.count == 2,
                let chatID = arguments["chatId"]?.stringValue,
                let text = arguments["text"]?.stringValue
            else { throw SendError.invalidInput }
            return try await send(chatID: chatID, text: text, allowsUnattended: allowsUnattended)
        }
    }

    @MainActor
    private static func send(
        chatID: String,
        text: String,
        allowsUnattended: @escaping UnattendedAuthorization
    ) async throws -> [String: String] {
        try Task.checkCancellation()
        // Messages can use either prefix for a direct chat. The prefix alone
        // does not establish transport; the script checks the selected account.
        let directPrefixes = ["iMessage;-;", "any;-;"]
        guard chatID.utf8.count <= 250,
            let prefix = directPrefixes.first(where: { chatID.hasPrefix($0) })
        else {
            throw SendError.invalidInput
        }
        let recipient = String(chatID.dropFirst(prefix.count))
        let phone = #"\A\+[1-9][0-9]{1,14}\z"#
        let email = #"\A[A-Za-z0-9_+%-]+(?:\.[A-Za-z0-9_+%-]+)*@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+\z"#
        guard
            recipient.range(of: phone, options: .regularExpression) != nil
                || recipient.range(of: email, options: .regularExpression) != nil,
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            text.count <= 3_500, text.utf8.count <= 14_000,
            !text.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0) && $0.value != 10
                    || (0x202A ... 0x202E).contains($0.value)
                    || (0x2066 ... 0x2069).contains($0.value)
            })
        else { throw SendError.invalidInput }

        guard enabled else { throw SendError.disabled }
        guard !inProgress else { throw SendError.busy }
        inProgress = true
        defer { inProgress = false }

        let unattended = allowsUnattended()
        if !unattended {
            guard confirm(recipient: recipient, text: text) else { throw SendError.cancelled }
        }
        try Task.checkCancellation()
        guard enabled else { throw SendError.disabled }

        let result: NSAppleEventDescriptor
        do {
            result = try await NSAppleScript.execute(
                script,
                handler: "sendConfirmedMessage",
                arguments: [chatID, text],
                beforeExecution: {
                    guard enabled else { throw SendError.disabled }
                    if unattended {
                        // This runs on the script queue. Consult the live grant after
                        // compilation, just before dispatch. The main actor awaits the script.
                        let stillAllowed = DispatchQueue.main.sync { allowsUnattended() }
                        guard stillAllowed else { throw SendError.authorizationChanged }
                    }
                }
            )
        } catch let error as NSAppleScript.ExecutionError {
            if error.number == Int(errAEEventNotPermitted) { throw SendError.permission }
            throw SendError.uncertain
        }
        guard result.booleanValue else { throw SendError.unavailableChat }
        return [
            "status": "accepted",
            "description": "Messages accepted the send request. Delivery is unverified.",
        ]
    }

    private static var enabled: Bool {
        let settings = UserDefaults.standard
        return settings.bool(forKey: enabledKey) && settings.bool(forKey: "messagesEnabled")
            && (settings.object(forKey: "isEnabled") as? Bool ?? true)
    }

    @MainActor
    private static func confirm(recipient: String, text: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Send iMessage to \(recipient)?"
        alert.informativeText = "Review the message before sending."
        let cancel = alert.addButton(withTitle: "Cancel")
        let send = alert.addButton(withTitle: "Send")
        cancel.keyEquivalent = "\u{1b}"
        send.keyEquivalent = ""

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 155))
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        let preview = NSTextView(frame: scrollView.contentView.bounds)
        preview.isEditable = false
        preview.isVerticallyResizable = true
        preview.autoresizingMask = [.width]
        preview.textContainer?.widthTracksTextView = true
        preview.font = .systemFont(ofSize: NSFont.systemFontSize)
        preview.string = text
        scrollView.documentView = preview
        alert.accessoryView = scrollView

        NSApp.activate()
        let timeout = Timer(timeInterval: 60, repeats: false) { _ in
            MainActor.assumeIsolated { NSApp.abortModal() }
        }
        RunLoop.main.add(timeout, forMode: .modalPanel)
        defer { timeout.invalidate() }
        return alert.runModal() == .alertSecondButtonReturn
    }

    // All arguments arrive as Apple event descriptors, outside the script source.
    private static let script = """
        on sendConfirmedMessage(expectedID, messageText)
            with timeout of 15 seconds
                tell application id "com.apple.MobileSMS"
                    set matches to every chat whose id is expectedID
                    if (count matches) is not 1 then return false
                    set destination to item 1 of matches
                    considering case
                        if id of destination is not expectedID then return false
                    end considering
                    if service type of account of destination is not iMessage then return false
                    send messageText to destination
                end tell
            end timeout
            return true
        end sendConfirmedMessage
        """

    enum SendError: LocalizedError {
        case invalidInput, disabled, busy, cancelled, authorizationChanged, permission, unavailableChat, uncertain

        var errorDescription: String? {
            switch self {
            case .invalidInput: "Use an existing one-to-one iMessage chat ID and nonempty plain text."
            case .disabled: "iMessage sending is off in iMCP settings."
            case .busy: "An iMessage send is already awaiting confirmation or completion."
            case .cancelled: "The send was cancelled or its confirmation expired."
            case .authorizationChanged: "Permission to send without confirmation was removed before sending."
            case .permission: "Allow iMCP to control Messages in Privacy & Security → Automation."
            case .unavailableChat: "The exact iMessage conversation is unavailable."
            case .uncertain: "Messages did not confirm acceptance. Check the conversation before retrying."
            }
        }
    }
}
