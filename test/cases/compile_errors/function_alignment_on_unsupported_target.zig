export fn entry() align(64) void {}

// error
// backend=stage2
// target=nvptx-cuda,nvptx64-cuda,spirv32-opengl,spirv32-vulkan,spirv32-opencl,spirv64-opencl,spirv64-amdhsa,wasm32-freestanding,wasm64-freestanding
//
// :1:25: error: target does not support function alignment
