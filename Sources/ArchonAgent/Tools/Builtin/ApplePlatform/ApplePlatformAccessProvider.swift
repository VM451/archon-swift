import Foundation

#if canImport(EventKit)
import EventKit
#endif

#if canImport(Contacts)
import Contacts
#endif

#if canImport(MapKit)
import MapKit
#endif

#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

// MARK: - Apple Platform Service Protocols

public protocol CalendarServiceProtocol: Sendable {
    func listEvents(startDate: Date, endDate: Date) async throws -> String
    func createEvent(title: String, startDate: Date, endDate: Date, location: String?, notes: String?) async throws -> String
    func findFreeSlots(startDate: Date, endDate: Date, slotDurationMinutes: Int) async throws -> String
}

public protocol RemindersServiceProtocol: Sendable {
    func listReminders(completed: Bool) async throws -> String
    func createReminder(title: String, dueDate: Date?, priority: Int, notes: String?) async throws -> String
    func completeReminder(title: String) async throws -> String
}

public protocol NotesServiceProtocol: Sendable {
    func searchNotes(query: String) async throws -> String
    func createNote(title: String, body: String) async throws -> String
    func readNote(title: String) async throws -> String
}

public protocol ContactsServiceProtocol: Sendable {
    func searchContacts(query: String) async throws -> String
    func getContactDetails(name: String) async throws -> String
}

public protocol MailServiceProtocol: Sendable {
    func draftEmail(recipient: String, subject: String, body: String) async throws -> String
    func searchMail(query: String) async throws -> String
}

public protocol FilesServiceProtocol: Sendable {
    func readFile(path: String) async throws -> String
    func writeFile(path: String, content: String) async throws -> String
    func listDirectory(path: String) async throws -> String
    func fileMetadata(path: String) async throws -> String
}

public protocol MapsServiceProtocol: Sendable {
    func searchPlaces(query: String, near: String?) async throws -> String
    func calculateDistance(from: String, to: String) async throws -> String
}

public protocol SystemControlServiceProtocol: Sendable {
    func getBatteryStatus() async throws -> String
    func getClipboard() async throws -> String
    func setClipboard(text: String) async throws -> String
    func setTimer(durationSeconds: Int, label: String?) async throws -> String
}

/// Unified provider combining all Apple platform service capabilities.
public protocol ApplePlatformAccessProvider: Sendable {
    var calendar: any CalendarServiceProtocol { get }
    var reminders: any RemindersServiceProtocol { get }
    var notes: any NotesServiceProtocol { get }
    var contacts: any ContactsServiceProtocol { get }
    var mail: any MailServiceProtocol { get }
    var files: any FilesServiceProtocol { get }
    var maps: any MapsServiceProtocol { get }
    var systemControl: any SystemControlServiceProtocol { get }
}

/// Returned when a host has registered an Apple-platform tool without wiring
/// the corresponding framework or application service. It prevents a tool
/// call from being reported as successful with fabricated data.
public enum ApplePlatformServiceError: Error, LocalizedError, Equatable, Sendable {
    case unavailable(service: String, capability: String)
    case permissionDenied(service: String)
    case invalidRequest(service: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case let .unavailable(service, capability):
            "\(service) \(capability) is unavailable until the host app provides an integration."
        case let .permissionDenied(service):
            "The host app denied access to \(service)."
        case let .invalidRequest(service, reason):
            "Invalid \(service) request: \(reason)"
        }
    }
}

/// Fail-closed service bundle for package-only consumers. Apps should inject
/// real EventKit, Contacts, Mail, Maps, clipboard, and timer adapters.
public actor UnavailableApplePlatformService:
    CalendarServiceProtocol,
    RemindersServiceProtocol,
    NotesServiceProtocol,
    ContactsServiceProtocol,
    MailServiceProtocol,
    FilesServiceProtocol,
    MapsServiceProtocol,
    SystemControlServiceProtocol {

    public init() {}

    public func listEvents(startDate: Date, endDate: Date) async throws -> String {
        _ = (startDate, endDate)
        throw ApplePlatformServiceError.unavailable(service: "Calendar", capability: "access")
    }

    public func createEvent(title: String, startDate: Date, endDate: Date, location: String?, notes: String?) async throws -> String {
        _ = (title, startDate, endDate, location, notes)
        throw ApplePlatformServiceError.unavailable(service: "Calendar", capability: "event creation")
    }

    public func findFreeSlots(startDate: Date, endDate: Date, slotDurationMinutes: Int) async throws -> String {
        _ = (startDate, endDate, slotDurationMinutes)
        throw ApplePlatformServiceError.unavailable(service: "Calendar", capability: "free/busy lookup")
    }

    public func listReminders(completed: Bool) async throws -> String {
        _ = completed
        throw ApplePlatformServiceError.unavailable(service: "Reminders", capability: "access")
    }

    public func createReminder(title: String, dueDate: Date?, priority: Int, notes: String?) async throws -> String {
        _ = (title, dueDate, priority, notes)
        throw ApplePlatformServiceError.unavailable(service: "Reminders", capability: "creation")
    }

    public func completeReminder(title: String) async throws -> String {
        _ = title
        throw ApplePlatformServiceError.unavailable(service: "Reminders", capability: "completion")
    }

    public func searchNotes(query: String) async throws -> String {
        _ = query
        throw ApplePlatformServiceError.unavailable(service: "Notes", capability: "search")
    }

    public func createNote(title: String, body: String) async throws -> String {
        _ = (title, body)
        throw ApplePlatformServiceError.unavailable(service: "Notes", capability: "creation")
    }

    public func readNote(title: String) async throws -> String {
        _ = title
        throw ApplePlatformServiceError.unavailable(service: "Notes", capability: "reading")
    }

    public func searchContacts(query: String) async throws -> String {
        _ = query
        throw ApplePlatformServiceError.unavailable(service: "Contacts", capability: "search")
    }

    public func getContactDetails(name: String) async throws -> String {
        _ = name
        throw ApplePlatformServiceError.unavailable(service: "Contacts", capability: "lookup")
    }

    public func draftEmail(recipient: String, subject: String, body: String) async throws -> String {
        _ = (recipient, subject, body)
        throw ApplePlatformServiceError.unavailable(service: "Mail", capability: "drafting")
    }

    public func searchMail(query: String) async throws -> String {
        _ = query
        throw ApplePlatformServiceError.unavailable(service: "Mail", capability: "search")
    }

    public func readFile(path: String) async throws -> String {
        _ = path
        throw ApplePlatformServiceError.unavailable(service: "Files", capability: "reading")
    }

    public func writeFile(path: String, content: String) async throws -> String {
        _ = (path, content)
        throw ApplePlatformServiceError.unavailable(service: "Files", capability: "writing")
    }

    public func listDirectory(path: String) async throws -> String {
        _ = path
        throw ApplePlatformServiceError.unavailable(service: "Files", capability: "listing")
    }

    public func fileMetadata(path: String) async throws -> String {
        _ = path
        throw ApplePlatformServiceError.unavailable(service: "Files", capability: "metadata")
    }

    public func searchPlaces(query: String, near: String?) async throws -> String {
        _ = (query, near)
        throw ApplePlatformServiceError.unavailable(service: "Maps", capability: "place search")
    }

    public func calculateDistance(from: String, to: String) async throws -> String {
        _ = (from, to)
        throw ApplePlatformServiceError.unavailable(service: "Maps", capability: "routing")
    }

    public func getBatteryStatus() async throws -> String {
        throw ApplePlatformServiceError.unavailable(service: "System control", capability: "battery status")
    }

    public func getClipboard() async throws -> String {
        throw ApplePlatformServiceError.unavailable(service: "System control", capability: "clipboard access")
    }

    public func setClipboard(text: String) async throws -> String {
        _ = text
        throw ApplePlatformServiceError.unavailable(service: "System control", capability: "clipboard writes")
    }

    public func setTimer(durationSeconds: Int, label: String?) async throws -> String {
        _ = (durationSeconds, label)
        throw ApplePlatformServiceError.unavailable(service: "System control", capability: "timer scheduling")
    }
}

/// Package defaults use this bundle so unconfigured platform actions fail
/// closed. Tests and host apps can inject `MockApplePlatformServices` or real
/// framework-backed adapters explicitly.
public struct UnavailableApplePlatformServices: ApplePlatformAccessProvider, Sendable {
    public let calendar: any CalendarServiceProtocol
    public let reminders: any RemindersServiceProtocol
    public let notes: any NotesServiceProtocol
    public let contacts: any ContactsServiceProtocol
    public let mail: any MailServiceProtocol
    public let files: any FilesServiceProtocol
    public let maps: any MapsServiceProtocol
    public let systemControl: any SystemControlServiceProtocol

    public init() {
        let service = UnavailableApplePlatformService()
        self.calendar = service
        self.reminders = service
        self.notes = service
        self.contacts = service
        self.mail = service
        self.files = service
        self.maps = service
        self.systemControl = service
    }
}

// MARK: - In-Memory Mock Services (Zero-Cloud, Sandboxed, CI Ready)

public final class MockApplePlatformServices: ApplePlatformAccessProvider, @unchecked Sendable {
    public let calendar: any CalendarServiceProtocol
    public let reminders: any RemindersServiceProtocol
    public let notes: any NotesServiceProtocol
    public let contacts: any ContactsServiceProtocol
    public let mail: any MailServiceProtocol
    public let files: any FilesServiceProtocol
    public let maps: any MapsServiceProtocol
    public let systemControl: any SystemControlServiceProtocol

    public init(
        events: [String] = ["Team Sync at 10:00 AM", "Product Demo at 2:00 PM"],
        reminderItems: [String] = ["Review PR #42", "Submit quarterly expense report"],
        noteItems: [String: String] = ["Project Roadmap": "Phase 1: Agentic runtime. Phase 2: Knowledge sync."],
        contactItems: [String: String] = ["Sarah Connor": "sarah@cyberdyne.com (555-0199)"],
        mailItems: [String] = ["From: Alice - Subject: Q3 Roadmap update"],
        fileStorage: [String: String] = ["welcome.txt": "Welcome to ArchonAgent Apple Platform Environment."],
        mockPlaces: [String: String] = ["Cupertino Coffee": "1 Infinite Loop, Cupertino, CA (0.4 miles away)"],
        batteryLevel: String = "Battery: 88% (Charging: false)"
    ) {
        self.calendar = MockCalendarService(events: events)
        self.reminders = MockRemindersService(reminders: reminderItems)
        self.notes = MockNotesService(notes: noteItems)
        self.contacts = MockContactsService(contacts: contactItems)
        self.mail = MockMailService(mails: mailItems)
        self.files = MockFilesService(storage: fileStorage)
        self.maps = MockMapsService(places: mockPlaces)
        self.systemControl = MockSystemControlService(batteryStatus: batteryLevel)
    }
}

public actor MockCalendarService: CalendarServiceProtocol {
    private var events: [String]
    public init(events: [String]) { self.events = events }

    public func listEvents(startDate: Date, endDate: Date) async throws -> String {
        events.isEmpty ? "No scheduled calendar events." : events.joined(separator: "\n- ")
    }
    public func createEvent(title: String, startDate: Date, endDate: Date, location: String?, notes: String?) async throws -> String {
        let loc = location.map { " at \($0)" } ?? ""
        let entry = "\(title)\(loc)"
        events.append(entry)
        return "Created calendar event: '\(title)'."
    }
    public func findFreeSlots(startDate: Date, endDate: Date, slotDurationMinutes: Int) async throws -> String {
        "Available free slot: 11:30 AM - 12:30 PM (60 min)."
    }
}

public actor MockRemindersService: RemindersServiceProtocol {
    private var pending: [String]
    private var completedList: [String] = []
    public init(reminders: [String]) { self.pending = reminders }

    public func listReminders(completed: Bool) async throws -> String {
        let list = completed ? completedList : pending
        return list.isEmpty ? "No reminders." : list.joined(separator: "\n- ")
    }
    public func createReminder(title: String, dueDate: Date?, priority: Int, notes: String?) async throws -> String {
        pending.append(title)
        return "Created reminder: '\(title)' (Priority: \(priority))."
    }
    public func completeReminder(title: String) async throws -> String {
        if let idx = pending.firstIndex(of: title) {
            let item = pending.remove(at: idx)
            completedList.append(item)
            return "Marked reminder '\(title)' as completed."
        }
        return "Reminder '\(title)' not found."
    }
}

public actor MockNotesService: NotesServiceProtocol {
    private var notes: [String: String]
    public init(notes: [String: String]) { self.notes = notes }

    public func searchNotes(query: String) async throws -> String {
        let matches = notes.filter { $0.key.localizedCaseInsensitiveContains(query) || $0.value.localizedCaseInsensitiveContains(query) }
        return matches.isEmpty ? "No notes matching '\(query)'." : matches.map { "\($0.key): \($0.value)" }.joined(separator: "\n---\n")
    }
    public func createNote(title: String, body: String) async throws -> String {
        notes[title] = body
        return "Created Apple Note: '\(title)'."
    }
    public func readNote(title: String) async throws -> String {
        notes[title] ?? "Note '\(title)' not found."
    }
}

public actor MockContactsService: ContactsServiceProtocol {
    private var contacts: [String: String]
    public init(contacts: [String: String]) { self.contacts = contacts }

    public func searchContacts(query: String) async throws -> String {
        let matches = contacts.filter { $0.key.localizedCaseInsensitiveContains(query) || $0.value.localizedCaseInsensitiveContains(query) }
        return matches.isEmpty ? "No contacts matching '\(query)'." : matches.map { "\($0.key) -> \($0.value)" }.joined(separator: "\n")
    }
    public func getContactDetails(name: String) async throws -> String {
        contacts[name] ?? "Contact '\(name)' not found."
    }
}

public actor MockMailService: MailServiceProtocol {
    private var drafts: [String] = []
    private var inbox: [String]
    public init(mails: [String]) { self.inbox = mails }

    public func draftEmail(recipient: String, subject: String, body: String) async throws -> String {
        let draft = "To: \(recipient) | Subject: \(subject) | Body: \(body)"
        drafts.append(draft)
        return "Successfully created Mail draft to '\(recipient)' with subject '\(subject)'."
    }
    public func searchMail(query: String) async throws -> String {
        let matches = inbox.filter { $0.localizedCaseInsensitiveContains(query) }
        return matches.isEmpty ? "No emails matching '\(query)'." : matches.joined(separator: "\n- ")
    }
}

public actor MockFilesService: FilesServiceProtocol {
    private var storage: [String: String]
    public init(storage: [String: String]) { self.storage = storage }

    public func readFile(path: String) async throws -> String {
        storage[path] ?? "File not found at '\(path)'."
    }
    public func writeFile(path: String, content: String) async throws -> String {
        storage[path] = content
        return "Successfully saved \(content.count) bytes to '\(path)'."
    }
    public func listDirectory(path: String) async throws -> String {
        storage.keys.joined(separator: "\n")
    }
    public func fileMetadata(path: String) async throws -> String {
        if let content = storage[path] {
            return "Path: \(path) | Size: \(content.count) bytes | Format: UTF-8"
        }
        return "File not found."
    }
}

public actor MockMapsService: MapsServiceProtocol {
    private var places: [String: String]
    public init(places: [String: String]) { self.places = places }

    public func searchPlaces(query: String, near: String?) async throws -> String {
        let matches = places.filter { $0.key.localizedCaseInsensitiveContains(query) || $0.value.localizedCaseInsensitiveContains(query) }
        return matches.isEmpty ? "Found nearest location for '\(query)': 1 Apple Park Way, Cupertino, CA." : matches.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
    }
    public func calculateDistance(from: String, to: String) async throws -> String {
        "Distance from \(from) to \(to): approx 4.2 miles (9 min driving)."
    }
}

public actor MockSystemControlService: SystemControlServiceProtocol {
    private var battery: String
    private var clipboard: String = ""
    public init(batteryStatus: String) { self.battery = batteryStatus }

    public func getBatteryStatus() async throws -> String { battery }
    public func getClipboard() async throws -> String { clipboard.isEmpty ? "Clipboard is empty." : clipboard }
    public func setClipboard(text: String) async throws -> String {
        clipboard = text
        return "Copied \(text.count) characters to clipboard."
    }
    public func setTimer(durationSeconds: Int, label: String?) async throws -> String {
        let name = label.map { " for '\($0)'" } ?? ""
        return "Set countdown timer for \(durationSeconds) seconds\(name)."
    }
}

// MARK: - Host Apple Platform Integration Boundary

/// Host-facing service bundle. Public EventKit, Contacts, MapKit, clipboard,
/// and sandboxed file access are implemented here; Notes, Mail, battery
/// telemetry, and timer scheduling fail closed until the consuming app supplies
/// concrete adapters.
public final class NativeApplePlatformServices: ApplePlatformAccessProvider, @unchecked Sendable {
    public let calendar: any CalendarServiceProtocol
    public let reminders: any RemindersServiceProtocol
    public let notes: any NotesServiceProtocol
    public let contacts: any ContactsServiceProtocol
    public let mail: any MailServiceProtocol
    public let files: any FilesServiceProtocol
    public let maps: any MapsServiceProtocol
    public let systemControl: any SystemControlServiceProtocol

    public init(rootDirectory: URL = FileManager.default.temporaryDirectory) {
        self.calendar = NativeCalendarService()
        self.reminders = NativeRemindersService()
        self.notes = NativeNotesService()
        self.contacts = NativeContactsService()
        self.mail = NativeMailService()
        self.files = NativeFilesService(rootDirectory: rootDirectory)
        self.maps = NativeMapsService()
        self.systemControl = NativeSystemControlService()
    }
}

public actor NativeCalendarService: CalendarServiceProtocol {
#if canImport(EventKit)
    private let store = EKEventStore()
#endif

    public init() {}

    public func listEvents(startDate: Date, endDate: Date) async throws -> String {
        guard startDate < endDate else {
            throw ApplePlatformServiceError.invalidRequest(
                service: "Calendar",
                reason: "startDate must be before endDate."
            )
        }
#if canImport(EventKit)
        try await requestAccess()
        let predicate = store.predicateForEvents(
            withStart: startDate,
            end: endDate,
            calendars: nil
        )
        var records: [NativeCalendarEventRecord] = []
        for event in store.events(matching: predicate) {
            guard let eventStartDate: Date = event.startDate,
                  let eventEndDate: Date = event.endDate else { continue }
            records.append(NativeCalendarEventRecord(
                id: event.eventIdentifier ?? UUID().uuidString,
                title: event.title ?? "Untitled event",
                startDate: eventStartDate,
                endDate: eventEndDate,
                location: event.location,
                notes: event.notes,
                isAllDay: event.isAllDay
            ))
        }
        return try nativeJSON(records)
#else
        throw ApplePlatformServiceError.unavailable(service: "Calendar", capability: "access")
#endif
    }

    public func createEvent(title: String, startDate: Date, endDate: Date, location: String?, notes: String?) async throws -> String {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ApplePlatformServiceError.invalidRequest(service: "Calendar", reason: "title must not be empty.")
        }
        guard startDate < endDate else {
            throw ApplePlatformServiceError.invalidRequest(
                service: "Calendar",
                reason: "startDate must be before endDate."
            )
        }
#if canImport(EventKit)
        try await requestAccess()
        guard let calendar = store.defaultCalendarForNewEvents else {
            throw ApplePlatformServiceError.unavailable(service: "Calendar", capability: "a writable default calendar")
        }
        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = startDate
        event.endDate = endDate
        event.location = location
        event.notes = notes
        event.calendar = calendar
        try store.save(event, span: .thisEvent, commit: true)
        return "Created calendar event '\(title)' (\(event.eventIdentifier ?? "unknown"))."
#else
        throw ApplePlatformServiceError.unavailable(service: "Calendar", capability: "event creation")
#endif
    }

    public func findFreeSlots(startDate: Date, endDate: Date, slotDurationMinutes: Int) async throws -> String {
        guard startDate < endDate, slotDurationMinutes > 0 else {
            throw ApplePlatformServiceError.invalidRequest(
                service: "Calendar",
                reason: "the date range must be ordered and slotDurationMinutes must be positive."
            )
        }
#if canImport(EventKit)
        try await requestAccess()
        let predicate = store.predicateForEvents(
            withStart: startDate,
            end: endDate,
            calendars: nil
        )
        let busyIntervals = store.events(matching: predicate).compactMap { event -> (Date, Date)? in
            guard let startDate = event.startDate as Date?, let endDate = event.endDate as Date? else { return nil }
            return (startDate, endDate)
        }
        let slotLength = TimeInterval(slotDurationMinutes * 60)
        var slots: [NativeTimeSlotRecord] = []
        var candidate = startDate
        while candidate.addingTimeInterval(slotLength) <= endDate {
            let candidateEnd = candidate.addingTimeInterval(slotLength)
            let overlaps = busyIntervals.contains { busyStart, busyEnd in
                busyStart < candidateEnd && busyEnd > candidate
            }
            if !overlaps {
                slots.append(NativeTimeSlotRecord(startDate: candidate, endDate: candidateEnd))
            }
            candidate = candidate.addingTimeInterval(slotLength)
        }
        return try nativeJSON(slots)
#else
        throw ApplePlatformServiceError.unavailable(service: "Calendar", capability: "free/busy lookup")
#endif
    }

#if canImport(EventKit)
    private func requestAccess() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            store.requestFullAccessToEvents { granted, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if granted {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: ApplePlatformServiceError.permissionDenied(service: "Calendar"))
                }
            }
        }
    }
#endif
}

public actor NativeRemindersService: RemindersServiceProtocol {
#if canImport(EventKit)
    private let store = EKEventStore()
#endif

    public init() {}

    public func listReminders(completed: Bool) async throws -> String {
        let records = try await fetchReminders(completed: completed)
        return try nativeJSON(records)
    }

    public func createReminder(title: String, dueDate: Date?, priority: Int, notes: String?) async throws -> String {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ApplePlatformServiceError.invalidRequest(service: "Reminders", reason: "title must not be empty.")
        }
        guard priority >= 0 else {
            throw ApplePlatformServiceError.invalidRequest(service: "Reminders", reason: "priority must not be negative.")
        }
#if canImport(EventKit)
        try await requestAccess()
        guard let calendar = store.defaultCalendarForNewReminders() else {
            throw ApplePlatformServiceError.unavailable(service: "Reminders", capability: "a writable default list")
        }
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.priority = priority
        reminder.notes = notes
        if let dueDate {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.era, .year, .month, .day, .hour, .minute],
                from: dueDate
            )
        }
        reminder.calendar = calendar
        try store.save(reminder, commit: true)
        return "Created reminder '\(title)' (\(reminder.calendarItemIdentifier))."
#else
        throw ApplePlatformServiceError.unavailable(service: "Reminders", capability: "creation")
#endif
    }

    public func completeReminder(title: String) async throws -> String {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ApplePlatformServiceError.invalidRequest(service: "Reminders", reason: "title must not be empty.")
        }
#if canImport(EventKit)
        try await requestAccess()
        let reminders = try await fetchReminderRecords(completed: false)
        guard let matchingReminder = reminders.first(where: { $0.title.caseInsensitiveCompare(title) == .orderedSame }) else {
            throw ApplePlatformServiceError.invalidRequest(service: "Reminders", reason: "no incomplete reminder matched the title.")
        }
        guard let reminder = store.calendarItem(withIdentifier: matchingReminder.id) as? EKReminder else {
            throw ApplePlatformServiceError.invalidRequest(service: "Reminders", reason: "the matching reminder could not be reloaded.")
        }
        reminder.isCompleted = true
        try store.save(reminder, commit: true)
        return "Completed reminder '\(title)'."
#else
        throw ApplePlatformServiceError.unavailable(service: "Reminders", capability: "completion")
#endif
    }

    private func fetchReminders(completed: Bool) async throws -> [NativeReminderRecord] {
#if canImport(EventKit)
        try await requestAccess()
        return try await fetchReminderRecords(completed: completed)
#else
        _ = completed
        throw ApplePlatformServiceError.unavailable(service: "Reminders", capability: "access")
#endif
    }

#if canImport(EventKit)
    private func fetchReminderRecords(completed: Bool) async throws -> [NativeReminderRecord] {
        let predicate: NSPredicate
        if completed {
            predicate = store.predicateForCompletedReminders(withCompletionDateStarting: nil, ending: nil, calendars: nil)
        } else {
            predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        }
        return await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                let records = (reminders ?? []).map {
                    NativeReminderRecord(
                        id: $0.calendarItemIdentifier,
                        title: $0.title,
                        completed: $0.isCompleted,
                        dueDate: nativeDate(from: $0.dueDateComponents),
                        priority: $0.priority,
                        notes: $0.notes
                    )
                }
                continuation.resume(returning: records)
            }
        }
    }

    private func requestAccess() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            store.requestFullAccessToReminders { granted, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if granted {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: ApplePlatformServiceError.permissionDenied(service: "Reminders"))
                }
            }
        }
    }
#endif
}

public actor NativeNotesService: NotesServiceProtocol {
    public init() {}

    public func searchNotes(query: String) async throws -> String {
        _ = query
        throw ApplePlatformServiceError.unavailable(service: "Notes", capability: "search")
    }

    public func createNote(title: String, body: String) async throws -> String {
        _ = (title, body)
        throw ApplePlatformServiceError.unavailable(service: "Notes", capability: "creation")
    }

    public func readNote(title: String) async throws -> String {
        _ = title
        throw ApplePlatformServiceError.unavailable(service: "Notes", capability: "reading")
    }
}

public actor NativeContactsService: ContactsServiceProtocol {
#if canImport(Contacts)
    private let store = CNContactStore()
#endif

    public init() {}

    public func searchContacts(query: String) async throws -> String {
        let contacts = try await matchingContacts(query: query)
        return try nativeJSON(contacts)
    }

    public func getContactDetails(name: String) async throws -> String {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ApplePlatformServiceError.invalidRequest(service: "Contacts", reason: "name must not be empty.")
        }
#if canImport(Contacts)
        let contacts = try await matchingContacts(query: name)
        guard let contact = contacts.first else {
            throw ApplePlatformServiceError.invalidRequest(service: "Contacts", reason: "no contact matched the name.")
        }
        return try nativeJSON(contact)
#else
        throw ApplePlatformServiceError.unavailable(service: "Contacts", capability: "lookup")
#endif
    }

#if canImport(Contacts)
    private func matchingContacts(query: String) async throws -> [NativeContactRecord] {
        try await requestAccess()
        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor
        ]
        let request = CNContactFetchRequest(keysToFetch: keys)
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var results: [NativeContactRecord] = []
        var fetchError: Error?
        do {
            try store.enumerateContacts(with: request) { contact, stop in
                let record = NativeContactRecord(contact: contact)
                if normalizedQuery.isEmpty || record.searchText.localizedCaseInsensitiveContains(normalizedQuery) {
                    results.append(record)
                }
                if results.count >= 100 {
                    stop.pointee = true
                }
            }
        } catch {
            fetchError = error
        }
        if let fetchError { throw fetchError }
        return results
    }

    private func requestAccess() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            store.requestAccess(for: .contacts) { granted, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if granted {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: ApplePlatformServiceError.permissionDenied(service: "Contacts"))
                }
            }
        }
    }
#else
    private func matchingContacts(query: String) async throws -> [NativeContactRecord] {
        _ = query
        throw ApplePlatformServiceError.unavailable(service: "Contacts", capability: "search")
    }
#endif
}

public actor NativeMailService: MailServiceProtocol {
    public init() {}

    public func draftEmail(recipient: String, subject: String, body: String) async throws -> String {
        _ = (recipient, subject, body)
        throw ApplePlatformServiceError.unavailable(service: "Mail", capability: "drafting")
    }

    public func searchMail(query: String) async throws -> String {
        _ = query
        throw ApplePlatformServiceError.unavailable(service: "Mail", capability: "search")
    }
}

public actor NativeFilesService: FilesServiceProtocol {
    private let rootDirectory: URL
    public init(rootDirectory: URL) { self.rootDirectory = rootDirectory }

    public func readFile(path: String) async throws -> String {
        let url = try SandboxPathResolver.resolve(path, relativeTo: rootDirectory)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return "File not found at '\(path)'."
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    public func writeFile(path: String, content: String) async throws -> String {
        let url = try SandboxPathResolver.resolve(path, relativeTo: rootDirectory)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return "Successfully wrote \(content.count) bytes to '\(path)'."
    }

    public func listDirectory(path: String) async throws -> String {
        let url = try SandboxPathResolver.resolve(path, relativeTo: rootDirectory)
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: url.path) else {
            return "Directory is empty or inaccessible."
        }
        return items.joined(separator: "\n")
    }

    public func fileMetadata(path: String) async throws -> String {
        let url = try SandboxPathResolver.resolve(path, relativeTo: rootDirectory)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return "Unable to read attributes for '\(path)'."
        }
        let size = (attrs[.size] as? Int) ?? 0
        return "File: \(path) | Size: \(size) bytes"
    }
}

public actor NativeMapsService: MapsServiceProtocol {
    public init() {}

    public func searchPlaces(query: String, near: String?) async throws -> String {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ApplePlatformServiceError.invalidRequest(service: "Maps", reason: "query must not be empty.")
        }
#if canImport(MapKit)
        let searchQuery = near.map { "\(query), \($0)" } ?? query
        let places = try await NativeMapsService.search(query: searchQuery)
        return try nativeJSON(places)
#else
        _ = near
        throw ApplePlatformServiceError.unavailable(service: "Maps", capability: "place search")
#endif
    }

    public func calculateDistance(from: String, to: String) async throws -> String {
        guard !from.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !to.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ApplePlatformServiceError.invalidRequest(service: "Maps", reason: "both locations must not be empty.")
        }
#if canImport(MapKit)
        let locations = try await NativeMapsService.search(query: from)
        let destinations = try await NativeMapsService.search(query: to)
        guard let origin = locations.first, let destination = destinations.first else {
            throw ApplePlatformServiceError.invalidRequest(service: "Maps", reason: "one or both locations could not be resolved.")
        }
        let distance = CLLocation(latitude: origin.latitude, longitude: origin.longitude)
            .distance(from: CLLocation(latitude: destination.latitude, longitude: destination.longitude))
        let kilometers = distance / 1_000
        return String(format: "%.2f km straight-line distance from '%@' to '%@'.", kilometers, from, to)
#else
        throw ApplePlatformServiceError.unavailable(service: "Maps", capability: "place search")
#endif
    }

#if canImport(MapKit)
    @MainActor
    private static func search(query: String) async throws -> [NativePlaceRecord] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        let search = MKLocalSearch(request: request)
        return try await withCheckedThrowingContinuation { continuation in
            search.start { response, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let places = response?.mapItems.map { item in
                    NativePlaceRecord(
                        name: item.name ?? query,
                        address: item.address?.fullAddress,
                        phoneNumber: item.phoneNumber,
                        url: item.url,
                        latitude: item.location.coordinate.latitude,
                        longitude: item.location.coordinate.longitude
                    )
                } ?? []
                continuation.resume(returning: places)
            }
        }
    }
#endif
}

public actor NativeSystemControlService: SystemControlServiceProtocol {
    public init() {}

    public func getBatteryStatus() async throws -> String {
        throw ApplePlatformServiceError.unavailable(service: "System control", capability: "battery status")
    }

    public func getClipboard() async throws -> String {
#if os(macOS)
        return await MainActor.run {
            NSPasteboard.general.string(forType: .string) ?? "Clipboard is empty."
        }
#elseif canImport(UIKit)
        return await MainActor.run {
            UIPasteboard.general.string ?? "Clipboard is empty."
        }
#else
        throw ApplePlatformServiceError.unavailable(service: "System control", capability: "clipboard access")
#endif
    }

    public func setClipboard(text: String) async throws -> String {
#if os(macOS)
        let written = await MainActor.run {
            NSPasteboard.general.clearContents()
            return NSPasteboard.general.setString(text, forType: .string)
        }
        guard written else {
            throw ApplePlatformServiceError.unavailable(service: "System control", capability: "clipboard writes")
        }
        return "Copied \(text.count) characters to the clipboard."
#elseif canImport(UIKit)
        await MainActor.run {
            UIPasteboard.general.string = text
        }
        return "Copied \(text.count) characters to the clipboard."
#else
        _ = text
        throw ApplePlatformServiceError.unavailable(service: "System control", capability: "clipboard writes")
#endif
    }

    public func setTimer(durationSeconds: Int, label: String?) async throws -> String {
        _ = (durationSeconds, label)
        throw ApplePlatformServiceError.unavailable(service: "System control", capability: "timer scheduling")
    }
}

private struct NativeCalendarEventRecord: Encodable, Sendable {
    let id: String
    let title: String
    let startDate: Date
    let endDate: Date
    let location: String?
    let notes: String?
    let isAllDay: Bool
}

private struct NativeTimeSlotRecord: Encodable, Sendable {
    let startDate: Date
    let endDate: Date
}

private struct NativeReminderRecord: Encodable, Sendable {
    let id: String
    let title: String
    let completed: Bool
    let dueDate: Date?
    let priority: Int
    let notes: String?
}

private struct NativeContactRecord: Encodable, Sendable {
    let id: String
    let givenName: String
    let familyName: String
    let organizationName: String
    let phoneNumbers: [String]
    let emailAddresses: [String]

    var searchText: String {
        [givenName, familyName, organizationName, phoneNumbers.joined(separator: " "), emailAddresses.joined(separator: " ")]
            .joined(separator: " ")
    }

#if canImport(Contacts)
    init(contact: CNContact) {
        self.id = contact.identifier
        self.givenName = contact.givenName
        self.familyName = contact.familyName
        self.organizationName = contact.organizationName
        self.phoneNumbers = contact.phoneNumbers.map(\.value.stringValue)
        self.emailAddresses = contact.emailAddresses.map { String($0.value) }
    }
#endif
}

private struct NativePlaceRecord: Encodable, Sendable {
    let name: String
    let address: String?
    let phoneNumber: String?
    let url: URL?
    let latitude: Double
    let longitude: Double
}

private func nativeDate(from components: DateComponents?) -> Date? {
    guard let components else { return nil }
    return Calendar.current.date(from: components)
}

private func nativeJSON<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}
