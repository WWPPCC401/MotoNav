#pragma once
// WorkBuddy custom: physical side buttons on Waveshare ESP32-S3-Touch-AMOLED-1.75.
//   BOOT (GPIO0, active LOW)                 -> cycle pages 0 -> 1 -> 2 -> 0
//   PWR  (TCA9554 @0x20 P4/EXIO4, active HIGH) -> toggle navigation voice mute
// Hardware facts (Waveshare HARDWARE_REFERENCE.md):
//   PWR is on the AXP2101 power path, its conditioned SYS_OUT state is readable
//   on TCA9554 P4; HIGH = pressed. Holding it ~6s hard-powers-off the board, so
//   we ONLY act on a short press-release, never on press-down or long hold.
// Included exactly once, after the page helpers and before Notifications.h.

#define SIDE_BTN_BOOT_GPIO    0
#define SIDE_BTN_TCA9554_ADDR 0x20           // preferred; auto-detected at boot (0x20 / 0x38)
#define SIDE_BTN_PWR_BIT      4              // P4 / EXIO4 = SYS_OUT
#define SIDE_BTN_DEBOUNCE_MS  35
#define SIDE_BTN_SHORT_MAX_MS 700            // press-release window; long hold is ignored
#define SIDE_BTN_POLL_MS      12

uint8_t sTcaAddr = 0;                       // resolved at boot by I2C probe
int sLastTca = -2;                          // last input value, for change logging

bool navMuted = false;                       // mirrored phone state, persisted in NVS
String pendingVoice = "";                    // BLE notification queued for the phone
unsigned long muteOsdUntil = 0;              // OSD overlay deadline

// per-key debounce state
bool     sBootStable = false, sPwrStable = false;
bool     sBootRaw = false,    sPwrRaw = false;
unsigned long sBootRawAt = 0, sPwrRawAt = 0;
unsigned long sBootDownAt = 0, sPwrDownAt = 0;
unsigned long sLastPoll = 0;

// Read IO-expander Input Port register. Returns -1 on I2C failure (never treat as pressed).
// Uses the same plain-STOP Wire pattern as the working pmuRead() in Battery.h.
int sideBtnReadTca(uint8_t addr) {
  if (!addr) return -1;
  Wire.beginTransmission(addr);
  Wire.write(0x00);                          // Input Port register
  if (Wire.endTransmission() != 0) return -1;
  if (Wire.requestFrom(addr, (uint8_t)1) != 1) return -1;
  return Wire.read();
}

void sideButtonsInit() {
  pinMode(SIDE_BTN_BOOT_GPIO, INPUT);        // externally pulled up; LOW = pressed
  Preferences pr;
  pr.begin("motonav", true);
  navMuted = pr.getBool("navmute", false);
  pr.end();

  // Probe the shared I2C bus: different 1.75 board revisions use 0x20 or 0x38
  // for the TCA9554. Prefer 0x20, fall back to any responding candidate.
  Serial.print("SideButtons I2C scan:");
  uint8_t fallback = 0;
  for (uint8_t a = 0x20; a <= 0x3F; a++) {
    if (a == 0x34) continue;                // AXP2101, not the expander
    Wire.beginTransmission(a);
    if (Wire.endTransmission() == 0) {
      Serial.printf(" 0x%02X", a);
      if (a == SIDE_BTN_TCA9554_ADDR) sTcaAddr = a;
      else if (!fallback) fallback = a;
    }
  }
  if (!sTcaAddr) sTcaAddr = fallback;
  Serial.println();
  int v = sideBtnReadTca(sTcaAddr);
  sLastTca = v;
  Serial.printf("SideButtons: BOOT=GPIO0 PWR=TCA9554@0x%02X P4 input=0x%02X navMuted=%d\n",
                sTcaAddr, v, (int)navMuted);
}

// Small key: cycle the three pages using the existing, production-proven path.
void onSideBtnPage() {
  if (sliding || dragging || callOn || pairOn || fxOn) return;
  muteOsdUntil = 0;                         // 翻页本身会整帧重画，别让 OSD 混进滑动快照
  int next = (page + 1) % 3;
  showPageAnimated(next, next > page ? 1 : -1, 0);
}

// Large key: toggle navigation voice. The phone owns the TTS, so we send a BLE
// command; iOS/Android App patch in this repo adds the matching listener.
void onSideBtnVoice() {
  navMuted = !navMuted;
  Preferences pr;
  pr.begin("motonav", false);
  pr.putBool("navmute", navMuted);
  pr.end();
  pendingVoice = String("T,V,") + (navMuted ? "1" : "0");
  muteOsdUntil = millis() + 1400;
  needFlush = true;
  Serial.printf("SideBtn PWR: navMuted=%d evt=%s\n", (int)navMuted, pendingVoice.c_str());
}

// Overlay drawn on the current framebuffer. Called every frame while active so it
// survives the navigation page's per-frame redraw.
void drawMuteOsd() {
  const int w = 236, h = 66, x = CX - w / 2, y = 190;
  uint16_t accent = navMuted ? C_RED : C_GREEN;
  gfx->fillRoundRect(x, y, w, h, 12, 0x18C6);
  gfx->drawRoundRect(x, y, w, h, 12, accent);
  printCenteredOut(navMuted ? "MUTED" : "VOICE ON", CX, y + 8, 4, accent);
  printCenteredOut("NAV SPEECH", CX, y + 42, 2, C_GREY);
  needFlush = true;
}

// Return true when a short press-release was detected for one key.
bool sideBtnEdge(bool raw, bool &stable, unsigned long &rawAt,
                 unsigned long &downAt, unsigned long now) {
  if (raw != stable) {
    if (!rawAt) rawAt = now;
    else if (now - rawAt >= SIDE_BTN_DEBOUNCE_MS) {
      stable = raw;
      rawAt = 0;
      if (stable) downAt = now;                                  // press-down
      else {                                                     // release
        unsigned long held = now - downAt;
        if (held >= SIDE_BTN_DEBOUNCE_MS && held <= SIDE_BTN_SHORT_MAX_MS) return true;
      }
    }
  } else rawAt = 0;
  return false;
}

void sideButtonsPoll() {
  unsigned long now = millis();
  if (now - sLastPoll < SIDE_BTN_POLL_MS) return;
  sLastPoll = now;

  bool bootRaw = (digitalRead(SIDE_BTN_BOOT_GPIO) == LOW);
  if (sideBtnEdge(bootRaw, sBootStable, sBootRawAt, sBootDownAt, now)) onSideBtnPage();

  int tca = sideBtnReadTca(sTcaAddr);
  if (tca >= 0) {                            // ignore failed reads, avoid phantom press
    if (tca != sLastTca) {                  // log level changes for hardware diagnosis
      Serial.printf("SideBtn TCA input 0x%02X -> 0x%02X (P4=%d)\n",
                    sLastTca, tca, (tca >> SIDE_BTN_PWR_BIT) & 1);
      sLastTca = tca;
    }
    bool pwrRaw = (tca & (1 << SIDE_BTN_PWR_BIT)) != 0;
    if (sideBtnEdge(pwrRaw, sPwrStable, sPwrRawAt, sPwrDownAt, now)) onSideBtnVoice();
  }
}

// Called every frame just before the flush: while active, redraw the OSD on top
// of whatever page was rendered (navigation redraws every frame). On expiry,
// ask the current page to repaint so the overlay is erased cleanly.
void sideButtonsFrame() {
  if (!muteOsdUntil) return;
  if ((int32_t)(millis() - muteOsdUntil) < 0) { drawMuteOsd(); return; }
  muteOsdUntil = 0;
  if (page == 2) musicDirty = true;
  else if (page == 1) wxDirty = true;
  else if (inNav) navDirty = true;
  else drawWaiting((bleConnected && bleAuthed) ? WAIT_READY : WAIT_NOLINK);
  needFlush = true;
}
