//
//  healthtocalendarApp.swift
//  healthtocalendar
//
//  Created by Mark Dias on 30/10/2025.
//

import SwiftUI
import CoreData

@main
struct healthtocalendarApp: App {
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}
