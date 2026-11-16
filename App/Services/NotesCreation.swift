import AppKit
import JSONSchema

enum NotesCreation {
    static let noteToolName = "notes_create"
    static let folderToolName = "notes_folders_create"
    static let toolNames = [noteToolName, folderToolName]

    static func enabledKey(for toolName: String) -> String {
        "notesCreation.\(toolName)"
    }

    private static let accountSchema = JSONSchema.string(description: "Exact Notes account name from notes_folders.")
    private static let pathSchema = JSONSchema.array(
        description: "Exact folder names in order from the account root, including the destination folder.",
        items: .string()
    )

    static let noteTool = Tool(
        name: noteToolName,
        description:
            "Create a new plain-text note in an explicit Notes account and folder. Notes may sync it to other devices.",
        inputSchema: .object(
            properties: [
                "account": accountSchema,
                "folderPath": pathSchema,
                "title": .string(description: "Title of the new note, on one line."),
                "text": .string(description: "Plain text of the new note, up to 64 KiB of UTF-8."),
            ],
            required: ["account", "folderPath", "title", "text"],
            additionalProperties: false
        ),
        annotations: .init(
            title: "Create Note",
            readOnlyHint: false,
            destructiveHint: false,
            idempotentHint: false,
            openWorldHint: true
        )
    ) { arguments in
        guard arguments.count == 4,
            let account = arguments["account"]?.stringValue,
            let title = arguments["title"]?.stringValue,
            let text = arguments["text"]?.stringValue,
            validName(account), validName(title),
            text.utf8.count <= 65_536, !text.utf8.contains(0)
        else { throw CreationError.invalidInput }
        let path = try folderPath(arguments["folderPath"])
        guard !path.isEmpty else { throw CreationError.invalidInput }

        return try await create(
            noteToolName,
            account: account,
            path: path,
            name: title,
            body: noteBody(title: title, text: text)
        )
    }

    static let folderTool = Tool(
        name: folderToolName,
        description: "Create a new folder in an explicit Notes account. Supply parentPath for a nested folder.",
        inputSchema: .object(
            properties: [
                "account": accountSchema,
                "parentPath": pathSchema,
                "name": .string(description: "Name of the new folder, on one line."),
            ],
            required: ["account", "name"],
            additionalProperties: false
        ),
        annotations: .init(
            title: "Create Note Folder",
            readOnlyHint: false,
            destructiveHint: false,
            idempotentHint: false,
            openWorldHint: true
        )
    ) { arguments in
        guard arguments.keys.allSatisfy({ ["account", "parentPath", "name"].contains($0) }),
            let account = arguments["account"]?.stringValue,
            let name = arguments["name"]?.stringValue,
            validName(account), validName(name)
        else { throw CreationError.invalidInput }
        let path = try arguments["parentPath"].map { try folderPath($0) } ?? []

        return try await create(folderToolName, account: account, path: path, name: name, body: "")
    }

    private static func validName(_ name: String) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && name.utf8.count <= 1024
            && name.rangeOfCharacter(from: .newlines) == nil && !name.utf8.contains(0)
    }

    private static func folderPath(_ value: Value?) throws -> [String] {
        guard case .array(let components) = value, components.count <= 16 else {
            throw CreationError.invalidInput
        }
        return try components.map {
            guard let name = $0.stringValue, validName(name) else { throw CreationError.invalidInput }
            return name
        }
    }

    static func noteBody(title: String, text: String) -> String {
        func escape(_ value: String) -> String {
            value.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }

        let body = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        return "<div>\(escape(title))</div><div>\(escape(body).replacingOccurrences(of: "\n", with: "<br>"))</div>"
    }

    private static func create(
        _ toolName: String,
        account: String,
        path: [String],
        name: String,
        body: String
    ) async throws -> [String: String] {
        try requireEnabled(toolName)
        let result: NSAppleEventDescriptor
        do {
            result = try await NSAppleScript.execute(
                script,
                handler: "createInNotes",
                arguments: [toolName, account, path.joined(separator: "\n"), name, body],
                beforeExecution: {
                    try requireEnabled(toolName)
                }
            )
        } catch let error as NSAppleScript.ExecutionError {
            if error.number == Int(errAEEventNotPermitted) { throw CreationError.permission }
            // Do not echo an AppleScript error that may include private Notes data.
            throw CreationError.uncertain
        }

        switch result.atIndex(1)?.stringValue {
        case "account": throw CreationError.account
        case "folder": throw CreationError.folder
        case "shared": throw CreationError.shared
        case "exists": throw CreationError.exists
        case "created":
            guard let automationID = result.atIndex(2)?.stringValue, !automationID.isEmpty else {
                throw CreationError.uncertain
            }
            return ["status": "created", "automationId": automationID]
        default: throw CreationError.uncertain
        }
    }

    private static func requireEnabled(_ toolName: String) throws {
        let settings = UserDefaults.standard
        guard settings.bool(forKey: enabledKey(for: toolName)),
            settings.bool(forKey: "notesEnabled"),
            (settings.object(forKey: "isEnabled") as? Bool ?? true)
        else { throw CreationError.disabled }
    }

    static let script = """
        on createInNotes(toolName, accountName, folderPath, itemName, noteBody)
            set AppleScript's text item delimiters to linefeed
            set pathComponents to text items of folderPath
            set AppleScript's text item delimiters to ""
            if folderPath is "" then set pathComponents to {}

            with timeout of 15 seconds
                tell application id "com.apple.Notes"
                    set accountMatches to {}
                    repeat with candidate in (get accounts)
                        if my exactName(name of candidate, accountName) then set end of accountMatches to contents of candidate
                    end repeat
                    if (count accountMatches) is not 1 then return {"account"}
                    set destination to item 1 of accountMatches

                    repeat with pathName in pathComponents
                        set folderMatches to my matchingFolders(destination, contents of pathName)
                        if (count folderMatches) is not 1 then return {"folder"}
                        set destination to item 1 of folderMatches
                        if shared of destination then return {"shared"}
                    end repeat

                    if toolName is "notes_create" then
                        if (count pathComponents) is 0 then return {"folder"}
                        set newItem to make new note at destination with properties {body:noteBody}
                    else if toolName is "notes_folders_create" then
                        if (count my matchingFolders(destination, itemName)) is not 0 then return {"exists"}
                        set newItem to make new folder at destination with properties {name:itemName}
                    else
                        return {}
                    end if
                    return {"created", id of newItem}
                end tell
            end timeout
        end createInNotes

        on matchingFolders(parentObject, wantedName)
            tell application id "com.apple.Notes"
                set parentID to id of parentObject
                set folderMatches to {}
                repeat with candidate in (get folders of parentObject)
                    if my exactName(name of candidate, wantedName) then
                        if id of container of candidate is parentID then set end of folderMatches to contents of candidate
                    end if
                end repeat
                return folderMatches
            end tell
        end matchingFolders

        on exactName(actualName, wantedName)
            considering case, diacriticals, hyphens, punctuation and white space
                return actualName is wantedName
            end considering
        end exactName
        """

    private enum CreationError: LocalizedError, CustomStringConvertible {
        case invalidInput, disabled, permission, account, folder, shared, exists, uncertain

        var description: String { localizedDescription }

        var errorDescription: String? {
            switch self {
            case .invalidInput: "Specify a Notes account and valid names, folder path, and text."
            case .disabled: "This Notes creation tool is off in iMCP settings."
            case .permission: "Allow iMCP to control Notes in Privacy & Security → Automation."
            case .account: "The exact Notes account name did not resolve to one account."
            case .folder: "The exact folder path did not resolve to one folder in that account."
            case .shared: "This tool only creates items in unshared Notes folders."
            case .exists: "A folder with that exact name already exists at the destination."
            case .uncertain: "Notes did not confirm creation. Check the destination before retrying."
            }
        }
    }
}
