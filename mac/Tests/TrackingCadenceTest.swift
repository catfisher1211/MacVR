import Foundation
@main struct TrackingCadenceTest {
    static func main() {
        let c=TrackingCadence()
        var t:UInt64=1_000_000_000, results:[Int]=[]
        func feed(_ rate:Int,seconds:Int) {
            for i in 0..<(rate*seconds) {
                // Timestamp jitter cancels every pair; receiving a burst does not affect source time.
                let jitter:Int64 = i%2 == 0 ? 100_000 : -100_000
                t += UInt64(Int64(1_000_000_000/rate)+jitter)
                if let r=c.observe(t) {results.append(r)}
            }
        }
        feed(90,seconds:4);precondition(results == [90])
        feed(120,seconds:4);precondition(results == [90,120])
        feed(120,seconds:3);precondition(results == [90,120],"stable rates must not repeatedly reconfigure")
        c.reset();results=[];feed(60,seconds:4);precondition(results.isEmpty,"unsupported cadence must not be rounded to 72")
        c.reset();t=1_000_000_000;feed(72,seconds:4);precondition(results == [72])
        print("PASS: tracking cadence, timestamp jitter, refresh transition, reset, unsupported rates")
    }
}
