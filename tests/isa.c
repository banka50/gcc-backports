// Compiled with -march=diamondrapids (AVX-512, AVX10.2, APX). Only assembled,
// never run: the point is that old binutils (buster's 2.31) could not assemble it.
void scale(float *restrict out, const float *restrict in, float k, int n) {
    for (int i = 0; i < n; i++) out[i] = in[i] * k;
}
