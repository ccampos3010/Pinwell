import ARKit
import simd

/// Aligns the previous TrueDepth frame with the phone's motion, then lets it settle.
/// ARKit's camera pose is the IMU-plus-camera estimate, so a tilt does not smear the map.
final class DepthFusion {
    private let lock = NSLock()
    private var fused: [Float] = []
    private var weight: [Float] = []
    private var doubt: [UInt8] = []
    private var previousPose: simd_float4x4?
    private var resets = 0
    private var agreed = 0
    private var tested = 0

    func snapshot() -> (resets: Int, agreed: Int, tested: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (resets, agreed, tested)
    }

    func fuse(
        raw: UnsafePointer<Float>,
        bytesPerRow: Int,
        width: Int,
        height: Int,
        imageWidth: Int,
        imageHeight: Int,
        intrinsics: simd_float3x3,
        pose: simd_float4x4
    ) -> [Float] {
        let count = width * height
        if fused.count != count || width < 2 || height < 2 {
            fused = readTight(raw: raw, bytesPerRow: bytesPerRow, width: width, height: height)
            weight = Array(repeating: 1, count: count)
            doubt = Array(repeating: 0, count: count)
            previousPose = pose
            return fused
        }

        let sx = Float(width) / Float(max(imageWidth, 1))
        let sy = Float(height) / Float(max(imageHeight, 1))
        let fx = intrinsics.columns.0.x * sx
        let fy = intrinsics.columns.1.y * sy
        let cx = intrinsics.columns.2.x * sx
        let cy = intrinsics.columns.2.y * sy

        var warped = [Float](repeating: 0, count: count)
        var warpedWeight = [Float](repeating: 0, count: count)
        let rel = simd_mul(simd_inverse(pose), previousPose ?? pose)
        let rotation = simd_float3x3(
            SIMD3(rel.columns.0.x, rel.columns.0.y, rel.columns.0.z),
            SIMD3(rel.columns.1.x, rel.columns.1.y, rel.columns.1.z),
            SIMD3(rel.columns.2.x, rel.columns.2.y, rel.columns.2.z)
        )
        let translation = SIMD3(rel.columns.3.x, rel.columns.3.y, rel.columns.3.z)
        let trace = rotation.columns.0.x + rotation.columns.1.y + rotation.columns.2.z
        let angle = acos(min(1, max(-1, (trace - 1) * 0.5)))
        let warp = angle < 0.35 && simd_length(translation) < 0.2 && fx > 1 && fy > 1
        if !warp {
            lock.lock()
            resets += 1
            lock.unlock()
        }

        if warp {
            for y in 0..<height {
                for x in 0..<width {
                    let i = y * width + x
                    let z = fused[i]
                    let wgt = weight[i]
                    if wgt < 0.25 || !z.isFinite || z < 0.05 || z > 2.5 { continue }
                    let cam = SIMD3<Float>(
                        (Float(x) + 0.5 - cx) * z / fx,
                        (cy - (Float(y) + 0.5)) * z / fy,
                        -z
                    )
                    let moved = rotation * cam + translation
                    let depth = -moved.z
                    if depth < 0.05 || depth > 2.5 { continue }
                    let u = moved.x * fx / depth + cx
                    let v = cy - moved.y * fy / depth
                    let ix = Int(u.rounded())
                    let iy = Int(v.rounded())
                    if ix < 0 || iy < 0 || ix >= width || iy >= height { continue }
                    let j = iy * width + ix
                    if warped[j] == 0 || depth < warped[j] {
                        warped[j] = depth
                        warpedWeight[j] = wgt
                    }
                }
            }
        }

        var next = [Float](repeating: 0, count: count)
        var nextWeight = [Float](repeating: 0, count: count)
        var nextDoubt = [UInt8](repeating: 0, count: count)
        var agree = 0
        var seen = 0
        let alpha: Float = 0.12
        for y in 0..<height {
            let row = UnsafeRawPointer(raw).advanced(by: y * bytesPerRow).assumingMemoryBound(to: Float.self)
            for x in 0..<width {
                let i = y * width + x
                let zNew = row[x]
                let fresh = zNew.isFinite && zNew > 0.05 && zNew < 2.5
                let zOld = warped[i]
                let held = zOld > 0.05 && warpedWeight[i] > 0.2
                if fresh { seen += 1 }
                if fresh && held && abs(zNew - zOld) <= max(0.015, zNew * 0.035) {
                    next[i] = zOld * (1 - alpha) + zNew * alpha
                    nextWeight[i] = min(30, warpedWeight[i] + 1)
                    agree += 1
                } else if fresh && held {
                    let waits = doubt[i] &+ 1
                    if waits >= 5 {
                        next[i] = zNew
                        nextWeight[i] = 1
                    } else {
                        next[i] = zOld
                        nextWeight[i] = warpedWeight[i]
                        nextDoubt[i] = waits
                    }
                } else if fresh {
                    next[i] = zNew
                    nextWeight[i] = 1
                } else if held {
                    next[i] = zOld
                    nextWeight[i] = warpedWeight[i] * 0.9
                }
            }
        }
        fused = next
        weight = nextWeight
        doubt = nextDoubt
        previousPose = pose
        lock.lock()
        agreed += agree
        tested += seen
        lock.unlock()
        return fused
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
