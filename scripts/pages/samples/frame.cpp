cudaGraphicsGLRegisterBuffer(&res, pbo, cudaGraphicsMapFlagsWriteDiscard);
// Every frame: the kernel writes into that buffer, on the GPU.
cudaGraphicsMapResources(1, &res);
cudaGraphicsResourceGetMappedPointer((void**)&pixels, &bytes, res);
fractal<<<dim3((w + 15) / 16, (h + 15) / 16), dim3(16, 16)>>>(pixels, w, h, scale);
cudaGraphicsUnmapResources(1, &res);
// OpenGL turns it into a texture (GPU to GPU) and draws a rectangle with it.
glBindBuffer(GL_PIXEL_UNPACK_BUFFER, pbo);
glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, w, h, GL_RGBA, GL_UNSIGNED_BYTE, 0);
glUseProgram(shader);
glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
