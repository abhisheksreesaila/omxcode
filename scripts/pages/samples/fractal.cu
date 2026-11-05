__global__ void fractal(uchar4* out, int w, int h, float scale) {
    int x = blockIdx.x * blockDim.x + threadIdx.x;
    int y = blockIdx.y * blockDim.y + threadIdx.y;
    if (x >= w || y >= h) return;
    out[y * w + x] = colour(x, y, w, h, scale);  // the maths: a __device__ function
}
