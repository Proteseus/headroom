// Board pins. Pick one Waveshare SKU via build flag:
//   (default)          ESP32-S3-Touch-AMOLED-1.8  — 368×448 SH8601
//   BOARD_WS_AMOLED_216 ESP32-S3-Touch-AMOLED-2.16 — 480×480 CO5300
#pragma once

#if defined(BOARD_WS_AMOLED_216)

// ---- CO5300 AMOLED over QSPI (2.16" rounded-square) ----
#define LCD_SDIO0 4
#define LCD_SDIO1 5
#define LCD_SDIO2 6
#define LCD_SDIO3 7
#define LCD_SCLK  38
#define LCD_CS    12
#define LCD_RST   39
#define LCD_WIDTH  480
#define LCD_HEIGHT 480

// ---- Shared I2C bus (PMU, touch, IMU, RTC, codec) ----
// Docs: GPIO14 = SCL, GPIO15 = SDA.
#define IIC_SDA 15
#define IIC_SCL 14

#define AXP2101_ADDR 0x34
// CST9220 — SensorLib exposes the same as CST92XX_SLAVE_ADDRESS (0x5A).
#define CST92XX_ADDR 0x5A
#define TP_INT       11
#define TP_RST       40

// Three keys (silkscreen L→R on the 2.16): IO18, PWR, BOOT.
// PWR is active-HIGH via BSS138; the others are active-LOW.
#define BTN_BOOT            0     // right — page cycle
#define BTN_SECONDARY      18     // left (IO18) — home / sync
#define BTN_SECONDARY_ACTIVE_LOW 1
#define BTN_STYLE          16     // middle (PWR / SYS_OUT) — rings↔pace
#define BTN_STYLE_ACTIVE_LOW     0
#define BTN_HAS_STYLE            1

#else

// Board: Waveshare ESP32-S3-Touch-AMOLED-1.8 (368x448, SH8601 QSPI, AXP2101 PMU,
// TCA9554 I/O expander, FT3168 touch). Pins verified against Waveshare's
// Mylibrary/pin_config.h. If your board revision differs, reconcile with the
// pin_config.h in Waveshare's official Arduino demo for this exact board.

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

// Two keys: BOOT on GPIO0; PWR via TCA9554 EXIO4 (active HIGH while held).
// Hold PWR ~6s still hardware-powers-off — only short taps are safe to bind.
#define BTN_BOOT            0
#define BTN_PWR_TCA_BIT     4     // EXIO4 on the expander
#define BTN_HAS_STYLE       0     // style stays touch long-press on the 1.8

#endif
