#include <glslang/SPIRV/SPVRemapper.h>

extern "C" {
   bool glslang_remap(uint32_t *spv, size_t *spv_len) {
      // We're in C++ land now
      std::vector<uint32_t> spv_vector(spv, spv + *spv_len);

      // Do the remap
      spv::spirvbin_t bin(1);
      bin.remap(spv_vector, spv::spirvbin_t::DO_EVERYTHING);

      // Copy the result back into the original buffer
      if (spv_vector.size() > *spv_len) return false;
      memcpy(spv, spv_vector.data(), spv_vector.size() * sizeof(uint32_t));
      *spv_len = spv_vector.size();

      // Return success
      return true;
   }
}
