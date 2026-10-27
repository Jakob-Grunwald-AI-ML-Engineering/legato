import Foundation

/// Which sample rate the system-audio tap's buffers really have, and when that has changed.
///
/// `kAudioTapPropertyFormat` is read before the aggregate device exists, and an output that renegotiates
/// (AirPods leaving A2DP 48 kHz for the headset profile at 24 kHz when the mic starts) changes the rate the
/// tap delivers at without changing the default output device. Pure; Core Audio is read by the caller.
enum TapRate {
    /// The rate to build the converter for: the aggregate device's nominal rate when it is known (the tap
    /// delivers at the device clock), else what the tap reported.
    static func effective(reported: Double, deviceNominal: Double?) -> Double {
        if let nominal = deviceNominal, nominal > 0 { return nominal }
        return reported
    }

    /// A tap built for `built` must be rebuilt when the device now runs at another rate. An unreadable
    /// rate (`nil`, or not positive) is no evidence of a change.
    static func needsRebuild(built: Double, deviceNominal: Double?) -> Bool {
        guard let nominal = deviceNominal, nominal > 0 else { return false }
        return nominal != built
    }
}
