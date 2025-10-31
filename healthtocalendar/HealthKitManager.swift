import Foundation
import HealthKit
import Combine

@MainActor
final class HealthKitManager: ObservableObject {
	@Published private(set) var authorizationStatus: HKAuthorizationStatus = .notDetermined
	@Published private(set) var workouts: [WorkoutItem] = []
	@Published private(set) var isLoading: Bool = false
	@Published private(set) var lastError: Error?

	private let healthStore = HKHealthStore()
	private var cancellables: Set<AnyCancellable> = []

	var isHealthDataAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

	func requestAuthorizationIfNeeded() async throws {
		guard isHealthDataAvailable else { return }
		let readTypes: Set<HKObjectType> = [
			HKObjectType.workoutType(),
			HKObjectType.quantityType(forIdentifier: .heartRate)!
		]
		try await healthStore.requestAuthorization(toShare: [], read: readTypes)
		self.authorizationStatus = self.healthStore.authorizationStatus(for: HKObjectType.workoutType())
	}

	func refreshAuthorizationStatus() {
		authorizationStatus = healthStore.authorizationStatus(for: HKObjectType.workoutType())
	}

	func loadRecentWorkouts(monthsBack: Int = 3) async {
		await MainActor.run { self.isLoading = true; self.lastError = nil }
		do {
			let endDate = Date()
			let startDate = Calendar.current.date(byAdding: .month, value: -monthsBack, to: endDate) ?? Date.distantPast
			let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: [])
			let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
			let hkWorkouts: [HKWorkout] = try await queryWorkouts(predicate: predicate, sortDescriptors: [sort])
			
			// First, load workouts without HR stats for immediate display
			let itemsWithoutHR = await MainActor.run {
				hkWorkouts.map { WorkoutItem(workout: $0) }
			}
			await MainActor.run { self.workouts = itemsWithoutHR }
			
			// Then, fetch HR stats in background for first 50 workouts only (to avoid too many queries)
			let workoutsToEnrich = Array(hkWorkouts.prefix(50))
			let enrichedMap: [String: WorkoutItem] = try await withThrowingTaskGroup(of: (String, WorkoutItem).self) { group in
				for workout in workoutsToEnrich {
					group.addTask { [weak self] in
						let workoutId = workout.uuid.uuidString
						guard let self else {
							let item = await MainActor.run { WorkoutItem(workout: workout) }
							return (workoutId, item)
						}
						let hr = try? await self.fetchHeartRateStats(for: workout)
						let item = await MainActor.run {
							WorkoutItem(workout: workout, averageHeartRate: hr?.average, maximumHeartRate: hr?.maximum)
						}
						return (workoutId, item)
					}
				}
				var results: [String: WorkoutItem] = [:]
				for try await (id, item) in group { results[id] = item }
				return results
			}
			
			// Update with enriched data, keeping the rest as-is
			await MainActor.run {
				self.workouts = self.workouts.map { item in
					enrichedMap[item.id] ?? item
				}
			}
		} catch {
			await MainActor.run { self.lastError = error }
		}
		await MainActor.run { self.isLoading = false }
	}

	private func queryWorkouts(predicate: NSPredicate?, sortDescriptors: [NSSortDescriptor]?, limit: Int = 100) async throws -> [HKWorkout] {
		try await withCheckedThrowingContinuation { continuation in
			let query = HKSampleQuery(sampleType: .workoutType(), predicate: predicate, limit: limit, sortDescriptors: sortDescriptors) { _, samples, error in
				if let error { continuation.resume(throwing: error); return }
				let workouts = samples as? [HKWorkout] ?? []
				continuation.resume(returning: workouts)
			}
			healthStore.execute(query)
		}
	}

	private func fetchHeartRateStats(for workout: HKWorkout) async throws -> (average: Double, maximum: Double)? {
		guard let hrType = HKObjectType.quantityType(forIdentifier: .heartRate) else { return nil }
		let predicate = HKQuery.predicateForSamples(withStart: workout.startDate, end: workout.endDate, options: .strictStartDate)
		return try await withCheckedThrowingContinuation { continuation in
			let query = HKStatisticsQuery(quantityType: hrType, quantitySamplePredicate: predicate, options: [.discreteAverage, .discreteMax]) { _, statistics, error in
				if let error { continuation.resume(throwing: error); return }
				guard let statistics else { continuation.resume(returning: nil); return }
				let avg = statistics.averageQuantity()?.doubleValue(for: HKUnit(from: "count/min"))
				let max = statistics.maximumQuantity()?.doubleValue(for: HKUnit(from: "count/min"))
				if let avg, let max { continuation.resume(returning: (avg, max)) } else { continuation.resume(returning: nil) }
			}
			healthStore.execute(query)
		}
	}
}

