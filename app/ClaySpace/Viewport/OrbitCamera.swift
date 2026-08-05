import simd

/// Orbit camera (task 4.4): target + spherical orbit, pan in the view
/// plane, dolly zoom, roll about the view axis, perspective or
/// orthographic projection with axis presets.
struct OrbitCamera {
    var target = SIMD3<Float>(0, 0.7, 0)
    var distance: Float = 3.2
    var azimuth: Float = 0.55      // radians, 0 = looking down -Z
    var elevation: Float = 0.32    // radians, clamped short of the poles
    var rollAngle: Float = 0
    var lens: Float = 1.7          // perspective focal factor (rd z-scale)
    var orthoHalfHeight: Float = 0 // > 0 switches to orthographic

    static let elevationLimit: Float = 1.53

    // MARK: Navigation

    mutating func orbit(deltaAzimuth: Float, deltaElevation: Float) {
        azimuth += deltaAzimuth
        elevation = min(max(elevation + deltaElevation, -Self.elevationLimit), Self.elevationLimit)
    }

    /// `scale` is the incremental pinch ratio (>1 zooms in).
    mutating func zoom(scale: Float) {
        guard scale > 0 else { return }
        distance = min(max(distance / scale, 0.3), 60)
        if orthoHalfHeight > 0 {
            orthoHalfHeight = min(max(orthoHalfHeight / scale, 0.1), 60)
        }
    }

    /// `deltaPoints` is the two-finger centroid delta in view points;
    /// content follows the fingers.
    mutating func pan(deltaPoints: SIMD2<Float>, viewportHeightPoints: Float) {
        guard viewportHeightPoints > 0 else { return }
        let worldPerPoint = 2 * currentHalfHeight / viewportHeightPoints
        let b = basis
        target -= b.right * (deltaPoints.x * worldPerPoint)
        target += b.up * (deltaPoints.y * worldPerPoint) // screen y is flipped
    }

    mutating func roll(delta: Float) {
        rollAngle += delta
    }

    // MARK: Projection & presets

    var isOrthographic: Bool { orthoHalfHeight > 0 }

    /// Vertical half-extent of the view volume at the target distance.
    private var currentHalfHeight: Float {
        isOrthographic ? orthoHalfHeight : distance / lens
    }

    mutating func setOrthographic(_ on: Bool) {
        orthoHalfHeight = on ? distance / lens : 0
    }

    static func preset(front: Bool = false, side: Bool = false, top: Bool = false,
                       distance: Float = 3.2) -> OrbitCamera {
        var cam = OrbitCamera()
        cam.distance = distance
        if front { cam.azimuth = 0; cam.elevation = 0 }
        if side { cam.azimuth = .pi / 2; cam.elevation = 0 }
        if top { cam.azimuth = 0; cam.elevation = OrbitCamera.elevationLimit }
        cam.setOrthographic(true)
        return cam
    }

    // MARK: Interpolation (bookmark/preset recall animation)

    static func interpolate(from a: OrbitCamera, to b: OrbitCamera, t: Float) -> OrbitCamera {
        func mix(_ x: Float, _ y: Float) -> Float { x + (y - x) * t }
        var azimuthDelta = b.azimuth - a.azimuth
        while azimuthDelta > .pi { azimuthDelta -= 2 * .pi }
        while azimuthDelta < -.pi { azimuthDelta += 2 * .pi }

        var cam = b
        cam.azimuth = a.azimuth + azimuthDelta * t
        cam.elevation = mix(a.elevation, b.elevation)
        cam.distance = mix(a.distance, b.distance)
        cam.rollAngle = mix(a.rollAngle, b.rollAngle)
        cam.lens = mix(a.lens, b.lens)
        cam.target = a.target + (b.target - a.target) * t
        // Ortho half-height lerps toward zero as extreme zoom; when the
        // projection kind changes, switch at the midpoint instead.
        cam.orthoHalfHeight = a.isOrthographic == b.isOrthographic
            ? mix(a.orthoHalfHeight, b.orthoHalfHeight)
            : (t < 0.5 ? a.orthoHalfHeight : b.orthoHalfHeight)
        return cam
    }

    // MARK: Ray-generation basis (consumed by the renderer)

    var position: SIMD3<Float> {
        let ce = cos(elevation), se = sin(elevation)
        let ca = cos(azimuth), sa = sin(azimuth)
        let dir = SIMD3<Float>(ce * sa, se, ce * ca)
        return target + dir * distance
    }

    var basis: (right: SIMD3<Float>, up: SIMD3<Float>, forward: SIMD3<Float>) {
        let forward = simd_normalize(target - position)
        var right = simd_cross(SIMD3<Float>(0, 1, 0), forward)
        // Elevation is clamped short of the poles, but stay safe:
        if simd_length_squared(right) < 1e-6 { right = SIMD3<Float>(1, 0, 0) }
        right = simd_normalize(right)
        var up = simd_cross(forward, right)
        if rollAngle != 0 {
            let c = cos(rollAngle), s = sin(rollAngle)
            let r = right * c + up * s
            up = up * c - right * s
            right = r
        }
        return (right, up, forward)
    }
}
