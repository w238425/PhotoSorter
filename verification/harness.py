# -*- coding: utf-8 -*-
"""
写真分类助手 — 算法验证沙盘
与 iOS App 使用完全相同的公式：
  - 清晰度 = 灰度128 Laplacian方差 / 500
  - 曝光分 = max(0, 1 - |均值-0.5| * 2.2)
  - 肤色占比 = 64x64 缩图, RGB阈值 与 HSV色相 取并集
  - 颜值分 = 清晰度*0.35 + 曝光*0.25 + 人脸占比*0.25 + 有脸*0.15
  - 分级 T0-T3 阈值: 人脸占比0.08 / 清晰度0.40 / 肤色0.20-0.45
  - 成组: 并查集 + 时间窗30min(适中阈值) + 封面宽松合并
  - 查重: 指纹距离 < 1.5 级别（此处用感知哈希完全相同模拟）
差异说明: 人脸检测/特征指纹是苹果 Vision 专有, 无法在 Windows 移植；
  此处人脸用"已知的真值"代替(测试图片是我画的, 有没有脸是确定的)，
  特征指纹用感知哈希(dHash)代替——阈值语义一致。
"""
import os, math, random, shutil
from PIL import Image, ImageDraw, ImageFilter
import numpy as np

OUT = r"C:\Users\Administrator\Desktop\写真分类测试"
random.seed(42)

# ---------------- 与 Swift 一致的阈值 ----------------
T = dict(minFaceArea=0.08, minSharpness=0.40, t2SkinLow=0.20, t2SkinHigh=0.45,
         goodHigh=0.70, goodMid=0.45, groupMedium=18, groupLoose=30)  # 哈希距离阈值(0-256)

# ---------------- 公式移植 ----------------
def gray_pixels(img, side):
    g = img.convert("L").resize((side, side), Image.NEAREST)
    return list(g.getdata())

def sharpness(img):
    side = 128
    px = gray_pixels(img, side)
    a = np.array(px, dtype=np.float64).reshape(side, side)
    lap = 4*a[1:-1,1:-1] - a[1:-1,:-2] - a[1:-1,2:] - a[:-2,1:-1] - a[2:,1:-1]
    var = lap.var()
    return min(var/500.0, 1.0)

def exposure_score(img):
    px = gray_pixels(img, 64)
    mean = sum(px)/len(px)/255.0
    return max(0.0, 1.0 - abs(mean-0.5)*2.2)

def _skin_rgb(r,g,b):
    mx, mn = max(r,g,b), min(r,g,b)
    return r>95 and g>40 and b>20 and (mx-mn)>15 and abs(r-g)>15 and r>g and r>b

def _skin_hsv(r,g,b):
    rf,gf,bf = r/255,g/255,b/255
    mx, mn = max(rf,gf,bf), min(rf,gf,bf)
    v, delta = mx, mx-mn
    if delta <= 0.1 or v <= 0.25 or v >= 0.98: return False
    if mx == rf: h = 60*(((gf-bf)/delta) % 6)
    elif mx == gf: h = 60*((bf-rf)/delta + 2)
    else: h = 60*((rf-gf)/delta + 4)
    s = delta/mx
    return 0 <= h <= 50 and 0.15 < s < 0.68

def skin_ratio(img):
    im = img.convert("RGB").resize((64,64), Image.NEAREST)
    px = list(im.getdata())
    skin = sum(1 for (r,g,b) in px if _skin_rgb(r,g,b) or _skin_hsv(r,g,b))
    return skin/len(px)

def is_heavy_filter(img):
    im = img.convert("RGB").resize((64,64), Image.NEAREST)
    px = list(im.getdata())
    sats = []
    for (r,g,b) in px:
        rf,gf,bf = r/255,g/255,b/255
        mx, mn = max(rf,gf,bf), min(rf,gf,bf)
        sats.append((mx-mn)/mx if mx>0 else 0)
    ms = sum(sats)/len(sats)
    return ms > 0.82 or ms < 0.02

def aesthetic(s):
    face_size = min(s["faceAreaRatio"]/0.15, 1.0)
    has_face = 1.0 if s["faceCount"] >= 1 else 0.0
    return s["sharpness"]*0.35 + s["exposureScore"]*0.25 + face_size*0.25 + has_face*0.15

def classify_level(s, t=T):
    is_portrait = 1 <= s["faceCount"] <= 3 and s["faceAreaRatio"] >= t["minFaceArea"] and s["sharpness"] >= t["minSharpness"]
    if not is_portrait: return "T0-普通"
    if s["skinRatio"] > t["t2SkinHigh"]: return "T3-非常暴露"
    if s["skinRatio"] >= t["t2SkinLow"]: return "T2-暴露"
    return "T1-写真"

def good_tier(a):
    return "高" if a >= T["goodHigh"] else ("中" if a >= T["goodMid"] else "低")

def dhash(img, size=16):
    g = img.convert("L").resize((size+1, size), Image.LANCZOS)
    px = list(g.getdata())
    bits = []
    for y in range(size):
        for x in range(size):
            bits.append(1 if px[y*(size+1)+x] > px[y*(size+1)+x+1] else 0)
    return bits

def hash_dist(a, b):
    return sum(1 for x, y in zip(a, b) if x != y)

# ---------------- 生成测试照片 ----------------
SKIN = (222,184,160)

def draw_face_body(d, cx, cy, fw, fh, body_w, body_h):
    d.ellipse([cx-fw/2, cy-fh/2, cx+fw/2, cy+fh/2], fill=SKIN)          # 脸
    d.ellipse([cx-fw*0.3, cy+fh*0.28, cx+fw*0.3, cy+fh*0.75], fill=SKIN) # 脖子
    d.pieslice([cx-body_w/2, cy+fh*0.6, cx+body_w/2, cy+fh*0.6+body_h], 180, 360, fill=(90,90,110))  # 肩(衣服)

def make_photo(path, style_bg, face=True, face_area=0.10, skin_boost=0.0,
               blur=False, dark=False, noise=True, size=512, body=True):
    img = Image.new("RGB", (size, size), style_bg)
    d = ImageDraw.Draw(img)
    if noise:
        arr = np.array(img, dtype=np.int16)
        n = np.random.default_rng(random.randint(0,9999)).integers(-9, 10, arr.shape[:2])[..., None]
        arr = np.clip(arr + n, 0, 255).astype(np.uint8)
        img = Image.fromarray(arr); d = ImageDraw.Draw(img)
    if face:
        # 面积 -> 边长
        f = math.sqrt(face_area) * size
        cx, cy = size*0.5, size*0.38
        draw_face_body(d, cx, cy, f, f*1.25, f*2.6, size*0.5 if body else size*0.2)
    if skin_boost > 0:
        # 用肤色填充画面下部比例 skin_boost 的区域(模拟大面积皮肤)
        h = int(size*skin_boost)
        d.rectangle([0, size-h, size, size], fill=SKIN)
    if dark:
        img = img.point(lambda p: p//3)
    if blur:
        img = img.filter(ImageFilter.GaussianBlur(14))
    img.save(path, quality=92)

def make_landscape(path, hue, size=512):
    img = Image.new("RGB", (size, size), hue)
    d = ImageDraw.Draw(img)
    d.polygon([(0,size),(size,size),(size,int(size*0.55))], fill=tuple(min(255,c+40) for c in hue))
    d.ellipse([size*0.7, size*0.08, size*0.88, size*0.26], fill=(250,240,200))
    img.save(path, quality=92)

def make_screenshot(path, size=512):
    img = Image.new("RGB", (size, size), (255,255,255))
    d = ImageDraw.Draw(img)
    d.rectangle([0,0,size,40], fill=(60,60,70))
    for i in range(6):
        d.rectangle([30, 80+i*60, size-30, 110+i*60], fill=(200,205,215))
    img.save(path, quality=92)

# ---------------- 组装"用户相册"(被打乱的状态) ----------------
input_dir = os.path.join(OUT, "01_测试相册_你存进来时是这样")
os.makedirs(input_dir, exist_ok=True)

STYLE_A = (176,186,208)   # 冷调影棚风
STYLE_B = (208,188,160)   # 暖调胶片风

plan = []  # (文件名, 生成参数, 真值描述, 套归属, 伪造拍摄时间分钟)
# 套A: 冷调写真 4张(主体) + 2张被打散到别处
for i in range(4):
    fn = f"IMG_{2000+i}.jpg"
    plan.append((fn, dict(style_bg=STYLE_A, face=True, face_area=0.10), "套A主体·有脸", "A", 600+i))
# 散落2张(时间远,风格同A)
for i in range(2):
    fn = f"IMG_{2100+i}.jpg"
    plan.append((fn, dict(style_bg=STYLE_A, face=True, face_area=0.11), "套A散图·有脸", "A", 900+i))
# 套B: 暖调·暴露(肤色约30%) 3张
for i in range(3):
    fn = f"IMG_{2200+i}.jpg"
    plan.append((fn, dict(style_bg=STYLE_B, face=True, face_area=0.16, skin_boost=0.22), "套B主体·暴露", "B", 1200+i))
# T3: 非常暴露 1张(肤色>45%)
plan.append(("IMG_2300.jpg", dict(style_bg=STYLE_B, face=True, face_area=0.16, skin_boost=0.42), "非常暴露·有脸", "C", 1300))
# 风景 2张
plan.append(("IMG_2400.jpg", dict(landscape=(70,120,90)), "风景·无脸", None, 1500))
plan.append(("IMG_2401.jpg", dict(landscape=(60,90,140)), "风景·无脸", None, 1501))
# 糊掉的废片 1张(有脸但失焦)
plan.append(("IMG_2500.jpg", dict(style_bg=STYLE_A, face=True, face_area=0.10, blur=True), "废片·糊", None, 1600))
# 截图 1张
plan.append(("IMG_2501.jpg", dict(screenshot=True), "截图·无脸", None, 1601))
# 暗·低颜值写真 1张
plan.append(("IMG_2502.jpg", dict(style_bg=STYLE_B, face=True, face_area=0.10, dark=True), "暗片·有脸", None, 1602))

names_shuffled = plan[:]
random.shuffle(names_shuffled)
for fn, kw, truth, setid, tmin in names_shuffled:
    p = os.path.join(input_dir, fn)
    if kw.get("landscape"): make_landscape(p, kw["landscape"])
    elif kw.get("screenshot"): make_screenshot(p)
    else: make_photo(p, **{k:v for k,v in kw.items() if k not in ("landscape","screenshot")})

# 完全重复的一张(查重演示)
shutil.copy(os.path.join(input_dir, "IMG_2000.jpg"), os.path.join(input_dir, "IMG_2600副本.jpg"))

# ---------------- 跑分类流水线(与App一致) ----------------
photos = {}
fps = {}
files = sorted(os.listdir(input_dir))
for fn in files:
    img = Image.open(os.path.join(input_dir, fn))
    s = dict(
        sharpness=sharpness(img),
        exposureScore=exposure_score(img),
        skinRatio=skin_ratio(img),
        faceCount=1 if not (kw_landscape(fn) if False else False) else 0,  # 占位, 下面按真值覆盖
        faceAreaRatio=0.0,
    )
    # 人脸检测为 Vision 专有 → 用生成真值代替
    p = next(x for x in plan if x[0] == fn or fn == "IMG_2600副本.jpg")
    src = plan[0] if fn == "IMG_2600副本.jpg" else p
    kw, truth, setid, tmin = src[1], src[2], src[3], src[4]
    has_face = bool(kw.get("face")) and not kw.get("landscape") and not kw.get("screenshot")
    s["faceCount"] = 1 if has_face else 0
    s["faceAreaRatio"] = (kw.get("face_area") or 0.0) if has_face else 0.0
    s["hasFilter"] = is_heavy_filter(img)
    s["aesthetic"] = aesthetic(s)
    s["level"] = classify_level(s)
    s["good"] = good_tier(s["aesthetic"])
    s["skinTier"] = ("极低" if s["skinRatio"]<0.10 else "低" if s["skinRatio"]<0.25 else "中" if s["skinRatio"]<0.50 else "高")
    s["truth"], s["setid"], s["tmin"] = truth, setid, tmin
    s["fake_time"] = f"{tmin//60:02d}:{tmin%60:02d}"
    photos[fn] = s
    fps[fn] = dhash(img)

# 成组: 并查集(与Swift同构)
ids = sorted(photos, key=lambda f: photos[f]["tmin"])
parent = {i: i for i in ids}
def find(x):
    while parent[x] != x:
        parent[x] = parent[parent[x]]
        x = parent[x]
    return x
def union(a, b):
    ra, rb = find(a), find(b)
    if ra != rb: parent[rb] = ra

for i, id1 in enumerate(ids):
    for id2 in ids[i+1:]:
        if photos[id2]["tmin"] - photos[id1]["tmin"] > 30: break
        if hash_dist(fps[id1], fps[id2]) < T["groupMedium"]:
            union(id1, id2)
roots = {}
for f in ids: roots.setdefault(find(f), f)
for f in ids:
    for root, cover in roots.items():
        if find(f) != find(cover) and hash_dist(fps[f], fps[cover]) < T["groupLoose"]:
            union(cover, f)

buckets = {}
for f in ids: buckets.setdefault(find(f), []).append(f)
sets = sorted(buckets.values(), key=len, reverse=True)

# 查重
dups, claimed = [], set()
for i, f1 in enumerate(ids):
    if f1 in claimed: continue
    grp = [f1]
    for f2 in ids[i+1:]:
        if f2 in claimed: continue
        if hash_dist(fps[f1], fps[f2]) == 0:
            grp.append(f2); claimed.add(f2)
    if len(grp) > 1: dups.append(grp); claimed.add(f1)

# 给套编号 & 每张照片打套标签
set_names = {}
for idx, members in enumerate(sets):
    nm = f"套#{idx+1:03d}({len(members)}张)"
    for m in members: photos[m]["set"] = nm
    set_names[nm] = members

# ---------------- 输出目录结构(模拟App建相册) ----------------
def link(src_dir, dst_dir, fn, order=None):
    os.makedirs(dst_dir, exist_ok=True)
    prefix = f"{order:03d}_" if order is not None else ""
    shutil.copy(os.path.join(src_dir, fn), os.path.join(dst_dir, prefix + fn))

sorted_dir = os.path.join(OUT, "02_排序结果_按套(整套不拆散)")
level_dir  = os.path.join(OUT, "03_分类_分级")
good_dir   = os.path.join(OUT, "04_分类_好看程度")
for nm, members in set_names.items():
    # 封面放第一, 其余按颜值降序 —— "排序结果"
    members_sorted = sorted(members, key=lambda f: -photos[f]["aesthetic"])
    for order, f in enumerate(members_sorted):
        link(input_dir, os.path.join(sorted_dir, nm), f, order)
for f in ids:
    lv = photos[f]["level"].split("-")[0]
    link(input_dir, os.path.join(level_dir, photos[f]["level"]), f)
    link(input_dir, os.path.join(good_dir, "好看-" + photos[f]["good"]), f)

# ---------------- 报告 ----------------
lines = []
lines.append("写真分类助手 · 算法验证沙盘 测试报告")
lines.append("=" * 78)
lines.append("说明: 公式与 iOS App 完全一致(清晰度/曝光/肤色/颜值/分级阈值/成组并查集)。")
lines.append("      人脸检测与特征指纹是苹果 Vision 专有组件, 此处分别用『生成真值』和『感知哈希』")
lines.append("      代替 —— 阈值语义一致, 用于验证分类与成组逻辑的正确性。")
lines.append("")
lines.append(f"{'文件名':<18}{'清晰度':>7}{'曝光':>6}{'肤色%':>6}{'颜值':>6}{'分级':<14}{'好看':>4}{'套':<16}{'真值'}")
lines.append("-" * 100)
for f in sorted(ids, key=lambda x: (photos[x]["set"], -photos[x]["aesthetic"])):
    s = photos[f]
    lines.append(f"{f:<18}{s['sharpness']:>7.2f}{s['exposureScore']:>6.2f}{s['skinRatio']*100:>6.0f}{s['aesthetic']:>6.2f}{s['level']:<14}{s['good']:>4}{s['set']:<16}{s['truth']}")
lines.append("")
lines.append("成组结果(套):")
for nm, members in set_names.items():
    lines.append(f"  {nm}: {', '.join(sorted(members))}")
lines.append("")
lines.append("查重结果:")
if dups:
    for g in dups:
        lines.append(f"  完全重复组: {', '.join(g)}  → 可删 {len(g)-1} 张(需系统确认)")
else:
    lines.append("  未发现重复")
lines.append("")
# 验证断言
lines.append("自动断言(策划案规则逐条核对):")
def check(name, cond): lines.append(f"  [{'PASS' if cond else 'FAIL'}] {name}")
pa = {f: photos[f] for f in photos}
check("套A的6张(4主体+2散图)合并为同一套 — 打散写真重组",
      len({photos[f]['set'] for f in photos if photos[f]['setid']=='A'}) == 1)
check("套B的3张合并为同一套", len({photos[f]['set'] for f in photos if photos[f]['setid']=='B'}) == 1)
check("套A普通写真判为 T1(肤色<20%)", all(photos[f]['level']=='T1-写真' for f in photos if photos[f]['setid']=='A'))
check("套B判为 T2(肤色20-45%)", all(photos[f]['level']=='T2-暴露' for f in photos if photos[f]['setid']=='B'))
check("大肤色占比照片判为 T3(>45%)", photos['IMG_2300.jpg']['level']=='T3-非常暴露')
check("风景照判为 T0(无人脸)", all(photos[f]['level']=='T0-普通' for f in photos if '风景' in photos[f]['truth']))
check("糊片因清晰度不达标不进 T1", photos['IMG_2500.jpg']['level']=='T0-普通')
check("截图判为 T0", photos['IMG_2501.jpg']['level']=='T0-普通')
check("颜值排序: 高颜值片进[好看-高]", any(photos[f]['good']=='高' for f in photos if photos[f]['setid']=='A'))
check("暗片颜值被压低", photos['IMG_2502.jpg']['good'] in ('低','中'))
check("完全重复照片被查重命中", len(dups) >= 1)
lines.append("")
lines.append("目录: 01=模拟你存入时被打乱的相册  02=按套排序结果(封面在先)  03=按分级  04=按好看程度")
report = "\n".join(lines)
with open(os.path.join(OUT, "测试报告.txt"), "w", encoding="utf-8") as f:
    f.write(report)
print(report)
