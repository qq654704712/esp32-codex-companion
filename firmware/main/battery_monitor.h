#pragma once

#include <stdbool.h>
#include <stdint.h>

typedef struct {
    bool valid;
    bool charging;
    uint8_t percent;
    uint16_t millivolts;
    int16_t current_ma;
} cc_battery_sample_t;

/** Attach a read-only client to the board's BQ27220 fuel gauge. */
bool cc_battery_monitor_init(void);
/** Read one coherent-enough UI sample without changing gauge configuration. */
bool cc_battery_monitor_read(cc_battery_sample_t *sample);
