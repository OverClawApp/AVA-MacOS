import Foundation
import Contacts
import EventKit
import os

/// Handles desktop_pim (Personal Information Manager) commands: contacts, calendar, reminders.
/// Native access — more reliable than AppleScript for structured data.
struct PIMHandler {
    private let logger = Logger(subsystem: Constants.bundleID, category: "PIM")
    private let contactStore = CNContactStore()
    private let eventStore = EKEventStore()

    func handle(_ request: CommandRequest) async throws -> CommandResponse {
        let params = request.params ?? [:]

        switch request.action {
        case "search_contacts":
            return try await searchContacts(id: request.id, params: params)
        case "list_events":
            return try await listEvents(id: request.id, params: params)
        case "create_event":
            return try await createEvent(id: request.id, params: params)
        case "list_reminders":
            return try await listReminders(id: request.id, params: params)
        case "create_reminder":
            return try await createReminder(id: request.id, params: params)
        default:
            return .failure(id: request.id, code: "UNKNOWN_ACTION", message: "Unknown pim action: \(request.action)")
        }
    }

    // MARK: - Contacts

    private func searchContacts(id: String, params: [String: JSONValue]) async throws -> CommandResponse {
        let query = params["query"]?.stringValue ?? ""

        // Request access
        let granted = try await contactStore.requestAccess(for: .contacts)
        guard granted else {
            return .permissionMissing(id: id, permission: "Contacts")
        }

        let keysToFetch: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactJobTitleKey as CNKeyDescriptor,
        ]

        let request = CNContactFetchRequest(keysToFetch: keysToFetch)
        if !query.isEmpty {
            request.predicate = CNContact.predicateForContacts(matchingName: query)
        }

        var contacts: [JSONValue] = []
        try contactStore.enumerateContacts(with: request) { contact, stop in
            if contacts.count >= 20 { stop.pointee = true; return }

            let emails = contact.emailAddresses.map { $0.value as String }
            let phones = contact.phoneNumbers.map { $0.value.stringValue }

            contacts.append(.object([
                "name": .string("\(contact.givenName) \(contact.familyName)".trimmingCharacters(in: .whitespaces)),
                "emails": .array(emails.map { .string($0) }),
                "phones": .array(phones.map { .string($0) }),
                "company": .string(contact.organizationName),
                "title": .string(contact.jobTitle),
            ]))
        }

        return .success(id: id, payload: [
            "contacts": .array(contacts),
            "count": .int(contacts.count),
        ])
    }

    // MARK: - Calendar Events

    private func listEvents(id: String, params: [String: JSONValue]) async throws -> CommandResponse {
        let granted = try await eventStore.requestFullAccessToEvents()
        guard granted else {
            return .permissionMissing(id: id, permission: "Calendar")
        }

        let daysAhead = params["days"]?.intValue ?? 7
        let startDate = Date()
        let endDate = Calendar.current.date(byAdding: .day, value: daysAhead, to: startDate)!

        let predicate = eventStore.predicateForEvents(withStart: startDate, end: endDate, calendars: nil)
        let events = eventStore.events(matching: predicate)

        let items = events.prefix(30).map { event -> JSONValue in
            .object([
                "title": .string(event.title ?? ""),
                "start": .string(event.startDate.ISO8601Format()),
                "end": .string(event.endDate.ISO8601Format()),
                "location": .string(event.location ?? ""),
                "allDay": .bool(event.isAllDay),
                "calendar": .string(event.calendar.title),
            ])
        }

        return .success(id: id, payload: [
            "events": .array(items),
            "count": .int(items.count),
            "range": .string("\(daysAhead) days"),
        ])
    }

    private func createEvent(id: String, params: [String: JSONValue]) async throws -> CommandResponse {
        let granted = try await eventStore.requestFullAccessToEvents()
        guard granted else {
            return .permissionMissing(id: id, permission: "Calendar")
        }

        guard let title = params["title"]?.stringValue else {
            return .failure(id: id, code: "MISSING_PARAM", message: "title is required")
        }

        let event = EKEvent(eventStore: eventStore)
        event.title = title
        event.calendar = eventStore.defaultCalendarForNewEvents

        if let startStr = params["start"]?.stringValue {
            let formatter = ISO8601DateFormatter()
            event.startDate = formatter.date(from: startStr) ?? Date()
        } else {
            event.startDate = Date()
        }

        let durationMinutes = params["duration"]?.intValue ?? 60
        event.endDate = event.startDate.addingTimeInterval(TimeInterval(durationMinutes * 60))

        if let location = params["location"]?.stringValue {
            event.location = location
        }

        try eventStore.save(event, span: .thisEvent)

        return .success(id: id, payload: [
            "created": .string(title),
            "start": .string(event.startDate.ISO8601Format()),
            "end": .string(event.endDate.ISO8601Format()),
        ])
    }

    // MARK: - Reminders

    private func listReminders(id: String, params: [String: JSONValue]) async throws -> CommandResponse {
        let granted = try await eventStore.requestFullAccessToReminders()
        guard granted else {
            return .permissionMissing(id: id, permission: "Reminders")
        }

        let predicate = eventStore.predicateForReminders(in: nil)

        return await withCheckedContinuation { continuation in
            eventStore.fetchReminders(matching: predicate) { reminders in
                let items = (reminders ?? [])
                    .filter { !$0.isCompleted }
                    .prefix(30)
                    .map { reminder -> JSONValue in
                        .object([
                            "title": .string(reminder.title ?? ""),
                            "completed": .bool(reminder.isCompleted),
                            "priority": .int(reminder.priority),
                            "dueDate": .string(reminder.dueDateComponents?.date?.ISO8601Format() ?? ""),
                            "list": .string(reminder.calendar.title),
                        ])
                    }

                continuation.resume(returning: .success(id: id, payload: [
                    "reminders": .array(items),
                    "count": .int(items.count),
                ]))
            }
        }
    }

    private func createReminder(id: String, params: [String: JSONValue]) async throws -> CommandResponse {
        let granted = try await eventStore.requestFullAccessToReminders()
        guard granted else {
            return .permissionMissing(id: id, permission: "Reminders")
        }

        guard let title = params["title"]?.stringValue else {
            return .failure(id: id, code: "MISSING_PARAM", message: "title is required")
        }

        let reminder = EKReminder(eventStore: eventStore)
        reminder.title = title
        reminder.calendar = eventStore.defaultCalendarForNewReminders()

        if let dueDateStr = params["dueDate"]?.stringValue {
            let formatter = ISO8601DateFormatter()
            if let date = formatter.date(from: dueDateStr) {
                reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            }
        }

        if let priority = params["priority"]?.intValue {
            reminder.priority = priority
        }

        try eventStore.save(reminder, commit: true)

        return .success(id: id, payload: [
            "created": .string(title),
        ])
    }
}
