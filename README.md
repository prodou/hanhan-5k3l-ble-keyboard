# HanHan 5K3L — ESP32-C3 蓝牙五键三灯 + HanHan Agent

## 项目组成

- `firmware/esp32c3_5btn_3led_ble/` — ESP32-C3 固件(Arduino + NimBLE-Arduino)
  - 5 个按键(GPIO0/1/3/4/10)→ BLE HID 键盘, 发送 F13~F17
  - 3 个 LED(GPIO2/6/7, 共用一颗限流电阻)→ 独立的自定义 BLE GATT 特征值控制,
    按 3ms 亮 / 6ms 灭 时分复用, 避免同时点亮
  - 启用 BLE 绑定(bonding), 支持断开自动重连
  - **同时长按 GPIO0 + GPIO1 五秒** → 断开当前连接并清空所有绑定记录, 方便换设备配对
- `HanHanAgent/` — macOS 菜单栏小工具(Swift)
  - 全局拦截来自本设备的 F13~F17 按键(不会传到当前聚焦的窗口)
  - 背景转发(不切换焦点)到用户在菜单里选定的目标 App

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
