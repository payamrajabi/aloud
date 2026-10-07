#include "ort_shim.h"
#include "../../Vendor/sherpa-onnx-asr/include/onnxruntime/onnxruntime_c_api.h"
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct OrtShimSession {
    OrtSession *session;
    OrtMemoryInfo *memory;
};

static const OrtApi *api;
static OrtEnv *env;
static pthread_once_t once = PTHREAD_ONCE_INIT;
static char init_error[256];

static void init(void) {
    api = OrtGetApiBase()->GetApi(ORT_API_VERSION);
    if (!api) {
        snprintf(init_error, sizeof init_error, "ONNX Runtime doesn't support API version %d", ORT_API_VERSION);
        return;
    }
    OrtStatus *s = api->CreateEnv(ORT_LOGGING_LEVEL_WARNING, "aloud", &env);
    if (s) {
        snprintf(init_error, sizeof init_error, "%s", api->GetErrorMessage(s));
        api->ReleaseStatus(s);
        env = NULL;
    }
}

/// Copies a failed status into `err` and releases it. Returns 1 if there was an error.
static int failed(OrtStatus *s, char *err, size_t err_len) {
    if (!s) return 0;
    if (err && err_len) snprintf(err, err_len, "%s", api->GetErrorMessage(s));
    api->ReleaseStatus(s);
    return 1;
}

OrtShimSession *ortshim_open(const char *model_path, int intra_threads, char *err, size_t err_len) {
    pthread_once(&once, init);
    if (!env) {
        if (err && err_len) snprintf(err, err_len, "%s", init_error[0] ? init_error : "ONNX Runtime failed to start");
        return NULL;
    }
    OrtSessionOptions *options = NULL;
    if (failed(api->CreateSessionOptions(&options), err, err_len)) return NULL;
    OrtShimSession *result = NULL;
    OrtSession *session = NULL;
    OrtMemoryInfo *memory = NULL;
    if (intra_threads > 0 && failed(api->SetIntraOpNumThreads(options, intra_threads), err, err_len)) goto done;
    if (failed(api->SetInterOpNumThreads(options, 1), err, err_len)) goto done;
    if (failed(api->SetSessionGraphOptimizationLevel(options, ORT_ENABLE_ALL), err, err_len)) goto done;
    if (failed(api->CreateSession(env, model_path, options, &session), err, err_len)) goto done;
    if (failed(api->CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &memory), err, err_len)) {
        api->ReleaseSession(session);
        goto done;
    }
    result = calloc(1, sizeof *result);
    result->session = session;
    result->memory = memory;
done:
    api->ReleaseSessionOptions(options);
    return result;
}

void ortshim_close(OrtShimSession *s) {
    if (!s) return;
    api->ReleaseSession(s->session);
    api->ReleaseMemoryInfo(s->memory);
    free(s);
}

int ortshim_run(OrtShimSession *s, const OrtShimInput *inputs, size_t n,
                const char *output_name, float **out_data, int64_t *out_shape, size_t *out_rank,
                char *err, size_t err_len) {
    *out_data = NULL;
    *out_rank = 0;
    OrtValue **values = calloc(n, sizeof *values);
    const char **names = calloc(n, sizeof *names);
    OrtValue *output = NULL;
    OrtTensorTypeAndShapeInfo *info = NULL;
    int rc = 1;

    for (size_t i = 0; i < n; i++) {
        size_t count = 1;
        for (size_t d = 0; d < inputs[i].rank; d++) count *= (size_t)inputs[i].shape[d];
        size_t bytes = count * (inputs[i].type == ORTSHIM_FLOAT ? sizeof(float) : sizeof(int64_t));
        ONNXTensorElementDataType type = inputs[i].type == ORTSHIM_FLOAT
            ? ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT : ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64;
        if (failed(api->CreateTensorWithDataAsOrtValue(s->memory, (void *)inputs[i].data, bytes,
                                                       inputs[i].shape, inputs[i].rank, type, &values[i]),
                   err, err_len)) goto done;
        names[i] = inputs[i].name;
    }
    if (failed(api->Run(s->session, NULL, names, (const OrtValue *const *)values, n,
                        &output_name, 1, &output), err, err_len)) goto done;

    if (failed(api->GetTensorTypeAndShape(output, &info), err, err_len)) goto done;
    ONNXTensorElementDataType type;
    size_t rank = 0, count = 0;
    if (failed(api->GetTensorElementType(info, &type), err, err_len)) goto done;
    if (type != ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT) {
        snprintf(err, err_len, "output %s isn't a float tensor", output_name);
        goto done;
    }
    if (failed(api->GetDimensionsCount(info, &rank), err, err_len)) goto done;
    if (rank > 8) { snprintf(err, err_len, "output rank %zu is too large", rank); goto done; }
    if (failed(api->GetDimensions(info, out_shape, rank), err, err_len)) goto done;
    if (failed(api->GetTensorShapeElementCount(info, &count), err, err_len)) goto done;
    float *src = NULL;
    if (failed(api->GetTensorMutableData(output, (void **)&src), err, err_len)) goto done;
    *out_data = malloc(count ? count * sizeof(float) : 1);
    if (count) memcpy(*out_data, src, count * sizeof(float));
    *out_rank = rank;
    rc = 0;

done:
    if (info) api->ReleaseTensorTypeAndShapeInfo(info);
    if (output) api->ReleaseValue(output);
    for (size_t i = 0; i < n; i++) if (values[i]) api->ReleaseValue(values[i]);
    free(values);
    free(names);
    return rc;
}

void ortshim_free(void *p) { free(p); }
