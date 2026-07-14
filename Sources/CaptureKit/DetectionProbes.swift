import Foundation
import CoreAudio
import AppKit

public enum DetectionProbes {
    /// Bundle-id prefixes of known meeting apps.
    static let meetingBundlePrefixes = [
        "us.zoom.xos", "com.microsoft.teams", "com.cisco.webex", "com.hnc.Discord", "com.skype.skype",
    ]

    /// True when a process other than us is running audio input — i.e., some process
    /// (possibly a browser tab) has the mic open. Excludes Debrief's own capture via
    /// the CoreAudio process-object list, so it stays meaningful while recording.
    /// If the process list can't be read, falls back to the device-wide probe below,
    /// which includes ourselves — i.e. reads "in use" for the whole recording, so the
    /// failure mode is "no auto-stop", never a wrongly truncated recording.
    public static func micInUseByOtherProcess() -> Bool {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else {
            return micInUseByAnyProcess()
        }
        var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &processes) == noErr else {
            return micInUseByAnyProcess()
        }
        let ourPID = getpid()
        return processes.contains { process in
            guard let pid = readUInt32(kAudioProcessPropertyPID, of: process),
                  pid_t(bitPattern: pid) != ourPID,
                  readUInt32(kAudioProcessPropertyIsRunningInput, of: process) ?? 0 != 0 else { return false }
            let bundle = bundleID(of: process)
            return !systemAudioDaemonPrefixes.contains { bundle.hasPrefix($0) }
        }
    }

    /// Always-on system listeners that report "running input" whenever ANY process
    /// starts the mic device (observed: Siri's wake-word daemon). Counting them would
    /// make the mic look busy for our entire recording and auto-stop would never fire.
    /// ponytail: denylist, extend if auto-stop is inert on a machine with another such
    /// daemon; the miss is fail-safe (recording just keeps going until manual stop).
    static let systemAudioDaemonPrefixes = ["com.apple.CoreSpeech", "com.apple.siri"]

    private static func bundleID(of object: AudioObjectID) -> String {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return "" }
        return value.takeRetainedValue() as String
    }

    /// Both process properties we need (PID, IsRunningInput) are 32-bit values.
    private static func readUInt32(_ selector: AudioObjectPropertySelector, of object: AudioObjectID) -> UInt32? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    /// Device-wide "is the default input running somewhere" — includes ourselves.
    /// Fallback only; prefer micInUseByOtherProcess.
    static func micInUseByAnyProcess() -> Bool {
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
        DetectionSnapshot(micInUse: micInUseByOtherProcess(), meetingAppRunning: meetingAppRunning())
    }
}
