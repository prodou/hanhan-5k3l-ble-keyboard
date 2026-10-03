# HanHan 5K3L — ESP32-C3 蓝牙五键三灯 + HanHan Agent

## 项目组成

- `firmware/esp32c3_5btn_3led_ble/` — ESP32-C3 固件(Arduino + NimBLE-Arduino)
  - 5 个按键(GPIO0/1/3/4/10)→ BLE HID 键盘, 发送 F13~F17
  - 3 个 LED(GPIO2/6/7, 共用一颗限流电阻)→ 独立的自定义 BLE GATT 特征值控制,
    支持常亮/闪烁/流水灯几种效果模式(见下方"LED 效果协议"), 硬件层固定
    10ms 一帧、每颗灯专属 3ms 导通窗口, **任意模式下单颗 LED 占空比恒定 <=30%**,
    且任意时刻最多一颗导通, 避免共用限流电阻叠加电流; 另支持每颗灯独立的
    亮度校准(0~30%), 用于抵消不同颜色 LED 正向压降不同导致的肉眼亮度差异
  - 启用 BLE 绑定(bonding), 支持断开自动重连; 同时支持**两条并发 BLE 连接**
    (例如手机/电脑当 HID 键盘用的同时, HanHan Agent 再单独连一条做 LED 控制),
    并带有广播看门狗兜底, 避免意外情况下"怎么都搜不到设备"
  - **同时长按 GPIO0 + GPIO1 五秒** → 断开当前连接并清空所有绑定记录, 方便换设备配对
- `HanHanAgent/` — macOS 菜单栏小工具(Swift)
  - 全局拦截来自本设备的 F13~F17 按键(不会传到当前聚焦的窗口)
  - 背景转发(不切换焦点)到用户在菜单里选定的目标 App
  - 菜单内置"LED 控制"(效果预设)和"亮度校准"(每颗灯单独 +5%/-5%/重置, 自动
    持久化到本地并在每次重连时自动下发给固件)
- `tools/led_test.py` — 独立的 LED 效果测试脚本(需要 `pip install bleak`,
  且运行环境要有正常的图形登录会话以便弹出蓝牙权限提示)

## LED 效果协议

自定义 Service UUID: `6E400100-...`, 下属两个 Characteristic:

### 效果特征值 `6E400101-...`(mask + mode, 2 字节)

| byte0 (mask)                  | byte1 (mode) | 效果 |
|--------------------------------|--------------|------|
| bit0/1/2 = LED0/1/2 是否参与   | 0            | 全灭(忽略 mask) |
|                                 | 1            | 常亮(mask 选中的灯常亮, `0b111` = 三灯都亮) |
|                                 | 2            | 闪烁(mask 选中的灯一起慢闪: 亮400ms/灭400ms) |
|                                 | 3            | 流水灯(忽略 mask, LED0→LED1→LED2 依次点亮, 每步150ms) |

只写 1 个字节时视为旧协议, 自动当作 `mode=1`(常亮)处理。

### 亮度校准特征值 `6E400102-...`(3 字节, 可写可读)

`byte[i]` = LED`i` 的占空比百分比, 范围 0~30(固件会自动夹到 30 以内),
用于在共用限流电阻的前提下, 单独调低偏亮的那颗灯, 使三颗灯观感亮度接近一致。
默认全部为 30(即原始最大占空)。HanHan Agent 会把每次调整后的值持久化并在
每次重连成功后自动重新下发一遍(固件重启后这个状态会丢失, 需要重新下发)。

> **⚠️ 踩坑记录**: 固件每次新增/修改 BLE 特征值(Characteristic)后, macOS 可能会
> 沿用之前连接缓存的旧 GATT 服务列表, 导致 App 发现不到新加的特征值(表现为:
> App 显示"已连接", 但写入新特征值毫无效果)。解决方法: 系统设置 -> 蓝牙 里把
> "HanHan 5K3L v0.1" 这个设备**移除/忽略**掉, 完全退出并重新打开 HanHan Agent
> 让它重新扫描连接一次, 缓存就会刷新。以后固件 GATT 结构有变化时都建议先这么做一遍。

测试示例:

```bash
pip install bleak
python3 tools/led_test.py static 0b111   # 三灯都亮
python3 tools/led_test.py blink 0b011    # LED0/LED1 一起慢闪
python3 tools/led_test.py chase          # 流水灯
python3 tools/led_test.py off            # 全灭
```

## 固件编译/烧录

需要先安装 `arduino-cli`、ESP32 开发板支持包(`esp32:esp32`)、`NimBLE-Arduino` 库。

```bash
arduino-cli compile --fqbn esp32:esp32:esp32c3:CDCOnBoot=cdc \
  firmware/esp32c3_5btn_3led_ble --output-dir build_out

arduino-cli upload -p /dev/cu.usbmodemXXXX \
  --fqbn esp32:esp32:esp32c3:CDCOnBoot=cdc \
  -i build_out/esp32c3_5btn_3led_ble.ino.bin \
  firmware/esp32c3_5btn_3led_ble
```

烧录前需要先按住 BOOT、再按一下 RESET、再松开 BOOT 进入下载模式
(部分板子插上 USB 会自动进入, 视板子而定)。

## HanHan Agent 安装 / 使用

1. 到 [Releases](../../releases) 下载最新的 `HanHanAgent.zip`, 解压后得到 `HanHan Agent.app`。
2. 拖到 `~/Applications` 或 `/Applications`, 双击打开(首次因为是临时签名, 需要右键 →
   打开 → 确认允许运行)。
3. 打开后会在菜单栏出现 "HH" 图标。第一次运行会请求"辅助功能"权限 ——
   去 **系统设置 → 隐私与安全性 → 辅助功能**, 勾选 "HanHan Agent"
   (没有这个权限完全收不到按键)。
4. 点菜单栏 "HH" 图标, 下拉列表会显示当前运行中的 App, 选择你要接收按键的目标。
5. 按板子上的按键, F13~F17 会被拦截并"背景注入"到选定的目标 App, 不会影响你当前正在
   操作的窗口。

也可以自己从源码编译:

```bash
cd HanHanAgent
./build.sh
open "build/HanHan Agent.app"
```
