import Testing
import Foundation
@testable import ArchonAgent

@Suite("Apple Platform Pre-Built Tools Tests")
struct ApplePlatformToolsTests {

    @Test("CalendarTool lists events, creates event, and finds free slots")
    func calendarToolOperations() async throws {
        let tool = CalendarTool(service: MockApplePlatformServices().calendar)

        // List
        let listJSON = "{\"action\": \"list\"}"
        let listRes = try await tool.call(argumentsJSON: listJSON)
        #expect(listRes.contains("Team Sync"))

        // Create
        let createJSON = "{\"action\": \"create\", \"title\": \"Design Review\", \"location\": \"Room 4B\"}"
        let createRes = try await tool.call(argumentsJSON: createJSON)
        #expect(createRes.contains("Created calendar event"))

        // Free slots
        let freeJSON = "{\"action\": \"findFreeSlots\", \"durationMinutes\": 45}"
        let freeRes = try await tool.call(argumentsJSON: freeJSON)
        #expect(freeRes.contains("Available free slot"))
    }

    @Test("RemindersTool lists, adds, and completes tasks")
    func remindersToolOperations() async throws {
        let tool = RemindersTool(service: MockApplePlatformServices().reminders)

        // List
        let listJSON = "{\"action\": \"list\"}"
        let listRes = try await tool.call(argumentsJSON: listJSON)
        #expect(listRes.contains("Review PR #42"))

        // Create
        let createJSON = "{\"action\": \"create\", \"title\": \"Deploy v2.0 update\", \"priority\": 5}"
        let createRes = try await tool.call(argumentsJSON: createJSON)
        #expect(createRes.contains("Created reminder"))

        // Complete
        let compJSON = "{\"action\": \"complete\", \"title\": \"Review PR #42\"}"
        let compRes = try await tool.call(argumentsJSON: compJSON)
        #expect(compRes.contains("completed"))
    }

    @Test("NotesTool searches, reads, and creates Apple Notes")
    func notesToolOperations() async throws {
        let tool = NotesTool(service: MockApplePlatformServices().notes)

        // Search
        let searchJSON = "{\"action\": \"search\", \"query\": \"Roadmap\"}"
        let searchRes = try await tool.call(argumentsJSON: searchJSON)
        #expect(searchRes.contains("Phase 1"))

        // Create
        let createJSON = "{\"action\": \"create\", \"title\": \"Meeting Notes\", \"body\": \"Discussed Q4 targets\"}"
        let createRes = try await tool.call(argumentsJSON: createJSON)
        #expect(createRes.contains("Created Apple Note"))
    }

    @Test("ContactsTool and MailTool perform contact lookup and email drafting")
    func contactsAndMailTools() async throws {
        let services = MockApplePlatformServices()
        let contactsTool = ContactsTool(service: services.contacts)
        let mailTool = MailTool(service: services.mail)

        let contactJSON = "{\"query\": \"Sarah Connor\"}"
        let contactRes = try await contactsTool.call(argumentsJSON: contactJSON)
        #expect(contactRes.contains("sarah@cyberdyne.com"))

        let mailJSON = "{\"action\": \"draft\", \"recipient\": \"sarah@cyberdyne.com\", \"subject\": \"Security Alert\", \"body\": \"Please inspect log.\"}"
        let mailRes = try await mailTool.call(argumentsJSON: mailJSON)
        #expect(mailRes.contains("Successfully created Mail draft"))
    }

    @Test("FilesTool, MapsTool, SystemControlTool, and TimerTool execute successfully")
    func filesMapsSystemTools() async throws {
        let services = MockApplePlatformServices()
        let filesTool = FilesTool(service: services.files)
        let mapsTool = MapsTool(service: services.maps)
        let systemTool = SystemControlTool(service: services.systemControl)
        let timerTool = TimerTool(service: services.systemControl)

        let writeJSON = "{\"action\": \"write\", \"path\": \"notes.txt\", \"content\": \"Agentic notes\"}"
        let writeRes = try await filesTool.call(argumentsJSON: writeJSON)
        #expect(writeRes.contains("Successfully saved"))

        let mapJSON = "{\"query\": \"Cupertino Coffee\"}"
        let mapRes = try await mapsTool.call(argumentsJSON: mapJSON)
        #expect(mapRes.contains("Infinite Loop"))

        let sysJSON = "{\"action\": \"getBattery\"}"
        let sysRes = try await systemTool.call(argumentsJSON: sysJSON)
        #expect(sysRes.contains("88%"))

        let timerJSON = "{\"durationSeconds\": 300, \"label\": \"Tea Brewing\"}"
        let timerRes = try await timerTool.call(argumentsJSON: timerJSON)
        #expect(timerRes.contains("300 seconds"))
    }

    @Test("Native platform adapters reject invalid requests before requesting access")
    func nativeAdaptersValidateRequests() async throws {
        let calendar = NativeCalendarService()
        do {
            _ = try await calendar.createEvent(
                title: "",
                startDate: Date(timeIntervalSince1970: 2),
                endDate: Date(timeIntervalSince1970: 1),
                location: nil,
                notes: nil
            )
            Issue.record("Expected invalid calendar input to be rejected.")
        } catch let error as ApplePlatformServiceError {
            guard case .invalidRequest = error else {
                Issue.record("Expected an invalid calendar request error, got: \(error)")
                return
            }
        }

        let contacts = NativeContactsService()
        do {
            _ = try await contacts.getContactDetails(name: " ")
            Issue.record("Expected an empty contact name to be rejected.")
        } catch let error as ApplePlatformServiceError {
            guard case .invalidRequest = error else {
                Issue.record("Expected an invalid contact request error, got: \(error)")
                return
            }
        }

        let maps = NativeMapsService()
        do {
            _ = try await maps.searchPlaces(query: " ", near: nil)
            Issue.record("Expected an empty map query to be rejected.")
        } catch let error as ApplePlatformServiceError {
            guard case .invalidRequest = error else {
                Issue.record("Expected an invalid map request error, got: \(error)")
                return
            }
        }
    }
}
