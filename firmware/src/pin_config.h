// Board: Waveshare ESP32-S3-Touch-AMOLED-1.8 (368x448, SH8601 QSPI, AXP2101 PMU,
// TCA9554 I/O expander, FT3168 touch). Pins verified against Waveshare's
// Mylibrary/pin_config.h. If your board revision differs, reconcile with the
// pin_config.h in Waveshare's official Arduino demo for this exact board.
#pragma once

// ---- SH8601 AMOLED over QSPI ----
#define LCD_SDIO0 4
#define LCD_SDIO1 5
#define LCD_SDIO2 6
#define LCD_SDIO3 7
#define LCD_SCLK  11
#define LCD_CS    12
#define LCD_WIDTH  368
#define LCD_HEIGHT 448

// ---- Shared I2C bus (PMU, expander, touch) ----
#define IIC_SDA 15
#define IIC_SCL 14

// I2C addresses. NOTE: some board revisions strap the TCA9554 at 0x21 instead
// of 0x20 (see waveshareteam/ESP32-S3-Touch-AMOLED-1.8 issue #3). If the panel
// stays black, try 0x21 here first.
#define AXP2101_ADDR 0x34
#define TCA9554_ADDR 0x20
#define FT3168_ADDR  0x38   // capacitive touch (FT3168 / FT3x68 family)
#define CST816_ADDR  0x15   // some V2 demos use CST816T instead
#define TP_INT       21     // touch interrupt (active-low pulse)
#define BTN_BOOT      0     // BOOT button (active low) → Headroom home
