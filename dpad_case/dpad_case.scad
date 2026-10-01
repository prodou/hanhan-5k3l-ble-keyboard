// ============================================================
// HanHan 5K3L — 25mm立方体 外壳 + 载板 参数化设计 (v6: 台阶卡槽+转向+新增盖板, 根据实打样反馈重做)
// 对应 firmware/esp32c3_5btn_3led_ble
//   5键: GPIO0/1/3/4/10 (上下左右+中)
//   3灯: GPIO2/6/7 (共用限流电阻, 分时复用)
//
// v2改动: 十字按键放大占满22x22; 新增cap零件(面板大孔+小顶杆压实际按键); LED放到十字间隙里
// v3改动: LED改回一排放在面板顶部; cap/面板孔缩小, 露出LED光线; 十字整体下移腾出LED排空间
// v4改动: 根据实拍datasheet量到的真实贴片按键尺寸(3.3x3.4x1.5mm本体,
//   引脚左右伸出共4.0mm, 2mm按压圆点), 重做载板卡槽
// v5改动: 左右按键转90度(引脚变竖直), 同排三键从"引脚对引脚"变"本体对本体",
//   腾出空间加大焊接预留; 每按键独立卡槽+两个过线孔
// v6改动(本次, 根据打样实测反馈):
//   - 卡槽改"台阶"结构: 实测发现引脚/焊点比本体底面低一截, 原来整槽同一深度
//     会被引脚先顶住导致本体扣不到位; 现在中间本体部分挖浅台阶(窄边收紧到
//     刚好放入的尺寸), 两端引脚区域直接挖穿到背面(legs可以自由沉下去不受阻挡,
//     这段开孔本身兼做过线通道, 去掉了v5里单独打的过线孔)
//   - 新增第5个零件 retainer(盖板): 贴在载板背面(靠电池那侧), 上面只开小孔走线,
//     把按键夹在载板和盖板之间防止移动/被顶出来; 靠4个定位柱插入载板定位孔背面
//     那一截(和shell的定位柱从两头分别顶住载板, 互不冲突)
//   - cap背面顶杆暂不加凸点, 靠retainer整体压住按键更简单可靠
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

// 实际贴片按键尺寸(来自实拍图实测: 3*3*1.5, 4脚左右两边伸出共4.0mm, 按压圆点约2mm)
button_body_x  = 3.3;    // 本体宽度(不含引脚, 引脚伸出方向)
button_leg_x   = 4.0;    // 含引脚方向的总跨度(引脚两边各伸出0.35mm)
button_body_y  = 3.4;    // 本体宽度(垂直引脚方向)
button_h       = 1.5;    // 按键总高度(贴装面到静止顶部)
button_dome_d  = 2.0;    // 按压圆点直径
actuator_d     = 2.3;    // 载板上贯穿孔径(对准2mm圆点, 留0.3mm余量), cap顶杆由此穿过去压键

// v6: 卡槽改成"台阶"结构 —— 实测发现引脚(焊点)比本体底面低一截,
// 之前整个卡槽挖成同一个深度, 导致引脚/焊点先触底, 把本体顶起来扣不到位。
// 现在中间本体部分挖成浅一点的台阶(刚好卡住本体, 窄边收紧到贴合尺寸),
// 两端引脚区域直接挖穿到载板背面(没有底, 引脚和焊点可以自由沉下去不受阻挡,
// 同时这段开孔本身就是过线通道, 不再需要单独的过线孔), 焊线从背面绕到
// 新增的盖板(retainer)上开的小孔穿出去。
perp_margin    = 0.15;   // 窄边(垂直引脚方向)预留: 缩到刚好能放进去
leg_margin     = 0.7;    // 引脚方向焊接预留空间(超出引脚尖端, 单边), 留大一点方便焊接不短路
ledge_len      = button_body_x + 2*perp_margin;      // 中间本体台阶的长度(沿引脚方向)
ledge_depth    = button_h + 0.15;                    // 本体台阶深度(贴面板那面往下挖, 不挖穿)
pocket_perp_w  = button_body_y + 2*perp_margin;      // 台阶+两端引脚槽统一的宽度(垂直引脚方向)
leg_slot_len   = (button_leg_x - button_body_x)/2 + leg_margin; // 单侧引脚槽长度(挖穿到背面)

wire_groove_w  = 1.3;    // LED引脚走线槽宽(配合0.9mm硅胶线)
wire_groove_depth = 1.0; // 走线槽深度(比按键卡槽浅, 只需过线)

// 按键帽(cap, 单独打印, 装进面板孔里, 背面顶杆对准载板下面的实际按键)
cap_t          = 1.6;    // cap本体厚度(含帽檐)
cap_rim_d      = key_hole_d - 0.4;  // cap外径(略小于面板孔, 留滑动间隙)
nub_d          = 2.0;    // cap背面顶杆直径(对准2mm圆点, 比actuator_d略小可自由穿过)
nub_h          = 0.3;    // cap背面顶杆长度: 本设计面板+载板零间隙贴合,
                          // = 卡槽深度(pocket_depth) - 按键实际高度(button_h) + 一点预压量
                          // 理论值≈0.2mm, 这里给了0.3mm, 装配后太松/太紧都需要实测微调重新打印!

// LED: 放回顶部一排(cap缩小后腾出的空间), 孔不用太大, 能看到光点就行
led_hole_d     = 3.0;    // 面板LED过孔
led_pitch      = 6.0;    // 三颗LED间距
led_row_cy     = 8.2;    // LED排相对面板中心的y偏移(正值=靠上)
led_positions  = [[-led_pitch,led_row_cy], [0,led_row_cy], [led_pitch,led_row_cy]];

// 载板(carrier plate, 单独打印, 贴在面板内侧)
carrier_w      = panel_area - 0.6;  // 载板宽(比面板可用区域小0.6mm装配间隙)
carrier_h      = panel_area - 0.6;  // 载板高
carrier_t      = 2.2;    // 载板厚度(需 ≥ ledge_depth(1.65) + 0.4mm底板厚度)
carrier_peg_d  = 1.6;    // 载板定位柱直径(对应外壳内侧定位孔)

// 盖板(retainer, 新增第5个零件): 贴在载板背面(靠电池那一侧), 把按键夹在
// 载板和盖板之间防止移动/被顶出来; 盖板上只开小孔走引线, 不需要对应面板孔。
retainer_t       = 1.0;   // 盖板厚度
retainer_hole_d  = 1.0;   // 盖板上的过线孔径(对准每个按键两端的引脚槽, 刚好让单根0.9mm线穿过)
retainer_peg_d   = carrier_peg_d - 0.2; // 盖板定位柱直径(插入载板定位孔背面那一截)
retainer_peg_h   = 1.0;   // 盖板定位柱长度(载板定位孔总深carrier_t=2.2, 正面已被shell的peg占了1.0mm, 背面还剩1.2mm可插)
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
// "shell"     外壳主体(含前面板按键/LED孔+USB开口+内部支柱)
// "carrier"   载板(贴面板内侧, 卡住贴片按键)
// "retainer"  盖板(贴载板背面, 夹住按键防止移动, 打印1个)
// "back"      后盖
// "cap"       按键帽(打印1个, 切片软件里阵列复制5个)
// "assembly"  装配预览(半透明, 仅肉眼检查对齐, 不要用它导出STL)
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

// 单个按键的"台阶"卡槽(vertical=false: 引脚水平/沿x方向; true: 引脚转90度/沿y方向)
// 中间本体台阶=窄边收紧的浅坑(刚好卡住本体), 两端引脚区=挖穿到背面的深槽
// (legs变低不会把本体顶起来, 同时兼做过线通道, 焊线从背面绕到盖板的小孔穿出)
module key_pocket(cx, cy, vertical) {
    // 中间本体台阶(浅, 不挖穿)
    lx = vertical ? pocket_perp_w : ledge_len;
    ly = vertical ? ledge_len : pocket_perp_w;
    translate([cx-lx/2, cy-ly/2, carrier_t-ledge_depth])
        cube([lx, ly, ledge_depth+0.5]);

    // 两端引脚槽(挖穿到背面, 沿引脚方向各一段)
    off = vertical ? [0, ledge_len/2 + leg_slot_len/2] : [ledge_len/2 + leg_slot_len/2, 0];
    sx = vertical ? pocket_perp_w : leg_slot_len;
    sy = vertical ? leg_slot_len : pocket_perp_w;
    for (s=[-1,1])
        translate([cx+s*off[0]-sx/2, cy+s*off[1]-sy/2, 0])
            cube([sx, sy, carrier_t+0.5]);
}

// ---------------- 载板(贴片按键固定件) ----------------
// 5个按键各自独立开"台阶"卡槽, 上/下/中 三键引脚保持水平(H),
// 左/右 两键转90度变成引脚竖直(V) —— 这样同一排的左/中/右三键之间
// 就不再是"引脚对引脚"占满4.0mm宽度, 而是"本体对本体"只占3.4mm宽度,
// 省出来的空间正好用来加大 leg_margin, 让焊接/走线更宽松不容易短路。
module carrier() {
    cx = carrier_w/2;
    cy = carrier_h/2 + key_cross_cy;
    difference() {
        cube([carrier_w, carrier_h, carrier_t]);

        key_pocket(cx, cy+key_pitch, false);  // 上
        key_pocket(cx, cy-key_pitch, false);  // 下
        key_pocket(cx-key_pitch, cy, true);   // 左(转90度)
        key_pocket(cx+key_pitch, cy, true);   // 右(转90度)
        key_pocket(cx, cy, false);            // 中(OK)

        // 5个按键中心的顶杆贯穿孔(对准实际按键的2mm圆点, 按键是圆形触点不受朝向影响)
        key_cross_positions(cx, cy)
            cylinder(d=actuator_d, h=carrier_t+1, $fn=16);

        // LED孔(贯穿)+ 一条水平走线槽方便LED引脚/导线引出
        led_dots(carrier_w/2, carrier_h/2)
            cylinder(d=led_hole_d, h=carrier_t+1, $fn=24);
        translate([0, carrier_h/2+led_row_cy-wire_groove_w/2, carrier_t-wire_groove_depth])
            cube([carrier_w, wire_groove_w, wire_groove_depth+0.5]);

        // 四角定位孔(背面留给retainer的定位柱插入, 正面留给shell的定位柱插入)
        for (dx=[-1,1]) for (dy=[-1,1])
            translate([carrier_w/2+dx*(carrier_w/2-1.5),
                        carrier_h/2+dy*(carrier_h/2-1.5),0])
                cylinder(d=carrier_peg_d, h=carrier_t+1, $fn=16);
    }
}

// ---------------- 盖板(retainer, 贴在载板背面, 夹住按键防止移动) ----------------
// 整块实心板(比载板稍大一圈更好压住边缘), 只在每个按键两端引脚槽对应位置
// 开小孔走线, 中间按键本体台阶部分完全被挡住(不需要开孔, 台阶本身已经封底)。
module retainer() {
    cx = carrier_w/2;
    cy = carrier_h/2 + key_cross_cy;
    positions_oriented = [
        [cx, cy+key_pitch, false],  // 上
        [cx, cy-key_pitch, false],  // 下
        [cx-key_pitch, cy, true],   // 左
        [cx+key_pitch, cy, true],   // 右
        [cx, cy, false]             // 中
    ];
    difference() {
        cube([carrier_w, carrier_h, retainer_t]);

        for (p = positions_oriented) {
            bx = p[0]; by = p[1]; vertical = p[2];
            off = vertical ? [0, ledge_len/2 + leg_slot_len/2]
                           : [ledge_len/2 + leg_slot_len/2, 0];
            for (s=[-1,1])
                translate([bx+s*off[0], by+s*off[1], -1])
                    cylinder(d=retainer_hole_d, h=retainer_t+2, $fn=16);
        }
    }
    // 四角定位柱(从盖板正面往上凸, 插入载板定位孔背面那一截, 和shell的定位柱分别从两头顶住载板)
    for (dx=[-1,1]) for (dy=[-1,1])
        translate([carrier_w/2+dx*(carrier_w/2-1.5),
                    carrier_h/2+dy*(carrier_h/2-1.5),
                    retainer_t])
            cylinder(d=retainer_peg_d, h=retainer_peg_h, $fn=16);
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
    translate([cube_size/2-carrier_w/2, cube_size/2-carrier_h/2, panel_t+carrier_t])
        color("green") retainer();
    translate([0.15, 0.15, cube_size-wall])
        color("lightblue") back_cover();
    // 5个cap摆在对应按键孔位置(z方向抬到面板外侧, 便于肉眼看位置)
    key_cross_positions(cube_size/2, cube_size/2 + key_cross_cy)
        translate([0,0,-cap_t]) color("yellow") cap();
}

// ============================================================
if (part_to_render == "shell") shell();
else if (part_to_render == "carrier") carrier();
else if (part_to_render == "retainer") retainer();
else if (part_to_render == "back") back_cover();
else if (part_to_render == "cap") cap();
else if (part_to_render == "assembly") assembly_preview();
