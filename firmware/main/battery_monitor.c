#include "battery_monitor.h"

#include <string.h>

#include "bsp/esp-bsp.h"
#include "driver/i2c_master.h"
#include "esp_log.h"

#define BQ27220_ADDRESS 0x55
#define BQ27220_REG_VOLTAGE 0x08
#define BQ27220_REG_CURRENT 0x0C
#define BQ27220_REG_STATE_OF_CHARGE 0x2C

static const char *TAG = "cc_battery";
static i2c_master_dev_handle_t gauge;

static bool read_u16(uint8_t reg, uint16_t *value) {
    if (!gauge || !value) return false;
    uint8_t bytes[2] = {0};
    const esp_err_t result = i2c_master_transmit_receive(
        gauge, &reg, 1, bytes, sizeof(bytes), 100);
    if (result != ESP_OK) return false;
    // BQ27220 standard commands return low byte first.
    *value = (uint16_t)bytes[0] | ((uint16_t)bytes[1] << 8);
    return true;
}

bool cc_battery_monitor_init(void) {
    if (gauge) return true;
    i2c_master_bus_handle_t bus = bsp_i2c_get_handle();
    if (!bus) {
        ESP_LOGW(TAG, "shared I2C bus unavailable");
        return false;
    }
    const i2c_device_config_t config = {
        .dev_addr_length = I2C_ADDR_BIT_LEN_7,
        .device_address = BQ27220_ADDRESS,
        .scl_speed_hz = 100000,
    };
    const esp_err_t result = i2c_master_bus_add_device(bus, &config, &gauge);
    if (result != ESP_OK) {
        gauge = NULL;
        ESP_LOGW(TAG, "BQ27220 attach failed: %s", esp_err_to_name(result));
        return false;
    }
    cc_battery_sample_t sample;
    if (!cc_battery_monitor_read(&sample)) {
        ESP_LOGW(TAG, "BQ27220 did not return a valid initial sample");
        return false;
    }
    ESP_LOGI(TAG, "battery %u%% %umV current=%dmA",
             sample.percent, sample.millivolts, sample.current_ma);
    return true;
}

bool cc_battery_monitor_read(cc_battery_sample_t *sample) {
    if (!sample) return false;
    memset(sample, 0, sizeof(*sample));
    uint16_t percent = 0;
    uint16_t millivolts = 0;
    uint16_t current_raw = 0;
    if (!read_u16(BQ27220_REG_STATE_OF_CHARGE, &percent) ||
        !read_u16(BQ27220_REG_VOLTAGE, &millivolts) ||
        !read_u16(BQ27220_REG_CURRENT, &current_raw)) {
        return false;
    }
    if (percent > 100 || millivolts < 2500 || millivolts > 5000) return false;
    sample->valid = true;
    sample->percent = (uint8_t)percent;
    sample->millivolts = millivolts;
    sample->current_ma = (int16_t)current_raw;
    sample->charging = sample->current_ma > 10;
    return true;
}
