#!/usr/bin/env python3
"""
HanHan 5K3L LED 效果测试脚本
----------------------------
通过 BLE 直接写自定义 LED 特征值, 测试三颗 LED 的几种效果模式。

协议(2 字节):
    byte0 = mask, bit0/1/2 分别对应 LED0(GPIO2)/LED1(GPIO6)/LED2(GPIO7) 是否参与显示
    byte1 = mode:
        0 = 全灭 (忽略 mask)
        1 = 常亮 (mask 选中的灯常亮显示, mask=0b111 即"三灯都亮")
        2 = 闪烁 (mask 选中的灯整体慢闪: 亮400ms / 灭400ms)
        3 = 流水灯 (忽略 mask, LED0->LED1->LED2->LED0 顺序点亮, 每步150ms)

    注意: 无论哪种模式, 固件内部都会用 10ms 一帧 / 每颗灯专属 3ms 导通窗口
    的硬件分时复用兜底, 保证任意一颗 LED 的占空比恒定 <=30%。

用法:
    pip install bleak
    python3 led_test.py off
    python3 led_test.py static 0b111        # 三灯都亮
    python3 led_test.py static 0b101        # LED0 和 LED2 亮
    python3 led_test.py blink 0b011         # LED0/LED1 一起慢闪
    python3 led_test.py chase                # 流水灯, mask 参数会被忽略
    python3 led_test.py calib 30 20 30       # 设置 LED0/1/2 亮度校准百分比(0~30)

本机(这台开发机)运行此脚本可能会因为没有 GUI/WindowServer 会话导致
CoreBluetooth 权限请求不出来("BLE is not authorized")。如果遇到这种情况,
请把本脚本拷到一台正常有图形界面登录的 Mac 上运行(例如你平时用来测试
HanHan Agent 的那台 Mac), 并在弹出的系统权限提示里允许蓝牙访问。
"""
import asyncio
import sys

from bleak import BleakClient, BleakScanner

DEVICE_NAME = "HanHan 5K3L v0.1"
LED_STATUS_CHAR_UUID = "6e400101-b5a3-f393-e0a9-e50e24dcca9e"
LED_CALIB_CHAR_UUID = "6e400102-b5a3-f393-e0a9-e50e24dcca9e"
MAX_DUTY_PERCENT = 30

MODE_OFF = 0
MODE_STATIC = 1
MODE_BLINK = 2
MODE_CHASE = 3


async def find_device(timeout: float = 8.0):
    print(f"[scan] 搜索 '{DEVICE_NAME}' ...")
    device = await BleakScanner.find_device_by_name(DEVICE_NAME, timeout=timeout)
    if device is None:
        print("[scan] 没找到设备, 请确认板子已上电广播、且没有被其他设备连着。")
        sys.exit(1)
    print(f"[scan] 找到: {device.address}")
    return device


async def send(mask: int, mode: int):
    device = await find_device()
    async with BleakClient(device) as client:
        payload = bytes([mask & 0xFF, mode & 0xFF])
        await client.write_gatt_char(LED_STATUS_CHAR_UUID, payload, response=False)
        print(f"[write] mask=0b{mask & 0xFF:08b} mode={mode} -> 已发送")
        await asyncio.sleep(1.0)  # 留点时间让写入真正生效/观察


async def send_calib(percents):
    clamped = [max(0, min(MAX_DUTY_PERCENT, p)) for p in percents]
    device = await find_device()
    async with BleakClient(device) as client:
        payload = bytes(clamped)
        await client.write_gatt_char(LED_CALIB_CHAR_UUID, payload, response=True)
        print(f"[write] 亮度校准 LED0/1/2 = {clamped} -> 已发送")
        await asyncio.sleep(1.0)


def parse_mask(arg: str) -> int:
    if arg.lower().startswith("0b"):
        return int(arg, 2)
    return int(arg, 0)


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    cmd = sys.argv[1].lower()
    if cmd == "off":
        asyncio.run(send(0, MODE_OFF))
    elif cmd == "static":
        mask = parse_mask(sys.argv[2]) if len(sys.argv) > 2 else 0b111
        asyncio.run(send(mask, MODE_STATIC))
    elif cmd == "blink":
        mask = parse_mask(sys.argv[2]) if len(sys.argv) > 2 else 0b111
        asyncio.run(send(mask, MODE_BLINK))
    elif cmd == "chase":
        asyncio.run(send(0b111, MODE_CHASE))
    elif cmd == "calib":
        if len(sys.argv) < 5:
            print("用法: python3 led_test.py calib <led0> <led1> <led2>  (每个 0~30)")
            sys.exit(1)
        percents = [int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])]
        asyncio.run(send_calib(percents))
    else:
        print(f"未知命令: {cmd}")
        print(__doc__)
        sys.exit(1)


if __name__ == "__main__":
    main()
