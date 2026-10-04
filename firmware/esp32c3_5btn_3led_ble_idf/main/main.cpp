#include "Arduino.h"
#include "esp_pm.h"
#include "driver/ledc.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

// 关键修复: 我们用的是 esp-nimble-cpp (非 Arduino 自带的 BLE 库),
// 所以 Arduino 核心里跟踪 "BLE 是否被使用" 的 _bleLibraryInUse 标志永远不会
// 被设置为 true (它只在链接 Arduino 自带 BLE 库时才会被置位)。
// initArduino() 据此误判 BLE 未被使用, 在 setup() 之前就调用了
// btMemRelease(BT_MODE_BLE) 把 BLE 控制器内存释放掉了, 导致随后
// NimBLEDevice::init() 在已释放的内存上初始化控制器, 出现两次
// "MAGIC fadebead" 初始化尝试、HLI Magic mismatch、最终空指针崩溃。
// 这里提供一个强符号覆盖掉 esp32-hal-bt.c 里的 weak bleInUse(),
// 告诉 Arduino 核心: BLE 确实在用, 不要释放这块内存。
extern "C" bool bleInUse(void) {
  return true;
}
/*
  ESP32-C3 五键三灯 BLE HID 方案
  --------------------------------
  重要硬件说明:
    ESP32-C3 只有 "USB Serial/JTAG" 控制器, 不支持真正的 USB-OTG/HID,
    所以本方案改为 **BLE(蓝牙低功耗)HID 键盘**, USB-C 仅用于供电和烧录/
    串口调试, 不参与按键/LED 功能。

  硬件连接:
    - 按键(内部上拉,按下=低电平): GPIO0, GPIO1, GPIO3, GPIO5, GPIO10 -> 另一端接 GND
      (GPIO0 是下载/BOOT 选通脚, 只要不是在"复位瞬间"被按住就不影响正常运行;
       原方案 F16 按键在 GPIO4, 现挪到 GPIO5, 把 GPIO4 让给电池 ADC 检测,
       因为 ESP32-C3 的 ADC2/GPIO5 实际不可用, 只有 ADC1/GPIO0~4 能读电压)
    - LED(共用同一限流电阻到 GND, 需分时点亮避免叠加电流):
        LED0 = GPIO2, LED1 = GPIO6, LED2 = GPIO7
    - 电池电压检测: GPIO4(ADC1) <- 两颗 220k/220k 等值分压电阻的中点,
      单节锂电池正极(最高 4.2V)经过 1:2 分压后约 0~2.1V 落在 ADC 安全量程内,
      固件内部再乘 2 还原成实际电池电压

  功能:
    1. 按键按下/松开 -> 通过标准 BLE HID 键盘 Input Report 发送 F13~F17,
       电脑蓝牙配对后当普通蓝牙键盘识别,主机侧用监听/映射软件识别这几个键。
    2. 3 个 LED 是"自定义功能指示灯",与系统的大小写/数字/滚动锁无关,
       所以**不使用**标准 HID 键盘 LED 输出报文(会被系统/其它键盘联动误触发),
       改用一个独立的**自定义 BLE GATT 特征值**(单独 Service/Characteristic),
       电脑端程序连接 BLE 后直接写这个特征值 2 个字节:
         byte0 = mask, bit0/1/2 分别对应 LED0(GPIO2)/LED1(GPIO6)/LED2(GPIO7) 是否参与显示
         byte1 = mode, 效果模式:
           0 = 全灭(忽略 mask)
           1 = 常亮  (mask 选中的灯常亮显示, 例: mask=0b111 即"三灯都亮")
           2 = 闪烁  (mask 选中的灯整体慢闪: 亮400ms / 灭400ms)
           3 = 流水灯(忽略 mask, LED0->LED1->LED2->LED0 顺序点亮, 每步150ms)
         只发 1 个字节时视为旧协议, 自动当作 byte1=1(常亮) 处理, 保持向后兼容。
       另有一个**亮度/带宽分配特征值**(同 Service 下), 写 3 个字节:
         byte0/1/2 = LED0/1/2 分配到的"帧内占比"百分比(0~100),
         **三者总和不能超过 100**(固件会按比例整体缩小超出的部分), 默认各 30。
         可以用来抵消不同颜色 LED 正向压降不同导致的肉眼亮度不一致,
         也可以在总预算内自由分配(比如某颗想格外亮一些就多分配给它)。
    3. **任意时刻三颗 LED 最多只有一颗导通, 不会在共用限流电阻上叠加电流**:
       硬件上 3 颗 LED 共用同一限流电阻到 GND, 为避免叠加电流,
       采用 10ms 为一帧的分时复用, 三颗灯各自分到一段首尾相接、互不重叠的
       专属导通窗口, 窗口宽度 = 10ms * 分配百分比/100(微秒级精度):
         LED0 窗口: [0, w0)
         LED1 窗口: [w0, w0+w1)
         LED2 窗口: [w0+w1, w0+w1+w2)
         (剩余部分, 如果 w0+w1+w2 < 10ms) : 全灭(帧尾间隔)
       "常亮"/"闪烁"/"流水灯"等上层效果只决定某颗 LED 在当前宏观时刻
       是否参与这个分时复用(即是否允许在轮到它的窗口导通),
       从不会让任何一颗 LED 跳过分时直接常通, 从根本上保证任意时刻
       最多同时一颗导通, 电气上绝对安全; 分配比例只影响"相对亮度",
       不影响"互斥性"这个安全保证。
    4. 支持**同时**连接手机/电脑(HID 键盘)和 HanHan Agent(LED 控制)两条独立
       BLE 连接: 每次有新连接建立后, 只要当前连接数还没到上限(2), 就会自动
       重新开启广播以便接纳另一条连接; loop() 里也有兜底逻辑, 只要连接数未满
       且当前没有在广播, 就会定期自动重新开启广播, 避免因为某次异常导致
       广播停掉后再也连不上。
    5. 电池电压检测与上报: 每 10 秒读一次 GPIO5 的 ADC 电压(多次采样取平均降噪),
       乘以分压比(x2)还原成实际电池电压, 再按单节锂电池 4.2V(满)~3.0V(空)
       的放电曲线换算成百分比, 通过两种方式上报:
         a) 标准 BLE 电池服务(0x180F, Battery Level 特征值 0x2A19) —— 只报百分比,
            系统/手机蓝牙设置里会原生显示电池图标, 这是 NimBLEHIDDevice 自带的。
         b) 自定义电压特征值(同 LED Service 下, UUID 见下方) —— 报 3 字节:
            byte0/1 = 电压毫伏(uint16, 小端), byte2 = 百分比(0~100),
            支持 Notify, 供 HanHan Agent 显示具体电压数值。

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
#define LED_CALIB_CHAR_UUID "6E400102-B5A3-F393-E0A9-E50E24DCCA9E"
#define BATTERY_VOLTAGE_CHAR_UUID "6E400103-B5A3-F393-E0A9-E50E24DCCA9E"

// 效果模式: 0=全灭 1=常亮 2=闪烁 3=流水灯
enum LedMode : uint8_t {
  LED_MODE_OFF = 0,
  LED_MODE_STATIC = 1,
  LED_MODE_BLINK = 2,
  LED_MODE_CHASE = 3,
};

const uint8_t LED_ALLOC_SUM_MAX = 100; // 三颗灯的分配百分比总和上限(时分复用天然保证任意时刻只有一颗导通,
                                        // 所以只要总和不超过一帧, 怎么分配都不会叠加电流)

volatile bool ledEnabled[3] = {false, false, false}; // mask: 常亮/闪烁模式下哪些灯参与显示
volatile uint8_t ledMode = LED_MODE_STATIC;
// 每颗 LED 分配到的帧内占比(0~100), 三者总和不能超过 100, 用于:
//   1) 抵消不同颜色 LED 正向压降不同导致的肉眼亮度差异
//   2) 让用户在总预算内自由分配亮度(比如想要某颗更亮, 可以多分配一些给它)
// 默认三等分(各 30, 总和 90, 留一点余量), 由 HanHan Agent 下发调整。
volatile uint8_t ledAllocPercent[3] = {30, 30, 30};

// 把三个百分比值按总和 <=100 的约束夹一遍: 单值先夹到 0~100, 总和超了就按比例整体缩小。
void clampLedAllocation(uint8_t vals[3]) {
  uint32_t sum = 0;
  for (uint8_t i = 0; i < 3; i++) {
    if (vals[i] > LED_ALLOC_SUM_MAX) vals[i] = LED_ALLOC_SUM_MAX;
    sum += vals[i];
  }
  if (sum > LED_ALLOC_SUM_MAX && sum > 0) {
    for (uint8_t i = 0; i < 3; i++) {
      vals[i] = (uint8_t)((uint32_t)vals[i] * LED_ALLOC_SUM_MAX / sum);
    }
  }
}

// 省电关键改动: LED 改用硬件 LEDC PWM(见下方 applyLedOutputs()/ledcSetup()),
// 不再需要 CPU 每 1ms 醒来手动翻转 GPIO。这里先声明, 供上面的 BLE 写回调
// (配置一变就立刻应用一次) 和下面的闪烁/流水灯定时步进调用。
void applyLedOutputs();

class LedStatusCallbacks : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic *pChr, NimBLEConnInfo &connInfo) override {
    std::string v = pChr->getValue();
    if (v.length() == 0) {
      return;
    }
    uint8_t mask = (uint8_t)v[0];
    ledEnabled[0] = mask & 0x01;
    ledEnabled[1] = mask & 0x02;
    ledEnabled[2] = mask & 0x04;
    // 只写 1 字节时视为旧协议, 默认常亮模式, 保持向后兼容
    ledMode = (v.length() >= 2) ? (uint8_t)v[1] : LED_MODE_STATIC;
    Serial.printf("[LED] write mask=0b%03b mode=%u\n", mask & 0x07, ledMode);
    applyLedOutputs();
  }
};

class LedCalibCallbacks : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic *pChr, NimBLEConnInfo &connInfo) override {
    std::string v = pChr->getValue();
    if (v.length() < 3) return;
    uint8_t vals[3] = {(uint8_t)v[0], (uint8_t)v[1], (uint8_t)v[2]};
    clampLedAllocation(vals);
    ledAllocPercent[0] = vals[0];
    ledAllocPercent[1] = vals[1];
    ledAllocPercent[2] = vals[2];
    Serial.printf("[LED] allocation%% = %u, %u, %u\n",
                  ledAllocPercent[0], ledAllocPercent[1], ledAllocPercent[2]);
    applyLedOutputs();
  }
};

NimBLECharacteristic *pLedCalibChr = nullptr;

// ------------------- 电池电压检测 -------------------
// 单节锂电池(满 4.2V / 建议放电下限 3.0V)经过 220k+220k 等值分压后接到 GPIO4(ADC1),
// ADC 读数约为电池电压的一半, 固件内部乘 2 还原。
const uint8_t BATTERY_ADC_PIN = 4; // ESP32-C3 的 ADC2(GPIO5) 实际不可用("adc unit not supported"),
                                    // 只有 ADC1(GPIO0~4) 能用, 所以改用原按键占用的 GPIO4,
                                    // 对应把那颗按键的线挪到 GPIO5(纯数字输入, 不需要 ADC)
const float BATTERY_DIVIDER_RATIO = 2.0f; // 分压比的倒数: 实际电压 = ADC电压 * 2
const uint32_t BATTERY_SAMPLE_COUNT = 16;  // 多次采样取平均, 降低 ADC 噪声
const uint32_t BATTERY_REPORT_INTERVAL_MS = 10000; // 每 10 秒测一次并上报

NimBLECharacteristic *pBatteryVoltageChr = nullptr;
uint32_t lastBatteryReportMs = 0;
uint16_t lastBatteryMv = 0;
uint8_t lastBatteryPercent = 0;

// 单节锂电池放电曲线的简单分段线性近似(电压 mV -> 百分比), 比纯线性更贴近真实电量观感。
// 电压越界(超过 4200 或低于 3000)会被夹到 100/0。
uint8_t batteryVoltageToPercent(uint16_t mv) {
  struct Point { uint16_t mv; uint8_t pct; };
  static const Point curve[] = {
    {4200, 100}, {4060, 90}, {3980, 80}, {3920, 70}, {3870, 65},
    {3820, 60},  {3790, 55}, {3770, 50}, {3740, 45}, {3680, 40},
    {3600, 30},  {3450, 20}, {3270, 10}, {3000, 0},
  };
  const int n = sizeof(curve) / sizeof(curve[0]);
  if (mv >= curve[0].mv) return 100;
  if (mv <= curve[n - 1].mv) return 0;
  for (int i = 0; i < n - 1; i++) {
    if (mv <= curve[i].mv && mv >= curve[i + 1].mv) {
      // 在 curve[i+1] ~ curve[i] 之间线性插值
      float t = (float)(mv - curve[i + 1].mv) / (float)(curve[i].mv - curve[i + 1].mv);
      return (uint8_t)(curve[i + 1].pct + t * (curve[i].pct - curve[i + 1].pct));
    }
  }
  return 0;
}

// 读取一次电池电压(多次采样平均), 更新 BLE 特征值并按需 notify, 同时同步到标准电池服务。
void updateBatteryReading() {
  uint32_t sumMv = 0;
  for (uint32_t i = 0; i < BATTERY_SAMPLE_COUNT; i++) {
    sumMv += analogReadMilliVolts(BATTERY_ADC_PIN);
  }
  uint16_t adcMv = (uint16_t)(sumMv / BATTERY_SAMPLE_COUNT);
  uint16_t batteryMv = (uint16_t)(adcMv * BATTERY_DIVIDER_RATIO);
  uint8_t percent = batteryVoltageToPercent(batteryMv);

  lastBatteryMv = batteryMv;
  lastBatteryPercent = percent;

  Serial.printf("[BATTERY] adc=%umV battery=%umV percent=%u%%\n", adcMv, batteryMv, percent);

  if (pBatteryVoltageChr) {
    uint8_t payload[3] = {(uint8_t)(batteryMv & 0xFF), (uint8_t)(batteryMv >> 8), percent};
    pBatteryVoltageChr->setValue(payload, 3);
    if (bleConnected) {
      pBatteryVoltageChr->notify();
    }
  }
  if (pHid) {
    pHid->setBatteryLevel(percent, bleConnected);
  }
}


// 同时允许的最大连接数。原来设成2是以为手机/电脑的HID连接和HanHan Agent的
// LED控制连接是两条独立连接, 需要各占一条。后来证实HanHan Agent优先复用
// 系统已有的那条连接(retrieveConnectedPeripherals), 并不会额外建连接;
// 加上用户确认平时只用一台设备连接, 改成1之后, 连上这一台设备后就彻底
// 停止广播, 省掉广播包本身的周期性射频开销。
const uint8_t MAX_DESIRED_CONNECTIONS = 1;

class ServerCallbacks : public NimBLEServerCallbacks {
  void onConnect(NimBLEServer *server, NimBLEConnInfo &connInfo) override {
    bleConnected = true;
    Serial.printf("[BLE] onConnect, connectedCount=%u\n", server->getConnectedCount());
    // 只要还没到连接数上限, 继续广播以便接纳另一条连接(例如手机当键盘用的同时,
    // HanHan Agent 还要单独连一条 BLE 来控制 LED)
    if (server->getConnectedCount() < MAX_DESIRED_CONNECTIONS) {
      NimBLEDevice::startAdvertising();
    }
    // 省电: 主动请求拉长连接间隔 + 增大 slave latency, 减少无线电唤醒次数。
    // 单位: interval=1.25ms 步进, timeout=10ms 步进。
    // min=30ms, max=100ms, latency=10(空闲时最多可跳过10个连接事件不响应,
    // 相当于空闲时实际间隔可放宽到 ~1.1s), timeout=6s。
    // 这是"建议值", 最终由对端(手机/电脑系统蓝牙或 HanHan Agent)决定是否采纳;
    // 如果对端没有完全按这个来, 射频仍会较频繁唤醒, 耗电会更接近"不省电"的水平。
    // 对于偶尔按键的场景, 这点延迟可接受, 换来待机耗电显著下降。
    server->updateConnParams(connInfo.getConnHandle(), 24, 80, 10, 600);
  }
  // 诊断用: 打印对端(手机/电脑系统蓝牙)最终实际采纳的连接参数, 用来确认
  // "对端没有按我们的请求来, 实际间隔仍然很短" 这个猜测是否属实。
  // 注意: 这个事件发生在运行期(不在开机 grace 窗口内), USB-Serial-JTAG
  // 在 light sleep 深睡后会读不到, 如果要抓这条日志, 需要在参数协商刚
  // 完成、设备还没进入深度 light sleep 的那一小段时间内连上串口监听。
  void onConnParamsUpdate(NimBLEConnInfo &connInfo) override {
    Serial.printf("[BLE] connParams updated: interval=%.2fms latency=%u timeout=%ums\n",
                  connInfo.getConnInterval() * 1.25f, connInfo.getConnLatency(),
                  connInfo.getConnTimeout() * 10);
  }
  void onDisconnect(NimBLEServer *server, NimBLEConnInfo &connInfo, int reason) override {
    bleConnected = server->getConnectedCount() > 0;
    Serial.printf("[BLE] onDisconnect reason=%d, connectedCount=%u\n", reason, server->getConnectedCount());
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

// GPIO0/1/3/5/10 -> F13~F17 (原 GPIO4 已让给电池分压 ADC, 该按键改接到 GPIO5)
Button buttons[5] = {
  {0,  KEY_F13, true, true, 0, false},
  {1,  KEY_F14, true, true, 0, false},
  {3,  KEY_F15, true, true, 0, false},
  {5,  KEY_F16, true, true, 0, false},
  {10, KEY_F17, true, true, 0, false},
};

const uint32_t DEBOUNCE_MS = 20;

// 省电关键改动: 按键不再靠 loop() 每 1ms 轮询 digitalRead(), 改成 GPIO
// 电平变化中断唤醒。中断里只做最轻量的"叫醒主任务"(xTaskNotifyGive),
// 真正的消抖/判断逻辑还是在 scanButtons() 里跑(逻辑不变), 只是触发时机从
// "每 1ms 必定跑一次"变成"有变化或到了消抖截止时间才跑一次", 这样 CPU 在
// 没人按键、LED 不需要更新的时候可以真正进入 light sleep。
TaskHandle_t mainTaskHandle = nullptr;

void IRAM_ATTR buttonIsr() {
  BaseType_t woken = pdFALSE;
  vTaskNotifyGiveFromISR(mainTaskHandle, &woken);
  if (woken) portYIELD_FROM_ISR();
}


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

// ------------------- LED 配置(硬件 LEDC PWM, 省电关键改动) -------------------
// 之前是 CPU 每 1ms 醒一次手动翻转 GPIO 模拟分时复用, 这会让 CPU 永远没法
// 进入深度 light sleep。现在改用芯片自带的 LEDC 外设: 三颗灯各占一个
// LEDC 通道, 共用同一个 100Hz(10ms 周期)定时器, 通过 ledc_set_duty_with_hpoint()
// 的 "hpoint"(相位偏移) + "duty"(导通宽度) 两个参数, 在硬件里原样复刻
// 原来"首尾相接、互不重叠的专属导通窗口"方案 —— 保证任意时刻最多一颗 LED
// 导通(电气安全不变), 但配置好之后 CPU 完全不用管, 波形由外设自己产生。
//
// 代价: LEDC 和大多数数字外设一样, 在真正的 light sleep 期间会被断电/停钟,
// 所以只要有至少一颗灯在亮, 就必须用一把 PM 锁(ESP_PM_NO_LIGHT_SLEEP)
// 阻止系统进入 light sleep, 否则波形会在睡眠期间冻结在睡着那一瞬间的电平,
// 看起来像卡亮/卡灭。这把锁只在"至少一颗灯需要亮"时持有, 灯全灭 or 根本
// 没有计划点亮时会释放, 不影响待机时的深度休眠。
const uint8_t LED_PINS[3] = {2, 6, 7};
const ledc_channel_t LED_CHANNELS[3] = {LEDC_CHANNEL_0, LEDC_CHANNEL_1, LEDC_CHANNEL_2};
const ledc_timer_t LED_TIMER = LEDC_TIMER_0;
const ledc_mode_t LED_SPEED_MODE = LEDC_LOW_SPEED_MODE; // ESP32-C3 只有低速模式
const uint32_t LED_PWM_FREQ_HZ = 100;         // 100Hz = 10ms 一帧, 和原方案一致
const ledc_timer_bit_t LED_DUTY_RES = LEDC_TIMER_13_BIT; // 0..8191
const uint32_t LED_DUTY_FULL = (1u << 13);    // 8192, 代表一整帧(100%)

esp_pm_lock_handle_t ledNoSleepLock = nullptr;
bool ledLockHeld = false; // 跟踪当前是否持有锁, 避免重复 acquire/release

// 开机保护锁: ESP32-C3 原生 USB(USB-Serial/JTAG, 也是我们接串口看日志用的那个)
// 在 light sleep 期间会被一起断电/停钟, 如果开机几百毫秒内就进入 light sleep,
// 会在电脑还没枚举完成这个 USB 设备时就把它打断, 导致电脑上这个串口直接消失、
// 且不会自动恢复(需要物理拔插才能让它重新枚举)。这对纯电池供电、不接电脑的
// 实际使用场景没有影响(没有主机在等它枚举), 但会让我们没法用串口调试、也会在
// 刚好插着 USB 的使用场景下偶发断开, 所以开机后短暂(几秒)禁止 light sleep,
// 给 USB 留出稳定枚举的时间窗口, 之后自动释放, 不影响长期续航。
esp_pm_lock_handle_t bootGraceLock = nullptr;
bool bootGraceHeld = false;
const uint32_t BOOT_USB_GRACE_MS = 5000;
uint32_t bootGraceEndMs = 0;

// 闪烁效果: 慢速整体亮/灭切换(这里的"亮"仍然要经过上面的分时窗口, 不是常通)
const uint32_t BLINK_PERIOD_MS = 800; // 亮400ms / 灭400ms
uint32_t nextBlinkToggleMs = 0;
bool blinkPhaseOn = true;

// 流水灯效果: 依次点亮 LED0 -> LED1 -> LED2 -> LED0 ...
const uint32_t CHASE_STEP_MS = 150;
uint8_t chaseIndex = 0;
uint32_t nextChaseStepMs = 0;

void ledcSetup() {
  ledc_timer_config_t timerCfg = {};
  timerCfg.speed_mode = LED_SPEED_MODE;
  timerCfg.duty_resolution = LED_DUTY_RES;
  timerCfg.timer_num = LED_TIMER;
  timerCfg.freq_hz = LED_PWM_FREQ_HZ;
  timerCfg.clk_cfg = LEDC_AUTO_CLK;
  ledc_timer_config(&timerCfg);

  for (uint8_t i = 0; i < 3; i++) {
    ledc_channel_config_t chCfg = {};
    chCfg.gpio_num = LED_PINS[i];
    chCfg.speed_mode = LED_SPEED_MODE;
    chCfg.channel = LED_CHANNELS[i];
    chCfg.intr_type = LEDC_INTR_DISABLE;
    chCfg.timer_sel = LED_TIMER;
    chCfg.duty = 0;
    chCfg.hpoint = 0;
    ledc_channel_config(&chCfg);
  }

  esp_pm_lock_create(ESP_PM_NO_LIGHT_SLEEP, 0, "led_pwm_active", &ledNoSleepLock);
}

void setupBle() {
  NimBLEDevice::init("HanHan 5K3L v0.1");

  // 降低发射功率: -9dBm 实测距离太近(需要贴近才能扫到/保持连接), 日常
  // 桌面使用距离(半米到一两米, 且中间常隔着机身/手)信号不够用。回调到
  // -3dBm, 比默认最大功率(+9dBm)省一些发射电流, 同时保留正常桌面距离的
  // 可靠连接范围。
  NimBLEDevice::setPower(-3);

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
  pLedCalibChr = pLedService->createCharacteristic(
    LED_CALIB_CHAR_UUID,
    NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR | NIMBLE_PROPERTY::READ
  );
  pLedCalibChr->setCallbacks(new LedCalibCallbacks());
  {
    uint8_t initVal[3] = {ledAllocPercent[0], ledAllocPercent[1], ledAllocPercent[2]};
    pLedCalibChr->setValue(initVal, 3);
  }
  // 自定义电池电压特征值(mV + 百分比), 同一个 LED Service 下, 支持 Notify
  pBatteryVoltageChr = pLedService->createCharacteristic(
    BATTERY_VOLTAGE_CHAR_UUID,
    NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::NOTIFY
  );
  pLedService->start();
  Serial.println("[BLE] led service started");

  pHid->getHidService()->start(); // 保持向后兼容, 新版本server->start()会一并启动
  pServer->start();
  Serial.println("[BLE] server started");

  // ADC 用于电池电压检测: 11dB 衰减对应约 0~2.6V 的较准确量程, 分压后的电压(<=2.1V)落在范围内
  analogSetPinAttenuation(BATTERY_ADC_PIN, ADC_11db);
  updateBatteryReading(); // 上电先测一次, 让 pHid 的电池服务初始值不是 0
  lastBatteryReportMs = millis();

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

  // 省电(ESP-IDF 工具链版本): 这里换成了自定义 sdkconfig 编译的 ESP-IDF 工程
  // (而不是 Arduino IDE 自带的预编译核心), 打开了 CONFIG_PM_ENABLE +
  // CONFIG_FREERTOS_USE_TICKLESS_IDLE + CONFIG_BT_CTRL_MODEM_SLEEP, 所以这里
  // 可以真正启用动态调频 + 自动 light sleep, 配合 BLE modem sleep 大幅降低
  // "已连接但空闲"状态下的平均电流。
  {
    esp_pm_config_t pmCfg = {};
    pmCfg.max_freq_mhz = 80;   // 有任务时最高跑到 80MHz(按键扫描/BLE/LED 足够用)
    pmCfg.min_freq_mhz = 10;   // 空闲时降到 10MHz, 配合 light sleep 省电
    pmCfg.light_sleep_enable = true; // 核心: 空闲时真正进入 light sleep
    esp_err_t pmErr = esp_pm_configure(&pmCfg);
    Serial.printf("[PM] esp_pm_configure() = %d (0=ok)\n", (int)pmErr);
  }

  // 开机保护: 先禁止 light sleep 几秒, 给 USB 枚举 + 串口日志留出稳定窗口
  // (见上方 bootGraceLock 注释), 之后在 loop() 里到点自动释放。
  esp_pm_lock_create(ESP_PM_NO_LIGHT_SLEEP, 0, "boot_usb_grace", &bootGraceLock);
  esp_pm_lock_acquire(bootGraceLock);
  bootGraceHeld = true;
  bootGraceEndMs = millis() + BOOT_USB_GRACE_MS;

  // 按键: 内部上拉, 按下拉低; 改用变化中断唤醒(见 buttonIsr), 不再靠轮询。
  mainTaskHandle = xTaskGetCurrentTaskHandle(); // setup()/loop() 跑在同一个 Arduino 任务里
  for (auto &b : buttons) {
    pinMode(b.pin, INPUT_PULLUP);
    attachInterrupt(digitalPinToInterrupt(b.pin), buttonIsr, CHANGE);
  }

  // LED: 配置硬件 LEDC PWM(见上方 "LED 配置" 注释), 初始全灭、不占用 PM 锁。
  ledcSetup();

  setupBle();
  Serial.println("[BOOT] setup() complete, entering loop()");

  uint32_t bootNow = millis();
  nextBlinkToggleMs = bootNow + BLINK_PERIOD_MS / 2;
  nextChaseStepMs = bootNow + CHASE_STEP_MS;
  applyLedOutputs(); // 初始状态(全灭)应用一次
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

void applyLedOutputs() {
  // ---- 根据当前效果模式, 决定每颗 LED 此刻"是否允许参与下面的分时复用窗口" ----
  // 注意: 这里只决定"允许/不允许", 从不跳过分时窗口直接常通,
  // 所以无论哪种模式, 三颗 LED 任意时刻最多只有一颗导通, 互不叠加电流。
  bool wantOn[3] = {false, false, false};
  switch (ledMode) {
    case LED_MODE_OFF:
      // 全灭, wantOn 保持全 false
      break;
    case LED_MODE_BLINK:
      for (uint8_t i = 0; i < 3; i++) wantOn[i] = ledEnabled[i] && blinkPhaseOn;
      break;
    case LED_MODE_CHASE:
      wantOn[chaseIndex] = true; // 忽略 mask, 依次只点亮一颗
      break;
    case LED_MODE_STATIC:
    default:
      for (uint8_t i = 0; i < 3; i++) wantOn[i] = ledEnabled[i];
      break;
  }

  uint8_t onCount = 0;
  for (uint8_t i = 0; i < 3; i++) if (wantOn[i]) onCount++;

  // ---- 省电关键优化: 同一时刻最多只有 0/1 颗 LED 要求亮起时(这是最常见的使用场景
  //      ——三颗灯分别展示不同功能状态, 基本不会两颗同时亮), 根本不需要分时复用,
  //      直接让那一颗的 duty = 满量程(100%, hpoint=0), 波形变成"恒定电平、没有
  //      任何跳变沿", 即使 light sleep 期间 LEDC 定时器被冻结在任意位置,
  //      输出电平本身也不会变(因为从头到尾都是同一个电平), 所以这种情况下
  //      完全不需要持有 ledNoSleepLock, CPU 依然可以深度休眠。
  //      只有真正 2 颗或 3 颗 LED 同时要求亮起时, 才会用到会产生跳变沿的
  //      分时复用窗口, 此时才需要用锁阻止 light sleep(否则波形会冻结在
  //      某次跳变中间, 导致灯卡亮/卡灭看起来不对)。----
  bool anyOn = false;
  if (onCount <= 1) {
    for (uint8_t i = 0; i < 3; i++) {
      bool on = wantOn[i];
      ledc_set_duty_with_hpoint(LED_SPEED_MODE, LED_CHANNELS[i], on ? LED_DUTY_FULL : 0, 0);
      ledc_update_duty(LED_SPEED_MODE, LED_CHANNELS[i]);
    }
    anyOn = false; // 恒定电平, 不需要禁止 light sleep
  } else {
    // ---- 硬件分时复用窗口: 一帧 = LED_DUTY_FULL(8192) 个 tick, 三颗灯按各自
    //      ledAllocPercent[] 分到一段首尾相接、互不重叠的专属导通窗口(duty+hpoint),
    //      剩余部分(如果总和 <100)留作帧尾全灭间隔。配置好以后由 LEDC 硬件自动
    //      循环输出, CPU 不用再管, 这是这次省电改动的核心。----
    uint32_t width[3];
    for (uint8_t i = 0; i < 3; i++) {
      width[i] = LED_DUTY_FULL * (uint32_t)ledAllocPercent[i] / 100;
    }
    uint32_t slotStart[3] = {0, width[0], width[0] + width[1]};

    for (uint8_t i = 0; i < 3; i++) {
      bool on = wantOn[i] && width[i] > 0;
      uint32_t duty = on ? width[i] : 0;
      uint32_t hpoint = on ? slotStart[i] : 0;
      ledc_set_duty_with_hpoint(LED_SPEED_MODE, LED_CHANNELS[i], duty, hpoint);
      ledc_update_duty(LED_SPEED_MODE, LED_CHANNELS[i]);
      anyOn = anyOn || on;
    }
  }

  // ---- PM 锁: 只有"2 颗以上 LED 同时亮"(真正用到会跳变的分时复用窗口)才需要
  //      阻止 light sleep; 0 或 1 颗亮时用的是恒定电平, 不受影响。----
  if (anyOn && !ledLockHeld) {
    esp_pm_lock_acquire(ledNoSleepLock);
    ledLockHeld = true;
  } else if (!anyOn && ledLockHeld) {
    esp_pm_lock_release(ledNoSleepLock);
    ledLockHeld = false;
  }
}

// 广播看门狗: 定期兜底检查, 只要连接数还没到上限但当前又没在广播(例如某次异常
// 导致广播意外停掉, 而 onConnect/onDisconnect 都没能触发重新广播), 就主动补一次,
// 避免出现"怎么都搜不到设备"的死锁状态。
uint32_t lastAdvCheckMs = 0;
const uint32_t ADV_CHECK_INTERVAL_MS = 2000;

void ensureAdvertising() {
  uint32_t now = millis();
  if (now - lastAdvCheckMs < ADV_CHECK_INTERVAL_MS) return;
  lastAdvCheckMs = now;
  if (!pServer) return;
  if (pServer->getConnectedCount() < MAX_DESIRED_CONNECTIONS && !NimBLEDevice::getAdvertising()->isAdvertising()) {
    Serial.println("[BLE] watchdog: not advertising but slots available, restarting advertising");
    NimBLEDevice::startAdvertising();
  }
}

void loop() {
  scanButtons();
  handleUnbondCombo();
  ensureAdvertising();

  uint32_t now = millis();

  // 开机保护锁到点自动释放(见 bootGraceLock 注释)
  if (bootGraceHeld && (int32_t)(now - bootGraceEndMs) >= 0) {
    esp_pm_lock_release(bootGraceLock);
    bootGraceHeld = false;
  }

  // ---- 闪烁/流水灯的"宏观步进"改成到点才触发一次 applyLedOutputs(),
  //      不再是每次 loop() 都无条件重算一遍。----
  if (ledMode == LED_MODE_BLINK && (int32_t)(now - nextBlinkToggleMs) >= 0) {
    blinkPhaseOn = !blinkPhaseOn;
    nextBlinkToggleMs = now + BLINK_PERIOD_MS / 2;
    applyLedOutputs();
  }
  if (ledMode == LED_MODE_CHASE && (int32_t)(now - nextChaseStepMs) >= 0) {
    chaseIndex = (chaseIndex + 1) % 3;
    nextChaseStepMs = now + CHASE_STEP_MS;
    applyLedOutputs();
  }

  if (now - lastBatteryReportMs >= BATTERY_REPORT_INTERVAL_MS) {
    lastBatteryReportMs = now;
    updateBatteryReading();
  }

  // ---- 省电核心: 不再固定 delay(1), 而是算出"下一件必须要做的事还有多久",
  //      只睡那么久, 用 ulTaskNotifyTake() 代替 delay() —— 这样按键中断可以
  //      随时提前把它叫醒, 没有事件发生时 CPU 能真正进入 light sleep 直到
  //      下一个预定截止时间(最长受限于 ADV_CHECK_INTERVAL_MS=2000ms)。----
  uint32_t nextDeadline = now + ADV_CHECK_INTERVAL_MS; // 兜底上限

  if (bootGraceHeld && (int32_t)(bootGraceEndMs - nextDeadline) < 0) {
    nextDeadline = bootGraceEndMs;
  }

  for (auto &b : buttons) {
    if (b.lastRaw != b.lastStable) {
      uint32_t deadline = b.lastChangeMs + DEBOUNCE_MS;
      if ((int32_t)(deadline - nextDeadline) < 0) nextDeadline = deadline;
    }
  }
  if (ledMode == LED_MODE_BLINK && (int32_t)(nextBlinkToggleMs - nextDeadline) < 0) {
    nextDeadline = nextBlinkToggleMs;
  }
  if (ledMode == LED_MODE_CHASE && (int32_t)(nextChaseStepMs - nextDeadline) < 0) {
    nextDeadline = nextChaseStepMs;
  }
  {
    uint32_t battDeadline = lastBatteryReportMs + BATTERY_REPORT_INTERVAL_MS;
    if ((int32_t)(battDeadline - nextDeadline) < 0) nextDeadline = battDeadline;
  }
  {
    uint32_t advDeadline = lastAdvCheckMs + ADV_CHECK_INTERVAL_MS;
    if ((int32_t)(advDeadline - nextDeadline) < 0) nextDeadline = advDeadline;
  }
  if (comboHolding && !comboTriggered) {
    uint32_t comboDeadline = comboHoldStartMs + UNBOND_HOLD_MS;
    if ((int32_t)(comboDeadline - nextDeadline) < 0) nextDeadline = comboDeadline;
  }

  int32_t sleepMs = (int32_t)(nextDeadline - now);
  if (sleepMs < 1) sleepMs = 1; // 至少让出一次, 避免死循环占满 CPU
  ulTaskNotifyTake(pdTRUE, pdMS_TO_TICKS((uint32_t)sleepMs));
}
