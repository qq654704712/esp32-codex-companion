#ifndef CODEX_COMPANION_DEVICE_MODEL_H
#define CODEX_COMPANION_DEVICE_MODEL_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define CC_SCREEN_SIZE_PX 360
#define CC_OUTER_RING_RADIUS_PX 175
#define CC_INNER_RING_RADIUS_PX 166
#define CC_RING_WIDTH_PX 5
#define CC_BUTTON_DEBOUNCE_MS 30
#define CC_PTT_POST_ROLL_MS 200
#define CC_QUOTA_STALE_MS 120000

typedef enum {
    CC_STATE_DISCONNECTED = 0,
    CC_STATE_IDLE,
    CC_STATE_SESSION_STARTING,
    CC_STATE_WORKING,
    CC_STATE_COMPLETED,
    CC_STATE_ERROR,
    CC_STATE_APPROVAL_REQUIRED,
    CC_STATE_INPUT_REQUIRED,
    CC_STATE_CONFIRMATION_REQUIRED,
    CC_STATE_LISTENING,
    CC_STATE_VOICE_ERROR,
    CC_STATE_WRITING,
    CC_STATE_RUNNING,
} cc_device_state_t;

typedef enum {
    CC_BUTTON_NONE = 0,
    CC_BUTTON_PTT_DOWN,
    CC_BUTTON_PTT_UP,
} cc_button_action_t;

typedef struct {
    bool available;
    uint8_t percent;
} cc_quota_value_t;

typedef struct {
    bool connected;
    cc_device_state_t remote_state;
    cc_device_state_t visible_state;
    cc_quota_value_t five_hour;
    cc_quota_value_t week;
    uint64_t quota_updated_at_ms;
    bool stable_button_down;
    bool candidate_button_down;
    uint64_t candidate_since_ms;
} cc_device_model_t;

void cc_device_model_init(cc_device_model_t *model);
void cc_device_set_connected(cc_device_model_t *model, bool connected,
                             uint64_t now_ms);
/**
 * Applies a state received from the Mac and returns true only when it changed.
 * Callers use this to avoid replaying UI effects (notably the shared-I2S
 * notification tone) for duplicate state updates.
 */
bool cc_device_set_remote_state(cc_device_model_t *model,
                                cc_device_state_t state);
cc_button_action_t cc_device_button_sample(cc_device_model_t *model,
                                            bool button_down,
                                            uint64_t now_ms);
void cc_device_update_quota(cc_device_model_t *model,
                            bool five_hour_available,
                            uint8_t five_hour_percent,
                            bool week_available,
                            uint8_t week_percent,
                            uint64_t now_ms);
void cc_device_mark_quota_fresh(cc_device_model_t *model, uint64_t now_ms);
bool cc_device_quota_is_stale(const cc_device_model_t *model,
                              uint64_t now_ms);

#ifdef __cplusplus
}
#endif

#endif
