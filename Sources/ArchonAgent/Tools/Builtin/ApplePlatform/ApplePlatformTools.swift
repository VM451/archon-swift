import Foundation

/// Pre-built Apple Calendar Tool for listing events, creating entries, and finding free meeting slots.
public struct CalendarTool: Tool {
    public var definition: ToolDefinition {
        ToolDefinition(
            name: "calendar",
            description: "Accesses Apple Calendar to list events, create new appointments, or check free scheduling slots.",
            parametersJSONSchema: [
                "type": AnySendable("object"),
                "properties": AnySendable([
                    "action": AnySendable([
                        "type": AnySendable("string"),
                        "description": AnySendable("Action: 'list', 'create', or 'findFreeSlots'")
                    ]),
                    "title": AnySendable([
                        "type": AnySendable("string"),
                        "description": AnySendable("Title of the event (required for 'create')")
                    ]),
                    "location": AnySendable([
                        "type": AnySendable("string"),
                        "description": AnySendable("Optional meeting location or video call link")
                    ]),
                    "notes": AnySendable([
                        "type": AnySendable("string"),
                        "description": AnySendable("Optional event notes or agenda")
                    ]),
                    "durationMinutes": AnySendable([
                        "type": AnySendable("integer"),
                        "description": AnySendable("Duration in minutes for 'findFreeSlots' (default: 30)")
                    ])
                ]),
                "required": AnySendable([AnySendable("action")])
            ]
        )
    }

    private let service: any CalendarServiceProtocol

    public init(service: any CalendarServiceProtocol = UnavailableApplePlatformServices().calendar) {
        self.service = service
    }

    public func call(argumentsJSON: String) async throws -> String {
        guard let data = argumentsJSON.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let action = json["action"] as? String else {
            throw GraphError.toolExecutionFailed(toolName: "calendar", errorDescription: "Missing 'action' parameter.")
        }

        switch action.lowercased() {
        case "list":
            let start = Date()
            let end = Date().addingTimeInterval(86400 * 7)
            return try await service.listEvents(startDate: start, endDate: end)

        case "create":
            let title = (json["title"] as? String) ?? "New Meeting"
            let start = Date().addingTimeInterval(3600)
            let end = start.addingTimeInterval(3600)
            let location = json["location"] as? String
            let notes = json["notes"] as? String
            return try await service.createEvent(title: title, startDate: start, endDate: end, location: location, notes: notes)

        case "findfreeslots", "free":
            let duration = (json["durationMinutes"] as? Int) ?? 30
            let start = Date()
            let end = Date().addingTimeInterval(86400 * 2)
            return try await service.findFreeSlots(startDate: start, endDate: end, slotDurationMinutes: duration)

        default:
            return "Unsupported action '\(action)'. Valid: list, create, findFreeSlots."
        }
    }
}

/// Pre-built Apple Reminders Tool for listing, creating, and completing tasks.
public struct RemindersTool: Tool {
    public var definition: ToolDefinition {
        ToolDefinition(
            name: "reminders",
            description: "Manages Apple Reminders lists, allowing agents to create tasks, check pending to-dos, and mark tasks complete.",
            parametersJSONSchema: [
                "type": AnySendable("object"),
                "properties": AnySendable([
                    "action": AnySendable([
                        "type": AnySendable("string"),
                        "description": AnySendable("Action: 'list', 'create', or 'complete'")
                    ]),
                    "title": AnySendable([
                        "type": AnySendable("string"),
                        "description": AnySendable("Reminder task title")
                    ]),
                    "priority": AnySendable([
                        "type": AnySendable("integer"),
                        "description": AnySendable("Priority from 0 (none) to 9 (high)")
                    ]),
                    "notes": AnySendable([
                        "type": AnySendable("string"),
                        "description": AnySendable("Additional task notes")
                    ])
                ]),
                "required": AnySendable([AnySendable("action")])
            ]
        )
    }

    private let service: any RemindersServiceProtocol

    public init(service: any RemindersServiceProtocol = UnavailableApplePlatformServices().reminders) {
        self.service = service
    }

    public func call(argumentsJSON: String) async throws -> String {
        guard let data = argumentsJSON.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let action = json["action"] as? String else {
            throw GraphError.toolExecutionFailed(toolName: "reminders", errorDescription: "Missing 'action'.")
        }

        switch action.lowercased() {
        case "list":
            let completed = (json["completed"] as? Bool) ?? false
            return try await service.listReminders(completed: completed)

        case "create":
            guard let title = json["title"] as? String else {
                return "Error: 'title' is required to create a reminder."
            }
            let priority = (json["priority"] as? Int) ?? 0
            let notes = json["notes"] as? String
            return try await service.createReminder(title: title, dueDate: nil, priority: priority, notes: notes)

        case "complete":
            guard let title = json["title"] as? String else {
                return "Error: 'title' is required to complete a reminder."
            }
            return try await service.completeReminder(title: title)

        default:
            return "Unsupported action '\(action)'."
        }
    }
}

/// Pre-built Apple Notes Tool for searching, reading, and creating notes.
public struct NotesTool: Tool {
    public var definition: ToolDefinition {
        ToolDefinition(
            name: "notes",
            description: "Interacts with Apple Notes to search notes, read specific note content, and create new notes.",
            parametersJSONSchema: [
                "type": AnySendable("object"),
                "properties": AnySendable([
                    "action": AnySendable([
                        "type": AnySendable("string"),
                        "description": AnySendable("Action: 'search', 'read', or 'create'")
                    ]),
                    "title": AnySendable([
                        "type": AnySendable("string"),
                        "description": AnySendable("Note title")
                    ]),
                    "body": AnySendable([
                        "type": AnySendable("string"),
                        "description": AnySendable("Note body content")
                    ]),
                    "query": AnySendable([
                        "type": AnySendable("string"),
                        "description": AnySendable("Search term for 'search' action")
                    ])
                ]),
                "required": AnySendable([AnySendable("action")])
            ]
        )
    }

    private let service: any NotesServiceProtocol

    public init(service: any NotesServiceProtocol = UnavailableApplePlatformServices().notes) {
        self.service = service
    }

    public func call(argumentsJSON: String) async throws -> String {
        guard let data = argumentsJSON.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let action = json["action"] as? String else {
            throw GraphError.toolExecutionFailed(toolName: "notes", errorDescription: "Missing 'action'.")
        }

        switch action.lowercased() {
        case "search":
            let query = (json["query"] as? String) ?? (json["title"] as? String) ?? ""
            return try await service.searchNotes(query: query)
        case "read":
            let title = (json["title"] as? String) ?? ""
            return try await service.readNote(title: title)
        case "create":
            let title = (json["title"] as? String) ?? "Untitled Note"
            let body = (json["body"] as? String) ?? ""
            return try await service.createNote(title: title, body: body)
        default:
            return "Unsupported action '\(action)'."
        }
    }
}

/// Pre-built Apple Contacts Tool for searching contacts and looking up phone/email details.
public struct ContactsTool: Tool {
    public var definition: ToolDefinition {
        ToolDefinition(
            name: "contacts",
            description: "Searches Apple Contacts and retrieves contact cards, email addresses, and phone numbers.",
            parametersJSONSchema: [
                "type": AnySendable("object"),
                "properties": AnySendable([
                    "query": AnySendable([
                        "type": AnySendable("string"),
                        "description": AnySendable("Name or email to search in contacts")
                    ])
                ]),
                "required": AnySendable([AnySendable("query")])
            ]
        )
    }

    private let service: any ContactsServiceProtocol

    public init(service: any ContactsServiceProtocol = UnavailableApplePlatformServices().contacts) {
        self.service = service
    }

    public func call(argumentsJSON: String) async throws -> String {
        guard let data = argumentsJSON.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let query = json["query"] as? String else {
            throw GraphError.toolExecutionFailed(toolName: "contacts", errorDescription: "Missing 'query'.")
        }
        return try await service.searchContacts(query: query)
    }
}

/// Pre-built Apple Mail Tool for drafting emails and querying inbox messages.
public struct MailTool: Tool {
    public var definition: ToolDefinition {
        ToolDefinition(
            name: "mail",
            description: "Interacts with Apple Mail to search correspondence or prepare email drafts for user confirmation.",
            parametersJSONSchema: [
                "type": AnySendable("object"),
                "properties": AnySendable([
                    "action": AnySendable([
                        "type": AnySendable("string"),
                        "description": AnySendable("Action: 'draft' or 'search'")
                    ]),
                    "recipient": AnySendable([
                        "type": AnySendable("string"),
                        "description": AnySendable("Recipient email address")
                    ]),
                    "subject": AnySendable([
                        "type": AnySendable("string"),
                        "description": AnySendable("Email subject line")
                    ]),
                    "body": AnySendable([
                        "type": AnySendable("string"),
                        "description": AnySendable("Email body text")
                    ]),
                    "query": AnySendable([
                        "type": AnySendable("string"),
                        "description": AnySendable("Search term for 'search' action")
                    ])
                ]),
                "required": AnySendable([AnySendable("action")])
            ]
        )
    }

    private let service: any MailServiceProtocol

    public init(service: any MailServiceProtocol = UnavailableApplePlatformServices().mail) {
        self.service = service
    }

    public func call(argumentsJSON: String) async throws -> String {
        guard let data = argumentsJSON.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let action = json["action"] as? String else {
            throw GraphError.toolExecutionFailed(toolName: "mail", errorDescription: "Missing 'action'.")
        }

        switch action.lowercased() {
        case "draft":
            let recipient = (json["recipient"] as? String) ?? ""
            let subject = (json["subject"] as? String) ?? "No Subject"
            let body = (json["body"] as? String) ?? ""
            return try await service.draftEmail(recipient: recipient, subject: subject, body: body)

        case "search":
            let query = (json["query"] as? String) ?? ""
            return try await service.searchMail(query: query)

        default:
            return "Unsupported action '\(action)'."
        }
    }
}

/// Pre-built Files Tool for reading, writing, and listing local and iCloud Drive documents.
public struct FilesTool: Tool {
    public var definition: ToolDefinition {
        ToolDefinition(
            name: "files",
            description: "Accesses sandboxed file system and iCloud documents to read, write, list, and inspect file metadata.",
            parametersJSONSchema: [
                "type": AnySendable("object"),
                "properties": AnySendable([
                    "action": AnySendable([
                        "type": AnySendable("string"),
                        "description": AnySendable("Action: 'read', 'write', 'list', or 'metadata'")
                    ]),
                    "path": AnySendable([
                        "type": AnySendable("string"),
                        "description": AnySendable("Relative file or directory path")
                    ]),
                    "content": AnySendable([
                        "type": AnySendable("string"),
                        "description": AnySendable("File contents to write")
                    ])
                ]),
                "required": AnySendable([AnySendable("action"), AnySendable("path")])
            ]
        )
    }

    private let service: any FilesServiceProtocol

    public init(service: any FilesServiceProtocol = UnavailableApplePlatformServices().files) {
        self.service = service
    }

    public func call(argumentsJSON: String) async throws -> String {
        guard let data = argumentsJSON.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let action = json["action"] as? String,
              let path = json["path"] as? String else {
            throw GraphError.toolExecutionFailed(toolName: "files", errorDescription: "Missing parameters.")
        }

        switch action.lowercased() {
        case "read":
            return try await service.readFile(path: path)
        case "write":
            let content = (json["content"] as? String) ?? ""
            return try await service.writeFile(path: path, content: content)
        case "list":
            return try await service.listDirectory(path: path)
        case "metadata", "info":
            return try await service.fileMetadata(path: path)
        default:
            return "Unsupported action '\(action)'."
        }
    }
}

/// Pre-built Apple Maps Tool for searching places, finding addresses, and estimating travel distances.
public struct MapsTool: Tool {
    public var definition: ToolDefinition {
        ToolDefinition(
            name: "maps",
            description: "Interacts with Apple Maps to search points of interest (POI), look up coordinates, or calculate distances.",
            parametersJSONSchema: [
                "type": AnySendable("object"),
                "properties": AnySendable([
                    "query": AnySendable([
                        "type": AnySendable("string"),
                        "description": AnySendable("Place name, business, or category to find")
                    ]),
                    "near": AnySendable([
                        "type": AnySendable("string"),
                        "description": AnySendable("Optional city, address, or landmark origin")
                    ]),
                    "destination": AnySendable([
                        "type": AnySendable("string"),
                        "description": AnySendable("Optional target location for distance calculation")
                    ])
                ]),
                "required": AnySendable([AnySendable("query")])
            ]
        )
    }

    private let service: any MapsServiceProtocol

    public init(service: any MapsServiceProtocol = UnavailableApplePlatformServices().maps) {
        self.service = service
    }

    public func call(argumentsJSON: String) async throws -> String {
        guard let data = argumentsJSON.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let query = json["query"] as? String else {
            throw GraphError.toolExecutionFailed(toolName: "maps", errorDescription: "Missing 'query'.")
        }

        if let dest = json["destination"] as? String {
            return try await service.calculateDistance(from: query, to: dest)
        }

        let near = json["near"] as? String
        return try await service.searchPlaces(query: query, near: near)
    }
}

/// Pre-built System Control Tool for device telemetry, battery status, and clipboard access.
public struct SystemControlTool: Tool {
    public var definition: ToolDefinition {
        ToolDefinition(
            name: "systemControl",
            description: "Controls and inspects Apple platform system features (battery, thermal state, clipboard).",
            parametersJSONSchema: [
                "type": AnySendable("object"),
                "properties": AnySendable([
                    "action": AnySendable([
                        "type": AnySendable("string"),
                        "description": AnySendable("Action: 'getBattery', 'getClipboard', or 'setClipboard'")
                    ]),
                    "text": AnySendable([
                        "type": AnySendable("string"),
                        "description": AnySendable("Text to copy to clipboard for 'setClipboard'")
                    ])
                ]),
                "required": AnySendable([AnySendable("action")])
            ]
        )
    }

    private let service: any SystemControlServiceProtocol

    public init(service: any SystemControlServiceProtocol = UnavailableApplePlatformServices().systemControl) {
        self.service = service
    }

    public func call(argumentsJSON: String) async throws -> String {
        guard let data = argumentsJSON.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let action = json["action"] as? String else {
            throw GraphError.toolExecutionFailed(toolName: "systemControl", errorDescription: "Missing 'action'.")
        }

        switch action.lowercased() {
        case "getbattery", "battery":
            return try await service.getBatteryStatus()
        case "getclipboard", "clipboard":
            return try await service.getClipboard()
        case "setclipboard", "copy":
            let text = (json["text"] as? String) ?? ""
            return try await service.setClipboard(text: text)
        default:
            return "Unsupported action '\(action)'."
        }
    }
}

/// Pre-built Timer Tool for setting and managing countdown timers on Apple platforms.
public struct TimerTool: Tool {
    public var definition: ToolDefinition {
        ToolDefinition(
            name: "timer",
            description: "Sets a countdown timer with optional label on Apple platforms.",
            parametersJSONSchema: [
                "type": AnySendable("object"),
                "properties": AnySendable([
                    "durationSeconds": AnySendable([
                        "type": AnySendable("integer"),
                        "description": AnySendable("Duration of the countdown timer in seconds")
                    ]),
                    "label": AnySendable([
                        "type": AnySendable("string"),
                        "description": AnySendable("Optional label for the timer")
                    ])
                ]),
                "required": AnySendable([AnySendable("durationSeconds")])
            ]
        )
    }

    private let service: any SystemControlServiceProtocol

    public init(service: any SystemControlServiceProtocol = UnavailableApplePlatformServices().systemControl) {
        self.service = service
    }

    public func call(argumentsJSON: String) async throws -> String {
        guard let data = argumentsJSON.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let duration = json["durationSeconds"] as? Int else {
            throw GraphError.toolExecutionFailed(toolName: "timer", errorDescription: "Missing 'durationSeconds'.")
        }

        let label = json["label"] as? String
        return try await service.setTimer(durationSeconds: duration, label: label)
    }
}
