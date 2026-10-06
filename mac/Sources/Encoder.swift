import Foundation
import VideoToolbox

/// Low-latency hardware H.264 encoder. Emits Annex-B with SPS/PPS in front of every IDR.
final class Encoder {
    // VideoToolbox's HEVC encoder rejects MaxFrameDelayCount on this Mac. Bound
    // submitted work ourselves so overload drops a new frame instead of aging poses.
    private final class Slots {
        let semaphore = DispatchSemaphore(value: 3)
        let lock = NSLock()
        var skipped = 0
        func acquire() -> Bool {
            if semaphore.wait(timeout: .now()) == .success { return true }
            lock.lock(); skipped += 1; lock.unlock(); return false
        }
        func takeSkipped() -> Int {
            lock.lock(); defer { skipped = 0; lock.unlock() }; return skipped
        }
    }
    private var slots = Slots()
    private var inputPool: CVPixelBufferPool?
    private var transfer: VTPixelTransferSession?
    func takeBackpressureSkips() -> Int { slots.takeSkipped() }
    func setExpectedFrameRate(_ fps: Int) {
        guard let session else { return }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps as CFTypeRef)
    }
    private var session: VTCompressionSession?
    private(set) var width = 0, height = 0
    private(set) var hevc = false
    private var frameNo: Int64 = 0, generation = 0   // generation: frames from an old session are dropped
    var forceIDR = true
    private var loggedError = false
    var onFrame: (_ annexB: Data, _ idr: Bool, _ timeNs: UInt64) -> Void = { _, _, _ in }
    private let statLock = NSLock()
    private var encodeNs: UInt64 = 0, encoded = 0
    /// Average submit-to-output encode time (ms) since the last call; nil if nothing was encoded.
    func takeEncodeMs() -> Double? {
        statLock.lock(); defer { encodeNs = 0; encoded = 0; statLock.unlock() }
        return encoded > 0 ? Double(encodeNs) / Double(encoded) / 1e6 : nil
    }

    /// Returns false if VideoToolbox could not create the session (the caller falls back, e.g. HEVC -> H.264).
    @discardableResult func configure(width w: Int, height h: Int, fps: Int, mbps: Int, maxQP: Int, hevc useHEVC: Bool = false) -> Bool {
        if let s = session { VTCompressionSessionInvalidate(s); session = nil }
        slots = Slots()   // late callbacks release their old session's slots
        width = w; height = h; forceIDR = true; hevc = useHEVC; generation += 1; loggedError = false
        inputPool = nil
        if useHEVC {
            let attrs: [CFString: Any] = [kCVPixelBufferWidthKey: w, kCVPixelBufferHeightKey: h,
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferIOSurfacePropertiesKey: [:]]
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &inputPool)
            if transfer == nil { VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transfer) }
        }
        // Low-latency rate control was slower in local HEVC tests; hardware
        // reporting was unavailable in that mode, so do not infer software use.
        let spec = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true] as CFDictionary
        let created = VTCompressionSessionCreate(allocator: nil, width: Int32(w), height: Int32(h), codecType: useHEVC ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
                                   encoderSpecification: spec, imageBufferAttributes: nil, compressedDataAllocator: nil,
                                   outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        guard created == noErr, let s = session else {
            NSLog("VR4Mac: %@ encoder %dx%d failed to start (%d)", useHEVC ? "HEVC" : "H.264", w, h, created); session = nil; return false
        }
        let props: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_ProfileLevel: useHEVC ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_High_AutoLevel,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_AverageBitRate: mbps * 1_000_000,
            kVTCompressionPropertyKey_ExpectedFrameRate: fps,
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 10,
            // explicit Rec.709 so the headset decoder doesn't guess the colour range/matrix (washed-out colours)
            kVTCompressionPropertyKey_ColorPrimaries: kCVImageBufferColorPrimaries_ITU_R_709_2,
            kVTCompressionPropertyKey_TransferFunction: kCVImageBufferTransferFunction_ITU_R_709_2,
            kVTCompressionPropertyKey_YCbCrMatrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
            kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality: true,
            // cap bursts (IDRs) at 2x the average over a quarter second so frames don't queue behind them
            kVTCompressionPropertyKey_DataRateLimits: [mbps * 1_000_000 / 8 / 2, 0.25] as CFArray,
        ]
        for (k, v) in props {
            let result = VTSessionSetProperty(s, key: k, value: v as CFTypeRef)
            if result != noErr { NSLog("VR4Mac: encoder property %@ rejected (%d)", k as String, result) }
        }
        // low-latency rate control undershoots badly on simple scenes; a QP ceiling keeps text/edges sharp. Too low a ceiling
        // makes VT *drop* detailed frames it can't fit under DataRateLimits (BONELAB lost ~8%), so it only guards quality.
        let st = VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxAllowedFrameQP, value: maxQP as CFTypeRef)
        var hw: CFBoolean?; VTSessionCopyProperty(s, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder, allocator: nil, valueOut: &hw)
        NSLog("VR4Mac: %@ encoder %dx%d @ %d fps, %d Mbps, max QP %d (%@), hardware %@", useHEVC ? "HEVC" : "H.264", w, h, fps, mbps, maxQP, st == noErr ? "ok" : "unsupported \(st)", hw == kCFBooleanTrue ? "yes" : "no")
        VTCompressionSessionPrepareToEncodeFrames(s)
        return true
    }

    /// Live bitrate change on the running session (no new session, no keyframe): Auto bitrate's adaptation.
    func setBitrate(_ mbps: Int) {
        guard let s = session else { return }
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: mbps * 1_000_000 as CFTypeRef)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_DataRateLimits, value: [mbps * 1_000_000 / 8 / 2, 0.25] as CFArray)
    }

    @discardableResult func encode(_ pb: CVPixelBuffer, timeNs: UInt64) -> Bool {
        guard let s = session else { return false }
        let slots = self.slots
        guard slots.acquire() else { return false }
        CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        let opts = forceIDR ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        forceIDR = false
        frameNo += 1
        // Real capture time: rate control budgets bits per second from PTS spacing. Counting frames as 1 ms apart told VT
        // it had 1000 fps, so slow games (BONELAB ~33 fps) got a tiny per-frame budget and frames were dropped.
        let hevc = self.hevc, gen = generation
        let t0 = DispatchTime.now().uptimeNanoseconds
        // Feed the hardware's native 4:2:0 format instead of making every
        // compression submission perform its own BGRA conversion.
        var input = pb, converted: CVPixelBuffer?
        if let inputPool, let transfer,
           CVPixelBufferPoolCreatePixelBuffer(nil, inputPool, &converted) == kCVReturnSuccess,
           let converted, VTPixelTransferSessionTransferImage(transfer, from: pb, to: converted) == noErr {
            input = converted
        }
        let pts = CMTime(value: CMTimeValue(t0 / 1000), timescale: 1_000_000)
        let result = VTCompressionSessionEncodeFrame(s, imageBuffer: input, presentationTimeStamp: pts,
                                        duration: .invalid, frameProperties: opts, infoFlagsOut: nil) { [weak self] status, _, sb in
            defer { slots.semaphore.signal() }
            guard status == noErr, let sb, let self, self.generation == gen else {
                if status != noErr, self?.loggedError == false { self?.loggedError = true; NSLog("VR4Mac: encode failed %d", status) }
                return
            }
            self.statLock.lock(); self.encodeNs += DispatchTime.now().uptimeNanoseconds - t0; self.encoded += 1; self.statLock.unlock()
            let (data, idr) = Encoder.annexB(sb, hevc: hevc)
            self.onFrame(data, idr, timeNs)
        }
        if result != noErr {
            slots.semaphore.signal()
            if !loggedError { loggedError = true; NSLog("VR4Mac: encode submission failed %d", result) }
            return false
        }
        return true
    }

    static func annexB(_ sb: CMSampleBuffer, hevc: Bool = false) -> (Data, Bool) {
        let start: [UInt8] = [0, 0, 0, 1]
        var out = Data()
        let att = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]]
        let idr = !(att?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        if idr, let fmt = CMSampleBufferGetFormatDescription(sb) {   // SPS/PPS (+VPS for HEVC) in front of every IDR
            let get = hevc ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex : CMVideoFormatDescriptionGetH264ParameterSetAtIndex
            var n = 0
            get(fmt, 0, nil, nil, &n, nil)
            for i in 0..<n {
                var p: UnsafePointer<UInt8>?, len = 0
                get(fmt, i, &p, &len, nil, nil)
                if let p { out.append(contentsOf: start); out.append(p, count: len) }
            }
        }
        guard let bb = CMSampleBufferGetDataBuffer(sb) else { return (out, idr) }
        var total = 0, ptr: UnsafeMutablePointer<CChar>?
        CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &total, dataPointerOut: &ptr)
        guard let ptr else { return (out, idr) }
        let raw = UnsafeRawPointer(ptr)
        var off = 0
        while off + 4 <= total {   // AVCC 4-byte big-endian lengths -> start codes
            let len = Int(UInt32(bigEndian: raw.loadUnaligned(fromByteOffset: off, as: UInt32.self)))
            off += 4
            guard off + len <= total else { break }
            out.append(contentsOf: start)
            out.append(raw.advanced(by: off).assumingMemoryBound(to: UInt8.self), count: len)
            off += len
        }
        return (out, idr)
    }
}
