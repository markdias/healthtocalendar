import Foundation
import HealthKit

struct WorkoutItem: Identifiable, Hashable {
	let id: String
	let startDate: Date
	let endDate: Date
	let workoutActivityType: HKWorkoutActivityType
	let duration: TimeInterval
	let totalDistance: Measurement<UnitLength>?
	let totalEnergyBurned: Measurement<UnitEnergy>?
	let averageHeartRate: Double?
	let maximumHeartRate: Double?

	init(workout: HKWorkout, averageHeartRate: Double? = nil, maximumHeartRate: Double? = nil) {
		self.id = workout.uuid.uuidString
		self.startDate = workout.startDate
		self.endDate = workout.endDate
		self.workoutActivityType = workout.workoutActivityType
		self.duration = workout.duration
		if let distance = workout.totalDistance?.doubleValue(for: .meter()) {
			self.totalDistance = Measurement(value: distance, unit: UnitLength.meters)
		} else {
			self.totalDistance = nil
		}
		if #available(iOS 18.0, *) {
			if let type = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned),
			   let sum = workout.statistics(for: type)?.sumQuantity()?.doubleValue(for: .kilocalorie()) {
				self.totalEnergyBurned = Measurement(value: sum, unit: UnitEnergy.kilocalories)
			} else {
				self.totalEnergyBurned = nil
			}
		} else {
			if let energy = workout.totalEnergyBurned?.doubleValue(for: .kilocalorie()) {
				self.totalEnergyBurned = Measurement(value: energy, unit: UnitEnergy.kilocalories)
			} else {
				self.totalEnergyBurned = nil
			}
		}
		self.averageHeartRate = averageHeartRate
		self.maximumHeartRate = maximumHeartRate
	}
}

extension HKWorkoutActivityType {
	var displayName: String {
		switch self {
		case .running: return "Running"
		case .walking: return "Walking"
		case .cycling: return "Cycling"
		case .yoga: return "Yoga"
		case .traditionalStrengthTraining: return "Strength Training"
		case .swimming: return "Swimming"
		case .highIntensityIntervalTraining: return "HIIT"
		default: return String(describing: self)
		}
	}
}

extension TimeInterval {
	func formattedHMS() -> String {
		let totalSeconds = Int(self.rounded())
		let hours = totalSeconds / 3600
		let minutes = (totalSeconds % 3600) / 60
		let seconds = totalSeconds % 60
		if hours > 0 {
			return String(format: "%d:%02d:%02d", hours, minutes, seconds)
		} else {
			return String(format: "%d:%02d", minutes, seconds)
		}
	}
}

