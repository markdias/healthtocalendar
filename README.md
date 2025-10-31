# healthtocalendar

healthtocalendar is a SwiftUI utility that synchronises recent Apple Health workouts into a calendar of your choice. This build automatically refreshes HealthKit and Calendar permissions on launch so new workouts appear grouped by month and can be exported in bulk.

## Key features

- **Automatic Health access** – the app proactively requests HealthKit permissions and begins loading recent workouts as soon as it launches.
- **Smart filtering** – workouts that already exist in any of your calendars are hidden, keeping the list focused on items that still need exporting.
- **Monthly organisation** – workouts are grouped into sections per month with quick stats to make long histories easier to scan.
- **Calendar export** – choose any writable calendar, then export one or many workouts with a single tap.

## Usage tips

1. Launch the app and approve the Health access prompt. Recent workouts from the past three months will appear automatically.
2. If prompted, grant Calendar access so the app can filter out workouts that already exist in your calendars.
3. Tap **Select All** or pick individual workouts, then tap **Export** to push them into the calendar you prefer.

If you change Calendar permissions in Settings, simply return to the app—the list will refresh when it becomes active again.
