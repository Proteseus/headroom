// headroom — Claude / Codex / Cursor / Vercel / Git desk gadget.
// Waveshare ESP32-S3-Touch-AMOLED-1.8. Polls the host server's /usage endpoint
// over Wi-Fi and renders dashboards on the AMOLED. Headroom is home: tap a
// grid slot to open a detail page; tap (or BOOT / long-press) to return home.
//
// Bring-up order matters on this board: own the I2C bus (one Wire.begin), bring
// up the AXP2101 rails, release the panel reset via the TCA9554 expander, THEN
// start the SH8601. Doing I2C ourselves avoids the XPowersLib/Adafruit
// Wire.begin() conflict that leaves the panel black (repo issue #3).

#include <Arduino.h>
#include <string.h>
#include <time.h>
#include <Wire.h>
#include <WiFi.h>
#include <WiFiMulti.h>
#include <ESPmDNS.h>
#include <ArduinoOTA.h>
#include <HTTPClient.h>
#include <ArduinoJson.h>
#include <esp_heap_caps.h>
#include <esp_task_wdt.h>
#include <Preferences.h>
#include <Arduino_GFX_Library.h>
#define XPOWERS_CHIP_AXP2101
#include <XPowersLib.h>

#include "pin_config.h"
#include "config.h"   // copy config_example.h -> config.h

// Older config.h files predate these — keep them building.
#ifndef HOST_TOKEN
#define HOST_TOKEN ""
#endif
#ifndef OTA_HOSTNAME
#define OTA_HOSTNAME "headroom"
#endif
#ifndef OTA_PASSWORD
#define OTA_PASSWORD ""
#endif

// Reboot if a single loop pass wedges this long (stuck I2C, wedged HTTP stack).
// Generous: a cold Wi-Fi associate plus a USB sync is legitimately slow.
static const uint32_t WDT_TIMEOUT_S = 30;

// ---------------- Display ----------------
// SH8601 has no hardware rotation. Panel stays native portrait (368×448).
// We draw into a logical landscape PSRAM canvas (448×368) with no per-pixel
// rotate, then rotate once on flush → native. Use 1 for CW if you flip.
static Arduino_DataBus *bus = new Arduino_ESP32QSPI(
    LCD_CS, LCD_SCLK, LCD_SDIO0, LCD_SDIO1, LCD_SDIO2, LCD_SDIO3);
static Arduino_SH8601 *panel = new Arduino_SH8601(
    bus, -1 /* RST via expander, not a GPIO */, 0 /* rotation */,
    LCD_WIDTH, LCD_HEIGHT);

// Shared palette (RGB565) — early so canvas flush can seal with COL_BG.
static const uint16_t COL_BG     = RGB565(16, 14, 12);
static const uint16_t COL_CLAUDE = RGB565(217, 119, 87);   // terracotta
static const uint16_t COL_OPENAI = RGB565(16, 163, 127);   // OpenAI / ChatGPT green
static const uint16_t COL_CURSOR = RGB565(120, 155, 200);  // faded blue (Cursor)
static const uint16_t COL_VERCEL = RGB565(240, 238, 234);  // Vercel-ish white
static const uint16_t COL_GIT    = RGB565(155, 85, 200);   // brighter GitHub purple
static const uint16_t COL_LOCAL  = RGB565(70, 175, 165);   // teal (local servers)
static const uint16_t COL_WHITE  = RGB565(240, 238, 234);
static const uint16_t COL_BLACK  = RGB565(0, 0, 0);
static const uint16_t COL_DIM    = RGB565(120, 116, 110);
static const uint16_t COL_BAR    = RGB565(42, 40, 38);     // unfilled quota track
static const uint16_t COL_GREEN  = RGB565(95, 155, 115);   // soft sage
static const uint16_t COL_AMBER  = RGB565(195, 155, 85);    // soft amber
static const uint16_t COL_RED    = RGB565(175, 105, 100);   // soft dusty red
static const uint16_t COL_CRT    = RGB565(232, 168, 48);   // boot amber phosphor
static const uint16_t COL_CRT_DIM= RGB565(140, 90, 28);
static const uint16_t COL_CRT_BG = RGB565(12, 8, 4);
static const uint16_t COL_CRT_HDR= RGB565(28, 18, 8);      // boot header bar
static const uint16_t COL_CRT_SCAN= RGB565(18, 12, 4);     // scanlines

// Green fringe sits on the native right edge (logical bottom at rotation 3).
// Paint over it in-panel after every blit. Also blank a few GRAM columns past
// LCD_WIDTH in case the panel scans slightly beyond our framebuffer.
static void sealNativeEdges(uint16_t color) {
  const int16_t fringe = 20;
  panel->fillRect(LCD_WIDTH - fringe, 0, fringe, LCD_HEIGHT, color);

  const int16_t extra = 16;
  bus->beginWrite();
  bus->writeC8D16D16(0x2A, LCD_WIDTH, LCD_WIDTH + extra - 1);
  bus->writeC8D16D16(0x2B, 0, LCD_HEIGHT - 1);
  bus->writeCommand(0x2C);
  bus->writeRepeat(color, (uint32_t)extra * LCD_HEIGHT);
  bus->endWrite();
}

// Logical landscape (448×368). Drawing is axis-aligned into PSRAM; we only pay
// for 90° CCW rotation when pushing pixels to the native 368×448 panel.
static const int16_t LOG_W = LCD_HEIGHT;  // 448
static const int16_t LOG_H = LCD_WIDTH;   // 368

// Rotate logical → native (matches former Arduino_Canvas rotation 3):
//   native(nx, ny) = logical(lx = LOG_W-1-ny, ly = nx)
//
// Done in tiles rather than whole rows. The source walk strides by LOG_W, so a
// full-row pass touches 368 separate cache lines and evicts each before the
// next row reuses it — every one of the 164k pixels becomes a PSRAM round
// trip. A 32×32 tile keeps its ~2KB of source lines resident while 32 rows
// drain out of them.
static const int16_t ROT_TILE = 32;

static void rotateLogicalToNative(const uint16_t *src, uint16_t *dst) {
  for (int16_t ny0 = 0; ny0 < LCD_HEIGHT; ny0 += ROT_TILE) {
    const int16_t nyEnd =
        (int16_t)((ny0 + ROT_TILE < LCD_HEIGHT) ? ny0 + ROT_TILE : LCD_HEIGHT);
    for (int16_t nx0 = 0; nx0 < LCD_WIDTH; nx0 += ROT_TILE) {
      const int16_t nxEnd =
          (int16_t)((nx0 + ROT_TILE < LCD_WIDTH) ? nx0 + ROT_TILE : LCD_WIDTH);
      for (int16_t ny = ny0; ny < nyEnd; ny++) {
        const uint16_t *s =
            src + ((LOG_W - 1) - ny) + (int32_t)nx0 * LOG_W;
        uint16_t *d = dst + (int32_t)ny * LCD_WIDTH + nx0;
        for (int16_t nx = nx0; nx < nxEnd; nx++) {
          *d++ = *s;
          s += LOG_W;
        }
      }
    }
  }
}

// Canvas = logical framebuffer. _native is rotated for panel flush.
class LandscapeCanvas : public Arduino_Canvas {
  uint16_t *_native = nullptr;

public:
  LandscapeCanvas(Arduino_G *out)
      : Arduino_Canvas(LOG_W, LOG_H, out, 0, 0, 0 /* no per-pixel rotate */) {}

  bool begin(int32_t speed = GFX_NOT_DEFINED) override {
    if ((speed != GFX_SKIP_OUTPUT_BEGIN) && _output) {
      if (!_output->begin(speed)) return false;
    }
    const size_t logBytes = (size_t)LOG_W * LOG_H * sizeof(uint16_t);
    const size_t natBytes = (size_t)LCD_WIDTH * LCD_HEIGHT * sizeof(uint16_t);
    if (!_framebuffer) {
      _framebuffer = (uint16_t *)ps_malloc(logBytes);
      if (!_framebuffer) return false;
      memset(_framebuffer, 0, logBytes);
    }
    if (!_native) {
      _native = (uint16_t *)ps_malloc(natBytes);
      if (!_native) return false;
      memset(_native, 0, natBytes);
    }
    return true;
  }

  void clear(uint16_t color) {
    if (!_framebuffer) return;
    uint32_t c32 = ((uint32_t)color << 16) | color;
    uint32_t *p = (uint32_t *)_framebuffer;
    size_t n = ((size_t)LOG_W * LOG_H) / 2;
    while (n--) *p++ = c32;
  }

  void flush(bool force_flush = false) override {
    (void)force_flush;
    if (!_framebuffer || !_native || !_output) return;
    rotateLogicalToNative(_framebuffer, _native);
    _output->draw16bitRGBBitmap(0, 0, _native, LCD_WIDTH, LCD_HEIGHT);
    sealNativeEdges(COL_BG);
  }

  // Push a logical axis-aligned dirty rect without a full frame.
  void flushLogicalRect(int16_t lx, int16_t ly, int16_t lw, int16_t lh) {
    if (!_framebuffer || !_output || lw <= 0 || lh <= 0) return;
    if (lx < 0) { lw += lx; lx = 0; }
    if (ly < 0) { lh += ly; ly = 0; }
    if (lx + lw > LOG_W) lw = (int16_t)(LOG_W - lx);
    if (ly + lh > LOG_H) lh = (int16_t)(LOG_H - ly);
    if (lw <= 0 || lh <= 0) return;

    const int16_t nx0 = ly;
    const int16_t nw = lh;
    const int16_t ny0 = (int16_t)((LOG_W - 1) - (lx + lw - 1));
    const int16_t nh = lw;

    uint16_t line[LCD_WIDTH];
    for (int16_t row = 0; row < nh; row++) {
      int16_t ny = (int16_t)(ny0 + row);
      int16_t lxCol = (int16_t)((LOG_W - 1) - ny);
      for (int16_t col = 0; col < nw; col++) {
        int16_t nx = (int16_t)(nx0 + col);
        line[col] = _framebuffer[(int32_t)nx * LOG_W + lxCol];
      }
      _output->draw16bitRGBBitmap(nx0, ny, line, nw, 1);
    }
  }
};
static LandscapeCanvas *gfx = new LandscapeCanvas(panel);

static void present() {
  gfx->flush();
}

static XPowersPMU PMU;

// Vendor "manufacturer page" unlock + display-on sequence for this SH8601
// panel batch. Arduino_GFX's generic SH8601 init table doesn't include this
// unlock, so panel->begin() "succeeds" (the QSPI writes go out fine) but the
// panel never actually lights up. Sequence + register values confirmed
// against a working init for this exact board; addresses re-sized for our
// 368x448 panel (367 = width-1, 447 = height-1).
static void sh8601VendorInit() {
  bus->beginWrite();
  bus->writeCommand(0x11);              // SLPOUT
  bus->endWrite();
  delay(120);

  bus->beginWrite();
  bus->writeC8D8(0xFE, 0x20);           // page select: MFR
  bus->writeC8D8(0x19, 0x10);
  bus->writeC8D8(0x1C, 0xA0);
  bus->writeC8D8(0xFE, 0x00);           // page select: USER
  bus->writeC8D8(0xC4, 0x80);
  bus->writeC8D8(0x3A, 0x55);           // pixel format: RGB565
  bus->writeC8D8(0x35, 0x00);           // tearing effect line
  // MADCTL: 0x00 = native portrait, no row/col exchange. The reference repo's
  // 0x30 sets the MV (row/col swap) bit, tuned for its square 480x480 panel —
  // on our rectangular 368x448 panel that swap misaligns the col/row address
  // windows below, causing wraparound (the green edge bar + bottom overflow).
  // If the image comes up mirrored or upside-down, try 0x40 (mirror X),
  // 0x80 (mirror Y), or 0xC0 (180 deg) instead.
  bus->writeC8D8(0x36, 0x00);
  bus->writeC8D8(0x53, 0x20);           // CABC control
  bus->writeC8D8(0x51, 0xFF);           // brightness: max (we dim later)
  bus->writeC8D8(0x63, 0xFF);

  uint8_t col[4] = {0x00, 0x00, (uint8_t)((LCD_WIDTH - 1) >> 8),
                     (uint8_t)((LCD_WIDTH - 1) & 0xFF)};
  bus->writeCommand(0x2A);
  bus->writeBytes(col, 4);

  uint8_t row[4] = {0x00, 0x00, (uint8_t)((LCD_HEIGHT - 1) >> 8),
                     (uint8_t)((LCD_HEIGHT - 1) & 0xFF)};
  bus->writeCommand(0x2B);
  bus->writeBytes(row, 4);

  bus->writeCommand(0x29);              // DISPON
  bus->endWrite();
  delay(50);
}

// ---------------- Data ----------------
struct ProviderQuota {
  bool ok = false;
  String plan;
  float sessionPct = -1;
  float weekPct = -1;
  float totalPct = -1;       // Cursor combined included-plan usage
  float sessionPace = -1;
  float weekPace = -1;
  float totalPace = -1;
  String sessionResets;
  String weekResets;
  String paceLabel;          // e.g. "50% in deficit"
  String runsOutIn;          // e.g. "3h 14m"
  int resetCredits = -1;     // -1 = unknown / N/A
  String resetCreditExpiries; // "10d 7h - 22d 4h"
  String onDemand;           // Cursor: "$30 / $30 on-demand"
};

// Burndown for one provider: the actual remaining-% curve plus where the
// current pace lands. The ideal line is a straight run from (t0,100) to
// (t1,0), so the host never sends it — we derive it here.
// Cursor may carry a second series (API) overlaid on the same axis.
static const uint8_t MAX_BURN_PTS = 24;   // mirrors device_view.MAX_BURNDOWN_POINTS
struct Burndown {
  bool ok = false;
  uint32_t t0 = 0, t1 = 0;
  uint8_t n = 0;
  uint32_t t[MAX_BURN_PTS];
  float remaining[MAX_BURN_PTS];
  uint8_t projN = 0;
  uint32_t projT[2];
  float projR[2];
  bool warn = false;       // pace runs out before the window resets
  bool exhausted = false;
  bool estimated = false;  // projection from token history, not from samples
  // "Runs out tomorrow 10:26" — the same phrase the menu bar shows, so the
  // desk and the Mac answer "do I make it" with the same words. Host-supplied
  // rather than assembled here: one vocabulary, one place to change it.
  String verdict;
  // Optional overlay (Cursor API). n2==0 means absent.
  uint8_t n2 = 0;
  uint32_t t2[MAX_BURN_PTS];
  float remaining2[MAX_BURN_PTS];
  uint8_t projN2 = 0;
  uint32_t projT2[2];
  float projR2[2];
  bool warn2 = false;
  bool exhausted2 = false;
  bool estimated2 = false;
};

enum Page : uint8_t {
  PAGE_GLANCE = 0,
  PAGE_CLAUDE = 1,
  PAGE_CODEX  = 2,
  PAGE_CURSOR = 3,
  PAGE_VERCEL = 4,
  PAGE_GIT    = 5,
  PAGE_LOCAL  = 6,
  PAGE_COUNT  = 7
};

static const uint8_t MAX_DEPLOYS = 6;
static const uint8_t MAX_COMMITS = 6;
static const uint8_t MAX_SERVERS = 6;

struct DeployRow {
  String project;
  String status;   // ready / building / error
  String target;   // production / preview / …
  String ago;
  String branch;
};

struct CommitRow {
  String repo;
  String subject;
  String ago;
  String branch;
};

struct ServerRow {
  String name;
  int port = 0;
  String cmd;
};

// Build identity, stamped by firmware/version.py. The counter moves on every
// build, not every commit, so a rebuild of uncommitted work is still
// distinguishable — which is the case where "did that actually flash?" is
// hardest to answer. Sent to the host on every poll so the question has a
// reading rather than an inference.
#ifndef FW_BUILD
#define FW_BUILD 0
#endif
#ifndef FW_VERSION
#define FW_VERSION "unversioned"
#endif

static const String &fwVersion() {
  static const String v = FW_VERSION;
  return v;
}

static String updatedZ = "";
static bool haveData = false;
static bool hostOk = false;   // last /usage fetch succeeded
static ProviderQuota claudeQ, codexQ, cursorQ;
static Burndown claudeBurn, codexBurn, cursorBurn;
static bool vercelOk = false;
static String vercelTeam = "";
static uint8_t vercelN = 0;
static DeployRow vercelRows[MAX_DEPLOYS];
static bool gitOk = false;
static uint8_t gitN = 0;
static CommitRow gitRows[MAX_COMMITS];
static bool localOk = false;
static String localHost = "";
static uint8_t localN = 0;
static ServerRow localRows[MAX_SERVERS];
static Page page = PAGE_GLANCE;

// Home's lower half has two readings of the same desk: what's left (a burndown
// per provider, under its ring) or what shipped (Vercel / Git / Local columns).
// Burndown leads — it's the reading you can't get anywhere else at a glance.
// Tap the header band to switch; the choice survives reboots in NVS so the
// board comes back the way it was left.
enum HomeMode : uint8_t { HOME_BURNDOWN = 0, HOME_ACTIVITY = 1 };
static HomeMode homeMode = HOME_BURNDOWN;
static Preferences prefs;
static const char *PREFS_NS = "headroom";
// Key renamed with the ordering flip — the old one's 0/1 meant the opposite,
// and a stale value would silently pin a board to the wrong default.
static const char *PREF_HOME_MODE = "home_pane";

// Must match docs/glossary.md / Shared/HeadroomCopy.swift.
static const char *LABEL_BURNDOWN = "Burndown";
static const char *LABEL_ACTIVITY = "Activity";
static const char *LABEL_COLLECTING_HISTORY = "Collecting history";
static const char *LABEL_NO_DATA = "no data";

static const char *homeModeName(HomeMode m) {
  return m == HOME_BURNDOWN ? LABEL_BURNDOWN : LABEL_ACTIVITY;
}

static void homeModeLoad() {
  // Read-only open on a namespace that doesn't exist yet just fails — default.
  if (!prefs.begin(PREFS_NS, true)) return;
  homeMode = prefs.getUChar(PREF_HOME_MODE, HOME_BURNDOWN) == HOME_ACTIVITY
                 ? HOME_ACTIVITY
                 : HOME_BURNDOWN;
  prefs.end();
}

static void homeModeSave() {
  if (!prefs.begin(PREFS_NS, false)) return;
  prefs.putUChar(PREF_HOME_MODE, (uint8_t)homeMode);
  prefs.end();
}

// Shared Sources panel state (same payload Mac Settings reads/writes).
static const uint8_t MAX_SOURCES = 8;
struct SourceRow {
  String id;
  String title;
  bool enabled = true;
  bool ok = false;
  bool stale = false;
};
static uint8_t sourceN = 0;
static SourceRow sourceRows[MAX_SOURCES];
static bool sourceEnabled(const char *id) {
  for (uint8_t i = 0; i < sourceN; i++) {
    if (sourceRows[i].id.equals(id)) return sourceRows[i].enabled;
  }
  return true;  // older hosts without sources[] → keep showing pages
}

// ---------------- I2C helpers ----------------
static uint8_t tcaAddr = TCA9554_ADDR;   // may be re-detected at boot

static bool i2cPresent(uint8_t addr) {
  Wire.beginTransmission(addr);
  return Wire.endTransmission() == 0;
}

static void i2cScan() {
  Serial.print("I2C scan:");
  int n = 0;
  for (uint8_t a = 1; a < 127; a++)
    if (i2cPresent(a)) { Serial.printf(" 0x%02X", a); n++; }
  Serial.println(n ? "" : "  (NONE — check SDA=15/SCL=14 wiring)");
}

// ---------------- TCA9554 (raw I2C) ----------------
static void tcaWrite(uint8_t reg, uint8_t val) {
  Wire.beginTransmission(tcaAddr);
  Wire.write(reg);
  Wire.write(val);
  Wire.endTransmission();
}

// Release the panel. On this board (per the working reference): expander pin 0
// = LCD reset, 1 = touch reset, 2 = DSI power-enable. Drive all three low, then
// high, so the display rail comes up and reset releases together.
static void panelReset() {
  tcaWrite(0x03, 0xF8);   // config: P0..P2 outputs, rest inputs
  tcaWrite(0x01, 0x00);   // low: assert reset + power off
  delay(30);
  tcaWrite(0x01, 0x07);   // high: release reset + enable DSI power
  delay(120);
}

// ---------------- Power ----------------
static void powerInit() {
  Wire.begin(IIC_SDA, IIC_SCL, 400000);   // own the bus once
  delay(50);
  i2cScan();

  // The TCA9554 straps at 0x20 on most units, 0x21 on some (repo issue #3).
  if (!i2cPresent(tcaAddr) && i2cPresent(0x21)) tcaAddr = 0x21;
  Serial.printf("TCA9554 @ 0x%02X %s\n", tcaAddr,
                i2cPresent(tcaAddr) ? "(ack)" : "(NO ACK — panel stays dark!)");

  bool ok = PMU.begin(Wire, AXP2101_ADDR, IIC_SDA, IIC_SCL);
  Serial.printf("AXP2101 begin: %s\n", ok ? "ok" : "FAIL (display rail off!)");
  if (ok) {
    PMU.setALDO1Voltage(3300); PMU.enableALDO1();
    PMU.setALDO2Voltage(3300); PMU.enableALDO2();
    PMU.setALDO3Voltage(3300); PMU.enableALDO3();   // ALDO3 = the display rail
    PMU.setALDO4Voltage(3300); PMU.enableALDO4();
    delay(50);
  }
  panelReset();
}

// ---------------- Formatting ----------------
// Render helpers write into caller-owned buffers. These run on every drawn
// row; returning Arduino String would churn the heap each frame and fragment
// it over the weeks this thing stays powered.
static const char *fmtPct(char *buf, size_t n, float p) {
  if (p < 0) snprintf(buf, n, "--%%");
  else if (p >= 99.5f) snprintf(buf, n, "100%%");
  else if (p >= 10) snprintf(buf, n, "%.0f%%", p);
  else snprintf(buf, n, "%.1f%%", p);
  return buf;
}

// ---------------- Networking ----------------
static WiFiMulti wifiMulti;
static String resolvedHost = "";   // cached IP (or hostname) of the Mac
static bool mdnsUp = false;

static void connectWifi() {
  WiFi.mode(WIFI_STA);
  for (auto &n : WIFI_NETWORKS) wifiMulti.addAP(n.ssid, n.pass);
}

// Resolve the Mac by name via mDNS; fall back to the configured IP. Cached so
// we only pay the lookup on first use and after a failed fetch.
static const String &hostFor() {
  if (resolvedHost.length()) return resolvedHost;
  if (mdnsUp) {
    IPAddress ip = MDNS.queryHost(HOST_NAME, 2000);
    if ((uint32_t)ip != 0) { resolvedHost = ip.toString(); return resolvedHost; }
  }
  resolvedHost = HOST_FALLBACK_IP;   // last resort
  return resolvedHost;
}

// The host only demands a token from non-loopback callers, which is every
// request the board makes over Wi-Fi. The USB path needs nothing: the cable
// already proves physical access.
static void addAuthHeader(HTTPClient &http) {
  if (sizeof(HOST_TOKEN) > 1) {
    http.addHeader("X-Headroom-Token", HOST_TOKEN);
  }
}

// Ask the host to force-refresh Sources (same endpoint Mac Settings uses).
static bool requestSyncRefreshHttp() {
  if (WiFi.status() != WL_CONNECTED) return false;
  String url = "http://" + hostFor() + ":" + String(HOST_PORT) + "/sync/refresh";
  HTTPClient http;
  http.setConnectTimeout(800);
  http.setTimeout(1200);
  if (!http.begin(url)) return false;
  http.addHeader("Content-Type", "application/json");
  addAuthHeader(http);
  int code = http.POST("{}");
  http.end();
  Serial.printf("sync refresh → HTTP %d\n", code);
  return code >= 200 && code < 300;
}

// USB CDC framed protocol (same /usage JSON as HTTP). Coexists with Serial
// debug logs: only lines starting with "HR " are protocol.
// Background polls use a short timeout so a missing host can't freeze touch;
// explicit long-press sync may wait longer.
static const uint32_t USB_TIMEOUT_POLL_MS = 900;
static const uint32_t USB_TIMEOUT_SYNC_MS = 3500;
// The host serves the board its ?view=device projection (~2KB), so this no
// longer has to hold a 30KB document. CDC RX buffers come out of DRAM, not
// PSRAM, so the 24KB given back here is 24KB the UI and Wi-Fi stack can use.
// Still 8x the expected frame.
static const size_t USB_RX_BUF = 16 * 1024;

// ArduinoJson DOM — keep it in PSRAM so we don't blow the tiny internal heap
// (canvas + WiFi already live there).
struct SpiRamAllocator : ArduinoJson::Allocator {
  void *allocate(size_t size) override {
    return heap_caps_malloc(size, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
  }
  void deallocate(void *ptr) override { heap_caps_free(ptr); }
  void *reallocate(void *ptr, size_t new_size) override {
    return heap_caps_realloc(ptr, new_size, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
  }
};
static SpiRamAllocator spiRamAlloc;

static void usbDrainInput() {
  uint32_t t0 = millis();
  while (Serial.available() && (millis() - t0) < 50) {
    Serial.read();
  }
}

static bool usbReadLine(String &out, uint32_t deadlineMs) {
  out = "";
  while (millis() < deadlineMs) {
    while (Serial.available()) {
      char c = (char)Serial.read();
      if (c == '\r') continue;
      if (c == '\n') return true;
      out += c;
      if (out.length() > 256) return false;
    }
    delay(1);
    yield();
  }
  return false;
}

static bool usbReadExact(char *out, size_t n, uint32_t deadlineMs) {
  size_t got = 0;
  while (got < n && millis() < deadlineMs) {
    while (Serial.available() && got < n) {
      int avail = Serial.available();
      if (avail <= 0) break;
      size_t chunk = (size_t)avail;
      if (chunk > n - got) chunk = n - got;
      size_t rd = Serial.readBytes(out + got, chunk);
      got += rd;
      if (rd == 0) break;
    }
    if (got < n) {
      delay(1);
      yield();
    }
  }
  return got == n;
}

// Wait for "HR <status> <nbytes>" then optionally read nbytes of body.
static bool usbTransact(const char *requestLine, int wantStatus,
                        char **bodyOut, size_t *bodyLen,
                        uint32_t timeoutMs) {
  if (bodyOut) *bodyOut = nullptr;
  if (bodyLen) *bodyLen = 0;

  usbDrainInput();
  Serial.print(requestLine);
  Serial.print('\n');
  // Do not Serial.flush() — with the Mac holding CDC it can block forever.

  uint32_t deadline = millis() + timeoutMs;
  while (millis() < deadline) {
    String line;
    if (!usbReadLine(line, deadline)) return false;
    if (!line.startsWith("HR ")) continue;

    // HR <status> <nbytes>
    int sp1 = line.indexOf(' ', 3);
    if (sp1 < 0) continue;
    int status = line.substring(3, sp1).toInt();
    int nbytes = line.substring(sp1 + 1).toInt();
    if (nbytes < 0 || nbytes > (int)USB_RX_BUF) return false;

    char *body = nullptr;
    if (nbytes > 0) {
      body = (char *)heap_caps_malloc(
          (size_t)nbytes + 1, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
      if (!body) {
        Serial.println("usb: OOM body");
        return false;
      }
      if (!usbReadExact(body, (size_t)nbytes, deadline)) {
        heap_caps_free(body);
        Serial.printf("usb: short body want=%d\n", nbytes);
        return false;
      }
      body[nbytes] = '\0';
      // trailing newline after body
      uint32_t trailDeadline = millis() + 50;
      while (millis() < trailDeadline) {
        if (Serial.available()) {
          (void)Serial.read();
          break;
        }
        delay(1);
      }
    }

    if (status != wantStatus) {
      Serial.printf("usb → HR %d (want %d)\n", status, wantStatus);
      if (body) heap_caps_free(body);
      return false;
    }
    if (bodyOut) {
      *bodyOut = body;
      if (bodyLen) *bodyLen = (size_t)nbytes;
    } else if (body) {
      heap_caps_free(body);
    }
    return true;
  }
  return false;
}

static bool requestSyncRefreshUsb() {
  bool ok = usbTransact("HR POST /sync/refresh", 202, nullptr, nullptr,
                        USB_TIMEOUT_SYNC_MS);
  Serial.printf("sync refresh → USB %s\n", ok ? "ok" : "fail");
  return ok;
}

static bool requestSyncRefresh() {
  if (WiFi.status() == WL_CONNECTED && requestSyncRefreshHttp()) return true;
  return requestSyncRefreshUsb();
}

// Forward decl — applyUsageDoc folds host middots before the helper's body.
static String boardAscii(const char *s);

// Only these keys survive deserialization. The host's ?view=device projection
// already drops the rest, but the filter also protects the board if it is
// pointed at an older host still serving the full ~30KB document.
static JsonDocument usageFilter() {
  JsonDocument filter;
  for (const char *key : {"updated", "plan", "quota_ok", "session_pct",
                          "session_pace_pct", "session_resets_in", "week_pct",
                          "week_pace_pct", "week_resets_in"}) {
    filter[key] = true;
  }
  filter["codex"] = true;
  filter["cursor"] = true;
  filter["vercel"]["ok"] = true;
  filter["vercel"]["team"] = true;
  filter["vercel"]["deployments"][0]["project"] = true;
  filter["vercel"]["deployments"][0]["status"] = true;
  filter["vercel"]["deployments"][0]["target"] = true;
  filter["vercel"]["deployments"][0]["ago"] = true;
  filter["vercel"]["deployments"][0]["branch"] = true;
  filter["git"]["ok"] = true;
  filter["git"]["commits"][0]["repo"] = true;
  filter["git"]["commits"][0]["subject"] = true;
  filter["git"]["commits"][0]["ago"] = true;
  filter["git"]["commits"][0]["branch"] = true;
  filter["local"]["ok"] = true;
  filter["local"]["host"] = true;
  filter["local"]["servers"][0]["name"] = true;
  filter["local"]["servers"][0]["port"] = true;
  filter["local"]["servers"][0]["cmd"] = true;
  filter["sources"][0]["id"] = true;
  filter["sources"][0]["title"] = true;
  filter["sources"][0]["enabled"] = true;
  filter["sources"][0]["ok"] = true;
  filter["sources"][0]["stale"] = true;
  // Whole subtree, like codex/cursor above: device_view has already trimmed it
  // (one pool, or Total+API for Cursor), so there is nothing further to filter.
  filter["burndown"] = true;
  return filter;
}

static bool applyUsageDoc(JsonDocument &doc) {
  updatedZ = String((const char *)(doc["updated"] | ""));

  // Claude (top-level, back-compat)
  claudeQ.ok           = doc["quota_ok"] | false;
  claudeQ.plan         = String((const char *)(doc["plan"] | ""));
  claudeQ.sessionPct   = doc["session_pct"].isNull() ? -1.f : (float)(doc["session_pct"] | -1.0);
  claudeQ.weekPct      = doc["week_pct"].isNull()    ? -1.f : (float)(doc["week_pct"] | -1.0);
  claudeQ.sessionPace  = doc["session_pace_pct"].isNull() ? -1.f : (float)(doc["session_pace_pct"] | -1.0);
  claudeQ.weekPace     = doc["week_pace_pct"].isNull()    ? -1.f : (float)(doc["week_pace_pct"] | -1.0);
  claudeQ.sessionResets= String((const char *)(doc["session_resets_in"] | ""));
  claudeQ.weekResets   = String((const char *)(doc["week_resets_in"] | ""));
  claudeQ.paceLabel = "";
  claudeQ.runsOutIn = "";
  claudeQ.resetCredits = -1;
  claudeQ.resetCreditExpiries = "";
  claudeQ.onDemand = "";

  // Codex (nested)
  JsonObject cx = doc["codex"].as<JsonObject>();
  if (!cx.isNull()) {
    codexQ.ok            = cx["ok"] | false;
    codexQ.plan          = String((const char *)(cx["plan"] | ""));
    codexQ.sessionPct    = cx["session_pct"].isNull() ? -1.f : (float)(cx["session_pct"] | -1.0);
    codexQ.weekPct       = cx["week_pct"].isNull()    ? -1.f : (float)(cx["week_pct"] | -1.0);
    codexQ.sessionPace   = cx["session_pace_pct"].isNull() ? -1.f : (float)(cx["session_pace_pct"] | -1.0);
    codexQ.weekPace      = cx["week_pace_pct"].isNull()    ? -1.f : (float)(cx["week_pace_pct"] | -1.0);
    codexQ.sessionResets = String((const char *)(cx["session_resets_in"] | ""));
    codexQ.weekResets    = String((const char *)(cx["week_resets_in"] | ""));
    codexQ.paceLabel     = String((const char *)(cx["pace_label"] | ""));
    codexQ.runsOutIn     = String((const char *)(cx["runs_out_in"] | ""));
    if (cx["reset_credits_available"].isNull()) codexQ.resetCredits = -1;
    else codexQ.resetCredits = (int)(cx["reset_credits_available"] | 0);
    codexQ.resetCreditExpiries = "";
    codexQ.onDemand = "";
    JsonArray ex = cx["reset_credits_expiries"].as<JsonArray>();
    if (!ex.isNull()) {
      for (JsonVariant v : ex) {
        const char *s = v.as<const char *>();
        if (!s || !s[0]) continue;
        if (codexQ.resetCreditExpiries.length()) codexQ.resetCreditExpiries += " - ";
        codexQ.resetCreditExpiries += s;
      }
    }
  } else {
    codexQ = ProviderQuota{};
  }

  // Cursor (nested Total + API pools; Auto is omitted from the UI)
  JsonObject cur = doc["cursor"].as<JsonObject>();
  if (!cur.isNull()) {
    cursorQ.ok            = cur["ok"] | false;
    cursorQ.plan          = String((const char *)(cur["plan"] | ""));
    cursorQ.totalPct      = cur["total_pct"].isNull() ? -1.f : (float)(cur["total_pct"] | -1.0);
    // sessionPct unused for Cursor — Auto is always empty and used to steal
    // the second ring from API. weekPct holds API.
    cursorQ.sessionPct    = -1.f;
    cursorQ.weekPct       = cur["api_pct"].isNull()  ? -1.f : (float)(cur["api_pct"] | -1.0);
    cursorQ.totalPace     = cur["total_pace_pct"].isNull() ? -1.f : (float)(cur["total_pace_pct"] | -1.0);
    cursorQ.sessionPace   = -1.f;
    cursorQ.weekPace      = cur["api_pace_pct"].isNull()  ? -1.f : (float)(cur["api_pace_pct"] | -1.0);
    String resets = String((const char *)(cur["resets_in"] | ""));
    cursorQ.sessionResets = resets;
    cursorQ.weekResets    = resets;
    cursorQ.paceLabel     = String((const char *)(cur["pace_label"] | ""));
    cursorQ.runsOutIn     = "";
    cursorQ.resetCredits  = -1;
    cursorQ.resetCreditExpiries = "";
    cursorQ.onDemand      = String((const char *)(cur["on_demand_label"] | ""));
  } else {
    cursorQ = ProviderQuota{};
  }

  // Burndown series (one pool per provider; Cursor may overlay API as *2)
  claudeBurn = Burndown();
  codexBurn = Burndown();
  cursorBurn = Burndown();
  JsonObject bd = doc["burndown"].as<JsonObject>();
  if (!bd.isNull()) {
    struct { const char *id; Burndown *dst; } targets[3] = {
      {"claude", &claudeBurn}, {"codex", &codexBurn}, {"cursor", &cursorBurn},
    };
    for (auto &target : targets) {
      JsonObject b = bd[target.id].as<JsonObject>();
      if (b.isNull()) continue;
      Burndown &out = *target.dst;
      out.t0 = (uint32_t)(b["t0"] | 0);
      out.t1 = (uint32_t)(b["t1"] | 0);
      if (out.t1 <= out.t0) continue;
      out.warn = b["warn"] | false;
      out.estimated = b["est"] | false;
      out.verdict = boardAscii((const char *)(b["verdict"] | ""));
      out.exhausted =
          strcmp((const char *)(b["status"] | ""), "exhausted") == 0;
      JsonArray pts = b["pts"].as<JsonArray>();
      if (!pts.isNull()) {
        for (JsonVariant v : pts) {
          if (out.n >= MAX_BURN_PTS) break;
          JsonArray pair = v.as<JsonArray>();
          if (pair.isNull() || pair.size() < 2) continue;
          out.t[out.n] = (uint32_t)(pair[0] | 0);
          out.remaining[out.n] = (float)(pair[1] | 0.0);
          out.n++;
        }
      }
      JsonArray proj = b["proj"].as<JsonArray>();
      if (!proj.isNull()) {
        for (JsonVariant v : proj) {
          if (out.projN >= 2) break;
          JsonArray pair = v.as<JsonArray>();
          if (pair.isNull() || pair.size() < 2) continue;
          out.projT[out.projN] = (uint32_t)(pair[0] | 0);
          out.projR[out.projN] = (float)(pair[1] | 0.0);
          out.projN++;
        }
      }
      // Optional Cursor API overlay.
      JsonArray pts2 = b["pts2"].as<JsonArray>();
      if (!pts2.isNull()) {
        out.warn2 = b["warn2"] | false;
        out.estimated2 = b["est2"] | false;
        out.exhausted2 =
            strcmp((const char *)(b["status2"] | ""), "exhausted") == 0;
        for (JsonVariant v : pts2) {
          if (out.n2 >= MAX_BURN_PTS) break;
          JsonArray pair = v.as<JsonArray>();
          if (pair.isNull() || pair.size() < 2) continue;
          out.t2[out.n2] = (uint32_t)(pair[0] | 0);
          out.remaining2[out.n2] = (float)(pair[1] | 0.0);
          out.n2++;
        }
        JsonArray proj2 = b["proj2"].as<JsonArray>();
        if (!proj2.isNull()) {
          for (JsonVariant v : proj2) {
            if (out.projN2 >= 2) break;
            JsonArray pair = v.as<JsonArray>();
            if (pair.isNull() || pair.size() < 2) continue;
            out.projT2[out.projN2] = (uint32_t)(pair[0] | 0);
            out.projR2[out.projN2] = (float)(pair[1] | 0.0);
            out.projN2++;
          }
        }
      }
      out.ok = out.n > 0;
    }
  }

  // Vercel deployments
  vercelOk = false;
  vercelTeam = "";
  vercelN = 0;
  JsonObject vx = doc["vercel"].as<JsonObject>();
  if (!vx.isNull()) {
    vercelOk = vx["ok"] | false;
    vercelTeam = String((const char *)(vx["team"] | ""));
    JsonArray deps = vx["deployments"].as<JsonArray>();
    if (!deps.isNull()) {
      for (JsonVariant v : deps) {
        if (vercelN >= MAX_DEPLOYS) break;
        JsonObject d = v.as<JsonObject>();
        if (d.isNull()) continue;
        DeployRow &r = vercelRows[vercelN++];
        r.project = String((const char *)(d["project"] | "?"));
        r.status  = String((const char *)(d["status"] | ""));
        r.target  = String((const char *)(d["target"] | ""));
        r.ago     = String((const char *)(d["ago"] | ""));
        r.branch  = String((const char *)(d["branch"] | ""));
      }
    }
  }

  // Git commits
  gitOk = false;
  gitN = 0;
  JsonObject gx = doc["git"].as<JsonObject>();
  if (!gx.isNull()) {
    gitOk = gx["ok"] | false;
    JsonArray commits = gx["commits"].as<JsonArray>();
    if (!commits.isNull()) {
      for (JsonVariant v : commits) {
        if (gitN >= MAX_COMMITS) break;
        JsonObject c = v.as<JsonObject>();
        if (c.isNull()) continue;
        CommitRow &r = gitRows[gitN++];
        r.repo    = String((const char *)(c["repo"] | "?"));
        r.subject = String((const char *)(c["subject"] | ""));
        r.ago     = String((const char *)(c["ago"] | ""));
        r.branch  = String((const char *)(c["branch"] | ""));
      }
    }
  }

  // Local listening servers
  localOk = false;
  localHost = "";
  localN = 0;
  JsonObject lx = doc["local"].as<JsonObject>();
  if (!lx.isNull()) {
    localOk = lx["ok"] | false;
    localHost = String((const char *)(lx["host"] | ""));
    JsonArray servers = lx["servers"].as<JsonArray>();
    if (!servers.isNull()) {
      for (JsonVariant v : servers) {
        if (localN >= MAX_SERVERS) break;
        JsonObject s = v.as<JsonObject>();
        if (s.isNull()) continue;
        ServerRow &r = localRows[localN++];
        r.name = String((const char *)(s["name"] | "?"));
        r.port = (int)(s["port"] | 0);
        r.cmd  = String((const char *)(s["cmd"] | ""));
      }
    }
  }

  // Sources panel (Mac Settings + ESP32 footer share this list).
  sourceN = 0;
  JsonArray sx = doc["sources"].as<JsonArray>();
  if (!sx.isNull()) {
    for (JsonVariant v : sx) {
      if (sourceN >= MAX_SOURCES) break;
      JsonObject s = v.as<JsonObject>();
      if (s.isNull()) continue;
      SourceRow &r = sourceRows[sourceN++];
      r.id = String((const char *)(s["id"] | ""));
      r.title = String((const char *)(s["title"] | r.id.c_str()));
      r.enabled = s["enabled"].isNull() ? true : (bool)(s["enabled"] | true);
      r.ok = s["ok"] | false;
      r.stale = s["stale"] | false;
    }
  }

  haveData = true;
  hostOk = true;
  return true;
}

static bool applyUsageJson(const char *payload, size_t len) {
  JsonDocument doc(&spiRamAlloc);
  JsonDocument filter = usageFilter();
  DeserializationError err = (len > 0)
      ? deserializeJson(doc, payload, len,
                        DeserializationOption::Filter(filter))
      : deserializeJson(doc, payload, DeserializationOption::Filter(filter));
  if (err) {
    Serial.printf("json parse fail: %s\n", err.c_str());
    hostOk = false;
    return false;
  }
  return applyUsageDoc(doc);
}

static bool applyUsageStream(Stream &stream) {
  JsonDocument doc(&spiRamAlloc);
  JsonDocument filter = usageFilter();
  DeserializationError err =
      deserializeJson(doc, stream, DeserializationOption::Filter(filter));
  if (err) {
    Serial.printf("json parse fail: %s\n", err.c_str());
    hostOk = false;
    return false;
  }
  return applyUsageDoc(doc);
}

static bool fetchUsageHttp() {
  if (WiFi.status() != WL_CONNECTED) return false;
  String url = "http://" + hostFor() + ":" + String(HOST_PORT) +
               "/usage?view=device&fw=" + fwVersion();
  HTTPClient http;
  // Fail fast — a slow/wrong LAN must not starve BOOT/touch.
  http.setConnectTimeout(700);
  http.setTimeout(1000);
  if (!http.begin(url)) return false;
  addAuthHeader(http);
  int code = http.GET();
  if (code != 200) {
    http.end();
    if (code == 401) {
      Serial.println("usage → HTTP 401: HOST_TOKEN missing or wrong");
    }
    resolvedHost = "";   // force a fresh mDNS lookup next time
    return false;
  }

  // Parse straight off the socket. getString() would hold the whole body in
  // heap at the same time as the JSON document — two copies of the payload
  // for no reason.
  bool ok = applyUsageStream(http.getStream());
  http.end();
  return ok;
}

static bool fetchUsageUsb(uint32_t timeoutMs) {
  char *body = nullptr;
  size_t len = 0;
  const String request = "HR GET /usage?fw=" + fwVersion();
  if (!usbTransact(request.c_str(), 200, &body, &len, timeoutMs)) return false;
  bool ok = applyUsageJson(body, len);
  if (body) heap_caps_free(body);
  return ok;
}

static bool fetchUsage(uint32_t usbTimeoutMs = USB_TIMEOUT_POLL_MS) {
  // Wi-Fi HTTP first when associated. USB is travel/offline fallback.
  // Do not service touch/BOOT from inside USB waits — Serial TX can block
  // forever while the host holds the CDC write path (UI deadlock).
  if (WiFi.status() == WL_CONNECTED && fetchUsageHttp()) {
    Serial.println("usage via Wi-Fi");
    return true;
  }
  if (fetchUsageUsb(usbTimeoutMs)) {
    Serial.println("usage via USB");
    return true;
  }
  hostOk = false;
  return false;
}

// ---------------- Rendering ----------------
// Logical landscape size (448×368).
static inline int16_t scrW() { return gfx->width(); }
static inline int16_t scrH() { return gfx->height(); }

static int16_t textWidth(const char *s, uint8_t size) {
  gfx->setTextSize(size);
  int16_t x1, y1; uint16_t w, h;
  gfx->getTextBounds(s, 0, 0, &x1, &y1, &w, &h);
  return (int16_t)w;
}

static void drawCentered(const char *s, int y, uint8_t size, uint16_t col) {
  const int16_t w = textWidth(s, size);
  gfx->setTextColor(col);
  gfx->setCursor((scrW() - w) / 2, y);
  gfx->print(s);
}

static void drawTextAt(const char *s, int x, int y, uint8_t size, uint16_t col) {
  gfx->setTextSize(size);
  gfx->setTextColor(col);
  gfx->setCursor(x, y);
  gfx->print(s);
}

// Right-aligned to `rightX`. Every page ends up doing this — measure, subtract,
// place — so it lives here instead of being open-coded a dozen times.
static void drawRightAt(const char *s, int rightX, int y, uint8_t size,
                        uint16_t col) {
  const int16_t w = textWidth(s, size);
  gfx->setTextColor(col);
  gfx->setCursor(rightX - w, y);
  gfx->print(s);
}

static void drawCentered(const String &s, int y, uint8_t size, uint16_t col) {
  drawCentered(s.c_str(), y, size, col);
}

static void drawTextAt(const String &s, int x, int y, uint8_t size, uint16_t col) {
  drawTextAt(s.c_str(), x, y, size, col);
}

static void drawRightAt(const String &s, int rightX, int y, uint8_t size,
                        uint16_t col) {
  drawRightAt(s.c_str(), rightX, y, size, col);
}

// Shared page inset — keep boot chrome + dashboards clear of the corner radius.
static const int16_t UI_PAD = 28;

static void drawStatus(const String &msg, uint16_t col) {
  gfx->clear(COL_CRT_BG);
  const int16_t pad = UI_PAD;
  gfx->drawRect(pad, pad, scrW() - pad * 2, scrH() - pad * 2, COL_CRT_DIM);
  drawCentered("HEADROOM", pad + 16, 2, COL_CRT);
  drawCentered(msg, scrH() / 2, 2, col);
  gfx->flush();
}

// ---- 8-bit CRT boot ----
static int16_t bootY = 0;
static uint8_t bootBlink = 0;

static void bootScanlines() {
  const int16_t x0 = UI_PAD + 4;
  const int16_t x1 = scrW() - UI_PAD - 4;
  const int16_t y0 = UI_PAD + 36;
  const int16_t y1 = scrH() - UI_PAD - 4;
  for (int16_t y = y0; y < y1; y += 3) {
    gfx->drawFastHLine(x0, y, (int16_t)(x1 - x0), COL_CRT_SCAN);
  }
}

static void bootChrome() {
  gfx->clear(COL_CRT_BG);
  const int16_t pad = UI_PAD;
  const int16_t inner = pad + 3;
  gfx->drawRect(pad, pad, scrW() - pad * 2, scrH() - pad * 2, COL_CRT);
  gfx->drawRect(inner, inner, scrW() - inner * 2, scrH() - inner * 2, COL_CRT_DIM);
  gfx->fillRect(inner + 1, inner + 1, scrW() - inner * 2 - 2, 26,
                COL_CRT_HDR);
  drawTextAt("HEADROOM", pad + 10, pad + 8, 2, COL_CRT);
  drawTextAt("ROM", scrW() - pad - 42, pad + 8, 2, COL_CRT_DIM);
  gfx->drawFastHLine(inner + 1, pad + 30, scrW() - inner * 2 - 2, COL_CRT);
  bootScanlines();
  bootY = pad + 42;
}

static void bootFlush() {
  bootBlink ^= 1;
  const int16_t cx = scrW() - UI_PAD - 18;
  const int16_t cy = UI_PAD + 8;
  gfx->fillRect(cx, cy, 8, 14, bootBlink ? COL_CRT : COL_CRT_HDR);
  gfx->flush();
}

static void bootSplash() {
  bootChrome();
  drawCentered("20 MINUTES", scrH() / 2 - 28, 2, COL_CRT_DIM);
  drawCentered("INTO THE FUTURE", scrH() / 2 - 6, 2, COL_CRT);
  drawCentered("* SYSTEM ONLINE *", scrH() / 2 + 28, 2, COL_CRT_DIM);
  gfx->fillRect(scrW() / 2 - 60, scrH() / 2 + 50, 120, 4, COL_CRT);
  bootFlush();
  delay(550);
  bootChrome();
  bootFlush();
}

static void bootLine(const char *label, const char *status, uint16_t statusCol) {
  if (bootY > scrH() - UI_PAD - 28) {
    bootChrome();
  }

  const int16_t x0 = UI_PAD + 10;
  const int16_t xMax = scrW() - UI_PAD - 10;
  gfx->setTextSize(2);
  int16_t x1, y1; uint16_t lw, lh, rw, rh, dw, dh;
  gfx->getTextBounds(label, 0, 0, &x1, &y1, &lw, &lh);
  gfx->getTextBounds(".", 0, 0, &x1, &y1, &dw, &dh);
  if (dw < 1) dw = 6;

  // Keep room for label + a few leader dots; show as many status chars as fit.
  const int16_t budget =
      (int16_t)(xMax - x0 - (int16_t)lw - 4 - (int16_t)(dw + 2) * 3);
  char right[40];
  size_t sn = strlen(status);
  if (sn >= sizeof(right)) sn = sizeof(right) - 1;
  memcpy(right, status, sn);
  right[sn] = '\0';
  while (sn > 0) {
    gfx->getTextBounds(right, 0, 0, &x1, &y1, &rw, &rh);
    if ((int16_t)rw <= budget) break;
    right[--sn] = '\0';
  }
  if (sn == 0) rw = 0;

  // Label (bright) … leaders (faded) … status
  drawTextAt(label, x0, bootY, 2, COL_CRT);
  const int16_t statusX = (int16_t)(xMax - (int16_t)rw);
  gfx->setTextColor(statusCol);
  gfx->setCursor(statusX, bootY);
  gfx->print(right);

  int16_t dotX = (int16_t)(x0 + (int16_t)lw + 4);
  const int16_t dotEnd = (int16_t)(statusX - 4);
  gfx->setTextColor(COL_CRT_DIM);
  while (dotX + (int16_t)dw <= dotEnd) {
    gfx->setCursor(dotX, bootY);
    gfx->print('.');
    dotX = (int16_t)(dotX + (int16_t)dw + 2);
  }

  bootY = (int16_t)(bootY + 20);
  bootFlush();
  delay(55);
}

// Growing dots after the label, marching toward the right edge (not a 4-dot loop).
static void bootProgress(const char *label, uint8_t step) {
  const int16_t x0 = UI_PAD + 10;
  const int16_t y = bootY;
  const int16_t xMax = scrW() - UI_PAD - 10;
  const int16_t bw = (int16_t)(xMax - x0);
  gfx->fillRect(x0, y, bw, 18, COL_CRT_BG);
  for (int16_t sy = y; sy < y + 18; sy += 3)
    gfx->drawFastHLine(x0, sy, bw, COL_CRT_SCAN);

  drawTextAt(label, x0, y, 2, COL_CRT);

  int16_t x1, y1; uint16_t lw, lh, dw, dh;
  gfx->setTextSize(2);
  gfx->getTextBounds(label, 0, 0, &x1, &y1, &lw, &lh);
  gfx->getTextBounds(".", 0, 0, &x1, &y1, &dw, &dh);
  if (dw < 1) dw = 6;

  const int16_t start = (int16_t)(x0 + (int16_t)lw + 4);
  const int16_t gap = (int16_t)(dw + 2);
  uint8_t maxDots = 0;
  for (int16_t x = start; x + (int16_t)dw <= xMax; x = (int16_t)(x + gap))
    maxDots++;
  if (maxDots < 1) maxDots = 1;

  uint8_t dots = (uint8_t)(step + 1);
  if (dots > maxDots) dots = maxDots;

  gfx->setTextColor(COL_CRT);
  int16_t dotX = start;
  for (uint8_t i = 0; i < dots; i++) {
    gfx->setCursor(dotX, y);
    gfx->print('.');
    dotX = (int16_t)(dotX + gap);
  }
  bootFlush();
}

// CodexBar-style pill progress bar + optional pace marker (where a linear
// burn would be right now in the window). Keep provider accent even at 100%.
static void drawBar(int16_t x, int16_t y, int16_t w, int16_t h,
                    float pct, float pacePct, uint16_t accent) {
  gfx->fillRoundRect(x, y, w, h, h / 2, COL_BAR);
  float p = pct < 0 ? 0 : (pct > 100 ? 100 : pct);
  int16_t fill = (int16_t)((w * p) / 100.0f + 0.5f);
  if (fill < h) fill = (p > 0) ? h : 0;
  if (fill > 0) {
    if (fill > w) fill = w;
    gfx->fillRoundRect(x, y, fill, h, h / 2, accent);
  }
  if (pacePct >= 0) {
    float pp = pacePct > 100 ? 100 : pacePct;
    int16_t cx = x + (int16_t)((w * pp) / 100.0f + 0.5f);
    if (cx < x + 3) cx = x + 3;
    if (cx > x + w - 4) cx = x + w - 4;
    // White tick (CodexBar) — slightly taller than the bar so it reads as a mark.
    gfx->fillRect(cx - 1, y - 2, 3, h + 4, COL_WHITE);
  }
}

// Compact full-width meter for model pages: title, bar, pct + reset on one
// line. Sized so two of them fit in the top half and leave the bottom half
// for the burndown chart (side-by-side columns were too narrow for the labels).
static const int16_t QUOTA_ROW_H = 54;

static void drawQuotaRowCompact(const char *title, float pct, float pace,
                                const String &resets, int16_t y, int16_t pad,
                                uint16_t accent) {
  const int16_t x = pad;
  const int16_t w = (int16_t)(scrW() - pad * 2);
  char buf[48];
  char pctBuf[12];
  drawTextAt(title, x, y, 2, COL_WHITE);
  drawBar(x, y + 18, w, 10, pct, pace, accent);
  snprintf(buf, sizeof buf, "%s used", fmtPct(pctBuf, sizeof pctBuf, pct));
  drawTextAt(buf, x, y + 36, 2, COL_WHITE);
  if (resets.length()) {
    snprintf(buf, sizeof buf, "Resets in %s", resets.c_str());
    drawRightAt(buf, (int16_t)(x + w), y + 36, 2, COL_DIM);
  }
}

// glcdfont is ASCII-only. Host copy uses middot (U+00B7 = UTF-8 C2 B7) which
// otherwise paints as two garbage glyphs — "On track XX 15%". device_view
// already substitutes, but older hosts and firmware-built strings still need
// this pass.
static String boardAscii(const char *s) {
  String out;
  if (!s || !s[0]) return out;
  out.reserve(strlen(s));
  while (*s) {
    const unsigned char c = (unsigned char)*s;
    if (c < 0x80) {
      out += (char)c;
      s++;
      continue;
    }
    // Middot · and the common dash codepoints → ASCII hyphen.
    if (c == 0xC2 && (unsigned char)s[1] == 0xB7) {  // U+00B7
      out += '-';
      s += 2;
      continue;
    }
    if (c == 0xE2 && (unsigned char)s[1] == 0x80 &&
        ((unsigned char)s[2] == 0x93 || (unsigned char)s[2] == 0x94)) {
      // U+2013 en-dash / U+2014 em-dash
      out += '-';
      s += 3;
      continue;
    }
    // Skip any other multi-byte sequence so we don't emit continuation bytes.
    if ((c & 0xE0) == 0xC0 && s[1]) { s += 2; out += '-'; continue; }
    if ((c & 0xF0) == 0xE0 && s[1] && s[2]) { s += 3; out += '-'; continue; }
    if ((c & 0xF8) == 0xF0 && s[1] && s[2] && s[3]) {
      s += 4;
      out += '-';
      continue;
    }
    s++;
  }
  return out;
}

static String truncFit(const String &s, int16_t maxW, uint8_t size) {
  // Ellipsize so a line fits in maxW pixels at the given text size.
  gfx->setTextSize(size);
  int16_t x1, y1; uint16_t tw, th;
  gfx->getTextBounds(s.c_str(), 0, 0, &x1, &y1, &tw, &th);
  if ((int16_t)tw <= maxW) return s;
  String out = s;
  while (out.length() > 1) {
    out.remove(out.length() - 1);
    String trial = out + "...";
    gfx->getTextBounds(trial.c_str(), 0, 0, &x1, &y1, &tw, &th);
    if ((int16_t)tw <= maxW) return trial;
  }
  return "...";
}

// Hard-clip to maxW — no ellipsis, so more of the real name stays visible.
static String clipFit(const String &s, int16_t maxW, uint8_t size) {
  gfx->setTextSize(size);
  int16_t x1, y1; uint16_t tw, th;
  gfx->getTextBounds(s.c_str(), 0, 0, &x1, &y1, &tw, &th);
  if ((int16_t)tw <= maxW) return s;
  String out = s;
  while (out.length() > 0) {
    out.remove(out.length() - 1);
    gfx->getTextBounds(out.c_str(), 0, 0, &x1, &y1, &tw, &th);
    if ((int16_t)tw <= maxW) return out;
  }
  return "";
}

// Name left + age right-aligned; clip name to one space before the age.
static void drawNameAgoRow(int16_t x, int16_t y, int16_t colW,
                           const String &name, const String &ago,
                           uint16_t nameCol, uint16_t agoCol) {
  gfx->setTextSize(2);
  int16_t x1, y1; uint16_t aw, ah, sw, sh;
  gfx->getTextBounds(ago.c_str(), 0, 0, &x1, &y1, &aw, &ah);
  gfx->getTextBounds(" ", 0, 0, &x1, &y1, &sw, &sh);  // one space gap
  String clipped = clipFit(name, (int16_t)(colW - (int16_t)aw - (int16_t)sw), 2);
  drawTextAt(clipped, x, y, 2, nameCol);
  gfx->setTextColor(agoCol);
  gfx->setCursor(x + colW - (int16_t)aw, y);
  gfx->print(ago);
}

// Activity dots stay neutral — status words carry good vs bad
// (same rule as the Mac GitHub list).
static uint16_t statusColor(const String &status) {
  (void)status;
  return COL_DIM;
}

// Normalize "ago" strings to whole hours for glance columns.
static String gitHoursAgo(const String &ago) {
  // ASCII only: gfx->print walks bytes into the 5x7 table, so a UTF-8 dash
  // would paint three CP437 glyphs.
  if (!ago.length()) return "-";
  int days = 0, hours = 0;
  const char *p = ago.c_str();
  while (*p) {
    while (*p == ' ') p++;
    if (!*p) break;
    char *end = nullptr;
    long v = strtol(p, &end, 10);
    if (end == p) break;
    if (*end == 'd' || *end == 'D') { days = (int)v; p = end + 1; }
    else if (*end == 'h' || *end == 'H') { hours = (int)v; p = end + 1; }
    else if (*end == 'm' || *end == 'M') { p = end + 1; }  // ignore minutes
    else break;
  }
  char b[12];
  snprintf(b, sizeof b, "%dh", days * 24 + hours);
  return String(b);
}

// "…T14:32:00+0200" -> "14:32". Every page shows this, so it gets a buffer
// rather than five substring() allocations per frame.
static bool updatedHHMM(char *buf, size_t n) {
  if (updatedZ.length() < 16 || n < 6) {
    buf[0] = '\0';
    return false;
  }
  memcpy(buf, updatedZ.c_str() + 11, 5);
  buf[5] = '\0';
  return true;
}

static const char *pageName(Page p) {
  switch (p) {
    case PAGE_GLANCE: return "Headroom";
    case PAGE_CLAUDE: return "Claude";
    case PAGE_CODEX:  return "Codex";
    case PAGE_CURSOR: return "Cursor";
    case PAGE_VERCEL: return "Vercel";
    case PAGE_GIT:    return "Git";
    case PAGE_LOCAL:  return "Local";
    default:          return "?";
  }
}

static void drawWifiDot(int16_t padX, int16_t top) {
  // Healthy link: nothing. Red only when last /usage fetch failed
  // (Wi-Fi HTTP or USB CDC).
  if (hostOk) return;
  gfx->fillCircle(scrW() - padX / 2, top + 8, 5, COL_RED);
}

// Hottest pool % + matching pace for a provider (-1 if unavailable).
// One pace layer: a pool's usage and where an even spend would have it.
struct PaceLayer { float pct; float pace; };

// Up to `max` layers, fastest window first so the shortest window ends up the
// outermost ring. A pool the API doesn't report is simply absent — Codex has
// no session window on some plans — so a provider can legitimately draw one
// ring instead of two.
static uint8_t providerLayers(const ProviderQuota &q, PaceLayer *out,
                              uint8_t max) {
  uint8_t n = 0;
  if (!q.ok || max == 0) return 0;
  if (q.totalPct >= 0) {
    // Cursor: Total (included) then API (on-demand). Both ride the same
    // billing cycle, so there is no faster/slower to order by — Total is the
    // headline ring, API the one that actually drains when you burn tokens.
    out[n++] = {q.totalPct, q.totalPace};
    if (n < max && q.weekPct >= 0) out[n++] = {q.weekPct, q.weekPace};
    return n;
  }
  if (q.sessionPct >= 0) out[n++] = {q.sessionPct, q.sessionPace};
  if (n < max && q.weekPct >= 0) out[n++] = {q.weekPct, q.weekPace};
  return n;
}

// Blend a colour toward the background. RGB565 has to be unpacked to do it.
static uint16_t dimToward(uint16_t color, uint16_t bg, float factor) {
  const int cr = (color >> 11) & 0x1F;
  const int cg = (color >> 5) & 0x3F;
  const int cb = color & 0x1F;
  const int br = (bg >> 11) & 0x1F;
  const int bgc = (bg >> 5) & 0x3F;
  const int bb = bg & 0x1F;
  const int r = br + (int)((cr - br) * factor + 0.5f);
  const int g = bgc + (int)((cg - bgc) * factor + 0.5f);
  const int b = bb + (int)((cb - bb) * factor + 0.5f);
  return (uint16_t)((r << 11) | (g << 5) | b);
}

// Fixed-width radial "now" line. Unlike an angular arc, its apparent width
// does not grow with radius, so inner and outer quota bands match.
static void drawRadialIndicator(int16_t cx, int16_t cy, int16_t inner,
                                int16_t outer, float angle,
                                uint16_t color) {
  const float radians = angle * DEG_TO_RAD;
  const float ux = cosf(radians);
  const float uy = sinf(radians);
  const float tx = -uy;
  const float ty = ux;
  for (int8_t offset = -1; offset <= 1; offset++) {
    gfx->drawLine(
        (int16_t)lroundf(cx + ux * inner + tx * offset),
        (int16_t)lroundf(cy + uy * inner + ty * offset),
        (int16_t)lroundf(cx + ux * outer + tx * offset),
        (int16_t)lroundf(cy + uy * outer + ty * offset),
        color);
  }
}

// One ring band: track + filled arc from 12 o'clock + radial pace line.
// The gap between where the arc stops and where the tick sits is the deficit.
static void drawPaceRing(int16_t cx, int16_t cy, int16_t r, int16_t thick,
                         float pct, float pacePct, uint16_t accent) {
  const int16_t inner = (int16_t)(r - thick);
  // A neutral track is indistinguishable from background at this size, so two
  // near-empty rings merge into one dark blob. Tinting keeps each ring legible
  // as a ring before any of it fills.
  // Shared Headroom ring contract: 20% tinted track, square usage arc, and a
  // high-contrast radial pace line. Swift surfaces mirror these semantics.
  gfx->fillArc(cx, cy, r, inner, 0, 360, dimToward(accent, COL_BG, 0.20f));
  if (pct >= 0) {
    float p = pct > 100 ? 100 : pct;
    float sweep = p * 3.6f;
    if (p > 0 && sweep < 2.0f) sweep = 2.0f;
    if (p >= 100 || sweep >= 359.0f) {
      gfx->fillArc(cx, cy, r, inner, 0, 360, accent);
    } else {
      gfx->fillArc(cx, cy, r, inner, -90.0f, -90.0f + sweep, accent);
    }
  }
  if (pacePct >= 0) {
    float pp = pacePct > 100 ? 100 : pacePct;
    float a = -90.0f + pp * 3.6f;
    drawRadialIndicator(cx, cy, (int16_t)(inner - 2),
                        (int16_t)(r + 2), a, COL_WHITE);
  }
}

// Concentric pace layers for one provider, plus the label underneath.
static void drawQuotaRing(int16_t cx, int16_t cy, int16_t r,
                          const ProviderQuota &q, uint16_t accent,
                          const char *label) {
  const int16_t thick = 6;
  const int16_t gap = 4;   // below ~4 the two bands read as one thick border
  PaceLayer layers[2];
  uint8_t n = providerLayers(q, layers, 2);
  if (n == 0) {
    drawPaceRing(cx, cy, r, thick, -1, -1, accent);
  } else {
    int16_t rr = r;
    for (uint8_t i = 0; i < n; i++) {
      // Equal thickness: a thinner inner band reads as subordinate, when the
      // two pools are just different time horizons of the same thing.
      drawPaceRing(cx, cy, rr, thick, layers[i].pct, layers[i].pace, accent);
      rr = (int16_t)(rr - thick - gap);
    }
  }
  gfx->setTextSize(2);
  int16_t x1, y1; uint16_t tw, th;
  gfx->getTextBounds(label, 0, 0, &x1, &y1, &tw, &th);
  gfx->setTextColor(accent);
  gfx->setCursor(cx - (int16_t)tw / 2, cy + r + 8);
  gfx->print(label);
}

// Host `updated` ends in ±HHMM — needed before drawBurndown for local day rules.
static int32_t updatedTzOffsetS();

// Burndown chart: dotted budget line falling from full at the window's start
// to zero at its reset, the actual remaining-% curve over it, and a lightly
// dashed accent tail for where the current pace lands. Below the budget line
// means burning faster than the window can afford. Windows ≥2 days also get
// local midnight rules + weekday names (same furniture as Mac/iOS provider
// cards and the home overall chart).
static void drawBurndown(const Burndown &b, int16_t x, int16_t y,
                         int16_t w, int16_t h, uint16_t accent) {
  // Reserve a label band under the plot when the window spans real days.
  const bool showDays =
      b.ok && b.t1 > b.t0 && (b.t1 - b.t0) >= 2u * 86400u && h >= 48;
  const int16_t axisH = showDays ? 12 : 0;
  const int16_t plotH = (int16_t)(h - axisH);

  const uint16_t track = dimToward(accent, COL_BG, 0.45f);
  gfx->drawRect(x, y, w, plotH, track);
  if (!b.ok || b.t1 <= b.t0) {
    // LABEL_COLLECTING_HISTORY is ~216px at size 2 — it doesn't fit a home column.
    drawTextAt(w >= 232 ? LABEL_COLLECTING_HISTORY : LABEL_NO_DATA,
               x + 8, y + plotH / 2 - 8, 2, COL_DIM);
    return;
  }

  const uint32_t span = b.t1 - b.t0;
  auto px = [&](uint32_t t) -> int16_t {
    if (t <= b.t0) return x;
    if (t >= b.t1) return (int16_t)(x + w - 1);
    return (int16_t)(x + (int32_t)((uint64_t)(t - b.t0) * (w - 1) / span));
  };
  auto py = [&](float remaining) -> int16_t {
    float r = remaining < 0 ? 0 : (remaining > 100 ? 100 : remaining);
    return (int16_t)(y + plotH - 1 - (int16_t)(r * (plotH - 1) / 100.0f));
  };

  // A 1px run vanishes on a 122px home chart at desk distance, so every stroke
  // here is 3px: the segment plus a row either side, clamped inside the box so
  // a full or empty pool doesn't eat the border.
  auto stroke = [&](int16_t ax, int16_t ay, int16_t bx, int16_t by,
                    uint16_t col) {
    for (int16_t d = -1; d <= 1; d++) {
      const int16_t a = (int16_t)(ay + d), c = (int16_t)(by + d);
      if (a < y || a > y + plotH - 1 || c < y || c > y + plotH - 1) continue;
      gfx->drawLine(ax, a, bx, c, col);
    }
  };

  // Day boundaries as vertical rules + weekday (or date) labels — mirrors
  // Mac drawBurndownCalendar / home drawGlanceBurndown. Skip the first edge
  // rule (it would sit on the left border). Dense monthly windows drop to
  // one mark a week so the grid stays readable.
  if (showDays) {
    const int32_t tz = updatedTzOffsetS();
    const uint32_t localT0 = (uint32_t)((int64_t)b.t0 + tz);
    const uint32_t localDay0 = localT0 - (localT0 % 86400u);
    const uint8_t dayCount =
        (uint8_t)((span + 86400u - 1u) / 86400u);
    const bool daily = dayCount > 0 && (w / (int16_t)dayCount) >= 22;
    const uint8_t step = daily ? 1 : 7;
    const uint16_t grid = dimToward(COL_WHITE, COL_BG, 0.22f);
    static const char *const WD[] = {
        "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"};
    const int16_t axisY = (int16_t)(y + plotH + 2);
    for (uint16_t d = 0; d < 62; d = (uint16_t)(d + step)) {
      const uint32_t localMidnight = localDay0 + (uint32_t)d * 86400u;
      const uint32_t dayUtc = (uint32_t)((int64_t)localMidnight - tz);
      if (dayUtc >= b.t1) break;
      const int16_t dx = px(dayUtc);
      if (dayUtc > b.t0) {
        gfx->drawFastVLine(dx, (int16_t)(y + 1), (int16_t)(plotH - 2), grid);
      }
      time_t tt = (time_t)localMidnight;
      struct tm parts;
      gmtime_r(&tt, &parts);
      if (daily) {
        drawTextAt(WD[parts.tm_wday], (int16_t)(dx + 2), axisY, 1, COL_DIM);
      } else {
        char label[8];
        snprintf(label, sizeof label, "%d", parts.tm_mday);
        drawTextAt(label, (int16_t)(dx + 2), axisY, 1, COL_DIM);
      }
    }
  }

  // Budget line, dashed so the solid actual curve still reads as the subject.
  const uint16_t budget = dimToward(COL_WHITE, COL_BG, 0.55f);
  for (int16_t i = 0; i < w; i += 6) {
    const int16_t i2 = (int16_t)((i + 3 < w) ? i + 3 : w - 1);
    const int16_t ya = (int16_t)(y + (int32_t)i * (plotH - 1) / (w - 1));
    const int16_t yb = (int16_t)(y + (int32_t)i2 * (plotH - 1) / (w - 1));
    gfx->drawLine((int16_t)(x + i), ya, (int16_t)(x + i2), yb, budget);
    if (ya + 1 <= y + plotH - 1) {
      gfx->drawLine((int16_t)(x + i), (int16_t)(ya + 1),
                    (int16_t)(x + i2), (int16_t)(yb + 1), budget);
    }
  }

  // Cursor API under Total so the headline pool sits on top when they share
  // an accent. Dimmed so the two stay distinguishable.
  if (b.n2 > 1) {
    const uint16_t line2 = b.exhausted2 ? COL_DIM
                         : dimToward(accent, COL_BG, 0.70f);
    for (uint8_t i = 1; i < b.n2; i++) {
      stroke(px(b.t2[i - 1]), py(b.remaining2[i - 1]),
             px(b.t2[i]), py(b.remaining2[i]), line2);
    }
    if (b.projN2 == 2) {
      const float dR2 = b.projR2[1] - b.projR2[0];
      if (dR2 < -0.5f || dR2 > 0.5f || b.warn2) {
        const int16_t x0 = px(b.projT2[0]), y0 = py(b.projR2[0]);
        const int16_t x1 = px(b.projT2[1]), y1 = py(b.projR2[1]);
        if (dR2 < -0.5f || dR2 > 0.5f) {
          const int16_t steps = (int16_t)(x1 - x0);
          // Same 6-on / 2-off as Mac/iOS — estimated vs measured is copy, not stroke.
          const int16_t stride = 8;
          const int16_t dash = 6;
          for (int16_t i = 0; i < steps; i += stride) {
            int16_t ax = (int16_t)(x0 + i);
            int16_t ay = (int16_t)(y0 + (int32_t)(y1 - y0) * i / (steps ? steps : 1));
            const int16_t seg = (i + dash > steps) ? (int16_t)(steps - i) : dash;
            stroke(ax, ay, (int16_t)(ax + seg),
                   (int16_t)(y0 + (int32_t)(y1 - y0) * (i + seg) /
                             (steps ? steps : 1)), line2);
          }
        }
        if (b.warn2) gfx->fillCircle(x1, y1, 3, line2);
      }
    }
    if (b.n2 > 0) {
      gfx->fillCircle(px(b.t2[b.n2 - 1]), py(b.remaining2[b.n2 - 1]), 2, line2);
    }
  }

  // Actual curve (primary / Total). Only exhaustion changes the colour, and it
  // desaturates rather than warns — same rule the Mac card follows. Running out
  // early is a reading, not a verdict: the curve's distance below the budget
  // diagonal already shows it, the dot marks where it hits zero, and the
  // caption says it in words. Painting all three plus the line itself red
  // spends the loudest colour on the thing least able to be precise about it.
  const uint16_t line = b.exhausted ? COL_DIM : accent;
  for (uint8_t i = 1; i < b.n; i++) {
    stroke(px(b.t[i - 1]), py(b.remaining[i - 1]),
           px(b.t[i]), py(b.remaining[i]), line);
  }

  // Projection: lightly dashed accent (6 on, 2 off — same as Mac/iOS) plus a
  // marker where it hits the floor. Skip a level forecast — measured-zero
  // pace would paint a bar across the whole window and erase the budget
  // diagonal (Codex idle after an early burn).
  if (b.projN == 2) {
    const float dR = b.projR[1] - b.projR[0];
    if (dR < -0.5f || dR > 0.5f || b.warn) {
      const int16_t x0 = px(b.projT[0]), y0 = py(b.projR[0]);
      const int16_t x1 = px(b.projT[1]), y1 = py(b.projR[1]);
      if (dR < -0.5f || dR > 0.5f) {
        const int16_t steps = (int16_t)(x1 - x0);
        const int16_t stride = 8;
        const int16_t dash = 6;
        for (int16_t i = 0; i < steps; i += stride) {
          int16_t ax = (int16_t)(x0 + i);
          int16_t ay = (int16_t)(y0 + (int32_t)(y1 - y0) * i / (steps ? steps : 1));
          const int16_t seg = (i + dash > steps) ? (int16_t)(steps - i) : dash;
          stroke(ax, ay, (int16_t)(ax + seg),
                 (int16_t)(y0 + (int32_t)(y1 - y0) * (i + seg) /
                           (steps ? steps : 1)), line);
        }
      }
      if (b.warn) gfx->fillCircle(x1, y1, 4, line);
    }
  }

  // Now marker (primary).
  if (b.n > 0) {
    const int16_t nx = px(b.t[b.n - 1]);
    const int16_t ny = py(b.remaining[b.n - 1]);
    gfx->fillCircle(nx, ny, 3, COL_WHITE);
    gfx->drawCircle(nx, ny, 4, COL_BG);   // keeps it off the curve it sits on
  }
}

// Headroom tap targets (logical coords) → detail pages, plus the header chip
// that flips the lower half between activity and burndowns.
enum HitKind : uint8_t { HIT_PAGE = 0, HIT_MODE = 1 };
struct GlanceHit {
  int16_t x, y, w, h;
  HitKind kind;
  Page target;
};
static const uint8_t MAX_GLANCE_HITS = 10;  // mode + 3 rings + 3 chart + 3 legend
static GlanceHit glanceHits[MAX_GLANCE_HITS];
static uint8_t glanceHitN = 0;

static void glanceClearHits() { glanceHitN = 0; }

static void glanceAddHit(int16_t x, int16_t y, int16_t w, int16_t h, Page target) {
  if (glanceHitN >= MAX_GLANCE_HITS) return;
  glanceHits[glanceHitN++] = {x, y, w, h, HIT_PAGE, target};
}

static void glanceAddModeHit(int16_t x, int16_t y, int16_t w, int16_t h) {
  if (glanceHitN >= MAX_GLANCE_HITS) return;
  glanceHits[glanceHitN++] = {x, y, w, h, HIT_MODE, PAGE_GLANCE};
}

static void nativeToLogical(int16_t nx, int16_t ny, int16_t *lx, int16_t *ly) {
  *lx = (int16_t)((LOG_W - 1) - ny);
  *ly = nx;
}

static bool glanceHitAt(int16_t nx, int16_t ny, GlanceHit *out) {
  if (page != PAGE_GLANCE || glanceHitN == 0) return false;
  int16_t lx, ly;
  nativeToLogical(nx, ny, &lx, &ly);
  for (uint8_t i = 0; i < glanceHitN; i++) {
    const GlanceHit &h = glanceHits[i];
    if (lx >= h.x && lx < h.x + h.w && ly >= h.y && ly < h.y + h.h) {
      *out = h;
      return true;
    }
  }
  return false;
}

static void flashGlanceSlot(const GlanceHit &h) {
  gfx->fillRect(h.x, h.y, h.w, h.h, COL_WHITE);
  gfx->flushLogicalRect(h.x, h.y, h.w, h.h);
  // No delay — next page paint replaces this immediately.
}

static const Burndown &burnFor(Page p);

// Lower half, activity reading: what shipped lately.
static void drawGlanceActivity(int16_t padX, int16_t span, int16_t midY,
                               int16_t lowBottom) {
  const Page lowPages[3] = {PAGE_VERCEL, PAGE_GIT, PAGE_LOCAL};

  // Local narrow (ports); Vercel/Git share the rest (~2–3 more chars).
  const int16_t lowTop = midY + 6;
  const int16_t localW = 78;
  const int16_t wideW = (span - localW) / 2;
  const int16_t lowW[3] = {wideW, (int16_t)(span - localW - wideW), localW};
  const int16_t lowX[3] = {
      padX,
      (int16_t)(padX + lowW[0]),
      (int16_t)(padX + lowW[0] + lowW[1])};
  const int16_t colPad = 4;
  const int16_t dotR = 5;
  const int16_t rowH = 20;
  const int16_t textX = 14;  // gap after status dot
  const uint8_t lowMax = 6;

  for (uint8_t i = 0; i < 3; i++) {
    glanceAddHit(lowX[i], midY, lowW[i], (int16_t)(lowBottom - midY), lowPages[i]);
    int16_t x = lowX[i] + colPad;
    int16_t colW = lowW[i] - colPad * 2;
    int16_t y = lowTop;

    if (i == 0) {
      // Vercel — status dot + project + age in hours (like Git).
      drawTextAt("Vercel", x, y, 2, COL_WHITE);
      y += 22;
      if (vercelOk && vercelN > 0) {
        for (uint8_t d = 0; d < vercelN && d < lowMax; d++) {
          if (y > lowBottom - 18) break;
          const DeployRow &r = vercelRows[d];
          gfx->fillCircle(x + dotR, y + 8, dotR, statusColor(r.status));
          drawNameAgoRow(x + textX, y, (int16_t)(colW - textX),
                         r.project, gitHoursAgo(r.ago),
                         COL_WHITE, COL_DIM);
          y += rowH;
        }
      } else {
        drawTextAt(vercelOk ? "-" : "down", x, y, 2, COL_DIM);
      }
    } else if (i == 1) {
      // Git — repo leaf (no owner) + age in hours (right-aligned).
      drawTextAt("Git", x, y, 2, COL_WHITE);
      y += 22;
      if (gitOk && gitN > 0) {
        for (uint8_t c = 0; c < gitN && c < lowMax; c++) {
          if (y > lowBottom - 18) break;
          String repo = gitRows[c].repo;
          int slash = repo.lastIndexOf('/');
          if (slash >= 0) repo = repo.substring(slash + 1);
          drawNameAgoRow(x, y, colW, repo, gitHoursAgo(gitRows[c].ago),
                         COL_WHITE, COL_DIM);
          y += rowH;
        }
      } else {
        drawTextAt(gitOk ? "-" : "down", x, y, 2, COL_DIM);
      }
    } else {
      // Local — one teal dot + port per listening server.
      drawTextAt("Local", x, y, 2, COL_WHITE);
      y += 22;
      if (localOk && localN > 0) {
        for (uint8_t s = 0; s < localN && s < lowMax; s++) {
          if (y > lowBottom - 18) break;
          gfx->fillCircle(x + dotR, y + 8, dotR, COL_LOCAL);
          String port = localRows[s].port > 0
                            ? (":" + String(localRows[s].port))
                            : "-";
          drawTextAt(port, x + textX, y, 2, COL_WHITE);
          y += rowH;
        }
      } else {
        drawTextAt(localOk ? "none" : "down", x, y, 2, COL_DIM);
      }
    }
  }
}

// Host `updated` ends in ±HHMM (e.g. +0200). Used to align the overall chart
// to the same local calendar week the Mac/iOS cards use. No NTP on the board.
static int32_t updatedTzOffsetS() {
  const int n = (int)updatedZ.length();
  if (n < 5) return 0;
  const char *s = updatedZ.c_str();
  const char sign = s[n - 5];
  if (sign != '+' && sign != '-') return 0;
  const int hh = (s[n - 4] - '0') * 10 + (s[n - 3] - '0');
  const int mm = (s[n - 2] - '0') * 10 + (s[n - 1] - '0');
  if (hh < 0 || hh > 14 || mm < 0 || mm > 59) return 0;
  const int32_t off = (int32_t)hh * 3600 + (int32_t)mm * 60;
  return sign == '-' ? -off : off;
}

// Clip a time/remaining segment to [tLo, tHi], interpolating at the edges so a
// weekly pool that runs past Friday still paints up to the chart's right edge
// instead of vanishing (Mac OverviewBurndownCard does the same).
static bool clipBurnSeg(uint32_t ta, float ra, uint32_t tb, float rb,
                        uint32_t tLo, uint32_t tHi,
                        uint32_t *oa, float *ora, uint32_t *ob, float *orb) {
  if (ta == tb) return false;
  if (ta > tb) {
    uint32_t ts = ta; ta = tb; tb = ts;
    float rs = ra; ra = rb; rb = rs;
  }
  if (tb < tLo || ta > tHi) return false;
  *oa = ta; *ora = ra; *ob = tb; *orb = rb;
  const float span = (float)(tb - ta);
  if (ta < tLo) {
    const float u = (float)(tLo - ta) / span;
    *oa = tLo;
    *ora = ra + u * (rb - ra);
  }
  if (tb > tHi) {
    const float u = (float)(tHi - ta) / span;
    *ob = tHi;
    *orb = ra + u * (rb - ra);
  }
  return *oa < *ob || (*oa == *ob && *ora != *orb);
}

// One provider's actual + dashed projection on a shared absolute-time axis.
// No budget diagonal — windows start and reset at different times.
static void drawOverallSeries(const Burndown &b, uint16_t accent,
                              int16_t x, int16_t y, int16_t w, int16_t h,
                              uint32_t tLo, uint32_t tHi) {
  if (!b.ok || b.n < 1 || tHi <= tLo) return;
  const uint32_t span = tHi - tLo;
  auto px = [&](uint32_t t) -> int16_t {
    if (t <= tLo) return x;
    if (t >= tHi) return (int16_t)(x + w - 1);
    return (int16_t)(x + (int32_t)((uint64_t)(t - tLo) * (w - 1) / span));
  };
  auto py = [&](float remaining) -> int16_t {
    float r = remaining < 0 ? 0 : (remaining > 100 ? 100 : remaining);
    return (int16_t)(y + h - 1 - (int16_t)(r * (h - 1) / 100.0f));
  };
  auto stroke = [&](int16_t ax, int16_t ay, int16_t bx, int16_t by,
                    uint16_t col) {
    for (int16_t d = -1; d <= 1; d++) {
      const int16_t a = (int16_t)(ay + d), c = (int16_t)(by + d);
      if (a < y || a > y + h - 1 || c < y || c > y + h - 1) continue;
      gfx->drawLine(ax, a, bx, c, col);
    }
  };

  const uint16_t line = b.exhausted ? COL_DIM : accent;
  for (uint8_t i = 1; i < b.n; i++) {
    uint32_t ta, tb; float ra, rb;
    if (!clipBurnSeg(b.t[i - 1], b.remaining[i - 1], b.t[i], b.remaining[i],
                     tLo, tHi, &ta, &ra, &tb, &rb)) {
      continue;
    }
    stroke(px(ta), py(ra), px(tb), py(rb), line);
  }

  if (b.projN == 2) {
    uint32_t p0t = b.projT[0], p1t = b.projT[1];
    float p0r = b.projR[0], p1r = b.projR[1];
    // Crop at held reset — same as Mac/iOS OverallBurndownChartMath.
    if (b.t1 > 0 && p1t > b.t1 && p1t > p0t) {
      const float u = (float)(b.t1 - p0t) / (float)(p1t - p0t);
      p1r = p0r + u * (p1r - p0r);
      p1t = b.t1;
    }
    if (p0r < 0) p0r = 0;
    if (p1r < 0) p1r = 0;
    const float dR = p1r - p0r;
    if (dR < -0.5f || dR > 0.5f || b.warn) {
      uint32_t ta, tb; float ra, rb;
      if (clipBurnSeg(p0t, p0r, p1t, p1r, tLo, tHi, &ta, &ra, &tb, &rb)) {
        const int16_t x0 = px(ta), y0 = py(ra);
        const int16_t x1 = px(tb), y1 = py(rb);
        // 6 on / 2 off along X — same pattern Mac/iOS use for projections.
        const int16_t steps = (int16_t)(x1 - x0);
        const int16_t stride = 8;
        const int16_t dash = 6;
        if (steps > 0 && (dR < -0.5f || dR > 0.5f)) {
          for (int16_t i = 0; i < steps; i += stride) {
            const int16_t ax = (int16_t)(x0 + i);
            const int16_t ay =
                (int16_t)(y0 + (int32_t)(y1 - y0) * i / steps);
            const int16_t seg =
                (i + dash > steps) ? (int16_t)(steps - i) : dash;
            stroke(ax, ay, (int16_t)(ax + seg),
                   (int16_t)(y0 + (int32_t)(y1 - y0) * (i + seg) / steps),
                   line);
          }
        }
        if (tb == p1t) {
          const int16_t r = (b.warn && p1r <= 0.5f) ? 3 : 2;
          gfx->fillCircle(x1, y1, r, line);
        }
      }
    }
  }

  // Accent dotted reset at t1 when it falls inside the shared domain.
  if (b.t1 > tLo && b.t1 < tHi) {
    const int16_t rx = px(b.t1);
    for (int16_t yy = (int16_t)(y + 1); yy < (int16_t)(y + h - 1); yy += 4) {
      const int16_t seg = (yy + 2 < y + h - 1) ? 2 : 1;
      gfx->drawFastVLine(rx, yy, seg, accent);
    }
  }

  // Now marker — last in-range actual point.
  for (int8_t i = (int8_t)b.n - 1; i >= 0; i--) {
    if (b.t[i] < tLo || b.t[i] > tHi) continue;
    const int16_t nx = px(b.t[i]);
    const int16_t ny = py(b.remaining[i]);
    gfx->fillCircle(nx, ny, 3, line);
    gfx->drawCircle(nx, ny, 4, COL_BG);
    break;
  }
}

// Lower half, burndown reading: one combined chart (Mac/iOS Overall burndown)
// under the three rings — shared calendar week, no budget diagonal.
static void drawGlanceBurndown(int16_t padX, int16_t span, int16_t midY,
                               int16_t lowBottom) {
  const Page pages[3] = {PAGE_CLAUDE, PAGE_CODEX, PAGE_CURSOR};
  const uint16_t accents[3] = {COL_CLAUDE, COL_OPENAI, COL_CURSOR};
  const Burndown *burns[3] = {&claudeBurn, &codexBurn, &cursorBurn};
  const int16_t slot = span / 3;

  uint32_t nowT = 0;
  uint8_t ready = 0;
  for (uint8_t i = 0; i < 3; i++) {
    if (burns[i]->ok && burns[i]->n > 0) {
      ready++;
      if (burns[i]->t[burns[i]->n - 1] > nowT) {
        nowT = burns[i]->t[burns[i]->n - 1];
      }
    }
  }

  // Day labels between chart and verdicts so curves keep the plot area.
  // Verdicts are full-width rows (not 3 cramped columns) — size-2 "Runs out
  // tomorrow 00:49" simply does not fit a third of this panel.
  const int16_t axisH = 12;
  const int16_t rowH = 16;
  const int16_t legendH = (int16_t)(3 * rowH + 2);
  const int16_t chartY = (int16_t)(midY + 6);
  const int16_t chartH =
      (int16_t)(lowBottom - legendH - axisH - chartY);
  const int16_t chartX = padX;
  const int16_t chartW = span;

  if (ready == 0 || chartH < 40) {
    drawTextAt(LABEL_COLLECTING_HISTORY, chartX + 8,
               chartY + (chartH > 0 ? chartH / 2 : 8), 2, COL_DIM);
    return;
  }

  // Fixed local calendar week: today−3 … today+4. Resets inside still paint;
  // farther ones stay off-canvas so history isn't compressed (matches
  // OverallBurndownChartMath on Mac/iOS).
  const int32_t tz = updatedTzOffsetS();
  const uint32_t localNow = (uint32_t)((int64_t)nowT + tz);
  const uint32_t localDay = localNow - (localNow % 86400u);
  const uint32_t todayUtc = (uint32_t)((int64_t)localDay - tz);
  const uint32_t tLo = todayUtc - 3u * 86400u;
  const uint32_t tHi = tLo + 7u * 86400u;

  const uint16_t track = dimToward(COL_WHITE, COL_BG, 0.35f);
  gfx->drawRect(chartX, chartY, chartW, chartH, track);

  // Horizontal 50% rule + vertical day rules (no Y labels — rings carry %).
  const uint16_t grid = dimToward(COL_WHITE, COL_BG, 0.22f);
  {
    const int16_t mid = (int16_t)(chartY + chartH / 2);
    gfx->drawFastHLine(chartX + 1, mid, chartW - 2, grid);
  }
  static const char *const WD[] = {
      "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"};
  // Unix day 0 = Thu → (days + 4) % 7 = Sun..Sat.
  const int startWd = (int)(((localDay / 86400u) + 4u) % 7u);
  const int16_t axisY = (int16_t)(chartY + chartH + 2);
  const uint32_t daySpan = (tHi > tLo) ? (tHi - tLo) : 1u;
  const uint8_t dayCount =
      (uint8_t)((daySpan + 86400u - 1u) / 86400u);
  const uint8_t daysToLabel = dayCount > 14 ? 14 : dayCount;
  for (uint8_t d = 0; d < daysToLabel; d++) {
    const uint32_t dayT = tLo + (uint32_t)d * 86400u;
    if (dayT > tHi) break;
    const int16_t dx =
        (int16_t)(chartX +
                  (int32_t)((uint64_t)(dayT - tLo) * (chartW - 1) / (tHi - tLo)));
    if (d > 0) {
      gfx->drawFastVLine(dx, (int16_t)(chartY + 1), (int16_t)(chartH - 2), grid);
    }
    const int wd = (startWd - 3 + (int)d + 70) % 7;
    drawTextAt(WD[wd], (int16_t)(dx + 2), axisY, 1, COL_DIM);
  }

  // "Now" marker — darker than day rules so it isn't mistaken for one.
  if (nowT > tLo && nowT < tHi) {
    const uint16_t nowCol = dimToward(COL_WHITE, COL_BG, 0.45f);
    const int16_t nx =
        (int16_t)(chartX +
                  (int32_t)((uint64_t)(nowT - tLo) * (chartW - 1) / (tHi - tLo)));
    gfx->drawFastVLine(nx, (int16_t)(chartY + 1), (int16_t)(chartH - 2),
                       nowCol);
  }

  for (uint8_t i = 0; i < 3; i++) {
    drawOverallSeries(*burns[i], accents[i], chartX, chartY, chartW, chartH,
                      tLo, tHi);
  }

  // Chart thirds → provider detail (same left→right order as the rings).
  const int16_t chartHitH = (int16_t)(chartY + chartH + axisH - midY);
  for (uint8_t i = 0; i < 3; i++) {
    glanceAddHit((int16_t)(padX + (int16_t)i * slot), midY, slot, chartHitH,
                 pages[i]);
  }

  // Legend: ring order, top → bottom. Full width so host verdicts stay intact.
  const int16_t legY = (int16_t)(lowBottom - legendH + 1);
  const int16_t dotR = 3;
  const int16_t textX = (int16_t)(padX + dotR * 2 + 8);
  const int16_t textW = (int16_t)(span - (textX - padX));
  for (uint8_t i = 0; i < 3; i++) {
    const int16_t y = (int16_t)(legY + (int16_t)i * rowH);
    glanceAddHit(padX, y, span, rowH, pages[i]);
    const Burndown &b = *burns[i];
    const uint16_t dot =
        b.ok ? (b.exhausted ? COL_DIM : accents[i]) : COL_DIM;
    gfx->fillCircle((int16_t)(padX + dotR), (int16_t)(y + 6), dotR, dot);
    if (b.ok && b.verdict.length()) {
      drawTextAt(truncFit(b.verdict, textW, 2), textX, y, 2, COL_DIM);
    } else if (b.ok && b.n > 0) {
      char left[8];
      snprintf(left, sizeof left, "%d%%",
               (int)(b.remaining[b.n - 1] + 0.5f));
      drawTextAt(left, textX, y, 2, accents[i]);
    } else {
      drawTextAt("-", textX, y, 2, COL_DIM);
    }
  }
}

static void drawGlancePage() {
  gfx->clear(COL_BG);
  glanceClearHits();
  const int16_t W = scrW();
  const int16_t H = scrH();
  const int16_t padX = UI_PAD;
  const int16_t top = UI_PAD;
  const int16_t bot = UI_PAD;

  drawTextAt("Headroom", padX, top, 3, COL_WHITE);
  // The chip names what the lower half is showing; the whole header band above
  // the rings switches it. A fingertip is ~40px on this panel, so the target is
  // the band, not the word — the outline is only there to say it's a control.
  const char *modeName = homeModeName(homeMode);
  const int16_t chipX = padX + 152;
  const int16_t chipW = (int16_t)(textWidth(modeName, 2) + 16);
  gfx->drawRoundRect(chipX - 8, top + 2, chipW, 24, 6, COL_DIM);
  drawTextAt(modeName, chipX, top + 6, 2, COL_DIM);
  glanceAddModeHit(0, 0, W, (int16_t)(top + 34));

  char when[8];
  if (updatedHHMM(when, sizeof when)) {
    drawRightAt(when, W - padX, top + 6, 2, COL_DIM);
  }

  // 3 equal top slots (quota rings).
  const int16_t span = W - padX * 2;
  const int16_t slot = span / 3;
  const int16_t ringR = 32;
  const int16_t ringCy = top + 74;
  const int16_t midY = ringCy + ringR + 48;  // clear labels under rings
  const int16_t lowBottom = H - bot;         // no footer — run to the margin

  const Page topPages[3] = {PAGE_CLAUDE, PAGE_CODEX, PAGE_CURSOR};
  const uint16_t topAccent[3] = {COL_CLAUDE, COL_OPENAI, COL_CURSOR};
  const char *topLabel[3] = {"Claude", "Codex", "Cursor"};

  const ProviderQuota *qs[3] = {&claudeQ, &codexQ, &cursorQ};
  for (uint8_t i = 0; i < 3; i++) {
    int16_t colX = padX + (int16_t)i * slot;
    glanceAddHit(colX, top + 36, slot, (int16_t)(midY - (top + 36)), topPages[i]);
    drawQuotaRing(colX + slot / 2, ringCy, ringR, *qs[i], topAccent[i],
                  topLabel[i]);
  }

  gfx->drawFastHLine(padX, midY, span, COL_DIM);

  if (homeMode == HOME_BURNDOWN) drawGlanceBurndown(padX, span, midY, lowBottom);
  else drawGlanceActivity(padX, span, midY, lowBottom);

  drawWifiDot(padX, top);
  present();
}

static const Burndown &burnFor(Page p) {
  if (p == PAGE_CODEX) return codexBurn;
  if (p == PAGE_CURSOR) return cursorBurn;
  return claudeBurn;
}

static void drawQuotaPage() {
  gfx->clear(COL_BG);
  const int16_t W = scrW();
  const int16_t H = scrH();
  const int16_t padX = UI_PAD;
  const int16_t top = UI_PAD;
  const int16_t bot = UI_PAD;

  const bool isCodex = (page == PAGE_CODEX);
  const bool isCursor = (page == PAGE_CURSOR);
  const ProviderQuota &q = isCodex ? codexQ : (isCursor ? cursorQ : claudeQ);
  const uint16_t accent = isCodex ? COL_OPENAI
                         : (isCursor ? COL_CURSOR : COL_CLAUDE);
  const char *brand = isCodex ? "Codex" : (isCursor ? "Cursor" : "Claude");

  // Header — brand in provider color + plan
  drawTextAt(brand, padX, top, 3, accent);
  if (q.plan.length()) {
    drawRightAt(q.plan.c_str(), W - padX, top + 6, 2, COL_DIM);
  }
  char when[8], updatedLine[20];
  snprintf(updatedLine, sizeof updatedLine, "Updated %s",
           updatedHHMM(when, sizeof when) ? when : "--");
  drawTextAt(updatedLine, padX, top + 32, 2, COL_DIM);
  gfx->drawFastHLine(padX, top + 56, W - padX * 2, COL_DIM);

  // Content below the header rule splits evenly: meters on top, burndown below.
  // Glance rings already carry pct/pace, so the detail page's job is readable
  // full-width bars plus a chart large enough to read at desk distance.
  const int16_t contentTop = top + 72;
  const int16_t contentBot = (int16_t)(H - bot - 10 - 12);  // above footer rule
  const int16_t midY =
      (int16_t)(contentTop + (contentBot - contentTop) / 2);

  if (q.ok && (q.totalPct >= 0 || q.sessionPct >= 0 || q.weekPct >= 0)) {
    int16_t rowY = contentTop;
    if (isCursor) {
      // Total + API stacked full-width. Auto is omitted (empty on most plans).
      // They share a reset window — label it once on the first meter.
      if (q.totalPct >= 0) {
        drawQuotaRowCompact("Total", q.totalPct, q.totalPace,
                            q.sessionResets, rowY, padX, accent);
        rowY += QUOTA_ROW_H;
      }
      if (q.weekPct >= 0) {
        drawQuotaRowCompact("API", q.weekPct, q.weekPace,
                            q.totalPct >= 0 ? String() : q.weekResets,
                            rowY, padX, accent);
        rowY += QUOTA_ROW_H;
      }
    } else {
      // Team Codex often has only a weekly window — skip empty session.
      if (q.sessionPct >= 0) {
        drawQuotaRowCompact("Session", q.sessionPct, q.sessionPace,
                            q.sessionResets, rowY, padX, accent);
        rowY += QUOTA_ROW_H;
      }
      if (q.weekPct >= 0) {
        drawQuotaRowCompact("Weekly", q.weekPct, q.weekPace, q.weekResets,
                            rowY, padX, accent);
        rowY += QUOTA_ROW_H;
      }
    }

    // Codex reset credits: one line in leftover top-half space, never the chart.
    if (isCodex && q.resetCredits >= 0 && rowY + 20 <= midY) {
      char cred[40];
      snprintf(cred, sizeof cred, "%d reset credits", q.resetCredits);
      drawTextAt(cred, padX, rowY, 2, COL_DIM);
      if (q.resetCreditExpiries.length()) {
        drawRightAt(q.resetCreditExpiries.c_str(), W - padX, rowY, 2, COL_DIM);
      }
    }

    // Bottom half: burndown for the provider's longest window.
    const Burndown &burn = burnFor(page);
    int16_t burnY = midY;
    drawTextAt(LABEL_BURNDOWN, padX, burnY, 2, COL_WHITE);
    // The host's verdict, in the host's words. Falls back to the locally
    // assembled tags only when talking to a server too old to send one.
    if (burn.verdict.length()) {
      // Neutral always — the words carry the warning; colour would shout.
      const uint16_t tint = burn.exhausted ? COL_DIM : COL_WHITE;
      // Host copy can grow, and running under the Burndown label is worse
      // than a smaller face, so measure before committing to size 2.
      const int16_t room =
          (int16_t)(W - padX * 2 - textWidth(LABEL_BURNDOWN, 2) - 12);
      const bool full = textWidth(burn.verdict.c_str(), 2) <= room;
      drawRightAt(burn.verdict.c_str(), W - padX,
                  full ? burnY : (int16_t)(burnY + 4), full ? 2 : 1, tint);
    } else if (burn.warn || burn.warn2) {
      drawRightAt("runs out early", W - padX, burnY, 2, COL_DIM);
    } else if (burn.estimated) {
      drawRightAt("estimated", W - padX, burnY, 2, COL_DIM);
    }
    burnY += 22;
    const int16_t chartH = (int16_t)(contentBot - burnY);
    if (chartH >= 36) {
      drawBurndown(burn, padX, burnY, (int16_t)(W - padX * 2), chartH, accent);
    }
  } else if (isCursor) {
    drawTextAt("cursor quota unavailable", padX, top + 100, 2, COL_DIM);
  } else if (isCodex) {
    drawTextAt("codex quota unavailable", padX, top + 100, 2, COL_DIM);
  } else {
    drawTextAt("claude quota unavailable", padX, top + 100, 2, COL_DIM);
  }

  // Bottom bar: page dots. No Today $/model footer.
  const int16_t footY = H - bot - 10;
  gfx->drawFastHLine(padX, footY - 12, W - padX * 2, COL_DIM);

  drawWifiDot(padX, top);
  present();
}

static void drawVercelPage() {
  gfx->clear(COL_BG);
  const int16_t W = scrW();
  const int16_t H = scrH();
  const int16_t padX = UI_PAD;
  const int16_t top = UI_PAD;
  const int16_t bot = UI_PAD;

  drawTextAt("Vercel", padX, top, 3, COL_VERCEL);
  if (vercelTeam.length()) {
    drawRightAt(vercelTeam.c_str(), W - padX, top + 6, 2, COL_DIM);
  }
  char when[8], updatedLine[20];
  snprintf(updatedLine, sizeof updatedLine, "Updated %s",
           updatedHHMM(when, sizeof when) ? when : "--");
  drawTextAt(updatedLine, padX, top + 32, 2, COL_DIM);
  gfx->drawFastHLine(padX, top + 56, W - padX * 2, COL_DIM);

  int16_t rowY = top + 70;
  if (vercelOk && vercelN > 0) {
    for (uint8_t i = 0; i < vercelN; i++) {
      const DeployRow &r = vercelRows[i];
      uint16_t sc = statusColor(r.status);
      // Status pill (small filled circle)
      gfx->fillCircle(padX + 4, rowY + 8, 5, sc);

      String proj = truncFit(r.project, W - padX * 2 - 90, 2);
      drawTextAt(proj, padX + 18, rowY, 2, COL_WHITE);

      String right = r.ago.length() ? r.ago : "--";
      drawRightAt(right.c_str(), W - padX, rowY, 2, COL_DIM);

      String sub = r.status;
      if (r.target.length()) sub += " - " + r.target;
      else if (r.branch.length()) sub += " - " + r.branch;
      drawTextAt(truncFit(sub, W - padX * 2 - 20, 2),
                 padX + 18, rowY + 20, 2, COL_DIM);

      rowY += 46;
      if (rowY > H - bot - 40) break;
    }
  } else {
    drawTextAt(vercelOk ? "no deployments" : "vercel unavailable",
               padX, top + 100, 2, COL_DIM);
  }

  const int16_t footY = H - bot - 10;
  gfx->drawFastHLine(padX, footY - 12, W - padX * 2, COL_DIM);
  drawTextAt(String((int)vercelN) + " recent", padX, footY, 2, COL_DIM);
  drawWifiDot(padX, top);
  present();
}

static void drawGitPage() {
  gfx->clear(COL_BG);
  const int16_t W = scrW();
  const int16_t H = scrH();
  const int16_t padX = UI_PAD;
  const int16_t top = UI_PAD;
  const int16_t bot = UI_PAD;

  drawTextAt("Git", padX, top, 3, COL_GIT);
  char when[8], updatedLine[20];
  snprintf(updatedLine, sizeof updatedLine, "Updated %s",
           updatedHHMM(when, sizeof when) ? when : "--");
  drawTextAt(updatedLine, padX, top + 32, 2, COL_DIM);
  gfx->drawFastHLine(padX, top + 56, W - padX * 2, COL_DIM);

  int16_t rowY = top + 70;
  if (gitOk && gitN > 0) {
    for (uint8_t i = 0; i < gitN; i++) {
      const CommitRow &r = gitRows[i];
      drawTextAt(truncFit(r.repo, W - padX * 2 - 80, 2), padX, rowY, 2, COL_DIM);

      String right = r.ago.length() ? r.ago : "--";
      drawRightAt(right.c_str(), W - padX, rowY, 2, COL_DIM);

      drawTextAt(truncFit(r.subject, W - padX * 2, 2),
                 padX, rowY + 21, 2, COL_WHITE);

      rowY += 47;
      if (rowY > H - bot - 40) break;
    }
  } else {
    drawTextAt(gitOk ? "no commits" : "git unavailable",
               padX, top + 100, 2, COL_DIM);
  }

  const int16_t footY = H - bot - 10;
  gfx->drawFastHLine(padX, footY - 12, W - padX * 2, COL_DIM);
  drawTextAt(String((int)gitN) + " recent", padX, footY, 2, COL_DIM);
  drawWifiDot(padX, top);
  present();
}

static void drawLocalPage() {
  gfx->clear(COL_BG);
  const int16_t W = scrW();
  const int16_t H = scrH();
  const int16_t padX = UI_PAD;
  const int16_t top = UI_PAD;
  const int16_t bot = UI_PAD;

  drawTextAt("Local", padX, top, 3, COL_LOCAL);
  if (localHost.length()) {
    drawRightAt(localHost.c_str(), W - padX, top + 6, 2, COL_DIM);
  }
  char when[8], updatedLine[20];
  snprintf(updatedLine, sizeof updatedLine, "Updated %s",
           updatedHHMM(when, sizeof when) ? when : "--");
  drawTextAt(updatedLine, padX, top + 32, 2, COL_DIM);
  gfx->drawFastHLine(padX, top + 56, W - padX * 2, COL_DIM);

  int16_t rowY = top + 70;
  if (localOk && localN > 0) {
    for (uint8_t i = 0; i < localN; i++) {
      const ServerRow &r = localRows[i];
      gfx->fillCircle(padX + 4, rowY + 8, 5, COL_GREEN);

      String left = truncFit(r.name, W - padX * 2 - 90, 2);
      drawTextAt(left, padX + 18, rowY, 2, COL_WHITE);

      String right = r.port > 0 ? (":" + String(r.port)) : "--";
      drawRightAt(right.c_str(), W - padX, rowY, 2, COL_DIM);

      String sub = r.cmd.length() ? r.cmd : "listening";
      drawTextAt(truncFit(sub, W - padX * 2 - 20, 2),
                 padX + 18, rowY + 20, 2, COL_DIM);

      rowY += 46;
      if (rowY > H - bot - 40) break;
    }
  } else {
    drawTextAt(localOk ? "no servers" : "local unavailable",
               padX, top + 100, 2, COL_DIM);
  }

  const int16_t footY = H - bot - 10;
  gfx->drawFastHLine(padX, footY - 12, W - padX * 2, COL_DIM);
  drawTextAt(String((int)localN) + " up", padX, footY, 2, COL_DIM);
  drawWifiDot(padX, top);
  present();
}

static void drawDashboard() {
  if (page != PAGE_GLANCE) glanceClearHits();
  if (page == PAGE_GLANCE) drawGlancePage();
  else if (page == PAGE_VERCEL) drawVercelPage();
  else if (page == PAGE_GIT) drawGitPage();
  else if (page == PAGE_LOCAL) drawLocalPage();
  else drawQuotaPage();
}

// ---------------- Touch (FT3168 / CST816) ----------------
// Waveshare brings the controller out of reset via TCA9554 P1, then the chip
// still needs an explicit power-mode write before finger events appear.
// Official demo also watches TP_INT (GPIO 21, active-low).
//
// Gestures: tap slot on Headroom → detail; tap on detail → home;
// long-press → home; BOOT → next page (cycles through all, then home).
static uint8_t touchAddr = 0;          // 0 = absent
static volatile bool touchIrq = false;
static bool touchDown = false;
static bool touchIgnore = false;
static bool touchCommitted = false;
static bool touchLongFired = false;
static bool touchHaveXY = false;   // true once this press has valid coords
static uint32_t touchDownMs = 0;
static uint32_t lastGestureMs = 0;
static int16_t touchStartX = 0, touchStartY = 0;
static int16_t touchLastX = 0, touchLastY = 0;
static const int16_t TAP_MAX_PX = 28;
static const uint32_t GESTURE_DEBOUNCE_MS = 40;
static const uint32_t LONG_PRESS_MS = 400;

enum Gesture : uint8_t {
  GESTURE_NONE = 0,
  GESTURE_TAP,
  GESTURE_HOME
};

// Set when GESTURE_TAP should open a glance slot (coords = touchStart*).
static bool gestureTapHit = false;

static void IRAM_ATTR onTouchIrq() { touchIrq = true; }

static bool touchWrite8(uint8_t addr, uint8_t reg, uint8_t val) {
  Wire.beginTransmission(addr);
  Wire.write(reg);
  Wire.write(val);
  return Wire.endTransmission() == 0;
}

static bool touchRead8(uint8_t addr, uint8_t reg, uint8_t *out) {
  Wire.beginTransmission(addr);
  Wire.write(reg);
  if (Wire.endTransmission(false) != 0) return false;
  if (Wire.requestFrom((int)addr, 1) != 1) return false;
  *out = Wire.read();
  return true;
}

static bool touchReadXY(int16_t *x, int16_t *y) {
  if (!touchAddr) return false;
  uint8_t n = 0;
  if (!touchRead8(touchAddr, 0x02, &n) || (n & 0x0F) == 0) return false;

  Wire.beginTransmission(touchAddr);
  Wire.write(0x03);
  if (Wire.endTransmission(false) != 0) return false;
  if (Wire.requestFrom((int)touchAddr, 4) != 4) return false;
  uint8_t b0 = Wire.read();
  uint8_t b1 = Wire.read();
  uint8_t b2 = Wire.read();
  uint8_t b3 = Wire.read();
  *x = (int16_t)(((uint16_t)(b0 & 0x0F) << 8) | b1);
  *y = (int16_t)(((uint16_t)(b2 & 0x0F) << 8) | b3);
  return true;
}

static bool touchInit() {
  pinMode(TP_INT, INPUT_PULLUP);

  // Prefer FT3168 @ 0x38 (product docs); fall back to CST816 @ 0x15 (V2 demos).
  if (i2cPresent(FT3168_ADDR)) {
    touchAddr = FT3168_ADDR;
    // Active mode (reg 0x00 = normal). Do NOT put the chip in monitor
    // (0xA5=0x01) — monitor reports no coordinates while held.
    touchWrite8(touchAddr, 0x00, 0x00);
    touchWrite8(touchAddr, 0xA5, 0x00);
    delay(20);
  } else if (i2cPresent(CST816_ADDR)) {
    touchAddr = CST816_ADDR;
    // Interrupt mode: periodic reports while touched (Waveshare demo).
    touchWrite8(touchAddr, 0xFA, 0x40);
    delay(20);
  } else {
    Serial.println("touch: no FT3168@0x38 or CST816@0x15 — gestures disabled");
    return false;
  }

  uint8_t id = 0xFF;
  // FT: ID @ 0xA0 (0x03 = FT3168). CST: ID @ 0xA7.
  touchRead8(touchAddr, touchAddr == FT3168_ADDR ? 0xA0 : 0xA7, &id);
  attachInterrupt(digitalPinToInterrupt(TP_INT), onTouchIrq, FALLING);
  Serial.printf("touch @ 0x%02X id=0x%02X irq=GPIO%d\n", touchAddr, id, TP_INT);
  return true;
}

static bool touchPressed() {
  if (!touchAddr) return false;
  uint8_t n = 0;
  if (!touchRead8(touchAddr, 0x02, &n)) return false;
  return (n & 0x0F) > 0;
}

// Logical deltas under canvas rotation 3 (X ↔ inverted native Y).
static void touchLogicalDelta(int16_t *dHoriz, int16_t *dVert) {
  const int16_t dNatX = (int16_t)(touchLastX - touchStartX);
  const int16_t dNatY = (int16_t)(touchLastY - touchStartY);
  *dHoriz = (int16_t)(-dNatY);
  *dVert = dNatX;
}

// Fire navigation on press (like BOOT), not on release — release felt laggy.
// FT3168 often asserts "down" one poll before XY is readable. We must keep
// trying until coords arrive; a one-shot edge check drops most taps when
// serviceUi() samples aggressively during USB waits.
static Gesture consumeGesture() {
  if (!touchAddr) return GESTURE_NONE;

  if (touchIrq) touchIrq = false;

  const bool down = touchPressed();
  const uint32_t now = millis();
  int16_t x = 0, y = 0;
  const bool haveXY = down && touchReadXY(&x, &y);

  if (down) {
    if (!touchDown) {
      touchDown = true;
      touchCommitted = false;
      touchLongFired = false;
      touchHaveXY = false;
      gestureTapHit = false;
      touchDownMs = now;
      touchStartX = touchStartY = touchLastX = touchLastY = 0;
      if ((now - lastGestureMs) < GESTURE_DEBOUNCE_MS) {
        touchIgnore = true;
        return GESTURE_NONE;
      }
      touchIgnore = false;
    }
    if (touchIgnore || touchCommitted) return GESTURE_NONE;

    if (haveXY) {
      if (!touchHaveXY) {
        touchHaveXY = true;
        touchStartX = touchLastX = x;
        touchStartY = touchLastY = y;
      } else {
        touchLastX = x;
        touchLastY = y;
      }
    }

    // Detail page: any press with or without XY goes home immediately.
    if (page != PAGE_GLANCE) {
      touchCommitted = true;
      lastGestureMs = now;
      return GESTURE_HOME;
    }

    // Glance: wait for XY, then open the slot under the finger.
    if (touchHaveXY) {
      GlanceHit hit;
      if (glanceHitAt(touchStartX, touchStartY, &hit)) {
        touchCommitted = true;
        lastGestureMs = now;
        gestureTapHit = true;
        return GESTURE_TAP;
      }
      // Missed slots — allow long-press sync on empty chrome.
      int16_t dHoriz = 0, dVert = 0;
      touchLogicalDelta(&dHoriz, &dVert);
      if (!touchLongFired &&
          abs(dHoriz) <= TAP_MAX_PX && abs(dVert) <= TAP_MAX_PX &&
          (now - touchDownMs) >= LONG_PRESS_MS) {
        touchLongFired = true;
        touchCommitted = true;
        lastGestureMs = now;
        return GESTURE_HOME;
      }
    }
    return GESTURE_NONE;
  }

  if (!touchDown) return GESTURE_NONE;
  touchDown = false;
  touchIgnore = false;
  touchCommitted = false;
  touchLongFired = false;
  touchHaveXY = false;
  gestureTapHit = false;
  return GESTURE_NONE;
}

// ---------------- Arduino ----------------
static uint32_t lastPoll = 0;

// Consecutive failed fetches, for backoff. A host that is off (Mac asleep,
// laptop elsewhere) shouldn't be hammered every POLL_INTERVAL_S forever —
// each attempt costs a blocking connect timeout the UI has to sit through.
static uint8_t fetchFails = 0;
static const uint8_t FETCH_BACKOFF_MAX = 8;   // POLL_INTERVAL_S * 8 ceiling

static uint32_t pollIntervalMs() {
  uint32_t mult = fetchFails < FETCH_BACKOFF_MAX ? fetchFails : FETCH_BACKOFF_MAX;
  if (mult == 0) mult = 1;
  return (uint32_t)POLL_INTERVAL_S * 1000u * mult;
}

static void goToPage(Page target, const char *why) {
  if (target == page) return;
  page = target;
  Serial.printf("%s → page %s\n", why, pageName(page));
  if (haveData) drawDashboard();
  else drawStatus("fetching...", COL_DIM);
}

static void goHome() {
  if (page == PAGE_GLANCE) return;
  goToPage(PAGE_GLANCE, "home");
}

static void toggleHomeMode() {
  homeMode = homeMode == HOME_ACTIVITY ? HOME_BURNDOWN : HOME_ACTIVITY;
  homeModeSave();
  Serial.printf("tap → home mode %s\n", homeModeName(homeMode));
  if (haveData) drawDashboard();
  else drawStatus("fetching...", COL_DIM);
}

static bool pageEnabled(Page p) {
  switch (p) {
    case PAGE_GLANCE: return true;
    case PAGE_CLAUDE: return sourceEnabled("claude");
    case PAGE_CODEX:  return sourceEnabled("codex");
    case PAGE_CURSOR: return sourceEnabled("cursor");
    case PAGE_VERCEL: return sourceEnabled("vercel");
    case PAGE_GIT:    return sourceEnabled("git");
    case PAGE_LOCAL:  return sourceEnabled("local");
    default: return true;
  }
}

// BOOT cycles Headroom → enabled sources only → Headroom.
static void goNextPage() {
  Page next = page;
  for (uint8_t i = 0; i < (uint8_t)PAGE_COUNT; i++) {
    next = (Page)(((int)next + 1) % (int)PAGE_COUNT);
    if (pageEnabled(next)) {
      goToPage(next, "boot");
      return;
    }
  }
}

static void forceSyncFromDesk() {
  drawStatus("syncing…", COL_AMBER);
  // An explicit long-press means the user wants a retry now — clear any
  // backoff the poller built up while the host was away.
  fetchFails = 0;
  bool ok = requestSyncRefresh();
  delay(150);
  yield();
  esp_task_wdt_reset();
  if (fetchUsage(USB_TIMEOUT_SYNC_MS)) drawDashboard();
  else drawStatus(ok ? "synced" : "sync failed", ok ? COL_GREEN : COL_RED);
}

// ---------------- OTA ----------------
// The board lives on a shelf; without this every firmware tweak means finding
// the cable. Only starts once Wi-Fi is up.
static bool otaUp = false;

static void otaBegin() {
  if (otaUp || WiFi.status() != WL_CONNECTED) return;
  ArduinoOTA.setHostname(OTA_HOSTNAME);
  if (sizeof(OTA_PASSWORD) > 1) ArduinoOTA.setPassword(OTA_PASSWORD);
  ArduinoOTA.onStart([]() {
    // The flash write starves everything else; the watchdog would fire.
    esp_task_wdt_delete(NULL);
    drawStatus("OTA update…", COL_AMBER);
  });
  ArduinoOTA.onProgress([](unsigned int done, unsigned int total) {
    static uint8_t lastPct = 255;
    uint8_t pct = total ? (uint8_t)((done * 100) / total) : 0;
    if (pct == lastPct) return;
    lastPct = pct;
    char line[24];
    snprintf(line, sizeof line, "OTA %u%%", (unsigned)pct);
    drawStatus(line, COL_CRT);
  });
  ArduinoOTA.onEnd([]() { drawStatus("OTA done — rebooting", COL_GREEN); });
  ArduinoOTA.onError([](ota_error_t) {
    drawStatus("OTA failed", COL_RED);
    esp_task_wdt_add(NULL);
  });
  ArduinoOTA.begin();
  otaUp = true;
  Serial.printf("OTA ready at %s.local\n", OTA_HOSTNAME);
}

static void pollBootButton() {
  static bool wasDown = false;
  static uint32_t lastChange = 0;
  bool down = digitalRead(BTN_BOOT) == LOW;
  uint32_t now = millis();
  if (down == wasDown) return;
  if (now - lastChange < 40) return;
  lastChange = now;
  wasDown = down;
  if (down) {
    Serial.println("boot btn");
    goNextPage();
  }
}

static void handleInput() {
  pollBootButton();
  Gesture g = consumeGesture();
  if (g == GESTURE_TAP) {
    if (page == PAGE_GLANCE) {
      GlanceHit hit;
      if (gestureTapHit && glanceHitAt(touchStartX, touchStartY, &hit)) {
        if (hit.kind == HIT_MODE) {
          toggleHomeMode();
        } else if (!pageEnabled(hit.target)) {
          drawStatus("disabled in Sources", COL_AMBER);
          delay(200);
          drawDashboard();
        } else {
          flashGlanceSlot(hit);
          goToPage(hit.target, "tap");
        }
      }
    } else {
      goHome();
    }
  } else if (g == GESTURE_HOME) {
    if (page == PAGE_GLANCE) forceSyncFromDesk();
    else goHome();
  }
}

void setup() {
  // /usage over CDC is ~30KB; the default 256-byte RX buffer drops it.
  Serial.setRxBufferSize(USB_RX_BUF);
  Serial.begin(115200);
  // Never block the UI forever when the Mac isn't draining CDC TX.
  Serial.setTxTimeoutMs(0);
  delay(1500);   // let native USB-CDC re-enumerate so the boot log isn't lost
  Serial.printf("headroom firmware %s\n", fwVersion().c_str());
  Serial.println("\n=== headroom booting ===");

  powerInit();
  pinMode(BTN_BOOT, INPUT_PULLUP);
  bool touchOk = touchInit();
  homeModeLoad();   // before the first home paint

  bool pok = panel->begin();
  Serial.printf("panel->begin: %s\n", pok ? "ok" : "FAIL");
  sh8601VendorInit();
  Serial.println("sh8601VendorInit sent");
  panel->setBrightness(200);
  // Wipe panel GRAM before the canvas takes over (kills power-on green fringe).
  panel->fillScreen(COL_BG);

  // Panel already started — skip nested begin inside the canvas.
  bool cok = gfx->begin(GFX_SKIP_OUTPUT_BEGIN);
  Serial.printf("canvas->begin (landscape %dx%d): %s  psram=%d\n",
                scrW(), scrH(), cok ? "ok" : "FAIL", (int)psramFound());

  bootSplash();
  bootLine("CPU", "ESP32-S3", COL_CRT);
  {
    char mem[16];
    snprintf(mem, sizeof mem, "%uKB", (unsigned)(ESP.getFreeHeap() / 1024));
    bootLine("HEAP", mem, COL_CRT);
  }
  bootLine("PSRAM", psramFound() ? "OK" : "FAIL",
           psramFound() ? COL_CRT : COL_RED);
  {
    char disp[20];
    snprintf(disp, sizeof disp, "%dx%d", (int)scrW(), (int)scrH());
    bootLine("DISPLAY", disp, pok && cok ? COL_CRT : COL_RED);
  }
  bootLine("PANEL", pok && cok ? "OK" : "FAIL",
           pok && cok ? COL_CRT : COL_RED);
  bootLine("TOUCH", touchOk ? "OK" : "FAIL",
           touchOk ? COL_CRT : COL_RED);

  {
    const size_t nAp = sizeof(WIFI_NETWORKS) / sizeof(WIFI_NETWORKS[0]);
    char aps[16];
    snprintf(aps, sizeof aps, "%u AP", (unsigned)nAp);
    bootLine("RADIO", aps, COL_CRT);
  }

  // Kick STA + known APs; associate in loop(). Desk USB can finish boot now.
  connectWifi();

  {
    int16_t hostY = bootY;
    bootProgress("LINK", 0);
    bool ok = fetchUsageUsb(USB_TIMEOUT_SYNC_MS);
    bootY = hostY;

    if (ok) {
      // Cable answered — skip the Wi-Fi wait; mDNS/OTA come up in loop().
      Serial.println("usage via USB (boot) — Wi-Fi continues in background");
      bootLine("WIFI", "PENDING", COL_CRT_DIM);
      bootLine("HOST", "USB", COL_CRT_DIM);
      bootLine("LINK", "USB", COL_CRT);
      bootLine("USAGE", "OK", COL_CRT);
      bootLine("READY", "GO", COL_CRT);
      delay(320);
      drawDashboard();
    } else {
      // No host on CDC — wait for Wi-Fi, then HTTP (USB still a fallback).
      uint32_t t0 = millis();
      uint32_t lastDots = 0;
      uint8_t spin = 0;
      bootProgress("WIFI", spin++);
      while (wifiMulti.run() != WL_CONNECTED && millis() - t0 < 20000) {
        if (millis() - lastDots >= 1000) {
          bootProgress("WIFI", spin++);
          lastDots = millis();
        }
        delay(50);
      }

      if (WiFi.status() == WL_CONNECTED) {
        String ssid = WiFi.SSID();
        bootLine("WIFI", ssid.length() ? ssid.c_str() : "OK", COL_CRT);
        bootLine("IP", WiFi.localIP().toString().c_str(), COL_CRT);
        {
          char rssi[12];
          snprintf(rssi, sizeof rssi, "%d dBm", WiFi.RSSI());
          bootLine("RSSI", rssi, COL_CRT);
        }
        mdnsUp = MDNS.begin(OTA_HOSTNAME);   // needed for MDNS.queryHost()
        bootLine("MDNS", mdnsUp ? OTA_HOSTNAME : "FAIL",
                 mdnsUp ? COL_CRT : COL_RED);
        otaBegin();
        bootLine("OTA", otaUp ? OTA_HOSTNAME : "OFF",
                 otaUp ? COL_CRT : COL_CRT_DIM);
        Serial.printf("wifi ok  ip=%s  ssid=%s  mdns=%d\n",
                      WiFi.localIP().toString().c_str(),
                      WiFi.SSID().c_str(), mdnsUp);
        bootLine("HOST", HOST_NAME, COL_CRT_DIM);
      } else {
        bootLine("WIFI", "FAIL", COL_RED);
        Serial.println("wifi FAILED (no known network in range?) — trying USB");
        bootLine("HOST", "USB", COL_CRT_DIM);
      }

      hostY = bootY;
      bootProgress("LINK", 0);
      ok = fetchUsage(USB_TIMEOUT_SYNC_MS);
      bootY = hostY;
      const char *linkLabel = ok
          ? (resolvedHost.length() ? resolvedHost.c_str() : "USB")
          : "FAIL";
      bootLine("LINK", linkLabel, ok ? COL_CRT : COL_RED);

      if (ok) {
        Serial.printf("host=%s  fetch ok  claude=%d codex=%d cursor=%d vercel=%d git=%d local=%d\n",
                      resolvedHost.length() ? resolvedHost.c_str() : "usb",
                      (int)claudeQ.ok, (int)codexQ.ok,
                      (int)cursorQ.ok, (int)vercelOk, (int)gitOk, (int)localOk);
        bootLine("USAGE", "OK", COL_CRT);
        bootLine("READY", "GO", COL_CRT);
        delay(320);
        drawDashboard();
      } else {
        Serial.println("fetch FAILED (server/host unreachable)");
        bootLine("USAGE", "FAIL", COL_RED);
        bootLine("READY", "FAIL", COL_RED);
        delay(400);
        drawStatus("server unreachable", COL_RED);
      }
    }
  }
  lastPoll = millis();

  // Last: a wedged I2C bus or HTTP stack should reboot us, not leave a frozen
  // panel on the desk. Registered after setup so a slow first associate can't
  // trip it.
  esp_task_wdt_config_t wdt = {
      .timeout_ms = WDT_TIMEOUT_S * 1000,
      .idle_core_mask = 0,
      .trigger_panic = true,
  };
  esp_task_wdt_reconfigure(&wdt);
  esp_task_wdt_add(NULL);
}

void loop() {
  esp_task_wdt_reset();

  // Input first, every pass — never starve BOOT/touch behind Wi-Fi or USB.
  handleInput();

  if (otaUp) ArduinoOTA.handle();

  // WiFiMulti.run() blocks for seconds while hunting APs. Call it rarely when
  // disconnected; when associated just poke it occasionally. lastWifi==0 means
  // try on the first loop pass (USB-fast boot left associate pending).
  static uint32_t lastWifi = 0;
  const uint32_t wifiEvery =
      (WiFi.status() == WL_CONNECTED) ? 10000u : 20000u;
  if (lastWifi == 0 || millis() - lastWifi >= wifiEvery) {
    lastWifi = millis();
    uint8_t st = wifiMulti.run();
    if (st == WL_CONNECTED) {
      if (!mdnsUp) mdnsUp = MDNS.begin(OTA_HOSTNAME);
      otaBegin();
    }
  }

  // Background poll — skip while finger is down.
  if (!touchDown && millis() - lastPoll >= pollIntervalMs()) {
    lastPoll = millis();
    if (fetchUsage()) {
      fetchFails = 0;
      drawDashboard();
    } else {
      if (fetchFails < FETCH_BACKOFF_MAX) fetchFails++;
      if (!haveData) drawStatus("server unreachable", COL_RED);
    }
  }
  delay(4);
}
