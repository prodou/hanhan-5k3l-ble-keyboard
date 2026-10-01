// ============================================================
// HanHan 5K3L — 25mm立方体 外壳 + 载板 参数化设计 (v2: 按键放大占满22x22)
// 对应 firmware/esp32c3_5btn_3led_ble
//   5键: GPIO0/1/3/4/10 (上下左右+中)
//   3灯: GPIO2/6/7 (共用限流电阻, 分时复用)
//
// v2改动:
//   - 十字按键整体放大, 占满面板22x22可用区域(之前是缩在一角的小按键)
//   - 新增"按键帽(cap)"零件: 面板开大孔(手指目标更大), cap背面有个小顶杆
//     精确顶在实际贴片按键(很小)的中心上, 兼顾手感和实际器件尺寸
//   - LED改放在十字按键中间的空隙里, 不用再单独占一排位置,
//     也不要求和光源精确对孔, 能透光看到亮点就行
//
// 用法:
//   1. 用 OpenSCAD (https://openscad.org) 打开本文件
//   2. 实测你买的贴片按键尺寸/厚度, 改 key_pocket_w / key_pocket_h / actuator_d
//      实测 ESP32-C3-Super-Mini 外形, 改 esp32_w/esp32_l/esp32_t
//      实测 面板到载板到按键顶部的装配间隙, 改 nub_h (这个最关键, 决定手感)
//   3. 顶部 part_to_render 切换要导出的零件, 然后 File > Export > STL
//      cap只需导出一次, 实际打印时在切片软件里阵列复制5个
//
// 建议打印方式: 树脂(SLA/DLP), 孔位/间距在2-7mm级别, FDM精度/公差不够。
// ============================================================

// ====可调参数====
cube_size      = 25;     // 立方体外形边长
wall           = 1.5;    // 外壳壁厚
panel_t        = wall;   // 前面板厚度(与外壳一体打印时=wall)
panel_area     = cube_size - 2*wall; // 面板内侧可用区域(=22, 四壁各留wall厚)

// 按键区(十字布局, 缩小一点, 给顶部LED一排腾出空间)
key_cap_d      = 4.1;    // 面板外露"按键帽"直径(手指按压目标, 比v2缩小)
key_hole_d     = 4.5;    // 面板按键过孔直径(配合cap, 留0.4mm装配间隙)
key_pitch      = 5.5;    // 十字按键中心间距
key_cross_cy   = -1.7;   // 十字整体向下偏移(相对面板中心), 给顶部LED一排留空间
key_pocket_w   = 4.6;    // 载板上实际贴片按键本体方形卡槽边长(按真实器件尺寸! 不是cap尺寸)
key_pocket_h   = 1.2;    // 卡槽深度(贴片按键本体厚度, 实测后调整)
actuator_d     = 2.2;    // 载板上贯穿孔径, 给cap的顶杆穿过去压实际按键的小触点

// 按键帽(cap, 单独打印, 装进面板孔里, 背面顶杆对准载板下面的实际按键)
cap_t          = 1.6;    // cap本体厚度(含帽檐)
cap_rim_d      = key_hole_d - 0.4;  // cap外径(略小于面板孔, 留滑动间隙)
nub_d          = 1.8;    // cap背面顶杆直径(需比actuator_d略小, 可自由穿过)
nub_h          = 0.8;    // cap背面顶杆长度: = 面板厚+载板前空隙+(载板厚-key_pocket_h)
                          // 必须实测后调整, 太短按不到键, 太长会顶死按键常按状态!

// LED: 放回顶部一排(cap缩小后腾出的空间), 孔不用太大, 能看到光点就行
led_hole_d     = 3.0;    // 面板LED过孔
led_pitch      = 6.0;    // 三颗LED间距
led_row_cy     = 8.2;    // LED排相对面板中心的y偏移(正值=靠上)
led_positions  = [[-led_pitch,led_row_cy], [0,led_row_cy], [led_pitch,led_row_cy]];

// 载板(carrier plate, 单独打印, 贴在面板内侧)
carrier_w      = panel_area - 0.6;  // 载板宽(比面板可用区域小0.6mm装配间隙)
carrier_h      = panel_area - 0.6;  // 载板高
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
// "shell"    外壳主体(含前面板按键/LED孔+USB开口+内部支柱)
// "carrier"  载板(贴面板内侧, 卡住贴片按键)
// "back"     后盖
// "cap"      按键帽(打印1个, 切片软件里阵列复制5个)
// "assembly" 装配预览(半透明, 仅肉眼检查对齐, 不要用它导出STL)
part_to_render = "shell";

// ============================================================
module key_cross_positions(cx, cy) {
    // 十字: 上下左右 + 中心, 返回5个位置, 正中心对齐(cx,cy), 不再偏移
    positions = [
        [cx, cy + key_pitch],   // 上
        [cx, cy - key_pitch],   // 下
        [cx - key_pitch, cy],   // 左
        [cx + key_pitch, cy],   // 右
        [cx, cy]                // 中
    ];
    for (p = positions) translate(p) children();
}

module led_dots(cx, cy) {
    for (p = led_positions) translate([cx + p[0], cy + p[1]]) children();
}

// ---------------- 外壳主体 ----------------
module shell() {
    difference() {
        cube([cube_size, cube_size, cube_size]);

        // 内部挖空(前面板和四周留wall厚, 后面开口装后盖)
        translate([wall, wall, panel_t])
            cube([cube_size-2*wall, cube_size-2*wall, cube_size]);

        // 前面板按键过孔(放大, 占满panel_area, 居中对齐面板几何中心)
        key_cross_positions(cube_size/2, cube_size/2 + key_cross_cy)
            translate([0,0,-1]) cylinder(d=key_hole_d, h=panel_t+2, $fn=48);

        // LED过孔(十字间隙里)
        led_dots(cube_size/2, cube_size/2)
            translate([0,0,-1]) cylinder(d=led_hole_d, h=panel_t+2, $fn=24);

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
        // 卡住实际贴片按键本体, 尺寸=真实器件尺寸, 和放大的cap无关)
        key_cross_positions(carrier_w/2, carrier_h/2 + key_cross_cy)
            translate([-key_pocket_w/2, -key_pocket_w/2, carrier_t-key_pocket_h])
                cube([key_pocket_w, key_pocket_w, key_pocket_h+0.5]);

        // 对应每个按键中心的小贯穿孔(cap的顶杆从这里穿过去压实际按键触点)
        key_cross_positions(carrier_w/2, carrier_h/2 + key_cross_cy)
            cylinder(d=actuator_d, h=carrier_t+1, $fn=16);

        // LED孔(贯穿, 坐标直接复用led_positions, 和shell()里用法一致, 天然对齐)
        led_dots(carrier_w/2, carrier_h/2)
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

// ---------------- 按键帽(cap) ----------------
// 放大的手指按压目标, 装进面板的key_hole_d孔里可自由上下滑动,
// 背面的小顶杆(nub)穿过载板的actuator_d孔精确压住实际贴片按键的触点。
module cap() {
    union() {
        // 帽体(露在面板外面的大圆饼, 带一点弧度更好按, 这里简化成平的)
        cylinder(d=cap_rim_d, h=cap_t, $fn=48);
        // 背面顶杆
        translate([0,0,-nub_h])
            cylinder(d=nub_d, h=nub_h, $fn=24);
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
    // 5个cap摆在对应按键孔位置(z方向抬到面板外侧, 便于肉眼看位置)
    key_cross_positions(cube_size/2, cube_size/2 + key_cross_cy)
        translate([0,0,-cap_t]) color("yellow") cap();
}

// ============================================================
if (part_to_render == "shell") shell();
else if (part_to_render == "carrier") carrier();
else if (part_to_render == "back") back_cover();
else if (part_to_render == "cap") cap();
else if (part_to_render == "assembly") assembly_preview();
