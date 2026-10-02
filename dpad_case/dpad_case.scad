// ============================================================
// HanHan 5K3L — 25mm立方体 外壳 + 载板 参数化设计 (v7: 简化卡槽为贯穿式, 走线全部挪到盖板)
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
// v6改动: 卡槽改成"台阶+深槽"结构试图解决引脚比本体低的问题, 新增盖板(retainer)
//   —— 打样后发现引脚两侧那两个深槽做得太大太夸张, 偏离了"中间凹一点放进去"的本意
// v7改动: 卡槽改成简单矩形直接贯穿整个载板厚度 —— 打样后发现贯穿孔从正面
//   看也是两个方正的洞, 偏离了"中间凹一点放按键壳体"的本意, 废弃。
// v8改动(本次, 按反馈再修正): 卡槽改成"从背面往里凹的分层沉孔", 不再贯穿:
//   - 引脚层(leg_zone, 靠背面, 宽=含引脚+焊接预留, 深leg_zone_depth): 放引脚/
//     焊点/引线弯折, 这一层背面是敞开的(不盖东西), 走线从这里直接出去
//   - 本体层(body_zone, 紧接引脚层往正面方向, 窄=贴合按键壳体, 深body_zone_depth):
//     卡住按键本体, 正面看过去只会看到这一层(窄的), 不是方正大洞
//   - 只有对准2mm圆顶的位置, 有个小圆孔(actuator_d)贯穿剩余厚度到正面,
//     让cap的顶杆穿过去压圆顶
//   盖板(retainer)不再开过线孔, 而是在对应每个按键的引脚层位置整块镂空(不盖住),
//   让载板上本来就敞开的引脚层保持敞开, 走线可以直接从背面任意方向出去。
// v9改动(本次): 盖板的镂空改回小孔 —— v8整块镂空开口太大了, 改成只在
//   引脚/引线实际露出的两端各开一个小孔(retainer_hole_d=1.4mm), 其余地方
//   盖板正常贴住载板背面, 把按键稳稳挡住不会往后掉。
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

// v8改动: 卡槽改成"背面往里凹的分层沉孔", 不贯穿(只有中间圆顶孔贯穿正面)
perp_margin    = 0.15;   // 窄边(垂直引脚方向)预留: 两层都缩到刚好能放进去
leg_margin     = 0.7;    // 引脚方向焊接预留空间(超出引脚尖端, 单边), 留大一点方便焊接不短路
body_margin    = 0.15;   // 本体层沿引脚方向的贴合间隙(单边)
pocket_len     = button_leg_x + 2*leg_margin;   // 引脚层长度(含焊接预留, 沿引脚方向)
pocket_w       = button_body_y + 2*perp_margin; // 两层共用的宽度(垂直引脚方向, 贴合本体)
body_pocket_len = button_body_x + 2*body_margin; // 本体层长度(沿引脚方向, 贴合壳体)
leg_zone_depth  = 0.7;   // 引脚层深度(从背面往里凹, 容纳引脚+焊点+引线弯折高度)
body_zone_depth = 0.9;   // 本体层深度(紧接引脚层, 卡住按键本体, 深度之和约等于按键总高)

wire_groove_w  = 1.3;    // LED引脚走线槽宽(配合0.9mm硅胶线)
wire_groove_depth = 1.0; // 走线槽深度(比按键卡槽浅, 只需过线)

// 按键帽(cap, 单独打印, 装进面板孔里, 背面顶杆对准载板下面的实际按键)
cap_t          = 1.6;    // cap本体厚度(含帽檐)
cap_rim_d      = key_hole_d - 0.4;  // cap外径(略小于面板孔, 留滑动间隙)
nub_d          = 2.0;    // cap背面顶杆直径(对准2mm圆点, 比actuator_d略小可自由穿过)
nub_h          = 0.75;   // cap背面顶杆长度: 需要穿过载板正面那段"只剩圆孔"的通道
                          // = carrier_t - leg_zone_depth - body_zone_depth + 一点预压量
                          // 理论值≈0.6mm通道+0.15预压, 装配后太松/太紧都需要实测微调重新打印!

// LED: 放回顶部一排(cap缩小后腾出的空间), 孔不用太大, 能看到光点就行
led_hole_d     = 3.0;    // 面板LED过孔
led_pitch      = 6.0;    // 三颗LED间距
led_row_cy     = 8.2;    // LED排相对面板中心的y偏移(正值=靠上)
led_positions  = [[-led_pitch,led_row_cy], [0,led_row_cy], [led_pitch,led_row_cy]];

// 载板(carrier plate, 单独打印, 贴在面板内侧)
carrier_w      = panel_area - 0.6;  // 载板宽(比面板可用区域小0.6mm装配间隙)
carrier_h      = panel_area - 0.6;  // 载板高
carrier_t      = 2.2;    // 载板厚度(分层沉孔: 引脚层0.7+本体层0.9, 剩下的0.6留给正面圆孔通道)
carrier_peg_d  = 1.6;    // 载板定位柱直径(对应外壳内侧定位孔)

// 盖板(retainer, 新增第5个零件): 贴在载板背面(靠电池那一侧), 把按键夹在
// 载板和盖板之间防止移动/被顶出来; 对应每个按键的引脚层位置整块镂空(不盖住),
// 让载板本来就敞开的引脚层保持敞开, 走线可以直接从背面出去, 不需要额外开孔。
retainer_t       = 1.0;   // 盖板厚度
retainer_slot_w  = 1.4;   // 盖板过线长条孔的短边宽度(沿引脚方向)
retainer_slot_len= 2.6;   // 盖板过线长条孔的长边长度(沿垂直引脚方向, 一次性盖住两条引脚/引线)
retainer_led_d   = led_hole_d + 0.3; // 盖板上LED过孔径(比面板LED孔略大留装配间隙)
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

// 单个按键的卡槽: 从背面(z=carrier_t这一侧)往里凹的分层沉孔, 不贯穿到正面
// (vertical=false: 引脚水平/沿x方向; true: 引脚转90度/沿y方向)
//   - 引脚层: 靠背面, 宽(含引脚+焊接预留), 深leg_zone_depth, 背面敞开走线
//   - 本体层: 紧接引脚层往正面方向, 窄(贴合本体), 深body_zone_depth
//   - 圆顶通孔: 从本体层继续贯穿剩余厚度到正面, 让cap顶杆穿过去压圆顶
module key_pocket(cx, cy, vertical) {
    eps = 0.05;

    leg_px = vertical ? pocket_w : pocket_len;
    leg_py = vertical ? pocket_len : pocket_w;
    translate([cx-leg_px/2, cy-leg_py/2, carrier_t-leg_zone_depth-eps])
        cube([leg_px, leg_py, leg_zone_depth+eps]);

    body_px = vertical ? pocket_w : body_pocket_len;
    body_py = vertical ? body_pocket_len : pocket_w;
    translate([cx-body_px/2, cy-body_py/2, carrier_t-leg_zone_depth-body_zone_depth-eps])
        cube([body_px, body_py, body_zone_depth+2*eps]);

    translate([cx, cy, -0.5])
        cylinder(d=actuator_d, h=carrier_t-leg_zone_depth-body_zone_depth+0.5+eps, $fn=32);
}

// ---------------- 载板(贴片按键固定件) ----------------
// 5个按键各自独立开卡槽(背面分层沉孔, 只有中间圆顶孔贯穿正面), 上/下/中 三键
// 引脚保持水平(H), 左/右 两键转90度变成引脚竖直(V) —— 这样同一排的左/中/右
// 三键之间就不再是"引脚对引脚"占满4.0mm宽度, 而是"本体对本体"只占3.4mm宽度,
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
// 整块板贴住载板背面, 挡住载板的引脚层(按键靠在这块板上不会往后掉出去),
// 只在每个按键引脚/引线实际露出的两端各开一个长条孔走线(一次盖住两条引脚/引线),
// 不整块镂空。另外3颗LED各开一个过孔(LED本体比载板厚, 一截会伸到盖板这边,
// 不开孔会被盖板堵住, 引脚也要从这里继续穿出去).
module wire_slot(h, vertical) {
    // 长条孔: 长边(retainer_slot_len)始终垂直于引脚方向, 短边(retainer_slot_w)沿引脚方向
    half = (retainer_slot_len - retainer_slot_w) / 2;
    offs = vertical ? [[-half,0],[half,0]] : [[0,-half],[0,half]];
    hull()
        for (o = offs)
            translate([o[0], o[1], 0])
                cylinder(d=retainer_slot_w, h=h, $fn=16);
}

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
            hole_offset = pocket_len/2 - retainer_slot_w/2 - 0.3; // 贴着引脚层两端, 留点边
            off = vertical ? [0, hole_offset] : [hole_offset, 0];
            for (s=[-1,1])
                translate([bx+s*off[0], by+s*off[1], -1])
                    wire_slot(retainer_t+2, vertical);
        }

        // LED过孔(对准carrier上的led_dots位置, 贯穿盖板, 让LED本体/引脚继续穿过去)
        led_dots(carrier_w/2, carrier_h/2)
            translate([0,0,-1])
                cylinder(d=retainer_led_d, h=retainer_t+2, $fn=24);
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
// 背面的小顶杆(nub)穿过载板正面的圆孔(actuator_d), 精确压住实际贴片按键的圆顶触点。
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
