//
//  ContentView.swift
//  healthtocalendar
//
//  Created by Mark Dias on 30/10/2025.
//

import SwiftUI
import CoreData
import HealthKit
import EventKit
import UIKit

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @StateObject private var healthKitManager = HealthKitManager()
    @StateObject private var eventKitManager = EventKitManager()

    @AppStorage("htc_default_calendar_id") private var storedCalendarIdentifier: String?
    @AppStorage("htc_workout_lookback") private var storedLookbackRawValue: String = WorkoutLookback.default.rawValue

    @State private var selectedWorkoutIds: Set<String> = []
    @State private var chosenCalendar: EKCalendar?
    @State private var exportResultMessage: String?
    @State private var isShowingExportAlert: Bool = false
    @State private var isExportCalendarPickerPresented: Bool = false
    @State private var isSettingsPresented: Bool = false

    var body: some View {
        NavigationView {
            content
            .navigationTitle("Workouts")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Select All") { selectAll() }
                        .disabled(visibleWorkouts.isEmpty)
                }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button {
                        isSettingsPresented = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")

                    Button("Export") { Task { await exportSelected() } }
                    .disabled(selectedWorkoutIds.isEmpty)
                }
            }
            .sheet(isPresented: $isExportCalendarPickerPresented) {
                CalendarPickerView(
                    manager: eventKitManager,
                    selectedCalendar: Binding(
                        get: { chosenCalendar },
                        set: { chosenCalendar = $0 }
                    ),
                    onFinish: { calendar in
                        guard let calendar else { return }
                        storedCalendarIdentifier = calendar.calendarIdentifier
                        Task { await performExport(to: calendar) }
                    }
                )
            }
            .sheet(isPresented: $isSettingsPresented) {
                SettingsView(
                    eventKitManager: eventKitManager,
                    selectedCalendar: Binding(
                        get: { chosenCalendar },
                        set: { newValue in
                            chosenCalendar = newValue
                            storedCalendarIdentifier = newValue?.calendarIdentifier
                        }
                    ),
                    lookbackSelection: Binding(
                        get: { lookbackSelection },
                        set: { newValue in
                            lookbackSelection = newValue
                            Task { await refreshAllData() }
                        }
                    ),
                    openSettings: openSettingsApp
                )
            }
            .alert("Export", isPresented: $isShowingExportAlert) {
                Button("OK", role: .cancel) { exportResultMessage = nil }
            } message: {
                Text(exportResultMessage ?? "")
            }
            .task {
                await ensureHealthAccessAndRefresh()
            }
            .onChange(of: scenePhase) {
                if scenePhase == .active {
                    Task {
                        await ensureHealthAccessAndRefresh()
                    }
                }
            }
            .onChange(of: eventKitManager.exportedWorkoutIDs) { _ in
                pruneSelections()
            }
            .onChange(of: healthKitManager.workouts) { _ in
                pruneSelections()
            }
        }
    }

    private var lookbackSelection: WorkoutLookback {
        get { WorkoutLookback(rawValue: storedLookbackRawValue) ?? .default }
        set { storedLookbackRawValue = newValue.rawValue }
    }

    private func openSettingsApp() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            openURL(url)
        }
    }

    @MainActor
    private func refreshAllData() async {
        await healthKitManager.loadRecentWorkouts(monthsBack: lookbackSelection.monthsBack)
        await refreshExportedWorkouts(for: healthKitManager.workouts)
    }

    @MainActor
    private func syncChosenCalendarWithStorage() {
        if let storedCalendarIdentifier,
           let match = eventKitManager.calendars.first(where: { $0.calendarIdentifier == storedCalendarIdentifier }) {
            chosenCalendar = match
        } else if let existing = chosenCalendar,
                  eventKitManager.calendars.contains(where: { $0.calendarIdentifier == existing.calendarIdentifier }) {
            chosenCalendar = existing
        } else {
            chosenCalendar = nil
        }
    }

    private var content: some View {
        Group {
            if !healthKitManager.isHealthDataAvailable {
                Text("Health data not available on this device.")
                    .multilineTextAlignment(.center)
                    .padding()
            } else if !visibleWorkouts.isEmpty {
                workoutsList
            } else if healthKitManager.isLoading {
                VStack(spacing: 16) {
                    ProgressView("Loading workouts…")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if healthKitManager.authorizationStatus == .sharingDenied {
                VStack(spacing: 20) {
                    Text("Health permissions are off.")
                        .font(.headline)
                    VStack(spacing: 12) {
                        Text("To enable Health access:")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        VStack(alignment: .leading, spacing: 8) {
                            Text("1. Open the Settings app")
                            Text("2. Tap Privacy & Security")
                            Text("3. Tap Health")
                            Text("4. Tap healthtocalendar")
                            Text("5. Turn on Workouts")
                        }
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .background(Color(.systemGray6))
                        .cornerRadius(8)
                    }
                    Button {
                        // Try to open Settings app (opens general Settings, user navigates from there)
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            openURL(url)
                        }
                    } label: {
                        Text("Open Settings App")
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
            } else if healthKitManager.authorizationStatus == .notDetermined {
                VStack(spacing: 20) {
                    ProgressView("Requesting Health access…")
                    Text("Approve the Health permissions prompt to load your recent workouts.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                .padding()
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 44))
                        .foregroundColor(.accentColor)
                    Text("You're all caught up!")
                        .font(.headline)
                    Text("Every recent workout is already on your calendar.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var workoutsList: some View {
        Group {
            List {
                if !isEventAccessGranted {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Calendar access is limited")
                                .font(.headline)
                            Text("Grant calendar access to hide workouts that are already scheduled.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Button("Open Settings") {
                                if let url = URL(string: UIApplication.openSettingsURLString) {
                                    openURL(url)
                                }
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding(.vertical, 4)
                    }
                }

                ForEach(groupedWorkouts) { group in
                    Section(header: MonthHeader(title: group.title, workoutCount: group.workouts.count)) {
                        ForEach(group.workouts) { item in
                            WorkoutRow(
                                item: item,
                                isSelected: selectedWorkoutIds.contains(item.id)
                            )
                            .contentShape(Rectangle())
                            .onTapGesture { toggleSelection(for: item.id) }
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                        }
                    }
                    .textCase(nil)
                }

                if !healthKitManager.isLoading && visibleWorkouts.isEmpty {
                    Section {
                        VStack(spacing: 12) {
                            Image(systemName: "party.popper")
                                .font(.system(size: 32))
                                .foregroundColor(.accentColor)
                            Text("Nothing left to export")
                                .font(.headline)
                            Text("Every recent workout is already on your calendar.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color(.systemGroupedBackground))
        }
    }

    private func toggleSelection(for id: String) {
        guard visibleWorkoutIDs.contains(id) else { return }
        if selectedWorkoutIds.contains(id) { selectedWorkoutIds.remove(id) } else { selectedWorkoutIds.insert(id) }
    }

    private func selectAll() {
        selectedWorkoutIds = visibleWorkoutIDs
    }

    @MainActor
    private func exportSelected() async {
        guard !selectedWorkoutIds.isEmpty else { return }
        do {
            try await eventKitManager.requestAccessIfNeeded()
            eventKitManager.reloadCalendars()
            syncChosenCalendarWithStorage()
            guard !eventKitManager.calendars.isEmpty else {
                exportResultMessage = "No calendars available. Please create a calendar in the Calendar app first."
                isShowingExportAlert = true
                return
            }
            if let storedCalendarIdentifier,
               let defaultCalendar = eventKitManager.calendars.first(where: { $0.calendarIdentifier == storedCalendarIdentifier }) {
                chosenCalendar = defaultCalendar
                await performExport(to: defaultCalendar)
            } else {
                if chosenCalendar == nil {
                    chosenCalendar = eventKitManager.calendars.first
                }
                isExportCalendarPickerPresented = true
            }
        } catch {
            let errorMsg = (error as NSError).userInfo[NSLocalizedDescriptionKey] as? String ?? error.localizedDescription
            exportResultMessage = errorMsg.isEmpty ? "Calendar access denied or failed." : errorMsg
            isShowingExportAlert = true
        }
    }

    @MainActor
    private func performExport(to calendar: EKCalendar) async {
        guard !selectedWorkoutIds.isEmpty else { return }
        let selected = healthKitManager.workouts.filter { selectedWorkoutIds.contains($0.id) }
        var createdOrUpdated = 0
        var errors: [String] = []
        for item in selected {
            do {
                _ = try eventKitManager.saveOrUpdateEvent(for: item, in: calendar)
                createdOrUpdated += 1
            } catch {
                let errorMsg = (error as NSError).userInfo[NSLocalizedDescriptionKey] as? String ?? error.localizedDescription
                errors.append(errorMsg)
            }
        }
        if createdOrUpdated == selected.count {
            exportResultMessage = "Exported \(createdOrUpdated) event(s) to '\(calendar.title)'."
        } else if createdOrUpdated > 0 {
            exportResultMessage = "Exported \(createdOrUpdated) of \(selected.count) event(s) to '\(calendar.title)'. Some failed."
        } else {
            let errorMsg = errors.first ?? "Failed to export events. Check calendar permissions."
            exportResultMessage = errorMsg
        }
        if createdOrUpdated > 0 {
            eventKitManager.exportedWorkoutIDs.formUnion(selected.map { $0.id })
        }
        storedCalendarIdentifier = calendar.calendarIdentifier
        chosenCalendar = calendar
        eventKitManager.refreshExportedWorkouts(from: healthKitManager.workouts)
        pruneSelections()
        isShowingExportAlert = true
    }

    @MainActor
    private func ensureHealthAccessAndRefresh() async {
        healthKitManager.refreshAuthorizationStatus()
        if healthKitManager.authorizationStatus == .notDetermined {
            try? await healthKitManager.requestAuthorizationIfNeeded()
            healthKitManager.refreshAuthorizationStatus()
        }
        await refreshAllData()
    }

    @MainActor
    private func refreshExportedWorkouts(for workouts: [WorkoutItem]) async {
        do {
            try await eventKitManager.requestAccessIfNeeded()
        } catch {
            eventKitManager.exportedWorkoutIDs = []
            pruneSelections()
            return
        }
        eventKitManager.reloadCalendars()
        syncChosenCalendarWithStorage()
        guard !workouts.isEmpty else {
            eventKitManager.exportedWorkoutIDs = []
            pruneSelections()
            return
        }
        eventKitManager.refreshExportedWorkouts(from: workouts)
        pruneSelections()
    }

    @MainActor
    private func pruneSelections() {
        selectedWorkoutIds = selectedWorkoutIds.intersection(visibleWorkoutIDs)
    }

    private var visibleWorkouts: [WorkoutItem] {
        healthKitManager.workouts
            .filter { !eventKitManager.exportedWorkoutIDs.contains($0.id) }
            .sorted { $0.startDate > $1.startDate }
    }

    private var visibleWorkoutIDs: Set<String> {
        Set(visibleWorkouts.map { $0.id })
    }

    private var groupedWorkouts: [MonthGroup] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: visibleWorkouts) { workout -> Date in
            let components = calendar.dateComponents([.year, .month], from: workout.startDate)
            return calendar.date(from: components) ?? workout.startDate
        }
        return grouped.map { key, workouts in
            let sorted = workouts.sorted { $0.startDate > $1.startDate }
            return MonthGroup(date: key, workouts: sorted)
        }
        .sorted { $0.date > $1.date }
    }

    private var isEventAccessGranted: Bool {
        if #available(iOS 17.0, *) {
            return eventKitManager.authorizationStatus == .fullAccess || eventKitManager.authorizationStatus == .authorized
        } else {
            return eventKitManager.authorizationStatus == .authorized
        }
    }

    private struct MonthGroup: Identifiable {
        let date: Date
        let workouts: [WorkoutItem]

        var id: Date { date }

        var title: String {
            MonthGroup.monthFormatter.string(from: date)
        }

        private static let monthFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateFormat = "LLLL yyyy"
            return formatter
        }()
    }
}

private struct WorkoutRow: View {
    let item: WorkoutItem
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(titleText)
                        .font(.headline)
                    Text(timeRangeText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isSelected ? Color.accentColor : Color.secondary)
                    .font(.title3)
            }

            if hasSupplementaryMetrics {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        if let distanceText = distanceText { TagView(text: distanceText, systemImage: "map") }
                        if let energyText = energyText { TagView(text: energyText, systemImage: "flame") }
                        if let avgHRText = avgHRText { TagView(text: avgHRText, systemImage: "heart") }
                    }
                    .padding(.horizontal, 2)
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private var titleText: String {
        "\(item.workoutActivityType.displayName) · \(item.duration.formattedHMS())"
    }

    private var timeRangeText: String {
        let start = item.startDate.formatted(date: .abbreviated, time: .shortened)
        let end = item.endDate.formatted(date: .omitted, time: .shortened)
        return "\(start) – \(end)"
    }

    private var distanceText: String? {
        guard let distance = item.totalDistance?.converted(to: .kilometers) else { return nil }
        return String(format: "%.2f km", distance.value)
    }

    private var energyText: String? {
        guard let energy = item.totalEnergyBurned?.converted(to: .kilocalories) else { return nil }
        return String(format: "%.0f kcal", energy.value)
    }

    private var avgHRText: String? {
        guard let avg = item.averageHeartRate else { return nil }
        return String(format: "Avg %.0f bpm", avg)
    }

    private var hasSupplementaryMetrics: Bool {
        distanceText != nil || energyText != nil || avgHRText != nil
    }
}

private struct MonthHeader: View {
    let title: String
    let workoutCount: Int

    var body: some View {
        HStack {
            Text(title)
                .font(.title3)
                .fontWeight(.semibold)
            Spacer()
            Text("\(workoutCount) \(workoutCount == 1 ? "workout" : "workouts")")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

private struct TagView: View {
    let text: String
    let systemImage: String

    var body: some View {
        Label {
            Text(text)
                .font(.caption)
        } icon: {
            Image(systemName: systemImage)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous)
                .fill(Color.accentColor.opacity(0.12))
        )
        .foregroundColor(Color.accentColor)
    }
}

struct SettingsView: View {
    @ObservedObject var eventKitManager: EventKitManager
    @Binding var selectedCalendar: EKCalendar?
    @Binding var lookbackSelection: WorkoutLookback
    let openSettings: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isCalendarPickerPresented: Bool = false

    private var isCalendarAccessGranted: Bool {
        if #available(iOS 17.0, *) {
            return eventKitManager.authorizationStatus == .fullAccess || eventKitManager.authorizationStatus == .authorized
        } else {
            return eventKitManager.authorizationStatus == .authorized
        }
    }

    private var selectedCalendarTitle: String {
        selectedCalendar?.title ?? "Choose…"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Workout history") {
                    Picker("Show workouts from", selection: $lookbackSelection) {
                        ForEach(WorkoutLookback.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    Text(lookbackSelection.detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Default calendar") {
                    if !isCalendarAccessGranted {
                        Text("Calendar access is required to manage your default calendar. Enable it in Settings.")
                            .foregroundStyle(.secondary)
                        Button("Open Settings App", action: openSettings)
                    } else if eventKitManager.calendars.isEmpty {
                        Text("No writable calendars available. Create one in the Calendar app, then return here to select it.")
                            .foregroundStyle(.secondary)
                    } else {
                        Button {
                            isCalendarPickerPresented = true
                        } label: {
                            HStack {
                                Text("Calendar")
                                Spacer()
                                Text(selectedCalendarTitle)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)

                        Text("Workouts export straight into this calendar automatically. Change it here anytime.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                do {
                    try await eventKitManager.requestAccessIfNeeded()
                    eventKitManager.reloadCalendars()
                } catch {
                    // Ignore errors here; the UI will show messaging above.
                }
            }
            .sheet(isPresented: $isCalendarPickerPresented) {
                CalendarPickerView(
                    manager: eventKitManager,
                    selectedCalendar: $selectedCalendar,
                    onFinish: { calendar in
                        if let calendar { selectedCalendar = calendar }
                        isCalendarPickerPresented = false
                    }
                )
            }
        }
    }
}

enum WorkoutLookback: String, CaseIterable, Identifiable {
    case threeMonths = "3m"
    case sixMonths = "6m"
    case twelveMonths = "12m"
    case allHistory = "all"

    static let `default`: WorkoutLookback = .sixMonths

    var id: String { rawValue }

    var title: String {
        switch self {
        case .threeMonths:
            return "Past 3 months"
        case .sixMonths:
            return "Past 6 months"
        case .twelveMonths:
            return "Past 12 months"
        case .allHistory:
            return "All workouts"
        }
    }

    var detail: String {
        switch self {
        case .threeMonths:
            return "Great for keeping recent training sessions in view without overwhelming lists."
        case .sixMonths:
            return "Covers roughly half a year's workouts—ideal for seasonal planning."
        case .twelveMonths:
            return "Review an entire year of activity before exporting."
        case .allHistory:
            return "Show every workout saved in Apple Health, no matter how old."
        }
    }

    var monthsBack: Int? {
        switch self {
        case .threeMonths:
            return 3
        case .sixMonths:
            return 6
        case .twelveMonths:
            return 12
        case .allHistory:
            return nil
        }
    }
}


#Preview {
    ContentView()
}
