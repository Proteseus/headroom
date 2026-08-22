#include "wifi_provisioning.h"

#include <Arduino.h>
#include <DNSServer.h>
#include <Preferences.h>
#include <WebServer.h>
#include <WiFi.h>
#include <esp_system.h>
#include <string.h>

namespace {

constexpr char kPrefsNamespace[] = "headroom_wifi";
constexpr char kSsidKey[] = "wifi_ssid";
constexpr char kPassKey[] = "wifi_pass";
constexpr char kApPassword[] = "headroom";
constexpr uint32_t kRestartDelayMs = 900;
constexpr size_t kMaxSsidLength = 32;
constexpr size_t kMaxPasswordLength = 63;

Preferences prefs;
DNSServer dnsServer;
WebServer server(80);

bool prefsReady = false;
bool portalActive = false;
bool restartPending = false;
uint32_t restartAtMs = 0;
char storedSsid[kMaxSsidLength + 1] = {};
char storedPassword[kMaxPasswordLength + 1] = {};
char apName[33] = "Headroom-Setup";

void loadStoredCredentials() {
  memset(storedSsid, 0, sizeof(storedSsid));
  memset(storedPassword, 0, sizeof(storedPassword));
  if (!prefsReady) return;

  prefs.getString(kSsidKey, storedSsid, sizeof(storedSsid));
  prefs.getString(kPassKey, storedPassword, sizeof(storedPassword));
  Serial.printf("wifi: stored credentials %s\n",
                storedSsid[0] ? "available" : "not found");
}

String htmlEscape(const String &value) {
  String escaped;
  escaped.reserve(value.length() + 8);
  for (size_t i = 0; i < value.length(); ++i) {
    switch (value[i]) {
      case '&': escaped += "&amp;"; break;
      case '<': escaped += "&lt;"; break;
      case '>': escaped += "&gt;"; break;
      case '"': escaped += "&quot;"; break;
      case '\'': escaped += "&#39;"; break;
      default: escaped += value[i]; break;
    }
  }
  return escaped;
}

String networkOptions() {
  String options;
  const int16_t found = WiFi.scanNetworks(false, true);
  if (found <= 0) return options;

  options.reserve((size_t)found * 48);
  for (int16_t i = 0; i < found; ++i) {
    const String ssid = WiFi.SSID(i);
    if (ssid.isEmpty()) continue;
    options += "<option value=\"";
    options += htmlEscape(ssid);
    options += "\">";
    options += htmlEscape(ssid);
    options += " (";
    options += String(WiFi.RSSI(i));
    options += " dBm)</option>";
  }
  WiFi.scanDelete();
  return options;
}

String portalPage(const char *message = nullptr) {
  String page;
  page.reserve(4200);
  page += F(R"HTML(<!doctype html>
<html lang="en"><head>
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="color-scheme" content="dark">
<title>Headroom setup</title>
<style>
:root{font-family:system-ui,-apple-system,sans-serif;color:#f0eeeA;background:#080808}
body{max-width:34rem;margin:0 auto;padding:2rem 1.2rem}
main{background:#151311;border:1px solid #d97757;border-radius:18px;padding:1.4rem}
h1{font-size:1.35rem;margin:.1rem 0 .4rem}p{color:#b5aaa2;line-height:1.45}
label{display:block;margin:1.1rem 0 .35rem;color:#d97757;font-size:.9rem}
input,button{box-sizing:border-box;width:100%;border-radius:10px;padding:.85rem;font:inherit}
input{color:#f0eeea;background:#080808;border:1px solid #5a514c}
button{margin-top:1.25rem;border:0;color:#080808;background:#d97757;font-weight:700}
.note{color:#c39b55}.error{color:#dc6a64}
</style></head><body><main>
<h1>Headroom Wi-Fi setup</h1>
<p>Choose the network that can reach your Mac and enter its password. Headroom will save it and restart.</p>
)HTML");
  if (message) {
    page += F("<p class=\"error\">");
    page += htmlEscape(message);
    page += F("</p>");
  }
  page += F(R"HTML(<form method="post" action="/save">
<label for="ssid">Network name (SSID)</label>
<input id="ssid" name="ssid" maxlength="32" required autocomplete="off" list="networks">
<datalist id="networks">)HTML");
  page += networkOptions();
  page += F(R"HTML(</datalist>
<label for="password">Wi-Fi password</label>
<input id="password" name="password" type="password" maxlength="63" autocomplete="current-password">
<button type="submit">Save and connect</button>
</form>
<p class="note">If the setup page does not appear automatically, open <b>http://192.168.4.1</b>.</p>
</main></body></html>)HTML");
  return page;
}

void handleRoot() {
  server.send(200, "text/html; charset=utf-8", portalPage());
}

void handleSave() {
  if (!server.hasArg("ssid")) {
    server.send(400, "text/html; charset=utf-8",
                portalPage("Please enter a network name."));
    return;
  }

  const String ssid = server.arg("ssid");
  const String password = server.hasArg("password") ? server.arg("password")
                                                     : String();
  if (ssid.isEmpty() || ssid.length() > kMaxSsidLength ||
      password.length() > kMaxPasswordLength) {
    server.send(400, "text/html; charset=utf-8",
                portalPage("The network name or password is too long."));
    return;
  }

  if (!prefsReady) {
    server.send(500, "text/html; charset=utf-8",
                portalPage("Flash storage is unavailable; nothing was saved."));
    return;
  }

  prefs.putString(kSsidKey, ssid);
  prefs.putString(kPassKey, password);
  strncpy(storedSsid, ssid.c_str(), sizeof(storedSsid) - 1);
  strncpy(storedPassword, password.c_str(), sizeof(storedPassword) - 1);
  restartPending = true;
  restartAtMs = millis() + kRestartDelayMs;

  Serial.printf("wifi: credentials saved for '%s'; restarting\n", ssid.c_str());
  server.send(200, "text/html; charset=utf-8", R"HTML(
<!doctype html><html><meta name="viewport" content="width=device-width,initial-scale=1">
<body style="font-family:system-ui;max-width:34rem;margin:3rem auto;padding:1rem;background:#080808;color:#f0eeeA">
<h1>Saved</h1><p>Headroom is restarting and will reconnect to the network.</p>
</body></html>)HTML");
}

void handleNotFound() {
  server.sendHeader("Location", "/", true);
  server.send(302, "text/plain", "redirecting to Headroom setup");
}

void startPortalServer() {
  server.on("/", HTTP_GET, handleRoot);
  server.on("/portal", HTTP_GET, handleRoot);
  server.on("/save", HTTP_POST, handleSave);
  server.onNotFound(handleNotFound);
  server.begin();
}

}  // namespace

void wifiProvisioningBegin() {
  prefsReady = prefs.begin(kPrefsNamespace, false);
  if (!prefsReady) {
    Serial.println("wifi: credential storage unavailable");
    return;
  }
  loadStoredCredentials();

  const uint64_t chip = ESP.getEfuseMac();
  snprintf(apName, sizeof(apName), "Headroom-%04X",
           (unsigned)(chip & 0xFFFFu));
}

void wifiProvisioningAddStoredNetwork(WiFiMulti &multi) {
  if (storedSsid[0]) {
    multi.addAP(storedSsid, storedPassword);
    Serial.printf("wifi: trying stored network '%s'\n", storedSsid);
  }
}

bool wifiProvisioningHasStoredNetwork() { return storedSsid[0] != '\0'; }

void wifiProvisioningStartPortal() {
  if (portalActive) return;

  // AP+STA keeps the setup AP available while the portal builds its scan list.
  WiFi.mode(WIFI_AP_STA);
  if (!WiFi.softAP(apName, kApPassword)) {
    Serial.println("wifi: setup AP failed to start");
  }
  dnsServer.setErrorReplyCode(DNSReplyCode::NoError);
  if (!dnsServer.start(53, "*", WiFi.softAPIP())) {
    Serial.println("wifi: captive DNS failed to start");
  }
  startPortalServer();
  portalActive = true;
  Serial.printf("wifi: setup AP '%s' password '%s' at http://%s\n",
                apName, kApPassword, WiFi.softAPIP().toString().c_str());
}

void wifiProvisioningLoop() {
  if (!portalActive) return;
  dnsServer.processNextRequest();
  server.handleClient();
  if (restartPending && (int32_t)(millis() - restartAtMs) >= 0) {
    Serial.println("wifi: restarting after provisioning");
    delay(50);
    ESP.restart();
  }
  delay(2);
}

bool wifiProvisioningActive() { return portalActive; }

const char *wifiProvisioningApName() { return apName; }

const char *wifiProvisioningApPassword() { return kApPassword; }
