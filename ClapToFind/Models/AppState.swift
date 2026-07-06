// ClapToFind — AppState.swift
// Represents the top-level operational state of the application.

import Foundation

/// The mutually exclusive operational states the app can be in.
enum AppState: Equatable {
    case idle
    case listening
    case alarming
}
