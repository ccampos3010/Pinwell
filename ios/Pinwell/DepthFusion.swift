import ARKit
import simd

/// Shows the raw TrueDepth frame while the phone is moving.
/// Once the pose settles, a short median takes out speckle. No warp: a bad
/// alignment was blending the face into itself and never converging.
final class DepthFusion {
    private let lock = NSLock()
    private var ring: [[Float]] = []
    private var previousPose: simd_float4x4?
    private var resets = 0
    private var agreed = 0
    private var tested = 0
    private var stableCount = 0
    private var movingCount = 0

    func snapshot() -> (resets: Int, agreed: Int, tested: Int, stable: Int, moving: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (resets, agreed, tested, stableCount, movingCount)
    }

    func fuse(
        raw: UnsafePointer<Float>,
        bytesPerRow: Int,
        width: Int,
        height: Int,
        pose: simd_float4x4
    ) -> [Float] {
        let count = width * height
        let current = readTight(raw: raw, bytesPerRow: bytesPerRow, width: width, height: height)
        let rel = simd_mul(simd_inverse(pose), previousPose ?? pose)
        let rotation = simd_float3x3(
            SIMD3(rel.columns.0.x, rel.columns.0.y, rel.columns.0.z),
            SIMD3(rel.columns.1.x, rel.columns.1.y, rel.columns.1.z),
            SIMD3(rel.columns.2.x, rel.columns.2.y, rel.columns.2.z)
        )
        let translation = SIMD3(rel.columns.3.x, rel.columns.3.y, rel.columns.3.z)
        let trace = rotation.columns.0.x + rotation.columns.1.y + rotation.columns.2.z
        let angle = acos(min(1, max(-1, (trace - 1) * 0.5)))
        let moving = previousPose != nil && (angle > 0.015 || simd_length(translation) > 0.005)
        previousPose = pose

        lock.lock()
        tested += count
        if moving {
            movingCount += 1
            resets += 1
            stableCount = 0
            ring.removeAll(keepingCapacity: true)
            lock.unlock()
            return current
        }
        stableCount += 1
        ring.append(current)
        if ring.count > 4 { ring.removeFirst(ring.count - 4) }
        if ring[0].count != count { ring.removeAll(); ring.append(current) }
        let frames = ring
        lock.unlock()

        if frames.count < 2 { return current }
        var out = [Float](repeating: 0, count: count)
        var matched = 0
        for i in 0..<count {
            var a: Float = 0
            var b: Float = 0
            var c: Float = 0
            var d: Float = 0
            var n = 0
            for frame in frames {
                let z = frame[i]
                if z > 0.05 && z < 2.5 {
                    switch n {
                    case 0: a = z
                    case 1: b = z
                    case 2: c = z
                    default: d = z
                    }
                    n += 1
                    if n == 4 { break }
                }
            }
            if n == 0 { continue }
            out[i] = Self.median(a, b, c, d, n)
            matched += 1
        }
        lock.lock()
        agreed += matched
        lock.unlock()
        return out
    }

    private static func median(_ a: Float, _ b: Float, _ c: Float, _ d: Float, _ n: Int) -> Float {
        if n <= 1 { return a }
        if n == 2 { return max(a, b) }
        if n == 3 {
            let low = min(a, b, c)
            let high = max(a, b, c)
            return a + b + c - low - high
        }
        let lowLeft = min(a, b)
        let highLeft = max(a, b)
        let lowRight = min(c, d)
        let highRight = max(c, d)
        let lowest = min(lowLeft, lowRight)
        let lowerMiddle = min(max(lowLeft, lowRight), min(highLeft, highRight))
        return a + b + c + d - lowest - lowerMiddle - max(highLeft, highRight)
    }

    private func readTight(
        raw: UnsafePointer<Float>,
        bytesPerRow: Int,
        width: Int,
        height: Int
    ) -> [Float] {
        var out = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = UnsafeRawPointer(raw).advanced(by: y * bytesPerRow).assumingMemoryBound(to: Float.self)
            for x in 0..<width {
                let z = row[x]
                out[y * width + x] = z.isFinite && z > 0 ? z : 0
            }
        }
        return out
    }
}
