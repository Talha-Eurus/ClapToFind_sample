// ClapToFind — ContentView.swift
// The single view for this app. Intentionally minimal — all display logic is
// derived from MainViewModel state; no business logic lives here.

import SwiftUI

struct ContentView: View {

    @State private var viewModel: MainViewModel

    init(viewModel: MainViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        NavigationStack {
            Form {
                permissionSection
                statusSection
                controlsSection
                sensitivitySection
            }
            .navigationTitle("ClapToFind")
        }
    }

    // MARK: – Sections

    @ViewBuilder
    private var permissionSection: some View {
        if viewModel.microphonePermission != .granted {
            Section("Microphone Access") {
                HStack {
                    Image(systemName: permissionIcon)
                        .foregroundStyle(permissionColor)
                    Text(permissionDescription)
                        .foregroundStyle(.secondary)
                }

                if viewModel.microphonePermission == .undetermined {
                    Button("Grant Permission") {
                        viewModel.requestMicrophonePermission()
                    }
                } else if viewModel.microphonePermission == .denied {
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    .foregroundStyle(.orange)
                }
            }
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        Section("Status") {
            Label(viewModel.statusMessage, systemImage: statusIcon)
                .foregroundStyle(statusColor)

            if viewModel.isAlarmActive {
                Label("ALARM ACTIVE", systemImage: "bell.fill")
                    .foregroundStyle(.red)
                    .fontWeight(.bold)
            }
        }
    }

    @ViewBuilder
    private var controlsSection: some View {
        Section("Controls") {
            switch viewModel.appState {
            case .idle:
                Button {
                    viewModel.startListening()
                } label: {
                    Label("Start Listening", systemImage: "mic.fill")
                }
                .disabled(viewModel.microphonePermission == .denied)

            case .listening:
                Button {
                    viewModel.stopListening()
                } label: {
                    Label("Stop Listening", systemImage: "mic.slash.fill")
                }
                .foregroundStyle(.red)

#if DEBUG
                Button {
                    viewModel.simulateClap()
                } label: {
                    Label("Simulate Clap (Debug)", systemImage: "hand.tap.fill")
                }
                .foregroundStyle(.orange)
#endif

            case .alarming:
                Button {
                    viewModel.stopAlarm()
                } label: {
                    Label("Stop Alarm", systemImage: "bell.slash.fill")
                }
                .foregroundStyle(.red)
                .fontWeight(.bold)

                Button {
                    viewModel.stopListening()
                } label: {
                    Label("Stop Listening", systemImage: "mic.slash.fill")
                }
                .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var sensitivitySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Sensitivity")
                    Spacer()
                    Text(sensitivityLabel)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $viewModel.sensitivity, in: 0...1)
                HStack {
                    Text("Low").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("High").font(.caption).foregroundStyle(.secondary)
                }
            }
        } footer: {
            Text("Higher sensitivity triggers on quieter claps but may increase false positives.")
        }
    }

    // MARK: – Computed display helpers

    private var permissionIcon: String {
        switch viewModel.microphonePermission {
        case .granted:    return "checkmark.circle.fill"
        case .denied:     return "xmark.circle.fill"
        case .undetermined: return "questionmark.circle.fill"
        }
    }

    private var permissionColor: Color {
        switch viewModel.microphonePermission {
        case .granted:    return .green
        case .denied:     return .red
        case .undetermined: return .orange
        }
    }

    private var permissionDescription: String {
        switch viewModel.microphonePermission {
        case .granted:    return "Microphone access granted."
        case .denied:     return "Microphone access denied."
        case .undetermined: return "Microphone access not yet requested."
        }
    }

    private var statusIcon: String {
        switch viewModel.appState {
        case .idle:      return "pause.circle"
        case .listening: return "waveform"
        case .alarming:  return "bell.fill"
        }
    }

    private var statusColor: Color {
        switch viewModel.appState {
        case .idle:      return .secondary
        case .listening: return .green
        case .alarming:  return .red
        }
    }

    private var sensitivityLabel: String {
        switch viewModel.sensitivity {
        case 0..<0.34:  return "Low"
        case 0.34..<0.67: return "Medium"
        default:        return "High"
        }
    }
}
