#ifndef RTMIFY_BRIDGE_H
#define RTMIFY_BRIDGE_H
#include <stdint.h>

typedef struct RtmifyGraph RtmifyGraph;
typedef enum RtmifyProfile {
    RTMIFY_PROFILE_GENERIC = 0,
    RTMIFY_PROFILE_MEDICAL = 1,
    RTMIFY_PROFILE_AEROSPACE = 2,
    RTMIFY_PROFILE_AUTOMOTIVE = 3,
} RtmifyProfile;

typedef struct RtmifyAnalysisSummary {
    int32_t profile;
    char profile_short_name[16];
    char profile_display_name[32];
    char profile_standards[128];
    int32_t warning_count;
    int32_t generic_gap_count;
    int32_t profile_gap_count;
    int32_t total_gap_count;
} RtmifyAnalysisSummary;

typedef struct RtmifyLicenseStatus {
    int32_t state;
    int32_t permits_use;
    int32_t using_free_run;
    int64_t expires_at;
    int64_t issued_at;
    int32_t detail_code;
    char expected_key_fingerprint[65];
    char license_signing_key_fingerprint[65];
} RtmifyLicenseStatus;

#define RTMIFY_OK                  0
#define RTMIFY_ERR_FILE_NOT_FOUND  1
#define RTMIFY_ERR_INVALID_XLSX    2
#define RTMIFY_ERR_MISSING_TAB     3
#define RTMIFY_ERR_LICENSE         4
#define RTMIFY_ERR_OUTPUT          5

int32_t rtmify_load(const char* xlsx_path, RtmifyGraph** out_graph);
int32_t rtmify_load_with_profile(const char* xlsx_path, int32_t profile,
                                 RtmifyGraph** out_graph, RtmifyAnalysisSummary* out_summary);
int32_t rtmify_generate(const RtmifyGraph* graph, const char* format,
                        const char* output_path, const char* project_name);
int32_t rtmify_gap_count(const RtmifyGraph* graph);
int32_t rtmify_graph_summary(const RtmifyGraph* graph, RtmifyAnalysisSummary* out_summary);
int32_t rtmify_warning_count(void);
const char* rtmify_last_error(void);
void rtmify_free(RtmifyGraph* graph);
int32_t rtmify_trace_license_get_status(RtmifyLicenseStatus* out_status);
int32_t rtmify_trace_license_install(const char* path, RtmifyLicenseStatus* out_status);
int32_t rtmify_trace_license_clear(RtmifyLicenseStatus* out_status);
int32_t rtmify_trace_license_record_successful_use(void);
int32_t rtmify_trace_license_info_json(void);
int32_t rtmify_check_license(void);

#endif
