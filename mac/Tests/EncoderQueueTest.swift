import Foundation
import CoreVideo

@main struct EncoderQueueTest {
    static func main() {
        let e = Encoder()
        precondition(e.configure(width:4096,height:2048,fps:90,mbps:150,maxQP:18,hevc:true))
        var pb:CVPixelBuffer?
        precondition(CVPixelBufferCreate(nil,4096,2048,kCVPixelFormatType_32BGRA,[kCVPixelBufferIOSurfacePropertiesKey:[:]] as CFDictionary,&pb) == kCVReturnSuccess)
        CVPixelBufferLockBaseAddress(pb!,[])
        memset(CVPixelBufferGetBaseAddress(pb!),128,CVPixelBufferGetDataSize(pb!))
        CVPixelBufferUnlockBaseAddress(pb!,[])
        let output=DispatchSemaphore(value:0)
        let lock=NSLock(); var invalid=0
        e.onFrame = { data,_,_ in
            if data.count < 5 || Array(data.prefix(4)) != [0,0,0,1] {lock.lock(); invalid+=1;lock.unlock()}
            output.signal()
        }
        for n in 0..<100 { e.encode(pb!,timeNs:UInt64(n)) }
        precondition(e.takeBackpressureSkips()>0,"saturation must drop submissions")
        precondition(output.wait(timeout:.now()+5) == .success,"encoder must produce output")
        Thread.sleep(forTimeInterval:0.2)
        precondition(e.encode(pb!,timeNs:101),"slots must recover")
        // Reconfiguration while work is pending must not leak slots into the new session.
        precondition(e.configure(width:4096,height:2048,fps:90,mbps:150,maxQP:18,hevc:true))
        precondition(e.encode(pb!,timeNs:102))
        Thread.sleep(forTimeInterval:0.3)
        precondition(e.encode(pb!,timeNs:103),"new session must recover its own slots")
        Thread.sleep(forTimeInterval:0.3)
        lock.lock(); precondition(invalid==0);lock.unlock()
        print("PASS: hardware HEVC output, bounded saturation, slot recovery, session replacement")
    }
}
