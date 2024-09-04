#pragma once
#include <stdint.h>

// Remap doesn't provide a C interface for some reason, so we create one here with the options we
// want baked in.
bool glslang_remap(uint32_t *spv, size_t *spv_len);
