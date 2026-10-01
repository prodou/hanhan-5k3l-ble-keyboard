// ============================================================
// HanHan 5K3L — 25mm立方体 外壳 + 载板 参数化设计
// 对应 firmware/esp32c3_5btn_3led_ble
//   5键: GPIO0/1/3/4/10 (上下左右+中)
//   3灯: GPIO2/6/7 (共用限流电阻, 分时复用)
//
// 用法:
//   1. 用 OpenSCAD (https://openscad.org 免费, 直接下载dmg安装, 不走brew)打开本文件
//   2. 按需修改下面"====可调参数===="区域(务必先用卡尺实测你买到的
//      贴片按键尺寸, 和ESP32-C3-Super-Mini的实际外形再改!)
//   3. 顶部 part_to_render 切换要导出的零件, 然后 File > Export > STL
//
// 建议打印方式: 树脂(SLA/DLP)打印, 因为孔位/间距都在3-7mm级别,
// FDM(熔丝)在这个尺寸下公差和开孔精度不够, 按键容易卡死或晃动。
// ============================================================

// ====可调参数====
cube_size      = 25;     // 立方体外形边长
wall           = 1.5;    // 外壳壁厚
panel_t        = wall;   // 前面板厚度(与外壳一体打印时=wall)

// 按键区(十字布局)
key_hole_d     = 4.0;    // 面板按键过孔直径(按键帽/actuator露出的孔, 实测后调整)
key_pocket_w   = 4.6;    // 载板上按键本体方形卡槽边长(按实际SMD按键外壌+0.2mm公差)
key_pocket_h   = 1.2;    // 卡槽深度(按键本体厚度, 实测后调整)
key_pitch      = 7.0;    // 十字按键中心间距

// LED区
led_hole_d     = 3.2;    // 面板LED过孔直径(3mm LED留0.2mm装配间隙)
led_pitch      = 6.0;    // 三颗LED间距
led_row_y      = cube_size - 5; // LED排所在y坐标(顶部往下5mm)

// 载板(carrier plate, 单独打印, 贴在面板内侧)
carrier_w      = 20;     // 载板宽
carrier_h      = 20;     // 载板高
carrier_t      = 1.6;    // 载板厚度
carrier_peg_d  = 1.6;    // 载板定位柱直径(对应外壳内侧定位孔)
wire_slot_w    = 3;      // 载板边缘走线缺口宽度(5键+3灯共8根线从此出)
wire_slot_h    = 2;

// 外壳内部: ESP32-C3-Super-Mini 实际尺寸(务必实测修改!)
esp32_w        = 18.0;
esp32_l        = 22.5;
esp32_t        = 4.0;    // 含USB-C插座/天线最高点
usb_slot_w     = 9.5;    // USB-C开口宽(留根据板子USB口位置修改X/Z偏移)
usb_slot_h     = 3.6;

// 后盖螺丝柱
screw_hole_d   = 1.8;    // 自攻螺丝过孔(配M2自攻螺丝)
boss_d         = 4.0;

// ====选择要渲染/导出的零件====
// "shell"   外壳主体(含前面板按键/LED孔+USB开口+内部支柱)
// "carrier" 载板(贴面板内侧, 卡住贴片按键)
// "back"    后盖
// "assembly" 三件装配预览(半透明外壳+载板+后盖, 仅用来肉眼检查对齐, 不要用它导出STL)
part_to_render = "shell";

// ============================================================
module key_cross_positions(cx, cy) {
    // 十字: 上下左右 + 中心, 返回5个位置
    positions = [
        [cx, cy + key_pitch],   // 上
        [cx, cy - key_pitch],   // 下
        [cx - key_pitch, cy],   // 左
        [cx + key_pitch, cy],   // 右
        [cx, cy]                // 中
    ];
    for (p = positions) translate(p) children();
}

module led_positions(cy) {
    cx = cube_size/2;
    for (i = [-1,0,1])
        translate([cx + i*led_pitch, cy]) children();
}

// ---------------- 外壳主体 ----------------
module shell() {
    difference() {
        cube([cube_size, cube_size, cube_size]);

        // 内部挖空(前面板和四周留wall厚, 后面开口装后盖)
        translate([wall, wall, panel_t])
            cube([cube_size-2*wall, cube_size-2*wall, cube_size]);

        // 前面板按键过孔(z方向贯穿前面板, 前面板是z=0那一面)
        key_cross_positions(cube_size/2, cube_size/2 - 3)
            translate([0,0,-1]) cylinder(d=key_hole_d, h=panel_t+2, $fn=32);

        // LED过孔
        led_positions(led_row_y)
            translate([0,0,-1]) cylinder(d=led_hole_d, h=panel_t+2, $fn=32);

        // 侧面USB-C开口(假设开在x=0这一侧墙, 靠后部, 按实际ESP32位置调整y/z)
        translate([-1, (cube_size-usb_slot_w)/2, cube_size-esp32_t-3])
            cube([wall+2, usb_slot_w, usb_slot_h]);
    }

    // 内部载板定位柱(4个角, 对应carrier_peg_d孔, 贴着前面板内侧)
    // 注意: carrier()以自身左下角为原点, 实际贴装时需 translate 到
    // (cube_size/2-carrier_w/2, cube_size/2-carrier_h/2, panel_t)
    // 这样carrier本地的按键/LED孔才会和下面shell挖的孔完全对齐
    peg_h = 1.0;
    for (dx = [-1,1]) for (dy = [-1,1])
        translate([cube_size/2 + dx*(carrier_w/2-1.5),
                    cube_size/2 + dy*(carrier_h/2-1.5),
                    panel_t])
            cylinder(d=carrier_peg_d-0.2, h=peg_h, $fn=16);

    // 后盖螺丝柱(四角, 内壁上)
    for (dx = [1,-1]) for (dy=[1,-1])
        translate([cube_size/2 + dx*(cube_size/2-3),
                    cube_size/2 + dy*(cube_size/2-3),
                    panel_t])
            difference(){
                cylinder(d=boss_d, h=cube_size-panel_t-wall, $fn=24);
                translate([0,0,-1]) cylinder(d=screw_hole_d, h=cube_size, $fn=16);
            }

    // ESP32支撑台阶(简单的两条导轨, 贴近后部, 具体位置按板子定)
    translate([wall, cube_size/2-esp32_w/2, cube_size-wall-1])
        cube([cube_size-2*wall, esp32_w, 1]);
}

// ---------------- 载板(贴片按键固定件) ----------------
module carrier() {
    difference() {
        cube([carrier_w, carrier_h, carrier_t]);

        // 按键方形卡槽(从背面向正面挖, 只挖carrier_t的下半部分当卡槽,
        // 让按键actuator能从正面pocket底部的小孔露出去顶住面板)
        key_cross_positions(carrier_w/2, carrier_h/2 - 3)
            translate([-key_pocket_w/2, -key_pocket_w/2, carrier_t-key_pocket_h])
                cube([key_pocket_w, key_pocket_w, key_pocket_h+0.5]);

        // 对应每个按键中心贯穿孔(按键actuator从这里顶出去压面板)
        key_cross_positions(carrier_w/2, carrier_h/2 - 3)
            cylinder(d=key_hole_d-0.5, h=carrier_t+1, $fn=24);

        // LED孔(贯穿, 坐标换算到与shell()里led_row_y全局对齐)
        led_local_y = led_row_y - (cube_size-carrier_h)/2;
        for (i=[-1,0,1])
            translate([carrier_w/2 + i*led_pitch, led_local_y, 0])
                cylinder(d=led_hole_d, h=carrier_t+1, $fn=24);

        // 四角定位孔
        for (dx=[-1,1]) for (dy=[-1,1])
            translate([carrier_w/2+dx*(carrier_w/2-1.5),
                        carrier_h/2+dy*(carrier_h/2-1.5),0])
                cylinder(d=carrier_peg_d, h=carrier_t+1, $fn=16);

        // 边缘走线缺口(让8根引线从载板侧边引出到ESP32)
        translate([carrier_w/2-wire_slot_w/2, -1, carrier_t-wire_slot_h])
            cube([wire_slot_w, 3, wire_slot_h+1]);
    }
}

// ---------------- 后盖 ----------------
module back_cover() {
    difference() {
        cube([cube_size-0.3, cube_size-0.3, wall]);
        for (dx = [1,-1]) for (dy=[1,-1])
            translate([cube_size/2 + dx*(cube_size/2-3),
                        cube_size/2 + dy*(cube_size/2-3), -1])
                cylinder(d=screw_hole_d+0.3, h=wall+2, $fn=16);
    }
}

// ---------------- 装配预览(仅用于检查对齐, 不导出STL) ----------------
module assembly_preview() {
    color("gray", 0.3) shell();
    translate([cube_size/2-carrier_w/2, cube_size/2-carrier_h/2, panel_t])
        color("orange") carrier();
    translate([0.15, 0.15, cube_size-wall])
        color("lightblue") back_cover();
}

// ============================================================
if (part_to_render == "shell") shell();
else if (part_to_render == "carrier") carrier();
else if (part_to_render == "back") back_cover();
else if (part_to_render == "assembly") assembly_preview();
