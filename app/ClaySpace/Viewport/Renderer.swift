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

    /// Layout mirrors `Uniforms` in Shaders.metal (128 bytes).
    struct Uniforms {
        var position: SIMD3<Float>
        var right: SIMD3<Float>
        var up: SIMD3<Float>
        var forward: SIMD3<Float>
        var params: SIMD4<Float> // aspect, time, lens, orthoHalfHeight
        var itemCount: Int32
        var bakedCount: Int32    // items below this index live in the cache
        var mirrorAxes: Int32    // layer mirror bits (CLAY_MIRROR_*)
        var mirrorK: Float       // Mirror Blend seam width
        var selectedIndex: Int32 // highlighted item; -1 = none
        var pad3: SIMD3<Float> = .zero
        var gridOrigin: SIMD4<Float>    // xyz origin; w = cache enabled (0/1)
        var gridInvExtent: SIMD4<Float> // xyz = 1/extent; w = normal epsilon
        var gridScale: SIMD4<Float>     // xyz = dims/maxResolution
        var lightDir: SIMD4<Float>      // xyz normalized (light dial)
        var material: SIMD4<Float>      // spec strength, shininess, metalness
        var layerBits: SIMD4<UInt32>    // visibility mask, mirror packed, count
    }

    static let maxItems = 256
    private let device: MTLDevice
    private let itemBuffer: MTLBuffer
    private let strokePointBuffer: MTLBuffer
    private let distanceTexture: MTLTexture
    private let colorTexture: MTLTexture
    private var uploadedVersion = -1
    private var uploadedCacheVersion = -1

    // Voxel raster pass (greedy mesh) composited via a shared depth buffer.
    private let voxelPipeline: MTLRenderPipelineState
    private let raymarchDepthState: MTLDepthStencilState
    private let voxelDepthState: MTLDepthStencilState
    private var depthTexture: MTLTexture?
    private var voxelPositionBuffer: MTLBuffer?
    private var voxelNormalBuffer: MTLBuffer?
    private var voxelColorBuffer: MTLBuffer?
    private var voxelIndexBuffer: MTLBuffer?
    private var voxelIndexCount = 0
    private var uploadedVoxelVersion = -1

    init?(device: MTLDevice, pixelFormat: MTLPixelFormat) {
        self.device = device
        guard let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let vertexFn = library.makeFunction(name: "fullscreen_vertex"),
              let fragmentFn = library.makeFunction(name: "raymarch_fragment"),
              let voxelVertexFn = library.makeFunction(name: "voxel_vertex"),
              let voxelFragmentFn = library.makeFunction(name: "voxel_fragment")
        else { return nil }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFn
        descriptor.fragmentFunction = fragmentFn
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        descriptor.depthAttachmentPixelFormat = .depth32Float

        let voxelDescriptor = MTLRenderPipelineDescriptor()
        voxelDescriptor.vertexFunction = voxelVertexFn
        voxelDescriptor.fragmentFunction = voxelFragmentFn
        voxelDescriptor.colorAttachments[0].pixelFormat = pixelFormat
        voxelDescriptor.depthAttachmentPixelFormat = .depth32Float

        let alwaysWrite = MTLDepthStencilDescriptor()
        alwaysWrite.depthCompareFunction = .always
        alwaysWrite.isDepthWriteEnabled = true
        let lessWrite = MTLDepthStencilDescriptor()
        lessWrite.depthCompareFunction = .less
        lessWrite.isDepthWriteEnabled = true

        let n = FieldCache.maxResolution
        let distanceDesc = MTLTextureDescriptor()
        distanceDesc.textureType = .type3D
        distanceDesc.pixelFormat = .r16Float
        distanceDesc.width = n
        distanceDesc.height = n
        distanceDesc.depth = n
        distanceDesc.usage = .shaderRead
        distanceDesc.storageMode = .shared
        let colorDesc = MTLTextureDescriptor()
        colorDesc.textureType = .type3D
        colorDesc.pixelFormat = .rgba8Unorm
        colorDesc.width = n
        colorDesc.height = n
        colorDesc.depth = n
        colorDesc.usage = .shaderRead
        colorDesc.storageMode = .shared

        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor),
              let voxelPipeline = try? device.makeRenderPipelineState(descriptor: voxelDescriptor),
              let raymarchDepthState = device.makeDepthStencilState(descriptor: alwaysWrite),
              let voxelDepthState = device.makeDepthStencilState(descriptor: lessWrite),
              let itemBuffer = device.makeBuffer(
                  length: MemoryLayout<SceneItem>.stride * Self.maxItems,
                  options: .storageModeShared),
              let strokePointBuffer = device.makeBuffer(
                  length: MemoryLayout<SIMD4<Float>>.stride * ClayEngine.maxStrokePoints,
                  options: .storageModeShared),
              let distanceTexture = device.makeTexture(descriptor: distanceDesc),
              let colorTexture = device.makeTexture(descriptor: colorDesc)
        else { return nil }

        self.queue = queue
        self.pipeline = pipeline
        self.voxelPipeline = voxelPipeline
        self.raymarchDepthState = raymarchDepthState
        self.voxelDepthState = voxelDepthState
        self.itemBuffer = itemBuffer
        self.strokePointBuffer = strokePointBuffer
        self.distanceTexture = distanceTexture
        self.colorTexture = colorTexture
    }

    private func uploadVoxelMesh(_ engine: ClayEngine) {
        guard engine.voxelMeshVersion != uploadedVoxelVersion else { return }
        uploadedVoxelVersion = engine.voxelMeshVersion
        voxelIndexCount = engine.voxelIndices.count
        guard voxelIndexCount > 0 else { return }
        func buffer(_ floats: [Float], reusing existing: inout MTLBuffer?) {
            let bytes = floats.count * 4
            if existing == nil || existing!.length < bytes {
                existing = device.makeBuffer(length: max(bytes, 1 << 14),
                                             options: .storageModeShared)
            }
            floats.withUnsafeBytes {
                existing!.contents().copyMemory(from: $0.baseAddress!, byteCount: bytes)
            }
        }
        buffer(engine.voxelPositions, reusing: &voxelPositionBuffer)
        buffer(engine.voxelNormals, reusing: &voxelNormalBuffer)
        buffer(engine.voxelColors, reusing: &voxelColorBuffer)
        let indexBytes = engine.voxelIndices.count * 4
        if voxelIndexBuffer == nil || voxelIndexBuffer!.length < indexBytes {
            voxelIndexBuffer = device.makeBuffer(length: max(indexBytes, 1 << 14),
                                                options: .storageModeShared)
        }
        engine.voxelIndices.withUnsafeBytes {
            voxelIndexBuffer!.contents().copyMemory(from: $0.baseAddress!,
                                                    byteCount: indexBytes)
        }
    }

    private func ensureDepthTexture(width: Int, height: Int) -> MTLTexture? {
        if let depth = depthTexture, depth.width == width, depth.height == height {
            return depth
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float, width: width, height: height, mipmapped: false)
        descriptor.usage = .renderTarget
        descriptor.storageMode = .private
        depthTexture = device.makeTexture(descriptor: descriptor)
        return depthTexture
    }

    func draw(to drawable: CAMetalDrawable, time: Float, camera: OrbitCamera,
              engine: ClayEngine, selectedIndex: Int,
              lightDir: SIMD3<Float> = simd_normalize(SIMD3(0.5, 0.8, 0.3)),
              fullQuality: Bool = true) {
        let items = engine.items
        let strokePoints = engine.strokePoints
        if engine.version != uploadedVersion {
            let count = min(items.count, Self.maxItems)
            items.prefix(count).withUnsafeBytes { src in
                itemBuffer.contents().copyMemory(from: src.baseAddress!, byteCount: src.count)
            }
            if !strokePoints.isEmpty {
                let pointCount = min(strokePoints.count, ClayEngine.maxStrokePoints)
                strokePoints.prefix(pointCount).withUnsafeBytes { src in
                    strokePointBuffer.contents().copyMemory(from: src.baseAddress!,
                                                            byteCount: src.count)
                }
            }
            uploadedVersion = engine.version
        }

        if let cache = engine.fieldCache, engine.fieldCacheVersion != uploadedCacheVersion {
            let nx = Int(cache.dims.x), ny = Int(cache.dims.y), nz = Int(cache.dims.z)
            let region = MTLRegionMake3D(0, 0, 0, nx, ny, nz)
            cache.distances.withUnsafeBytes { src in
                distanceTexture.replace(region: region, mipmapLevel: 0, slice: 0,
                                        withBytes: src.baseAddress!,
                                        bytesPerRow: nx * 2, bytesPerImage: nx * ny * 2)
            }
            cache.colors.withUnsafeBytes { src in
                colorTexture.replace(region: region, mipmapLevel: 0, slice: 0,
                                     withBytes: src.baseAddress!,
                                     bytesPerRow: nx * 4, bytesPerImage: nx * ny * 4)
            }
            uploadedCacheVersion = engine.fieldCacheVersion
        }
        uploadVoxelMesh(engine)

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0.86, green: 0.85, blue: 0.84, alpha: 1)
        if let depth = ensureDepthTexture(width: drawable.texture.width,
                                          height: drawable.texture.height) {
            pass.depthAttachment.texture = depth
            pass.depthAttachment.loadAction = .clear
            pass.depthAttachment.storeAction = .dontCare
            pass.depthAttachment.clearDepth = 1.0
        }

        guard let commands = queue.makeCommandBuffer(),
              let encoder = commands.makeRenderCommandEncoder(descriptor: pass)
        else { return }

        let width = Float(drawable.texture.width)
        let height = Float(max(drawable.texture.height, 1))
        let basis = camera.basis
        let cache = engine.fieldCache
        let cacheUsable = cache != nil && uploadedCacheVersion == engine.fieldCacheVersion
        var uniforms = Uniforms(
            position: camera.position,
            right: basis.right,
            up: basis.up,
            forward: basis.forward,
            params: SIMD4(width / height, time, camera.lens, camera.orthoHalfHeight),
            itemCount: Int32(min(items.count, Self.maxItems)),
            bakedCount: Int32(cacheUsable ? (cache?.bakedItemCount ?? 0) : 0),
            mirrorAxes: engine.mirrorAxes,
            mirrorK: engine.mirrorK,
            selectedIndex: Int32(selectedIndex),
            gridOrigin: cacheUsable
                ? SIMD4(cache!.origin.x, cache!.origin.y, cache!.origin.z, 1)
                : SIMD4(0, 0, 0, 0),
            gridInvExtent: cacheUsable
                ? SIMD4(1 / cache!.extent.x, 1 / cache!.extent.y, 1 / cache!.extent.z,
                        max(0.0007, cache!.voxelSize * 0.3))
                : SIMD4(0, 0, 0, 0.0007),
            gridScale: cacheUsable
                ? SIMD4(Float(cache!.dims.x) / Float(FieldCache.maxResolution),
                        Float(cache!.dims.y) / Float(FieldCache.maxResolution),
                        Float(cache!.dims.z) / Float(FieldCache.maxResolution), 0)
                : SIMD4(1, 1, 1, 0),
            lightDir: SIMD4(lightDir.x, lightDir.y, lightDir.z, 0),
            material: engine.materialPreset.shadingParams,
            layerBits: SIMD4(engine.layerVisibilityMask,
                             engine.layerMirrorPacked,
                             UInt32(max(engine.sdfLayers.count, 1)),
                             fullQuality ? 1 : 0)
        )

        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(raymarchDepthState)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentBuffer(itemBuffer, offset: 0, index: 1)
        encoder.setFragmentBuffer(strokePointBuffer, offset: 0, index: 2)
        encoder.setFragmentTexture(distanceTexture, index: 0)
        encoder.setFragmentTexture(colorTexture, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        if voxelIndexCount > 0,
           let positions = voxelPositionBuffer, let normals = voxelNormalBuffer,
           let colors = voxelColorBuffer, let indices = voxelIndexBuffer {
            encoder.setRenderPipelineState(voxelPipeline)
            encoder.setDepthStencilState(voxelDepthState)
            encoder.setVertexBuffer(positions, offset: 0, index: 0)
            encoder.setVertexBuffer(normals, offset: 0, index: 1)
            encoder.setVertexBuffer(colors, offset: 0, index: 2)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 3)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.drawIndexedPrimitives(type: .triangle, indexCount: voxelIndexCount,
                                          indexType: .uint32, indexBuffer: indices,
                                          indexBufferOffset: 0)
        }
        encoder.endEncoding()

        commands.present(drawable)
        commands.commit()
    }
}
