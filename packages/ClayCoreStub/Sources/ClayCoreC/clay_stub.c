/* Stub implementation of the clay.h ABI. Returns canned data (a unit
 * sphere field) so the app shell links and runs before ClayCore lands. */
#include "include/clay.h"

#include <math.h>
#include <stdlib.h>

struct clay_document {
    size_t layer_count;
};

const char *clay_version_string(void) { return "claycore-stub 0.1.0"; }

uint32_t clay_abi_version(void) {
    return ((uint32_t)CLAY_ABI_VERSION_MAJOR << 16) | CLAY_ABI_VERSION_MINOR;
}

clay_status clay_document_create(clay_document **out_doc) {
    if (!out_doc) return CLAY_ERR_INVALID_ARGUMENT;
    clay_document *doc = calloc(1, sizeof(clay_document));
    if (!doc) return CLAY_ERR_OUT_OF_MEMORY;
    doc->layer_count = 0;
    *out_doc = doc;
    return CLAY_OK;
}

void clay_document_destroy(clay_document *doc) { free(doc); }

size_t clay_document_layer_count(const clay_document *doc) {
    return doc ? doc->layer_count : 0;
}

clay_status clay_eval_points(const clay_document *doc,
                             const float *xyz,
                             size_t count,
                             float *out_distances) {
    if (!doc || !xyz || !out_distances) return CLAY_ERR_INVALID_ARGUMENT;
    for (size_t i = 0; i < count; i++) {
        const float x = xyz[3 * i + 0];
        const float y = xyz[3 * i + 1];
        const float z = xyz[3 * i + 2];
        out_distances[i] = sqrtf(x * x + y * y + z * z) - 1.0f;
    }
    return CLAY_OK;
}
