// ClapToFind — ClapToFindApp.swift
// App entry point. Performs dependency injection here so Views remain
// free of construction logic. All service objects are created once and
// shared via the ViewModel.

import SwiftUI
import AVFoundation

@main
struct ClapToFindApp: App {

    /// The shared engine instance is created here so AlarmService and
    /// AudioEngineService can share the same AVAudioEngine graph.
    private let sharedEngine = AVAudioEngine()

    private let viewModel: MainViewModel

    init() {
        let sessionManager = AudioSessionManager()
        let engineService = AudioEngineService(engine: sharedEngine)
        let detector = ClapDetector(configuration: .default)
        let alarmService = AlarmService(engine: sharedEngine)

        viewModel = MainViewModel(
            sessionManager: sessionManager,
            engineService: engineService,
            detector: detector,
            alarmService: alarmService
        )
    }

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
        }
    }
}
