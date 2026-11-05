view.framebufferOnly = false  // (once: let a kernel write the screen's texture)

func draw(in view: MTKView) {
    guard let drawable = view.currentDrawable,
          let commands = queue.makeCommandBuffer(),
          let encoder = commands.makeComputeCommandEncoder() else { return }
    encoder.setComputePipelineState(fractal)        // the compiled .metal kernel
    encoder.setTexture(drawable.texture, index: 0)
    encoder.setBytes(&scale, length: 4, index: 0)
    encoder.dispatchThreads(MTLSize(width: w, height: h, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
    encoder.endEncoding()
    commands.present(drawable)
    commands.commit()
}
