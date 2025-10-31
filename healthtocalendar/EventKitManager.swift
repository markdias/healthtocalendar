import Foundation
import EventKit
import SwiftUI
import Combine
import HealthKit

@MainActor
final class EventKitManager: ObservableObject {
	@Published private(set) var authorizationStatus: EKAuthorizationStatus = .notDetermined
        @Published private(set) var calendars: [EKCalendar] = []
        @Published var exportedWorkoutIDs: Set<String> = []
	@Published private(set) var lastError: Error?

	let eventStore = EKEventStore()

	func requestAccessIfNeeded() async throws {
		let status = EKEventStore.authorizationStatus(for: .event)
		await MainActor.run { self.authorizationStatus = status }
		
		if status == .denied || status == .restricted {
			throw NSError(domain: "EventKit", code: 1, userInfo: [NSLocalizedDescriptionKey: "Calendar access denied. Enable access in Settings → Privacy & Security → Calendars."])
		}
		
		if status == .notDetermined {
			let granted = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
				self.eventStore.requestFullAccessToEvents { granted, error in
					if let error { continuation.resume(throwing: error); return }
					continuation.resume(returning: granted)
				}
			}
			await MainActor.run { self.authorizationStatus = EKEventStore.authorizationStatus(for: .event) }
			if !granted { 
				throw NSError(domain: "EventKit", code: 1, userInfo: [NSLocalizedDescriptionKey: "Calendar access denied. Enable access in Settings → Privacy & Security → Calendars."])
			}
		}
	}

	func reloadCalendars() {
		self.calendars = eventStore.calendars(for: .event).sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
	}

        func saveOrUpdateEvent(for item: WorkoutItem, in calendar: EKCalendar) throws -> EKEvent {
                let existing = findExistingEvent(for: item, in: [calendar])
                let event = existing ?? EKEvent(eventStore: eventStore)
                event.calendar = calendar
                event.title = makeTitle(for: item)
                event.startDate = item.startDate
                event.endDate = item.endDate
                event.notes = makeNotes(for: item)
                try eventStore.save(event, span: .thisEvent, commit: true)
                return event
        }

        func refreshExportedWorkouts(from workouts: [WorkoutItem]) {
                let status = EKEventStore.authorizationStatus(for: .event)
                self.authorizationStatus = status
                guard isReadable(status: status) else {
                        exportedWorkoutIDs = []
                        return
                }

                let calendars = eventStore.calendars(for: .event)
                var exported: Set<String> = []
                for workout in workouts {
                        if findExistingEvent(for: workout, in: calendars) != nil {
                                exported.insert(workout.id)
                        }
                }
                exportedWorkoutIDs = exported
        }

	private func makeTitle(for item: WorkoutItem) -> String {
		"Workout – \(item.workoutActivityType.displayName) (\(item.duration.formattedHMS()))"
	}

	private func makeNotes(for item: WorkoutItem) -> String {
		var lines: [String] = []
		lines.append("Type: \(item.workoutActivityType.displayName)")
		lines.append("Duration: \(item.duration.formattedHMS())")
		if let distance = item.totalDistance?.converted(to: .kilometers) {
			lines.append(String(format: "Distance: %.2f km", distance.value))
		}
		if let energy = item.totalEnergyBurned?.converted(to: .kilocalories) {
			lines.append(String(format: "Energy: %.0f kcal", energy.value))
		}
		if let avg = item.averageHeartRate { lines.append(String(format: "Avg HR: %.0f bpm", avg)) }
		if let max = item.maximumHeartRate { lines.append(String(format: "Max HR: %.0f bpm", max)) }
		lines.append("—")
		lines.append(signatureLine(for: item))
		return lines.joined(separator: "\n")
	}

	private func signatureLine(for item: WorkoutItem) -> String {
		// Signature to uniquely identify events created by this app for update matching
		"HTC_ID=\(item.id) START=\(Int(item.startDate.timeIntervalSince1970)) DURATION=\(Int(item.duration)) TYPE=\(item.workoutActivityType.rawValue)"
	}

        private func findExistingEvent(for item: WorkoutItem, in calendars: [EKCalendar]) -> EKEvent? {
                // First try to find by signature in notes
                let timeWindowStart = item.startDate.addingTimeInterval(-5 * 60)
                let timeWindowEnd = item.endDate.addingTimeInterval(5 * 60)
                let predicate = eventStore.predicateForEvents(withStart: timeWindowStart, end: timeWindowEnd, calendars: calendars)
                let events = eventStore.events(matching: predicate)
                let signature = signatureLine(for: item)
                if let bySignature = events.first(where: { $0.notes?.contains(signature) == true }) {
                        return bySignature
                }
		// Fallback: match by duration and title type within window
		return events.first(where: { event in
			let durationMatches = abs(event.endDate.timeIntervalSince(event.startDate) - item.duration) < 60
			let titleContainsType = (event.title ?? "").localizedCaseInsensitiveContains(item.workoutActivityType.displayName)
			return durationMatches && titleContainsType
		})
        }

        private func isReadable(status: EKAuthorizationStatus) -> Bool {
                if #available(iOS 17.0, *) {
                        return status == .authorized || status == .fullAccess
                } else {
                        return status == .authorized
                }
        }
}

struct CalendarPickerView: View {
	@ObservedObject var manager: EventKitManager
	@Binding var selectedCalendar: EKCalendar?
	@Environment(\.dismiss) private var dismiss

	var body: some View {
		NavigationView {
			List(manager.calendars, id: \.calendarIdentifier) { calendar in
				HStack {
					Text(calendar.title)
					Spacer()
					if selectedCalendar?.calendarIdentifier == calendar.calendarIdentifier { Image(systemName: "checkmark") }
				}
				.contentShape(Rectangle())
				.onTapGesture { selectedCalendar = calendar }
			}
			.navigationTitle("Choose Calendar")
			.toolbar {
				ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
				ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
			}
		}
		.onAppear {
			manager.reloadCalendars()
		}
	}
}

