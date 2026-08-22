#pragma once

#include <WiFiMulti.h>

// Non-blocking Wi-Fi onboarding. The normal WiFiMulti path remains intact;
// when it cannot associate, Headroom exposes a local setup AP while USB CDC
// remains available as the offline transport.
void wifiProvisioningBegin();
void wifiProvisioningAddStoredNetwork(WiFiMulti &multi);
bool wifiProvisioningHasStoredNetwork();
void wifiProvisioningStartPortal();
void wifiProvisioningLoop();
bool wifiProvisioningActive();
const char *wifiProvisioningApName();
const char *wifiProvisioningApPassword();
