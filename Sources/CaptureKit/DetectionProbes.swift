import Foundation
import CoreAudio
import AppKit

public enum DetectionProbes {
    /// Bundle-id prefixes of known meeting apps.
    static let meetingBundlePrefixes = [
        "us.zoom.xos", "com.microsoft.teams", "com.cisco.webex", "com.hnc.Discord", "com.skype.skype",
    ]

    /// True when the default input device is running "somewhere" — i.e., some process
    /// (possibly a browser tab) has the mic open. Includes ourselves, so callers must
    /// only poll while NOT recording.
    public static func micInUseByAnyProcess() -> Bool {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &addr, 0, nil, &size, &deviceID) == noErr,
              deviceID != 0 else { return false }

        var running: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        addr.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &running) == noErr else { return false }
        return running != 0
    }

    public static func meetingAppRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { app in
            guard let bundle = app.bundleIdentifier else { return false }
            return meetingBundlePrefixes.contains { bundle.hasPrefix($0) }
        }
    }

    public static func snapshot() -> DetectionSnapshot {
        DetectionSnapshot(micInUse: micInUseByAnyProcess(), meetingAppRunning: meetingAppRunning())
    }
}
