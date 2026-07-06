# ClapToFind

A production-quality iOS app that continuously monitors microphone input, detects hand claps using a custom real-time DSP algorithm, and triggers a loud synthesised alarm when a clap is detected.

---

## How to Run

**Requirements:**

- Xcode 16 or later (projectxq uses `PBXFileSystemSynchronizedRootGroup`)
- iOS 17.0+ deployment target (project is currently set to 26.4 / iOS 18 SDK)

**Steps:**

1. Clone or download the repository.
2. Open `ClapToFind.xcodeproj` in Xcode.
3. Select your device in the scheme selector.
4. Set your development team in *Signing & Capabilities*.
5. Build and run (`⌘R`).
6. Grant microphone permission when prompted.
7. Tap **Start Listening** and clap your hands.

---

## Minimum iOS Version

**iOS 17.0** — required
