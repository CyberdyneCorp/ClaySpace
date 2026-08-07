import Metal
import os
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
        var previewInfo: SIMD3<Float> = SIMD3(-1, 0, 0) // x = preview slot
        var gridOrigin: SIMD4<Float>    // xyz origin; w = cache enabled (0/1)
        var gridInvExtent: SIMD4<Float> // xyz = 1/extent; w = normal epsilon
        var gridScale: SIMD4<Float>     // xyz = dims/maxResolution
        var lightDir: SIMD4<Float>      // xyz normalized (light dial)
        var material: SIMD4<Float>      // spec strength, shininess, metalness
        var layerBits: SIMD4<UInt32>    // visibility mask, mirror packed, count
        var maskOrigin: SIMD4<Float>    // xyz freeze-field origin; w = enabled
        var maskInvExtent: SIMD4<Float> // xyz = 1/extent
        var maskScale: SIMD4<Float>     // xyz = dims/maxResolution
        var previewBound: SIMD4<Float>  // xyz union-sphere center; w radius
    }

    static let maxItems = 256
    private let device: MTLDevice
    private let itemBuffer: MTLBuffer
    private let strokePointBuffer: MTLBuffer
    private let distanceTexture: MTLTexture
    private let colorTexture: MTLTexture
    private var uploadedVersion = -1
    private var uploadedCacheVersion = -1
    private var uploadedPointCount = 0
    /// Last GPU time of a completed frame, for the debug HUD.
    let gpuFrameTime = OSAllocatedUnfairLock<Double>(initialState: 0)

    /// During strokes the pool only appends — upload just the suffix.
    /// Any shrink or in-place edit (undo, thickness slider) falls back to
    /// a full copy.
    static func pointUploadRange(uploaded: Int, current: Int) -> Range<Int>? {
        guard current > 0 else { return nil }
        return current > uploaded ? uploaded..<current : 0..<current
    }

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
    private let maskTexture: MTLTexture
    private var uploadedMaskVersion = -1

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
        let maskDesc = MTLTextureDescriptor()
        maskDesc.textureType = .type3D
        maskDesc.pixelFormat = .r8Unorm
        maskDesc.width = ClayEngine.MaskField.maxResolution
        maskDesc.height = ClayEngine.MaskField.maxResolution
        maskDesc.depth = ClayEngine.MaskField.maxResolution
        maskDesc.usage = .shaderRead
        maskDesc.storageMode = .shared
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
              let colorTexture = device.makeTexture(descriptor: colorDesc),
              let maskTexture = device.makeTexture(descriptor: maskDesc)
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
        self.maskTexture = maskTexture
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
              fullQuality: Bool = true,
              preview: [SceneItem] = []) {
        let items = engine.items
        let strokePoints = engine.strokePoints
        if engine.version != uploadedVersion {
            let count = min(items.count, Self.maxItems)
            items.prefix(count).withUnsafeBytes { src in
                itemBuffer.contents().copyMemory(from: src.baseAddress!, byteCount: src.count)
            }
            let pointCount = min(strokePoints.count, ClayEngine.maxStrokePoints)
            if let range = Self.pointUploadRange(uploaded: uploadedPointCount,
                                                 current: pointCount) {
                let stride = MemoryLayout<SIMD4<Float>>.stride
                strokePoints[range].withUnsafeBytes { src in
                    strokePointBuffer.contents()
                        .advanced(by: range.lowerBound * stride)
                        .copyMemory(from: src.baseAddress!, byteCount: src.count)
                }
            }
            uploadedPointCount = pointCount
            uploadedVersion = engine.version
        }

        if let cache = engine.fieldCache, engine.fieldCacheVersion != uploadedCacheVersion {
            let nx = Int(cache.dims.x), ny = Int(cache.dims.y), nz = Int(cache.dims.z)
            // A partial bake on top of the texture we already uploaded only
            // needs its slab (docs/06 §2.2); anything else re-uploads whole.
            if let dirty = cache.dirtyCells,
               uploadedCacheVersion == engine.fieldCacheVersion - 1 {
                let cx = Int(dirty.max.x - dirty.min.x) + 1
                let cy = Int(dirty.max.y - dirty.min.y) + 1
                let cz = Int(dirty.max.z - dirty.min.z) + 1
                var slabDistances = [Float16]()
                slabDistances.reserveCapacity(cx * cy * cz)
                var slabColors = [UInt8]()
                slabColors.reserveCapacity(cx * cy * cz * 4)
                for z in Int(dirty.min.z)...Int(dirty.max.z) {
                    for y in Int(dirty.min.y)...Int(dirty.max.y) {
                        let row = (z * ny + y) * nx + Int(dirty.min.x)
                        slabDistances.append(contentsOf: cache.distances[row..<(row + cx)])
                        slabColors.append(contentsOf: cache.colors[(row * 4)..<((row + cx) * 4)])
                    }
                }
                let region = MTLRegionMake3D(Int(dirty.min.x), Int(dirty.min.y),
                                             Int(dirty.min.z), cx, cy, cz)
                slabDistances.withUnsafeBytes { src in
                    distanceTexture.replace(region: region, mipmapLevel: 0, slice: 0,
                                            withBytes: src.baseAddress!,
                                            bytesPerRow: cx * 2, bytesPerImage: cx * cy * 2)
                }
                slabColors.withUnsafeBytes { src in
                    colorTexture.replace(region: region, mipmapLevel: 0, slice: 0,
                                         withBytes: src.baseAddress!,
                                         bytesPerRow: cx * 4, bytesPerImage: cx * cy * 4)
                }
            } else {
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
            }
            uploadedCacheVersion = engine.fieldCacheVersion
        }
        uploadVoxelMesh(engine)

        // Freeze tint field (active SDF layer's mask), lazy per version.
        let maskField = engine.maskField()
        if let field = maskField, engine.maskFieldVersion != uploadedMaskVersion {
            let nx = Int(field.dims.x), ny = Int(field.dims.y), nz = Int(field.dims.z)
            field.weights.withUnsafeBytes { raw in
                maskTexture.replace(region: MTLRegionMake3D(0, 0, 0, nx, ny, nz),
                                    mipmapLevel: 0, slice: 0,
                                    withBytes: raw.baseAddress!,
                                    bytesPerRow: nx, bytesPerImage: nx * ny)
            }
        }
        uploadedMaskVersion = engine.maskFieldVersion

        // Pending ghosts (shape press or spray stamps): extra items past
        // the live list; the shader marches them as one combined field and
        // tints the silhouette.
        var previewSlot: Int32 = -1
        var previewCount: Int32 = 0
        let liveCount = min(items.count, Self.maxItems)
        var previewBound = SIMD4<Float>(repeating: 0)
        if !preview.isEmpty, liveCount < Self.maxItems {
            let ghosts = Array(preview.prefix(Self.maxItems - liveCount))
            previewSlot = Int32(liveCount)
            previewCount = Int32(ghosts.count)
            ghosts.withUnsafeBytes { src in
                itemBuffer.contents()
                    .advanced(by: MemoryLayout<SceneItem>.stride * liveCount)
                    .copyMemory(from: src.baseAddress!, byteCount: src.count)
            }
            // Union sphere: rays that miss it skip the ghost march entirely.
            var mn = ghosts[0].boundCenter - SIMD3(repeating: ghosts[0].boundRadius)
            var mx = ghosts[0].boundCenter + SIMD3(repeating: ghosts[0].boundRadius)
            for ghost in ghosts {
                mn = simd_min(mn, ghost.boundCenter - SIMD3(repeating: ghost.boundRadius))
                mx = simd_max(mx, ghost.boundCenter + SIMD3(repeating: ghost.boundRadius))
            }
            let center = (mn + mx) * 0.5
            previewBound = SIMD4(center.x, center.y, center.z,
                                 simd_length(mx - mn) * 0.5)
        }

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
            previewInfo: SIMD3(Float(previewSlot), Float(previewCount),
                               0.9 * min(max(engine.safeStepScale, 0.5), 1.3)),
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
                             fullQuality ? 1 : 0),
            maskOrigin: maskField.map {
                SIMD4($0.origin.x, $0.origin.y, $0.origin.z, 1)
            } ?? SIMD4(0, 0, 0, 0),
            maskInvExtent: maskField.map {
                SIMD4(1 / $0.extent.x, 1 / $0.extent.y, 1 / $0.extent.z, 0)
            } ?? SIMD4(repeating: 0),
            maskScale: maskField.map {
                let n = Float(ClayEngine.MaskField.maxResolution)
                return SIMD4(Float($0.dims.x) / n, Float($0.dims.y) / n,
                             Float($0.dims.z) / n, 0)
            } ?? SIMD4(repeating: 0),
            previewBound: previewBound
        )

        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(raymarchDepthState)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentBuffer(itemBuffer, offset: 0, index: 1)
        encoder.setFragmentBuffer(strokePointBuffer, offset: 0, index: 2)
        encoder.setFragmentTexture(distanceTexture, index: 0)
        encoder.setFragmentTexture(colorTexture, index: 1)
        encoder.setFragmentTexture(maskTexture, index: 2)
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

        commands.addCompletedHandler { [gpuFrameTime] buffer in
            // MTLCommandBuffer isn't Sendable; only two doubles cross.
            nonisolated(unsafe) let completed = buffer
            gpuFrameTime.withLock { $0 = completed.gpuEndTime - completed.gpuStartTime }
        }
        commands.present(drawable)
        commands.commit()
    }
}
