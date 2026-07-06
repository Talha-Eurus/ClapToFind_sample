// ClapToFind — MicrophonePermission.swift
// Models the microphone authorization state as a first-class type.

import Foundation

/// Represents the microphone permission state as granted by the user.
enum MicrophonePermission: Equatable {
    case undetermined
    case granted
    case denied
}
