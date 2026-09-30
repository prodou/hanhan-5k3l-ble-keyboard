/*
  ESP32-C3 五键三灯 BLE HID 方案
  --------------------------------
  重要硬件说明:
    ESP32-C3 只有 "USB Serial/JTAG" 控制器, 不支持真正的 USB-OTG/HID,
    所以本方案改为 **BLE(蓝牙低功耗)HID 键盘**, USB-C 仅用于供电和烧录/
    串口调试, 不参与按键/LED 功能。

  硬件连接:
    - 按键(内部上拉,按下=低电平): GPIO0, GPIO1, GPIO3, GPIO4, GPIO10 -> 另一端接 GND
      (GPIO0 是下载/BOOT 选通脚, 只要不是在"复位瞬间"被按住就不影响正常运行)
    - LED(共用同一限流电阻到 GND, 需分时点亮避免叠加电流):
        LED0 = GPIO2, LED1 = GPIO6, LED2 = GPIO7

  功能:
    1. 按键按下/松开 -> 通过标准 BLE HID 键盘 Input Report 发送 F13~F17,
       电脑蓝牙配对后当普通蓝牙键盘识别,主机侧用监听/映射软件识别这几个键。
    2. 3 个 LED 是"自定义功能指示灯",与系统的大小写/数字/滚动锁无关,
       所以**不使用**标准 HID 键盘 LED 输出报文(会被系统/其它键盘联动误触发),
       改用一个独立的**自定义 BLE GATT 特征值**(单独 Service/Characteristic),
       电脑端程序连接 BLE 后直接写这个特征值 1 个字节:
         bit0 = LED0(GPIO2) 使能
         bit1 = LED1(GPIO6) 使能
         bit2 = LED2(GPIO7) 使能
    3. 被使能的 LED 按 3ms 亮 / 6ms 灭 的时序点亮;
       由于 3 个 LED 共用同一颗限流电阻(共地),不能同时点亮多颗,
       所以用 9ms = 3ms x 3 时隙 的轮询方式错开点亮:
         时隙0 (0~3ms)  : 只有 LED0 允许亮
         时隙1 (3~6ms)  : 只有 LED1 允许亮
         时隙2 (6~9ms)  : 只有 LED2 允许亮
       某个 LED 未被使能时,轮到它的时隙也保持灭。
       这样每个使能的 LED 自身呈现"亮3ms灭6ms"的观感,且任意时刻最多一颗在导通。

  Arduino IDE 设置:
    开发板:  ESP32C3 Dev Module
    需要先安装库: NimBLE-Arduino (Library Manager 搜索安装)
    其余选项保持默认即可(不需要 USB CDC/USB OTG 相关设置)
*/

#include <NimBLEDevice.h>
#include <NimBLEServer.h>
#include <NimBLEHIDDevice.h>
#include <HIDTypes.h>

// ------------------- BLE HID 键盘 报文描述符 (仅 Keyboard, Report ID = 1) -------------------
#define KEYBOARD_ID 0x01
static const uint8_t hidReportDescriptor[] = {
  USAGE_PAGE(1),      0x01,        // USAGE_PAGE (Generic Desktop Ctrls)
  USAGE(1),           0x06,        // USAGE (Keyboard)
  COLLECTION(1),      0x01,        // COLLECTION (Application)
  REPORT_ID(1),       KEYBOARD_ID, //   REPORT_ID (1)
  USAGE_PAGE(1),      0x07,        //   USAGE_PAGE (Kbrd/Keypad)
  USAGE_MINIMUM(1),   0xE0,        //   USAGE_MINIMUM (0xE0)
  USAGE_MAXIMUM(1),   0xE7,        //   USAGE_MAXIMUM (0xE7)
  LOGICAL_MINIMUM(1), 0x00,        //   LOGICAL_MINIMUM (0)
  LOGICAL_MAXIMUM(1), 0x01,        //   LOGICAL_MAXIMUM (1)
  REPORT_SIZE(1),     0x01,        //   REPORT_SIZE (1)
  REPORT_COUNT(1),    0x08,        //   REPORT_COUNT (8)   -> 8 个修饰键 bit
  HIDINPUT(1),        0x02,        //   INPUT (Data,Var,Abs)
  REPORT_COUNT(1),    0x01,        //   REPORT_COUNT (1)   -> 1 字节保留
  REPORT_SIZE(1),     0x08,        //   REPORT_SIZE (8)
  HIDINPUT(1),        0x01,        //   INPUT (Const,Array,Abs)
  REPORT_COUNT(1),    0x06,        //   REPORT_COUNT (6)   -> 6 字节按键码
  REPORT_SIZE(1),     0x08,        //   REPORT_SIZE (8)
  LOGICAL_MINIMUM(1), 0x00,
  LOGICAL_MAXIMUM(1), 0x65,
  USAGE_PAGE(1),      0x07,
  USAGE_MINIMUM(1),   0x00,
  USAGE_MAXIMUM(1),   0x65,
  HIDINPUT(1),        0x00,        //   INPUT (Data,Array,Abs)
  END_COLLECTION(0)
};

// 按键在 USB/BLE HID Keyboard Usage Page 上的标准键码: F13~F17
// (选用这几个键是因为几乎不会被系统/其他软件占用, 方便 HanHan Agent 安全拦截转发)
static const uint8_t KEY_F13 = 0x68;
static const uint8_t KEY_F14 = 0x69;
static const uint8_t KEY_F15 = 0x6A;
static const uint8_t KEY_F16 = 0x6B;
static const uint8_t KEY_F17 = 0x6C;

NimBLEServer *pServer = nullptr;
NimBLEHIDDevice *pHid = nullptr;
NimBLECharacteristic *pInputKeyboard = nullptr;
NimBLECharacteristic *pLedStatusChr = nullptr;

volatile bool bleConnected = false;

// ------------------- 自定义 LED 状态 BLE 服务 -------------------
// 独立于 HID 服务, 使用自定义 128-bit UUID, 与系统键盘锁定状态完全隔离。
#define LED_SERVICE_UUID "6E400100-B5A3-F393-E0A9-E50E24DCCA9E"
#define LED_STATUS_CHAR_UUID "6E400101-B5A3-F393-E0A9-E50E24DCCA9E"

volatile bool ledEnabled[3] = {false, false, false};

class LedStatusCallbacks : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic *pChr, NimBLEConnInfo &connInfo) override {
    std::string v = pChr->getValue();
    if (v.length() > 0) {
      uint8_t b = (uint8_t)v[0];
      ledEnabled[0] = b & 0x01;
      ledEnabled[1] = b & 0x02;
      ledEnabled[2] = b & 0x04;
    }
  }
};

class ServerCallbacks : public NimBLEServerCallbacks {
  void onConnect(NimBLEServer *server, NimBLEConnInfo &connInfo) override {
    bleConnected = true;
  }
  void onDisconnect(NimBLEServer *server, NimBLEConnInfo &connInfo, int reason) override {
    bleConnected = false;
    NimBLEDevice::startAdvertising();
  }
};

// ------------------- 按键配置 -------------------
struct Button {
  uint8_t pin;
  uint8_t keycode;
  bool lastStable;   // 消抖后的稳定电平 (true = 高/未按下)
  bool lastRaw;      // 上一次读到的原始电平
  uint32_t lastChangeMs;
  bool pressedSent;  // 是否已经发送过 press
};

// GPIO0/1/3/4/10 -> F13~F17
Button buttons[5] = {
  {0,  KEY_F13, true, true, 0, false},
  {1,  KEY_F14, true, true, 0, false},
  {3,  KEY_F15, true, true, 0, false},
  {4,  KEY_F16, true, true, 0, false},
  {10, KEY_F17, true, true, 0, false},
};

const uint32_t DEBOUNCE_MS = 20;

// ------------------- 清空绑定组合键(GPIO0 + GPIO1 同时长按 5 秒) -------------------
// 注意: 执行后会主动断开当前连接并清空板子这边保存的全部绑定密钥,
// 此时原来连接的手机/电脑只会看到"普通断开"(不会提示"已解绑"),
// 它自己保存的配对记录并不会被清掉。若之后它尝试自动重连会因为密钥不匹配而连接失败(无提示),
// 需要在对方设备上也手动"忽略此设备/取消配对"后重新扫描配对。
const uint32_t UNBOND_HOLD_MS = 5000;
uint32_t comboHoldStartMs = 0;
bool comboHolding = false;
bool comboTriggered = false;

void handleUnbondCombo() {
  bool pin0Pressed = (digitalRead(0) == LOW);
  bool pin1Pressed = (digitalRead(1) == LOW);
  uint32_t now = millis();

  if (pin0Pressed && pin1Pressed) {
    if (!comboHolding) {
      comboHolding = true;
      comboHoldStartMs = now;
      comboTriggered = false;
    } else if (!comboTriggered && (now - comboHoldStartMs) >= UNBOND_HOLD_MS) {
      comboTriggered = true;
      Serial.println("[BLE] combo held 5s -> disconnect + clear all bonds");
      if (pServer && pServer->getConnectedCount() > 0) {
        for (uint16_t connHandle : pServer->getPeerDevices()) {
          pServer->disconnect(connHandle);
        }
      }
      NimBLEDevice::deleteAllBonds();
      NimBLEDevice::startAdvertising();
    }
  } else {
    comboHolding = false;
    comboTriggered = false;
  }
}

// 当前按下的按键集合(最多 6 个, 跟 HID boot keyboard report 对齐)
uint8_t activeKeys[6] = {0, 0, 0, 0, 0, 0};

void sendKeyboardReport() {
  if (!bleConnected || !pInputKeyboard) {
    return;
  }
  uint8_t report[8] = {0};
  // report[0] = modifier bits (未使用), report[1] = reserved
  memcpy(&report[2], activeKeys, 6);
  pInputKeyboard->setValue(report, sizeof(report));
  pInputKeyboard->notify();
}

void addKey(uint8_t keycode) {
  for (uint8_t i = 0; i < 6; i++) {
    if (activeKeys[i] == keycode) {
      return;  // 已存在
    }
  }
  for (uint8_t i = 0; i < 6; i++) {
    if (activeKeys[i] == 0) {
      activeKeys[i] = keycode;
      break;
    }
  }
  sendKeyboardReport();
}

void removeKey(uint8_t keycode) {
  for (uint8_t i = 0; i < 6; i++) {
    if (activeKeys[i] == keycode) {
      activeKeys[i] = 0;
    }
  }
  sendKeyboardReport();
}

// ------------------- LED 配置 -------------------
const uint8_t LED_PINS[3] = {2, 6, 7};

const uint32_t SLOT_MS = 3;      // 每个时隙 3ms
uint8_t currentSlot = 0;
uint32_t lastSlotMs = 0;

void setupBle() {
  NimBLEDevice::init("HanHan 5K3L v0.1");

  // 启用绑定(bonding), 不要求输入/输出(Just Works 配对),
  // 让手机把本设备当成正式的蓝牙键盘配对并记住, 支持自动重连和在系统里断开/忘记。
  NimBLEDevice::setSecurityAuth(true, false, true);
  NimBLEDevice::setSecurityIOCap(BLE_HS_IO_NO_INPUT_OUTPUT);

  pServer = NimBLEDevice::createServer();
  pServer->setCallbacks(new ServerCallbacks());

  Serial.println("[BLE] init done, creating HID device...");

  // ---- HID 键盘服务 ----
  pHid = new NimBLEHIDDevice(pServer);
  pInputKeyboard = pHid->getInputReport(KEYBOARD_ID);
  Serial.println("[BLE] input report created");

  pHid->setManufacturer("DIY");
  pHid->setPnp(0x02, 0xE502, 0xA111, 0x0210);
  pHid->setHidInfo(0x00, 0x01);
  pHid->setReportMap((uint8_t *)hidReportDescriptor, sizeof(hidReportDescriptor));
  Serial.println("[BLE] report map set");

  // ---- 自定义 LED 状态服务(独立于 HID, 不影响系统锁定灯) ----
  NimBLEService *pLedService = pServer->createService(LED_SERVICE_UUID);
  pLedStatusChr = pLedService->createCharacteristic(
    LED_STATUS_CHAR_UUID,
    NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR
  );
  pLedStatusChr->setCallbacks(new LedStatusCallbacks());
  pLedService->start();
  Serial.println("[BLE] led service started");

  pHid->getHidService()->start(); // 保持向后兼容, 新版本server->start()会一并启动
  pServer->start();
  Serial.println("[BLE] server started");

  NimBLEAdvertising *pAdvertising = NimBLEDevice::getAdvertising();
  // 先设置名字(此时 scanResp 还未开启, 会直接写入主广播包),
  // 保证第一次扫描就能看到正确的设备名, 不用等建立连接才读到。
  bool nameOk = pAdvertising->setName("HanHan 5K3L v0.1");
  pAdvertising->setAppearance(HID_KEYBOARD);
  pAdvertising->addServiceUUID(pHid->getHidService()->getUUID());
  pAdvertising->enableScanResponse(true);
  bool advOk = pAdvertising->start();
  Serial.printf("[BLE] setName() = %d\n", nameOk);
  Serial.printf("[BLE] advertising start() = %d\n", advOk);
  {
    auto advPayload = pAdvertising->getAdvertisementData().getPayload();
    Serial.printf("[BLE] adv payload size = %d, bytes = ", (int)advPayload.size());
    for (uint8_t b : advPayload) Serial.printf("%02X ", b);
    Serial.println();
    auto scanPayload = pAdvertising->getScanData().getPayload();
    Serial.printf("[BLE] scan payload size = %d, bytes = ", (int)scanPayload.size());
    for (uint8_t b : scanPayload) Serial.printf("%02X ", b);
    Serial.println();
  }
}

void setup() {
  Serial.begin(115200);
  delay(1500);
  Serial.println("\n\n[BOOT] ESP32C3 5key3led BLE firmware starting...");

  // 按键: 内部上拉, 按下拉低
  for (auto &b : buttons) {
    pinMode(b.pin, INPUT_PULLUP);
  }

  // LED: 输出, 初始全灭
  for (uint8_t i = 0; i < 3; i++) {
    pinMode(LED_PINS[i], OUTPUT);
    digitalWrite(LED_PINS[i], LOW);
  }

  setupBle();
  Serial.println("[BOOT] setup() complete, entering loop()");

  lastSlotMs = millis();
}

void scanButtons() {
  uint32_t now = millis();
  for (auto &b : buttons) {
    bool raw = digitalRead(b.pin); // HIGH = 未按下, LOW = 按下

    if (raw != b.lastRaw) {
      b.lastChangeMs = now;
      b.lastRaw = raw;
    }

    if ((now - b.lastChangeMs) >= DEBOUNCE_MS && raw != b.lastStable) {
      b.lastStable = raw;
      if (b.lastStable == LOW) {
        // 按下
        if (!b.pressedSent) {
          addKey(b.keycode);
          b.pressedSent = true;
        }
      } else {
        // 松开
        if (b.pressedSent) {
          removeKey(b.keycode);
          b.pressedSent = false;
        }
      }
    }
  }
}

void updateLeds() {
  uint32_t now = millis();
  if (now - lastSlotMs >= SLOT_MS) {
    lastSlotMs += SLOT_MS;
    currentSlot = (currentSlot + 1) % 3;
  }

  for (uint8_t i = 0; i < 3; i++) {
    bool on = (i == currentSlot) && ledEnabled[i];
    digitalWrite(LED_PINS[i], on ? HIGH : LOW);
  }
}

void loop() {
  scanButtons();
  updateLeds();
  handleUnbondCombo();
}
