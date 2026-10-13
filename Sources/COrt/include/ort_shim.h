// A minimal C wrapper around the ONNX Runtime C API: open a model, run it with a
// few float/int64 inputs, read back one float output. Swift calls this instead of
// the OrtApi function-pointer table directly.
#pragma once
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct OrtShimSession OrtShimSession;

typedef enum { ORTSHIM_FLOAT = 0, ORTSHIM_INT64 = 1 } OrtShimType;

typedef struct {
    const char *name;
    OrtShimType type;
    const void *data;       // borrowed for the duration of the call
    const int64_t *shape;
    size_t rank;
} OrtShimInput;

/// Loads a model. `intra_threads` <= 0 lets ONNX Runtime choose. Returns NULL and
/// writes a message into `err` on failure.
OrtShimSession *ortshim_open(const char *model_path, int intra_threads, char *err, size_t err_len);
void ortshim_close(OrtShimSession *session);

/// Runs the model and copies the float output named `output_name` into a buffer
/// allocated with malloc (free it with ortshim_free). `out_shape` must hold 8 values.
/// Returns 0 on success.
int ortshim_run(OrtShimSession *session, const OrtShimInput *inputs, size_t input_count,
                const char *output_name, float **out_data, int64_t *out_shape, size_t *out_rank,
                char *err, size_t err_len);

void ortshim_free(void *p);

#ifdef __cplusplus
}
#endif
