import Metal
import QuartzCore
import simd

/// Placeholder renderer: draws a fullscreen triangle whose fragment shader
/// sphere-traces a hardcoded smin scene (see Shaders.metal). Stands in for
/// the brick-cache renderer (tasks 4.1–4.3) so the shell, gestures, and CI
/// have a live viewport to build against.
@MainActor
final class Renderer {
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState

    /// Layout mirrors `Uniforms` in Shaders.metal: three float3 rows
    /// (16-byte strides on both sides) plus a packed params vector.
    struct Uniforms {
        var position: SIMD3<Float>
        var right: SIMD3<Float>
        var up: SIMD3<Float>
        var forward: SIMD3<Float>
        var params: SIMD4<Float> // aspect, time, lens, orthoHalfHeight
    }

    init?(device: MTLDevice, pixelFormat: MTLPixelFormat) {
        guard let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let vertexFn = library.makeFunction(name: "fullscreen_vertex"),
              let fragmentFn = library.makeFunction(name: "raymarch_fragment")
        else { return nil }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFn
        descriptor.fragmentFunction = fragmentFn
        descriptor.colorAttachments[0].pixelFormat = pixelFormat

        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor)
        else { return nil }

        self.queue = queue
        self.pipeline = pipeline
    }

    func draw(to drawable: CAMetalDrawable, time: Float, camera: OrbitCamera) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0.86, green: 0.85, blue: 0.84, alpha: 1)

        guard let commands = queue.makeCommandBuffer(),
              let encoder = commands.makeRenderCommandEncoder(descriptor: pass)
        else { return }

        let width = Float(drawable.texture.width)
        let height = Float(max(drawable.texture.height, 1))
        let basis = camera.basis
        var uniforms = Uniforms(
            position: camera.position,
            right: basis.right,
            up: basis.up,
            forward: basis.forward,
            params: SIMD4(width / height, time, camera.lens, camera.orthoHalfHeight)
        )

        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()

        commands.present(drawable)
        commands.commit()
    }
}
