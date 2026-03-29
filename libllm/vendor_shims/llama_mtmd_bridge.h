#ifndef RTM_LLAMA_MTMD_BRIDGE_H
#define RTM_LLAMA_MTMD_BRIDGE_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

struct rtm_llm_session;

typedef enum rtm_llm_error_kind {
    RTM_LLM_ERROR_NONE = 0,
    RTM_LLM_ERROR_MODEL_NOT_FOUND = 1,
    RTM_LLM_ERROR_MMPROJ_NOT_FOUND = 2,
    RTM_LLM_ERROR_IMAGE_NOT_FOUND = 3,
    RTM_LLM_ERROR_BACKEND_INIT_FAILED = 4,
    RTM_LLM_ERROR_BACKEND_INFERENCE_FAILED = 5,
    RTM_LLM_ERROR_UTF8_DECODE_FAILED = 6,
    RTM_LLM_ERROR_OUT_OF_MEMORY = 7,
    RTM_LLM_ERROR_UNSUPPORTED_REQUEST = 8,
    RTM_LLM_ERROR_UNKNOWN = 9,
} rtm_llm_error_kind;

typedef enum rtm_llm_finish_reason {
    RTM_LLM_FINISH_STOP = 0,
    RTM_LLM_FINISH_LENGTH = 1,
    RTM_LLM_FINISH_ERROR = 2,
    RTM_LLM_FINISH_UNKNOWN = 3,
} rtm_llm_finish_reason;

typedef struct rtm_llm_model_config {
    const char * model_path;
    const char * mmproj_path;
    uint32_t ctx_size;
    uint16_t threads;
    uint16_t gpu_layers;
    uint32_t seed;
    bool has_seed;
} rtm_llm_model_config;

typedef struct rtm_llm_request {
    const char * prompt;
    const char * image_path;
    uint32_t max_tokens;
    bool has_max_tokens;
    float temperature;
    float top_p;
    uint32_t seed;
    bool has_seed;
    bool json_mode;
} rtm_llm_request;

typedef struct rtm_llm_response {
    char * text;
    uint32_t prompt_tokens;
    bool has_prompt_tokens;
    uint32_t completion_tokens;
    bool has_completion_tokens;
    rtm_llm_finish_reason finish_reason;
} rtm_llm_response;

struct rtm_llm_session * rtm_llm_session_create(const rtm_llm_model_config * config);
void rtm_llm_session_destroy(struct rtm_llm_session * session);
bool rtm_llm_infer_image(struct rtm_llm_session * session, const rtm_llm_request * request, rtm_llm_response * response);
const char * rtm_llm_last_error(const struct rtm_llm_session * session);
rtm_llm_error_kind rtm_llm_session_error_kind(const struct rtm_llm_session * session);
const char * rtm_llm_global_last_error(void);
rtm_llm_error_kind rtm_llm_global_error_kind(void);
void rtm_llm_response_free(rtm_llm_response * response);

#ifdef __cplusplus
}
#endif

#endif
