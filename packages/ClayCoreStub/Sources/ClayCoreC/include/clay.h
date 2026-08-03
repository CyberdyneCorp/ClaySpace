/* clay.h — ClayCore stable C ABI (stub surface, ABI 0.1)
 *
 * Contract per docs/05-claycore-library.md §11: opaque handles, error
 * codes, caller-owned buffers; no C++ types cross this boundary. The
 * real implementation lives in the ClayCore repository; this header is
 * the seam the ClaySpace app codes against.
 */
#ifndef CLAY_H
#define CLAY_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define CLAY_ABI_VERSION_MAJOR 0
#define CLAY_ABI_VERSION_MINOR 1

typedef enum clay_status {
    CLAY_OK = 0,
    CLAY_ERR_INVALID_ARGUMENT = 1,
    CLAY_ERR_UNSUPPORTED = 2,
    CLAY_ERR_OUT_OF_MEMORY = 3
} clay_status;

/* Library identity */
const char *clay_version_string(void);
uint32_t clay_abi_version(void); /* (major << 16) | minor */

/* Document lifecycle (opaque handle) */
typedef struct clay_document clay_document;

clay_status clay_document_create(clay_document **out_doc);
void clay_document_destroy(clay_document *doc);
size_t clay_document_layer_count(const clay_document *doc);

/* Batch field evaluation: xyz = count interleaved float triples,
 * out_distances = caller-owned buffer of count floats. */
clay_status clay_eval_points(const clay_document *doc,
                             const float *xyz,
                             size_t count,
                             float *out_distances);

#ifdef __cplusplus
}
#endif

#endif /* CLAY_H */
