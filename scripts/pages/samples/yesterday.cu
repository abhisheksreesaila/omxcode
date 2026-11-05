// the maths: a __device__ function
__device__ uchar4 colour(int x, int y, int w, int h, Params p);
// the kernel: find your pixel, check the edges, write it
__global__ void fractal(uchar4* out, int w, int h, Params p) {
    int x = blockIdx.x * blockDim.x + threadIdx.x;
    int y = blockIdx.y * blockDim.y + threadIdx.y;
    if (x >= w || y >= h) return;
    out[y * w + x] = colour(x, y, w, h, p);
}
// host code, every frame: map the shared buffer, launch, unmap
cudaGraphicsMapResources(1, &res);
cudaGraphicsResourceGetMappedPointer((void**)&pixels, &bytes, res);
fractal<<<dim3((w + 15) / 16, (h + 15) / 16), dim3(16, 16)>>>(pixels, w, h, p);
cudaGraphicsUnmapResources(1, &res);
// then OpenGL: buffer to texture, and a rectangle drawn by a GLSL shader
glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, w, h, GL_RGBA, GL_UNSIGNED_BYTE, 0);
glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
