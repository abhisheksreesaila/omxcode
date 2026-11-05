kernel void fractal(texture2d<float, access::write> out [[texture(0)]],
                    constant float& scale [[buffer(0)]],
                    uint2 gid [[thread_position_in_grid]]) {
    out.write(colour(gid, scale), gid);  // straight into the screen's texture
}
