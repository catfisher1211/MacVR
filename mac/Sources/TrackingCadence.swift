import Foundation

/// The released Quest client advertises its startup refresh before the runtime
/// applies the USB refresh override. Measure the source clock, not USB arrival
/// jitter, to keep the encoder and game pacing in step with tracking afterward.
final class TrackingCadence {
    private let lock = NSLock()
    private var start: UInt64 = 0, last: UInt64 = 0
    private var count = 0, candidate = 0, confirmations = 0, reported = 0
    func reset() {
        lock.lock(); defer { lock.unlock() }
        start = 0; last = 0; count = 0; candidate = 0; confirmations = 0; reported = 0
    }
    func observe(_ time: UInt64) -> Int? {
        lock.lock(); defer { lock.unlock() }
        guard last > 0, time > last, time - last < 100_000_000 else {
            start = time; last = time; count = 0; confirmations = 0; return nil
        }
        last = time; count += 1
        guard time - start >= 1_000_000_000 else { return nil }
        let measured = Double(count) * 1e9 / Double(time - start)
        start = time; count = 0
        let rate = [72, 80, 90, 120].min { abs(Double($0) - measured) < abs(Double($1) - measured) }!
        guard abs(Double(rate) - measured) < Double(rate) * 0.02 else { confirmations = 0; return nil }
        confirmations = candidate == rate ? confirmations + 1 : 1; candidate = rate
        guard confirmations >= 2, rate != reported else { return nil }
        reported = rate; return rate
    }
}
