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
#include <Wire.h>
#include <WiFi.h>
#include <WiFiMulti.h>
#include <ESPmDNS.h>
#include <HTTPClient.h>
#include <ArduinoJson.h>
#include <esp_heap_caps.h>
#include <Arduino_GFX_Library.h>
#define XPOWERS_CHIP_AXP2101
#include <XPowersLib.h>

#include "pin_config.h"
#include "config.h"   // copy config_example.h -> config.h

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
static void rotateLogicalToNative(const uint16_t *src, uint16_t *dst) {
  for (int16_t ny = 0; ny < LCD_HEIGHT; ny++) {
    const uint16_t *s = src + ((LOG_W - 1) - ny);
    uint16_t *d = dst + (int32_t)ny * LCD_WIDTH;
    for (int16_t nx = 0; nx < LCD_WIDTH; nx++) {
      d[nx] = *s;
      s += LOG_W;
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
struct Bucket { double cost = 0; double total = 0; };

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
  String resetCreditExpiries; // "10d 7h · 22d 4h"
  String onDemand;           // Cursor: "$30 / $30 on-demand"
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

static Bucket today, session5h, week;
static String topModel = "-";
static String updatedZ = "";
static bool haveData = false;
static bool hostOk = false;   // last /usage fetch succeeded
static ProviderQuota claudeQ, codexQ, cursorQ;
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
static String fmtTokens(double n) {
  char b[16];
  if (n >= 1e9)      snprintf(b, sizeof b, "%.2fB", n / 1e9);
  else if (n >= 1e6) snprintf(b, sizeof b, "%.1fM", n / 1e6);
  else if (n >= 1e3) snprintf(b, sizeof b, "%.1fk", n / 1e3);
  else               snprintf(b, sizeof b, "%.0f", n);
  return String(b);
}

static String fmtCost(double c) {
  char b[16];
  if (c >= 1000)    snprintf(b, sizeof b, "$%.1fk", c / 1000.0);
  else if (c >= 100) snprintf(b, sizeof b, "$%.0f", c);
  else               snprintf(b, sizeof b, "$%.2f", c);
  return String(b);
}

static String fmtPct(float p) {
  char b[16];
  if (p < 0) return String("--%");
  if (p >= 99.5f) snprintf(b, sizeof b, "100%%");
  else if (p >= 10) snprintf(b, sizeof b, "%.0f%%", p);
  else              snprintf(b, sizeof b, "%.1f%%", p);
  return String(b);
}

static String shortModel(const String &m) {
  // "claude-opus-4-8" -> "opus 4.8"
  String s = m;
  s.replace("claude-", "");
  int dash = s.indexOf('-');
  if (dash > 0) {
    String fam = s.substring(0, dash);
    String ver = s.substring(dash + 1);
    ver.replace("-", ".");
    return fam + " " + ver;
  }
  return s;
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

// Ask the host to force-refresh Sources (same endpoint Mac Settings uses).
static bool requestSyncRefreshHttp() {
  if (WiFi.status() != WL_CONNECTED) return false;
  String url = "http://" + hostFor() + ":" + String(HOST_PORT) + "/sync/refresh";
  HTTPClient http;
  http.setConnectTimeout(800);
  http.setTimeout(1200);
  if (!http.begin(url)) return false;
  http.addHeader("Content-Type", "application/json");
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
// Enough for a ~30KB /usage frame; keep modest so internal heap stays free
// for UI/Wi-Fi (large CDC RX buffers are carved from DRAM, not PSRAM).
static const size_t USB_RX_BUF = 40 * 1024;

// ArduinoJson DOM for a ~30KB /usage payload — keep it in PSRAM so we don't
// blow the tiny internal heap (canvas + WiFi already live there).
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

static bool applyUsageJson(const char *payload, size_t len) {
  JsonDocument doc(&spiRamAlloc);
  DeserializationError err = (len > 0)
      ? deserializeJson(doc, payload, len)
      : deserializeJson(doc, payload);
  if (err) {
    Serial.printf("json parse fail: %s\n", err.c_str());
    hostOk = false;
    return false;
  }

  today.cost     = doc["today"]["cost_usd"]      | 0.0;
  today.total    = doc["today"]["total"]         | 0.0;
  session5h.cost = doc["session_5h"]["cost_usd"] | 0.0;
  session5h.total= doc["session_5h"]["total"]    | 0.0;
  week.cost      = doc["week"]["cost_usd"]        | 0.0;
  week.total     = doc["week"]["total"]           | 0.0;
  updatedZ       = String((const char *)(doc["updated"] | ""));

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
        if (codexQ.resetCreditExpiries.length()) codexQ.resetCreditExpiries += " · ";
        codexQ.resetCreditExpiries += s;
      }
    }
  } else {
    codexQ = ProviderQuota{};
  }

  // Cursor (nested Total + Auto + API pools)
  JsonObject cur = doc["cursor"].as<JsonObject>();
  if (!cur.isNull()) {
    cursorQ.ok            = cur["ok"] | false;
    cursorQ.plan          = String((const char *)(cur["plan"] | ""));
    cursorQ.totalPct      = cur["total_pct"].isNull() ? -1.f : (float)(cur["total_pct"] | -1.0);
    cursorQ.sessionPct    = cur["auto_pct"].isNull() ? -1.f : (float)(cur["auto_pct"] | -1.0);
    cursorQ.weekPct       = cur["api_pct"].isNull()  ? -1.f : (float)(cur["api_pct"] | -1.0);
    cursorQ.totalPace     = cur["total_pace_pct"].isNull() ? -1.f : (float)(cur["total_pace_pct"] | -1.0);
    cursorQ.sessionPace   = cur["auto_pace_pct"].isNull() ? -1.f : (float)(cur["auto_pace_pct"] | -1.0);
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

  // Pick the model with the most tokens today.
  double best = -1;
  topModel = "-";
  JsonObject bm = doc["by_model"].as<JsonObject>();
  for (JsonPair kv : bm) {
    double t = kv.value()["total"] | 0.0;
    if (t > best) { best = t; topModel = String(kv.key().c_str()); }
  }
  haveData = true;
  hostOk = true;
  return true;
}

static bool fetchUsageHttp() {
  if (WiFi.status() != WL_CONNECTED) return false;
  String url = "http://" + hostFor() + ":" + String(HOST_PORT) + "/usage";
  HTTPClient http;
  // Fail fast — a slow/wrong LAN must not starve BOOT/touch.
  http.setConnectTimeout(700);
  http.setTimeout(1000);
  if (!http.begin(url)) return false;
  int code = http.GET();
  if (code != 200) {
    http.end();
    resolvedHost = "";   // force a fresh mDNS lookup next time
    return false;
  }

  String payload = http.getString();
  http.end();
  return applyUsageJson(payload.c_str(), payload.length());
}

static bool fetchUsageUsb(uint32_t timeoutMs) {
  char *body = nullptr;
  size_t len = 0;
  if (!usbTransact("HR GET /usage", 200, &body, &len, timeoutMs)) return false;
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

static void drawCentered(const String &s, int y, uint8_t size, uint16_t col) {
  gfx->setTextSize(size);
  gfx->setTextColor(col);
  int16_t x1, y1; uint16_t w, h;
  gfx->getTextBounds(s.c_str(), 0, y, &x1, &y1, &w, &h);
  gfx->setCursor((scrW() - w) / 2, y);
  gfx->print(s);
}

static void drawTextAt(const String &s, int x, int y, uint8_t size, uint16_t col) {
  gfx->setTextSize(size);
  gfx->setTextColor(col);
  gfx->setCursor(x, y);
  gfx->print(s);
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

  // Right status must fit; truncate long SSIDs / hostnames.
  char right[18];
  size_t sn = strlen(status);
  if (sn > 16) {
    memcpy(right, status, 15);
    right[15] = '\0';
  } else {
    memcpy(right, status, sn + 1);
  }

  const int16_t x0 = UI_PAD + 10;
  const int16_t xMax = scrW() - UI_PAD - 10;
  gfx->setTextSize(2);
  int16_t x1, y1; uint16_t lw, lh, rw, rh, dw, dh;
  gfx->getTextBounds(label, 0, 0, &x1, &y1, &lw, &lh);
  gfx->getTextBounds(right, 0, 0, &x1, &y1, &rw, &rh);
  gfx->getTextBounds(".", 0, 0, &x1, &y1, &dw, &dh);
  if (dw < 1) dw = 6;

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

// Growing dots after the label (WIFI. → WIFI.. → WIFI...), advanced by caller.
static void bootProgress(const char *label, uint8_t step) {
  char left[24];
  size_t n = strlen(label);
  if (n > 12) n = 12;
  memcpy(left, label, n);
  const uint8_t dots = (uint8_t)((step % 4) + 1);  // 1..4
  for (uint8_t i = 0; i < dots; i++) left[n + i] = '.';
  left[n + dots] = '\0';

  const int16_t x0 = UI_PAD + 10;
  const int16_t y = bootY;
  const int16_t bw = (int16_t)(scrW() - UI_PAD * 2 - 20);
  gfx->fillRect(x0, y, bw, 18, COL_CRT_BG);
  for (int16_t sy = y; sy < y + 18; sy += 3)
    gfx->drawFastHLine(x0, sy, bw, COL_CRT_SCAN);
  drawTextAt(left, x0, y, 2, COL_CRT);
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

static void drawQuotaRow(const char *title, float pct, float pace,
                         const String &resets, const String &paceLabel,
                         const String &runsOut, int16_t y, int16_t pad,
                         uint16_t accent) {
  const int16_t W = scrW();
  drawTextAt(title, pad, y, 2, COL_WHITE);
  drawBar(pad, y + 26, W - pad * 2, 12, pct, pace, accent);

  String left = fmtPct(pct) + " used";
  drawTextAt(left, pad, y + 48, 2, COL_WHITE);
  if (resets.length()) {
    String right = "Resets in " + resets;
    gfx->setTextSize(2);
    int16_t x1, y1; uint16_t tw, th;
    gfx->getTextBounds(right.c_str(), 0, 0, &x1, &y1, &tw, &th);
    gfx->setTextColor(COL_DIM);
    gfx->setCursor(W - pad - tw, y + 48);
    gfx->print(right);
  }
  // CodexBar pace line: "50% in deficit" … "Runs out in 3h 14m"
  if (paceLabel.length() || runsOut.length()) {
    if (paceLabel.length())
      drawTextAt(paceLabel, pad, y + 70, 2, COL_DIM);
    if (runsOut.length()) {
      String right = "Runs out in " + runsOut;
      gfx->setTextSize(2);
      int16_t x1, y1; uint16_t tw, th;
      gfx->getTextBounds(right.c_str(), 0, 0, &x1, &y1, &tw, &th);
      gfx->setTextColor(COL_DIM);
      gfx->setCursor(W - pad - tw, y + 70);
      gfx->print(right);
    }
  }
}

// Three Cursor lanes fit above the footer using the same bar/label treatment
// with tighter vertical rhythm and no separate pace-detail line.
static void drawQuotaRowCompact(const char *title, float pct, float pace,
                                const String &resets, int16_t y, int16_t pad,
                                uint16_t accent) {
  const int16_t W = scrW();
  drawTextAt(title, pad, y, 2, COL_WHITE);
  drawBar(pad, y + 20, W - pad * 2, 9, pct, pace, accent);
  drawTextAt(fmtPct(pct) + " used", pad, y + 37, 2, COL_WHITE);
  if (resets.length()) {
    String right = "Resets in " + resets;
    gfx->setTextSize(2);
    int16_t x1, y1; uint16_t tw, th;
    gfx->getTextBounds(right.c_str(), 0, 0, &x1, &y1, &tw, &th);
    gfx->setTextColor(COL_DIM);
    gfx->setCursor(W - pad - tw, y + 37);
    gfx->print(right);
  }
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

// Name left + age right-aligned in a fixed column (short names don't shift ages).
static void drawNameAgoRow(int16_t x, int16_t y, int16_t colW,
                           const String &name, const String &ago,
                           uint16_t nameCol, uint16_t agoCol) {
  gfx->setTextSize(2);
  int16_t x1, y1; uint16_t aw, ah;
  gfx->getTextBounds("999h", 0, 0, &x1, &y1, &aw, &ah);  // widest age we expect
  const int16_t agoReserve = (int16_t)aw;
  const int16_t gap = 4;
  String clipped = clipFit(name, (int16_t)(colW - agoReserve - gap), 2);
  drawTextAt(clipped, x, y, 2, nameCol);
  gfx->getTextBounds(ago.c_str(), 0, 0, &x1, &y1, &aw, &ah);
  gfx->setTextColor(agoCol);
  gfx->setCursor(x + colW - (int16_t)aw, y);
  gfx->print(ago);
}

static uint16_t statusColor(const String &status) {
  if (status == "ready") return COL_GREEN;
  if (status == "building") return COL_AMBER;
  if (status == "error") return COL_RED;
  return COL_DIM;
}

// Normalize "ago" strings to whole hours for glance columns.
static String gitHoursAgo(const String &ago) {
  if (!ago.length()) return "—";
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
static void providerHottest(const ProviderQuota &q, float *pctOut, float *paceOut) {
  *pctOut = -1;
  *paceOut = -1;
  if (!q.ok) return;
  // Cursor exposes a true combined Total. Use it as the headline value;
  // Auto/API remain breakdowns on the detail page.
  if (q.totalPct >= 0) {
    *pctOut = q.totalPct;
    *paceOut = q.totalPace;
    return;
  }
  if (q.sessionPct > *pctOut) {
    *pctOut = q.sessionPct;
    *paceOut = q.sessionPace;
  }
  if (q.weekPct > *pctOut) {
    *pctOut = q.weekPct;
    *paceOut = q.weekPace;
  }
}

// Quota ring: track + filled arc from 12 o'clock + white pace tick + black 0°.
static void drawQuotaRing(int16_t cx, int16_t cy, int16_t r, float pct,
                          float pacePct, uint16_t accent, const char *label) {
  const int16_t thick = 6;
  gfx->fillArc(cx, cy, r, (int16_t)(r - thick), 0, 360, COL_BAR);
  if (pct >= 0) {
    float p = pct > 100 ? 100 : pct;
    float sweep = p * 3.6f;
    if (p > 0 && sweep < 2.0f) sweep = 2.0f;
    if (p >= 100 || sweep >= 359.0f) {
      gfx->fillArc(cx, cy, r, (int16_t)(r - thick), 0, 360, accent);
    } else {
      gfx->fillArc(cx, cy, r, (int16_t)(r - thick), -90.0f, -90.0f + sweep, accent);
    }
  }
  if (pacePct >= 0) {
    float pp = pacePct > 100 ? 100 : pacePct;
    float a = -90.0f + pp * 3.6f;
    gfx->fillArc(cx, cy, (int16_t)(r + 2), (int16_t)(r - thick - 1),
                 a - 2.8f, a + 2.8f, COL_WHITE);
  }
  // Black 0° mark at 12 o'clock (start of the ring).
  gfx->fillArc(cx, cy, (int16_t)(r + 2), (int16_t)(r - thick - 1),
               -90.0f - 2.6f, -90.0f + 2.6f, COL_BLACK);
  gfx->setTextSize(2);
  int16_t x1, y1; uint16_t tw, th;
  gfx->getTextBounds(label, 0, 0, &x1, &y1, &tw, &th);
  gfx->setTextColor(accent);
  gfx->setCursor(cx - (int16_t)tw / 2, cy + r + 8);
  gfx->print(label);
}

// Headroom tap targets (logical coords) → detail pages.
struct GlanceHit {
  int16_t x, y, w, h;
  Page target;
};
static GlanceHit glanceHits[6];
static uint8_t glanceHitN = 0;

static void glanceClearHits() { glanceHitN = 0; }

static void glanceAddHit(int16_t x, int16_t y, int16_t w, int16_t h, Page target) {
  if (glanceHitN >= 6) return;
  glanceHits[glanceHitN++] = {x, y, w, h, target};
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

static void drawGlancePage() {
  gfx->clear(COL_BG);
  glanceClearHits();
  const int16_t W = scrW();
  const int16_t H = scrH();
  const int16_t padX = UI_PAD;
  const int16_t top = UI_PAD;
  const int16_t bot = UI_PAD;
  const int16_t footY = H - bot - 6;

  drawTextAt("Headroom", padX, top, 3, COL_WHITE);
  String when = "";
  if (updatedZ.length() >= 16) when = updatedZ.substring(11, 16);
  if (when.length()) {
    gfx->setTextSize(2);
    int16_t x1, y1; uint16_t tw, th;
    gfx->getTextBounds(when.c_str(), 0, 0, &x1, &y1, &tw, &th);
    gfx->setTextColor(COL_DIM);
    gfx->setCursor(W - padX - (int16_t)tw, top + 6);
    gfx->print(when);
  }

  // 3 equal top slots (quota rings); lower row gives Local less width.
  const int16_t span = W - padX * 2;
  const int16_t slot = span / 3;
  const int16_t ringR = 32;
  const int16_t ringCy = top + 74;
  const int16_t midY = ringCy + ringR + 48;  // clear labels under rings
  const int16_t lowBottom = footY - 4;

  const Page topPages[3] = {PAGE_CLAUDE, PAGE_CODEX, PAGE_CURSOR};
  const Page lowPages[3] = {PAGE_VERCEL, PAGE_GIT, PAGE_LOCAL};
  const uint16_t topAccent[3] = {COL_CLAUDE, COL_OPENAI, COL_CURSOR};
  const char *topLabel[3] = {"Claude", "Codex", "Cursor"};

  float pct = -1, pace = -1;
  const ProviderQuota *qs[3] = {&claudeQ, &codexQ, &cursorQ};
  for (uint8_t i = 0; i < 3; i++) {
    int16_t colX = padX + (int16_t)i * slot;
    glanceAddHit(colX, top + 36, slot, (int16_t)(midY - (top + 36)), topPages[i]);
    providerHottest(*qs[i], &pct, &pace);
    drawQuotaRing(colX + slot / 2, ringCy, ringR, pct, pace, topAccent[i], topLabel[i]);
  }

  gfx->drawFastHLine(padX, midY, span, COL_DIM);

  // Lower row — Local narrow (ports); Vercel/Git share the rest (~2–3 more chars).
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
        drawTextAt(vercelOk ? "—" : "down", x, y, 2, COL_DIM);
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
        drawTextAt(gitOk ? "—" : "down", x, y, 2, COL_DIM);
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
                            : "—";
          drawTextAt(port, x + textX, y, 2, COL_WHITE);
          y += rowH;
        }
      } else {
        drawTextAt(localOk ? "none" : "down", x, y, 2, COL_DIM);
      }
    }
  }

  // Sources footer — same list as Mac Settings (green/amber/red/off).
  if (sourceN > 0) {
    const int16_t srcR = 3;
    const int16_t gap = 12;
    const int16_t totalW = (int16_t)sourceN * gap - (gap - 2 * srcR);
    int16_t sx = padX + (span - totalW) / 2;
    for (uint8_t i = 0; i < sourceN; i++) {
      uint16_t col = COL_DIM;
      if (sourceRows[i].enabled) {
        if (sourceRows[i].ok)
          col = sourceRows[i].stale ? COL_AMBER : COL_GREEN;
        else
          col = COL_RED;
      }
      gfx->fillCircle(sx + srcR, footY + 2, srcR, col);
      sx += gap;
    }
  }

  drawWifiDot(padX, top);
  present();
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
    gfx->setTextSize(2);
    int16_t x1, y1; uint16_t tw, th;
    gfx->getTextBounds(q.plan.c_str(), 0, 0, &x1, &y1, &tw, &th);
    gfx->setTextColor(COL_DIM);
    gfx->setCursor(W - padX - tw, top + 6);
    gfx->print(q.plan);
  }
  String when = "";
  if (updatedZ.length() >= 16) when = updatedZ.substring(11, 16);
  drawTextAt(when.length() ? ("Updated " + when) : "Updated --",
             padX, top + 32, 2, COL_DIM);
  gfx->drawFastHLine(padX, top + 56, W - padX * 2, COL_DIM);

  if (q.ok && (q.totalPct >= 0 || q.sessionPct >= 0 || q.weekPct >= 0)) {
    int16_t rowY = top + 72;
    if (isCursor) {
      if (q.totalPct >= 0) {
        drawQuotaRowCompact("Total", q.totalPct, q.totalPace,
                            q.sessionResets, rowY, padX, accent);
        rowY += 68;
      }
      if (q.sessionPct >= 0) {
        drawQuotaRowCompact("Auto", q.sessionPct, q.sessionPace,
                            q.sessionResets, rowY, padX, accent);
        rowY += 68;
      }
      if (q.weekPct >= 0) {
        drawQuotaRowCompact("API", q.weekPct, q.weekPace,
                            q.weekResets, rowY, padX, accent);
        rowY += 68;
      }
    } else {
      // Team Codex often has only a weekly window — skip empty session.
      if (q.sessionPct >= 0) {
        drawQuotaRow("Session", q.sessionPct, q.sessionPace, q.sessionResets,
                     "", "", rowY, padX, accent);
        rowY += 98;
      }
      if (q.weekPct >= 0) {
        drawQuotaRow("Weekly", q.weekPct, q.weekPace, q.weekResets,
                     isCodex ? q.paceLabel : "",
                     isCodex ? q.runsOutIn : "",
                     rowY, padX, accent);
        rowY += (isCodex && q.paceLabel.length()) ? 120 : 98;
      }
    }

    // Limit Reset Credits (Codex only)
    if (isCodex && q.resetCredits >= 0) {
      gfx->drawFastHLine(padX, rowY, W - padX * 2, COL_DIM);
      rowY += 14;
      drawTextAt("Limit Reset Credits", padX, rowY, 2, COL_WHITE);
      rowY += 30;
      String left = String(q.resetCredits) + " available";
      drawTextAt(left, padX, rowY, 2, COL_WHITE);
      if (q.resetCreditExpiries.length()) {
        gfx->setTextSize(2);
        int16_t x1, y1; uint16_t tw, th;
        gfx->getTextBounds(q.resetCreditExpiries.c_str(), 0, 0, &x1, &y1, &tw, &th);
        gfx->setTextColor(COL_DIM);
        gfx->setCursor(W - padX - tw, rowY);
        gfx->print(q.resetCreditExpiries);
      }
    }
  } else if (isCursor) {
    drawTextAt("cursor quota unavailable", padX, top + 100, 2, COL_RED);
  } else if (isCodex) {
    drawTextAt("codex quota unavailable", padX, top + 100, 2, COL_RED);
  } else {
    drawTextAt("claude quota unavailable", padX, top + 100, 2, COL_RED);
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
    gfx->setTextSize(2);
    int16_t x1, y1; uint16_t tw, th;
    gfx->getTextBounds(vercelTeam.c_str(), 0, 0, &x1, &y1, &tw, &th);
    gfx->setTextColor(COL_DIM);
    gfx->setCursor(W - padX - tw, top + 6);
    gfx->print(vercelTeam);
  }
  String when = "";
  if (updatedZ.length() >= 16) when = updatedZ.substring(11, 16);
  drawTextAt(when.length() ? ("Updated " + when) : "Updated --",
             padX, top + 32, 2, COL_DIM);
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
      gfx->setTextSize(2);
      int16_t x1, y1; uint16_t tw, th;
      gfx->getTextBounds(right.c_str(), 0, 0, &x1, &y1, &tw, &th);
      gfx->setTextColor(COL_DIM);
      gfx->setCursor(W - padX - tw, rowY);
      gfx->print(right);

      String sub = r.status;
      if (r.target.length()) sub += " · " + r.target;
      else if (r.branch.length()) sub += " · " + r.branch;
      drawTextAt(truncFit(sub, W - padX * 2 - 20, 2),
                 padX + 18, rowY + 20, 2, COL_DIM);

      rowY += 46;
      if (rowY > H - bot - 40) break;
    }
  } else {
    drawTextAt(vercelOk ? "no deployments" : "vercel unavailable",
               padX, top + 100, 2, COL_RED);
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
  {
    const char *u = "michellzappa";
    gfx->setTextSize(2);
    int16_t x1, y1; uint16_t tw, th;
    gfx->getTextBounds(u, 0, 0, &x1, &y1, &tw, &th);
    gfx->setTextColor(COL_DIM);
    gfx->setCursor(W - padX - tw, top + 6);
    gfx->print(u);
  }
  String when = "";
  if (updatedZ.length() >= 16) when = updatedZ.substring(11, 16);
  drawTextAt(when.length() ? ("Updated " + when) : "Updated --",
             padX, top + 32, 2, COL_DIM);
  gfx->drawFastHLine(padX, top + 56, W - padX * 2, COL_DIM);

  int16_t rowY = top + 70;
  if (gitOk && gitN > 0) {
    for (uint8_t i = 0; i < gitN; i++) {
      const CommitRow &r = gitRows[i];
      drawTextAt(truncFit(r.repo, W - padX * 2 - 80, 2), padX, rowY, 2, COL_DIM);

      String right = r.ago.length() ? r.ago : "--";
      gfx->setTextSize(2);
      int16_t x1, y1; uint16_t tw, th;
      gfx->getTextBounds(right.c_str(), 0, 0, &x1, &y1, &tw, &th);
      gfx->setTextColor(COL_DIM);
      gfx->setCursor(W - padX - tw, rowY);
      gfx->print(right);

      drawTextAt(truncFit(r.subject, W - padX * 2, 2),
                 padX, rowY + 21, 2, COL_WHITE);

      rowY += 47;
      if (rowY > H - bot - 40) break;
    }
  } else {
    drawTextAt(gitOk ? "no commits" : "git unavailable",
               padX, top + 100, 2, COL_RED);
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
    gfx->setTextSize(2);
    int16_t x1, y1; uint16_t tw, th;
    gfx->getTextBounds(localHost.c_str(), 0, 0, &x1, &y1, &tw, &th);
    gfx->setTextColor(COL_DIM);
    gfx->setCursor(W - padX - tw, top + 6);
    gfx->print(localHost);
  }
  String when = "";
  if (updatedZ.length() >= 16) when = updatedZ.substring(11, 16);
  drawTextAt(when.length() ? ("Updated " + when) : "Updated --",
             padX, top + 32, 2, COL_DIM);
  gfx->drawFastHLine(padX, top + 56, W - padX * 2, COL_DIM);

  int16_t rowY = top + 70;
  if (localOk && localN > 0) {
    for (uint8_t i = 0; i < localN; i++) {
      const ServerRow &r = localRows[i];
      gfx->fillCircle(padX + 4, rowY + 8, 5, COL_GREEN);

      String left = truncFit(r.name, W - padX * 2 - 90, 2);
      drawTextAt(left, padX + 18, rowY, 2, COL_WHITE);

      String right = r.port > 0 ? (":" + String(r.port)) : "--";
      gfx->setTextSize(2);
      int16_t x1, y1; uint16_t tw, th;
      gfx->getTextBounds(right.c_str(), 0, 0, &x1, &y1, &tw, &th);
      gfx->setTextColor(COL_DIM);
      gfx->setCursor(W - padX - tw, rowY);
      gfx->print(right);

      String sub = r.cmd.length() ? r.cmd : "listening";
      drawTextAt(truncFit(sub, W - padX * 2 - 20, 2),
                 padX + 18, rowY + 20, 2, COL_DIM);

      rowY += 46;
      if (rowY > H - bot - 40) break;
    }
  } else {
    drawTextAt(localOk ? "no servers" : "local unavailable",
               padX, top + 100, 2, COL_RED);
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
  bool ok = requestSyncRefresh();
  delay(150);
  yield();
  if (fetchUsage(USB_TIMEOUT_SYNC_MS)) drawDashboard();
  else drawStatus(ok ? "synced" : "sync failed", ok ? COL_GREEN : COL_RED);
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
        if (!pageEnabled(hit.target)) {
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
  Serial.println("\n=== headroom booting ===");

  powerInit();
  pinMode(BTN_BOOT, INPUT_PULLUP);
  bool touchOk = touchInit();

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
    bootLine("DISP", disp, pok && cok ? COL_CRT : COL_RED);
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

  connectWifi();
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
    mdnsUp = MDNS.begin("headroom");   // needed for MDNS.queryHost()
    bootLine("MDNS", mdnsUp ? "headroom" : "FAIL",
             mdnsUp ? COL_CRT : COL_RED);
    Serial.printf("wifi ok  ip=%s  ssid=%s  mdns=%d\n",
                  WiFi.localIP().toString().c_str(),
                  WiFi.SSID().c_str(), mdnsUp);
    bootLine("HOST", HOST_NAME, COL_CRT_DIM);
  } else {
    bootLine("WIFI", "FAIL", COL_RED);
    Serial.println("wifi FAILED (no known network in range?) — trying USB");
    bootLine("HOST", "USB", COL_CRT_DIM);
  }

  {
    int16_t hostY = bootY;
    bootProgress("LINK", 0);
    bool ok = fetchUsage();
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
  lastPoll = millis();
}

void loop() {
  // Input first, every pass — never starve BOOT/touch behind Wi-Fi or USB.
  handleInput();

  // WiFiMulti.run() blocks for seconds while hunting APs. Call it rarely when
  // disconnected; when associated just poke it occasionally.
  static uint32_t lastWifi = 0;
  const uint32_t wifiEvery =
      (WiFi.status() == WL_CONNECTED) ? 10000u : 20000u;
  if (millis() - lastWifi >= wifiEvery) {
    lastWifi = millis();
    uint8_t st = wifiMulti.run();
    if (st == WL_CONNECTED && !mdnsUp) mdnsUp = MDNS.begin("headroom");
  }

  // Background poll — skip while finger is down.
  if (!touchDown &&
      millis() - lastPoll >= (uint32_t)POLL_INTERVAL_S * 1000) {
    lastPoll = millis();
    if (fetchUsage()) drawDashboard();
    else if (!haveData) drawStatus("server unreachable", COL_RED);
  }
  delay(4);
}
