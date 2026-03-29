#include "llama_mtmd_bridge.h"

#include "llama.h"
#include "mtmd.h"
#include "mtmd-helper.h"

#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <memory>
#include <string>
#include <vector>

extern "C" void ggml_backend_load_all(void);

namespace {

int32_t effective_gpu_layers(const rtm_llm_model_config * config) {
    if (!config) {
        return -1;
    }
    return config->gpu_layers == 0 ? -1 : static_cast<int32_t>(config->gpu_layers);
}

struct Session {
    llama_model * model = nullptr;
    mtmd_context * vision = nullptr;
    rtm_llm_model_config config{};
    std::string last_error;
    rtm_llm_error_kind last_error_kind = RTM_LLM_ERROR_NONE;
};

thread_local std::string g_last_error;
thread_local rtm_llm_error_kind g_last_error_kind = RTM_LLM_ERROR_NONE;

void set_global_error(rtm_llm_error_kind kind, const std::string & message) {
    g_last_error_kind = kind;
    g_last_error = message;
}

void set_session_error(Session * session, rtm_llm_error_kind kind, const std::string & message) {
    session->last_error_kind = kind;
    session->last_error = message;
    set_global_error(kind, message);
}

void clear_session_error(Session * session) {
    session->last_error_kind = RTM_LLM_ERROR_NONE;
    session->last_error.clear();
}

bool path_exists(const char * path) {
    return path != nullptr && *path != '\0' && std::filesystem::exists(path);
}

uint32_t default_seed(const rtm_llm_request * request, const rtm_llm_model_config & config) {
    if (request->has_seed) {
        return request->seed;
    }
    if (config.has_seed) {
        return config.seed;
    }
    return LLAMA_DEFAULT_SEED;
}

llama_sampler * make_sampler(const rtm_llm_request * request, const rtm_llm_model_config & config) {
    auto chain = llama_sampler_chain_init(llama_sampler_chain_default_params());
    if (request->temperature <= 0.0f) {
        llama_sampler_chain_add(chain, llama_sampler_init_greedy());
        return chain;
    }

    if (request->top_p > 0.0f && request->top_p < 1.0f) {
        llama_sampler_chain_add(chain, llama_sampler_init_top_p(request->top_p, 1));
    }
    llama_sampler_chain_add(chain, llama_sampler_init_temp(request->temperature));
    llama_sampler_chain_add(chain, llama_sampler_init_dist(default_seed(request, config)));
    return chain;
}

std::string add_media_marker(const char * prompt) {
    std::string final_prompt = prompt ? prompt : "";
    const char * marker = mtmd_default_marker();
    if (final_prompt.find(marker) == std::string::npos) {
        final_prompt += marker;
    }
    return final_prompt;
}

std::string token_to_piece(const llama_vocab * vocab, llama_token token) {
    int size = 256;
    std::vector<char> buf(static_cast<size_t>(size));
    while (true) {
        const int written = llama_token_to_piece(vocab, token, buf.data(), size, 0, true);
        if (written >= 0) {
            return std::string(buf.data(), static_cast<size_t>(written));
        }
        size = -written + 8;
        buf.resize(static_cast<size_t>(size));
    }
}

bool copy_text_out(const std::string & src, rtm_llm_response * response) {
    response->text = static_cast<char *>(std::malloc(src.size() + 1));
    if (!response->text) {
        return false;
    }
    std::memcpy(response->text, src.data(), src.size());
    response->text[src.size()] = '\0';
    return true;
}

} // namespace

extern "C" struct rtm_llm_session * rtm_llm_session_create(const rtm_llm_model_config * config) {
    if (config == nullptr) {
        set_global_error(RTM_LLM_ERROR_BACKEND_INIT_FAILED, "null model config");
        return nullptr;
    }
    if (!path_exists(config->model_path)) {
        set_global_error(RTM_LLM_ERROR_MODEL_NOT_FOUND, "model file not found");
        return nullptr;
    }
    if (!path_exists(config->mmproj_path)) {
        set_global_error(RTM_LLM_ERROR_MMPROJ_NOT_FOUND, "mmproj file not found");
        return nullptr;
    }

    llama_backend_init();
    ggml_backend_load_all();
    llama_log_set([](enum ggml_log_level level, const char * text, void * user_data) {
        if (level >= GGML_LOG_LEVEL_ERROR) {
            Session * session = static_cast<Session *>(user_data);
            if (session) {
                session->last_error = text;
                session->last_error_kind = RTM_LLM_ERROR_BACKEND_INIT_FAILED;
            } else if (text) {
                set_global_error(RTM_LLM_ERROR_BACKEND_INIT_FAILED, text);
            }
        }
    }, nullptr);

    std::unique_ptr<Session> session(new Session{});
    session->config = *config;

    llama_model_params model_params = llama_model_default_params();
    model_params.n_gpu_layers = effective_gpu_layers(config);
    session->model = llama_model_load_from_file(config->model_path, model_params);
    if (!session->model) {
        if (g_last_error.empty()) {
            set_global_error(RTM_LLM_ERROR_BACKEND_INIT_FAILED, "failed to load llama model");
        }
        return nullptr;
    }

    mtmd_context_params vision_params = mtmd_context_params_default();
    vision_params.use_gpu = effective_gpu_layers(config) != 0;
    vision_params.print_timings = false;
    vision_params.n_threads = config->threads;
    session->vision = mtmd_init_from_file(config->mmproj_path, session->model, vision_params);
    if (!session->vision) {
        llama_model_free(session->model);
        session->model = nullptr;
        if (g_last_error.empty()) {
            set_global_error(RTM_LLM_ERROR_BACKEND_INIT_FAILED, "failed to load multimodal projector");
        }
        return nullptr;
    }

    clear_session_error(session.get());
    return reinterpret_cast<rtm_llm_session *>(session.release());
}

extern "C" void rtm_llm_session_destroy(struct rtm_llm_session * opaque) {
    Session * session = reinterpret_cast<Session *>(opaque);
    if (!session) {
        return;
    }
    if (session->vision) {
        mtmd_free(session->vision);
    }
    if (session->model) {
        llama_model_free(session->model);
    }
    delete session;
}

extern "C" bool rtm_llm_infer_image(struct rtm_llm_session * opaque, const rtm_llm_request * request, rtm_llm_response * response) {
    Session * session = reinterpret_cast<Session *>(opaque);
    if (!session || !request || !response) {
        set_global_error(RTM_LLM_ERROR_BACKEND_INFERENCE_FAILED, "invalid inference arguments");
        return false;
    }
    clear_session_error(session);
    *response = {};
    llama_log_set([](enum ggml_log_level level, const char * text, void * user_data) {
        if (level >= GGML_LOG_LEVEL_ERROR && text) {
            Session * current = static_cast<Session *>(user_data);
            if (current) {
                current->last_error = text;
                current->last_error_kind = RTM_LLM_ERROR_BACKEND_INFERENCE_FAILED;
            }
        }
    }, session);

    if (!path_exists(request->image_path)) {
        set_session_error(session, RTM_LLM_ERROR_IMAGE_NOT_FOUND, "image file not found");
        return false;
    }

    llama_context_params ctx_params = llama_context_default_params();
    ctx_params.n_ctx = session->config.ctx_size;
    ctx_params.n_batch = static_cast<uint32_t>(std::min<uint32_t>(session->config.ctx_size, 2048));

    llama_context * lctx = llama_init_from_model(session->model, ctx_params);
    if (!lctx) {
        set_session_error(session, RTM_LLM_ERROR_BACKEND_INFERENCE_FAILED, "failed to create llama context");
        return false;
    }
    auto free_lctx = std::unique_ptr<llama_context, decltype(&llama_free)>(lctx, &llama_free);
    llama_set_n_threads(lctx, session->config.threads, session->config.threads);

    auto sampler = std::unique_ptr<llama_sampler, decltype(&llama_sampler_free)>(
        make_sampler(request, session->config),
        &llama_sampler_free);

    std::string user_prompt = add_media_marker(request->prompt);
    llama_chat_message message{
        .role = "user",
        .content = user_prompt.c_str(),
    };
    const char * tmpl = llama_model_chat_template(session->model, nullptr);
    std::vector<char> formatted(4096);
    int formatted_size = tmpl
        ? llama_chat_apply_template(tmpl, &message, 1, true, formatted.data(), static_cast<int32_t>(formatted.size()))
        : -1;
    if (formatted_size < 0) {
        formatted.assign(user_prompt.begin(), user_prompt.end());
        formatted.push_back('\0');
        formatted_size = static_cast<int>(formatted.size() - 1);
    } else if (formatted_size > static_cast<int>(formatted.size())) {
        formatted.resize(static_cast<size_t>(formatted_size));
        formatted_size = llama_chat_apply_template(tmpl, &message, 1, true, formatted.data(), static_cast<int32_t>(formatted.size()));
    }
    if (formatted_size < 0) {
        set_session_error(session, RTM_LLM_ERROR_BACKEND_INFERENCE_FAILED, "failed to apply chat template");
        return false;
    }

    mtmd_bitmap * bitmap = mtmd_helper_bitmap_init_from_file(session->vision, request->image_path);
    if (!bitmap) {
        set_session_error(session, RTM_LLM_ERROR_BACKEND_INFERENCE_FAILED, "failed to load image bitmap");
        return false;
    }
    auto free_bitmap = std::unique_ptr<mtmd_bitmap, decltype(&mtmd_bitmap_free)>(bitmap, &mtmd_bitmap_free);

    mtmd_input_text input_text{
        .text = formatted.data(),
        .add_special = true,
        .parse_special = true,
    };
    const mtmd_bitmap * bitmaps[1] = { bitmap };
    mtmd_input_chunks * chunks = mtmd_input_chunks_init();
    if (!chunks) {
        set_session_error(session, RTM_LLM_ERROR_OUT_OF_MEMORY, "failed to allocate mtmd chunks");
        return false;
    }
    auto free_chunks = std::unique_ptr<mtmd_input_chunks, decltype(&mtmd_input_chunks_free)>(chunks, &mtmd_input_chunks_free);

    const int32_t tokenized = mtmd_tokenize(session->vision, chunks, &input_text, bitmaps, 1);
    if (tokenized != 0) {
        set_session_error(session, RTM_LLM_ERROR_BACKEND_INFERENCE_FAILED, "failed to tokenize multimodal prompt");
        return false;
    }

    llama_pos new_n_past = 0;
    const int32_t eval_status = mtmd_helper_eval_chunks(session->vision, lctx, chunks, 0, 0, static_cast<int32_t>(ctx_params.n_batch), true, &new_n_past);
    if (eval_status != 0) {
        set_session_error(session, RTM_LLM_ERROR_BACKEND_INFERENCE_FAILED, "failed to evaluate multimodal prompt");
        return false;
    }

    const llama_vocab * vocab = llama_model_get_vocab(session->model);
    const uint32_t max_tokens = request->has_max_tokens ? request->max_tokens : 512;
    std::string output;
    output.reserve(2048);
    response->prompt_tokens = static_cast<uint32_t>(mtmd_helper_get_n_tokens(chunks));
    response->has_prompt_tokens = true;

    for (uint32_t i = 0; i < max_tokens; ++i) {
        const llama_token token = llama_sampler_sample(sampler.get(), lctx, -1);
        llama_sampler_accept(sampler.get(), token);

        if (llama_vocab_is_eog(vocab, token)) {
            response->completion_tokens = i;
            response->has_completion_tokens = true;
            response->finish_reason = RTM_LLM_FINISH_STOP;
            if (!copy_text_out(output, response)) {
                set_session_error(session, RTM_LLM_ERROR_OUT_OF_MEMORY, "failed to allocate output text");
                return false;
            }
            return true;
        }

        output += token_to_piece(vocab, token);
        auto batch = llama_batch_get_one(const_cast<llama_token *>(&token), 1);
        const int32_t decode_status = llama_decode(lctx, batch);
        if (decode_status != 0) {
            set_session_error(session, RTM_LLM_ERROR_BACKEND_INFERENCE_FAILED, "failed during token decode");
            return false;
        }
    }

    response->completion_tokens = max_tokens;
    response->has_completion_tokens = true;
    response->finish_reason = RTM_LLM_FINISH_LENGTH;
    if (!copy_text_out(output, response)) {
        set_session_error(session, RTM_LLM_ERROR_OUT_OF_MEMORY, "failed to allocate output text");
        return false;
    }
    return true;
}

extern "C" const char * rtm_llm_last_error(const struct rtm_llm_session * opaque) {
    const Session * session = reinterpret_cast<const Session *>(opaque);
    if (!session) {
        return "";
    }
    return session->last_error.c_str();
}

extern "C" rtm_llm_error_kind rtm_llm_session_error_kind(const struct rtm_llm_session * opaque) {
    const Session * session = reinterpret_cast<const Session *>(opaque);
    if (!session) {
        return RTM_LLM_ERROR_UNKNOWN;
    }
    return session->last_error_kind;
}

extern "C" const char * rtm_llm_global_last_error(void) {
    return g_last_error.c_str();
}

extern "C" rtm_llm_error_kind rtm_llm_global_error_kind(void) {
    return g_last_error_kind;
}

extern "C" void rtm_llm_response_free(rtm_llm_response * response) {
    if (!response) {
        return;
    }
    if (response->text) {
        std::free(response->text);
        response->text = nullptr;
    }
}
