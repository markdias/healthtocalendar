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

    @State private var selectedWorkoutIds: Set<String> = []
    @State private var isCalendarPickerPresented: Bool = false
    @State private var chosenCalendar: EKCalendar?
    @State private var isExporting: Bool = false
    @State private var exportResultMessage: String?
    @State private var isShowingExportAlert: Bool = false

    var body: some View {
        NavigationView {
            content
            .navigationTitle("Workouts")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Select All") { selectAll() }
                        .disabled(healthKitManager.workouts.isEmpty)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Export") { Task { await exportSelected() } }
                    .disabled(selectedWorkoutIds.isEmpty)
                }
            }
            .sheet(isPresented: $isCalendarPickerPresented, onDismiss: {
                Task { await performExportIfReady() }
            }) {
                CalendarPickerView(manager: eventKitManager, selectedCalendar: $chosenCalendar)
            }
            .alert("Export", isPresented: $isShowingExportAlert) {
                Button("OK", role: .cancel) { exportResultMessage = nil }
            } message: {
                Text(exportResultMessage ?? "")
            }
            .task {
                healthKitManager.refreshAuthorizationStatus()
                // Always try to load workouts - if it succeeds, we have access
                await healthKitManager.loadRecentWorkouts()
            }
            .onChange(of: scenePhase) {
                if scenePhase == .active {
                    Task { @MainActor in
                        healthKitManager.refreshAuthorizationStatus()
                        // Try to load workouts - if it succeeds, we have access regardless of status
                        await healthKitManager.loadRecentWorkouts()
                    }
                }
            }
        }
    }

    private var content: some View {
        Group {
            if !healthKitManager.isHealthDataAvailable {
                Text("Health data not available on this device.")
                    .multilineTextAlignment(.center)
                    .padding()
            } else if !healthKitManager.workouts.isEmpty {
                // Show workouts if we have any loaded (regardless of status)
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
            } else {
                // .notDetermined
                VStack(spacing: 16) {
                    Text("This app needs access to your Health data to work correctly.")
                        .font(.headline)
                        .multilineTextAlignment(.center)
                    Text("Tap Open Settings below, then turn on Health permissions.")
                        .multilineTextAlignment(.center)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                    Button("Connect to Health") {
                        Task { @MainActor in
                            // Small delay to let button animation complete and UI settle
                            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
                            do {
                                try await healthKitManager.requestAuthorizationIfNeeded()
                                healthKitManager.refreshAuthorizationStatus()
                                await healthKitManager.loadRecentWorkouts()
                            } catch {
                                // no-op
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    Button {
                        // Try to open Settings app (opens general Settings, user navigates from there)
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            openURL(url)
                        }
                    } label: {
                        Text("Open Settings")
                    }
                }
                .padding()
            }
        }
    }

    private var workoutsList: some View {
        Group {
            if healthKitManager.workouts.isEmpty {
                VStack(spacing: 12) {
                    if healthKitManager.isLoading {
                        ProgressView("Loading workouts…")
                    } else {
                        Text("No workouts found.")
                            .foregroundStyle(.secondary)
                        Button("Refresh") { Task { await healthKitManager.loadRecentWorkouts() } }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(healthKitManager.workouts) { item in
                        WorkoutRow(
                            item: item,
                            isSelected: selectedWorkoutIds.contains(item.id)
                        )
                        .contentShape(Rectangle())
                        .onTapGesture { toggleSelection(for: item.id) }
                    }
                }
            }
        }
    }

    private func toggleSelection(for id: String) {
        if selectedWorkoutIds.contains(id) { selectedWorkoutIds.remove(id) } else { selectedWorkoutIds.insert(id) }
    }

    private func selectAll() {
        selectedWorkoutIds = Set(healthKitManager.workouts.map { $0.id })
    }

    @MainActor
    private func exportSelected() async {
        guard !selectedWorkoutIds.isEmpty else { return }
        do {
            try await eventKitManager.requestAccessIfNeeded()
            eventKitManager.reloadCalendars()
            guard !eventKitManager.calendars.isEmpty else {
                exportResultMessage = "No calendars available. Please create a calendar in the Calendar app first."
                isShowingExportAlert = true
                return
            }
            if chosenCalendar == nil { chosenCalendar = eventKitManager.calendars.first }
            isCalendarPickerPresented = true
        } catch {
            let errorMsg = (error as NSError).userInfo[NSLocalizedDescriptionKey] as? String ?? error.localizedDescription
            exportResultMessage = errorMsg.isEmpty ? "Calendar access denied or failed." : errorMsg
            isShowingExportAlert = true
        }
    }

    @MainActor
    private func performExportIfReady() async {
        guard let calendar = chosenCalendar, !selectedWorkoutIds.isEmpty else { return }
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
        isShowingExportAlert = true
    }
}

private struct WorkoutRow: View {
    let item: WorkoutItem
    let isSelected: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(titleText)
                    .font(.headline)
                Text(timeRangeText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    if let distanceText = distanceText { Text(distanceText).font(.caption).foregroundStyle(.secondary) }
                    if let energyText = energyText { Text(energyText).font(.caption).foregroundStyle(.secondary) }
                    if let avgHRText = avgHRText { Text(avgHRText).font(.caption).foregroundStyle(.secondary) }
                }
            }
            Spacer()
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundColor(isSelected ? Color.accentColor : Color.secondary)
        }
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
}


#Preview {
    ContentView()
}
