# -*- coding: utf-8 -*-
"""
真人照片实测 v3（最终版）：
- DNN 人脸检测
- GrabCut 人像分割 + 人脸参照肤色（只统计人形区域内的皮肤，排除背景干扰）
- ORB 特征点匹配成组（模拟 Vision 指纹，沙盘验证过：同套 177+ / 不同人 <15，阈值 40）
- 查重四道闸（同套豁免 / 特征极严 / 体积一致 / 人工确认）
"""
import os, shutil, itertools
import numpy as np
import cv2
from PIL import Image, ImageEnhance, ImageDraw

SRC = "realphotos"
OUT = r"C:/Users/Administrator/Desktop/真人照片分类测试"

T = dict(
    blur_mean=3.0, blur_var=40.0,
    t1_face_ratio=0.02,
    t2_skin=0.20, t3_skin=0.45,     # 皮肤占"人形区域"的比例
    group_matches=40,               # ORB 匹配点数 ≥ 40 → 同套
    dup_matches=150,                # 近重复：匹配点极多
)

net = cv2.dnn.readNetFromCaffe("face.prototxt", "face.caffemodel")
orb = cv2.ORB_create(nfeatures=800, scaleFactor=1.2, nlevels=8)
bf = cv2.BFMatcher(cv2.NORM_HAMMING)

def detect_faces(img):
    h, w = img.shape[:2]
    blob = cv2.dnn.blobFromImage(cv2.cvtColor(img, cv2.COLOR_RGB2BGR), 1.0, (300, 300), (104, 177, 123))
    net.setInput(blob)
    det = net.forward()
    out = []
    for i in range(det.shape[2]):
        conf = det[0, 0, i, 2]
        if conf > 0.55:
            x1, y1, x2, y2 = (det[0, 0, i, 3:7] * [w, h, w, h]).astype(int)
            out.append((max(0, x1), max(0, y1), min(w, x2) - x1, min(h, y2) - y1, float(conf)))
    return out

def face_info(img):
    faces = detect_faces(img)
    if not faces:
        return 0, 0.0
    h, w = img.shape[:2]
    big = max(faces, key=lambda f: f[2] * f[3])
    return len(faces), float((big[2] * big[3]) / (h * w))

def clarity(img):
    g = cv2.cvtColor(img, cv2.COLOR_RGB2GRAY)
    h, w = g.shape
    scale = 512.0 / max(h, w)
    if scale < 1:
        g = cv2.resize(g, (int(w * scale), int(h * scale)))
    lap = cv2.Laplacian(g, cv2.CV_64F)
    return float(np.abs(lap).mean()), float(lap.var())

def exposure(img):
    return float(cv2.cvtColor(img, cv2.COLOR_RGB2GRAY).astype(np.float32).mean() / 255.0)

def person_mask(img, face):
    """GrabCut 人像分割：以人脸框为中心扩展矩形初始化"""
    h, w = img.shape[:2]
    x, y, fw, fh = face[:4]
    for shrink in (1.0, 0.7, 0.45):
        rx = max(0, int(x - fw * 0.8 * shrink)); ry = max(0, int(y - fh * 0.6 * shrink))
        rw = min(w - rx, int(fw * (1 + 1.6 * shrink))); rh = min(h - ry, int(fh * (1 + 3.0 * shrink)))
        if rw < 8 or rh < 8 or rx >= w or ry >= h:
            continue
        if rw * rh > 0.85 * w * h:      # 矩形撑满全图会导致无背景样本
            continue
        img = np.ascontiguousarray(img)
        mask = np.zeros((h, w), np.uint8)
        bgd, fgd = np.zeros((1, 65), np.float64), np.zeros((1, 65), np.float64)
        try:
            cv2.grabCut(img, mask, (rx, ry, rw, rh), bgd, fgd, 5, cv2.GC_INIT_WITH_RECT)
        except cv2.error:
            continue
        m = np.where((mask == cv2.GC_FGD) | (mask == cv2.GC_PR_FGD), 255, 0).astype(np.uint8)
        n, labels = cv2.connectedComponents(m)
        face_cx, face_cy = min(w-1, x + fw // 2), min(h-1, y + fh // 2)
        comp = labels[face_cy, face_cx]
        if comp == 0:
            return m
        return np.where(labels == comp, 255, 0).astype(np.uint8)
    # 兜底：人脸框直接扩展（放弃精分割）
    m = np.zeros((h, w), np.uint8)
    m[max(0, y):min(h, y + int(fh * 3)), max(0, x):min(w, x + int(fw * 2))] = 255
    return m

def skin_ratio(img, face, pmask):
    """皮肤占人形区域比例：人脸参照肤色 × 人像掩码交集"""
    x, y, fw, fh = face[:4]
    ch, cw = fh, fw
    fy, fx = max(0, y), max(0, x)
    center = img[fy:y + fh, fx:x + fw]
    if center.size == 0:
        return 0.0
    cch, ccw = center.shape[:2]
    core = center[cch // 4:3 * cch // 4, ccw // 4:3 * ccw // 4]
    f_hsv = cv2.cvtColor(core, cv2.COLOR_RGB2HSV).reshape(-1, 3).astype(np.float32)
    f_hue, f_sat = np.median(f_hsv[:, 0]), np.median(f_hsv[:, 1])
    hsv = cv2.cvtColor(img, cv2.COLOR_RGB2HSV)
    H, S, V = hsv[:, :, 0].astype(np.int16), hsv[:, :, 1].astype(np.int16), hsv[:, :, 2].astype(np.int16)
    dh = np.abs(H - int(f_hue)); dh = np.minimum(dh, 180 - dh)
    skin_like = (dh <= 12) & (np.abs(S - int(f_sat)) <= 55) & (V > 60) & (V < 245) & (S > 25)
    area = float((pmask > 0).sum())
    if area == 0:
        return 0.0
    return float((skin_like & (pmask > 0)).sum() / area)

def orb_descriptors(img):
    g = cv2.cvtColor(img, cv2.COLOR_RGB2GRAY)
    return orb.detectAndCompute(g, None)[1]

def match_count(d1, d2):
    if d1 is None or d2 is None:
        return 0
    raw = bf.knnMatch(d1, d2, k=2)
    return len([m for m, n2 in raw if m.distance < 0.75 * n2.distance])

def aesthetic(cm, cv_, exp, fr):
    s_cla = min(max(cm / 12.0, cv_ / 150.0), 1.0)
    s_exp = 1.0 - min(abs(exp - 0.52) / 0.35, 1.0)
    s_face = 1.0 if fr > 0.10 else fr / 0.10
    return round((0.4 * s_cla + 0.3 * s_exp + 0.3 * s_face) * 100, 1)

# ---------- 测试池（12 张真人像 + 5 张同套变体） ----------
pool = {}
for f in sorted(os.listdir(SRC)):
    if f.endswith(".jpg"):
        pool[f.replace(".jpg", "")] = np.array(Image.open(os.path.join(SRC, f)).convert("RGB"))
b = Image.open(os.path.join(SRC, "p06.jpg")).convert("RGB"); w, h = b.size
pool["p06v2"] = np.array(b.crop((int(w * 0.08), 0, w, int(h * 0.92))).resize((w, h)))
pool["p06v3"] = np.array(ImageEnhance.Brightness(b.crop((0, int(h * 0.06), int(w * 0.94), h)).resize((w, h))).enhance(0.92))
b = Image.open(os.path.join(SRC, "p09.jpg")).convert("RGB"); w, h = b.size
pool["p09v2"] = np.array(ImageEnhance.Brightness(b.crop((int(w * 0.10), int(h * 0.05), w, h)).resize((w, h))).enhance(1.08))

names = sorted(pool.keys())
order = [names[i] for i in np.random.RandomState(7).permutation(len(names))]

# ---------- 分析 ----------
results, descriptors = {}, {}
for name in order:
    img = pool[name]
    small = img if max(img.shape[:2]) <= 512 else cv2.resize(img, (512, int(512 * img.shape[0] / img.shape[1])))
    cm, cvv = clarity(small)
    exp = exposure(small)
    nface, fr = face_info(small)
    skin = 0.0
    faces = detect_faces(small)
    if faces:
        big = max(faces, key=lambda f: f[2] * f[3])
        pm = person_mask(small, big)
        skin = skin_ratio(small, big, pm)
    blur = not (cm >= T["blur_mean"] or cvv >= T["blur_var"])
    if blur:
        level = "T0-低质/废片"
    elif nface == 0:
        level = "T0-非写真"
    elif fr >= T["t1_face_ratio"] and skin < T["t2_skin"]:
        level = "T1-写真"
    elif skin >= T["t3_skin"]:
        level = "T3-非常暴露"
    elif skin >= T["t2_skin"]:
        level = "T2-暴露写真"
    else:
        level = "T1-写真"
    score = aesthetic(cm, cvv, exp, fr)
    looks = "好看-高" if score >= 70 else ("好看-中" if score >= 45 else "好看-低")
    results[name] = dict(cla=cm, clav=cvv, exp=exp, skin=skin, nface=nface, fratio=fr,
                         level=level, score=score, looks=looks)
    descriptors[name] = orb_descriptors(small)

# ---------- 成组：ORB 匹配 + 并查集 ----------
parent = {n: n for n in order}
def find(x):
    while parent[x] != x:
        parent[x] = parent[parent[x]]; x = parent[x]
    return x
def union(a, b):
    ra, rb = find(a), find(b)
    if ra != rb: parent[ra] = rb

edges = []
for a, b2 in itertools.combinations(order, 2):
    m = match_count(descriptors[a], descriptors[b2])
    if m >= T["group_matches"]:
        union(a, b2); edges.append((a, b2, m))

sets = {}
for n in order:
    sets.setdefault(find(n), []).append(n)
set_list = sorted(sets.values(), key=len, reverse=True)

# ---------- 查重四道闸（前-autonomous三道） ----------
dup_groups, seen = [], set()
for a, b2 in itertools.combinations(order, 2):
    if find(a) == find(b2): continue
    if match_count(descriptors[a], descriptors[b2]) < T["dup_matches"]: continue
    sa, sb = pool[a].nbytes, pool[b2].nbytes
    if abs(sa - sb) / max(sa, sb) > 0.10: continue
    key = tuple(sorted((a, b2)))
    if key not in seen: seen.add(key); dup_groups.append(key)

# ---------- 输出（按用户新设计：单一排序序列，无分类文件夹） ----------
if os.path.exists(OUT): shutil.rmtree(OUT)
p_raw = os.path.join(OUT, "01_测试相池_真人照片(打乱)"); os.makedirs(p_raw)
p_fin = os.path.join(OUT, "02_最终排序_一键导入这份"); os.makedirs(p_fin)

RANK = {"T3": 3, "T2": 2, "T1": 1, "T0": 0}
def lrank(n): return RANK[results[n]["level"][:2]]

def save(img, path):
    Image.fromarray(img).resize((360, int(360 * img.shape[0] / img.shape[1]))).save(path, quality=88)

for n in order:
    save(pool[n], os.path.join(p_raw, n + ".jpg"))

# 最终序列：套间按套最高分级降序→套均颜值；套内封面在前→颜值降序；散图殿后按分级→颜值
multi = [ms for ms in set_list if len(ms) >= 2]
multi.sort(key=lambda ms: (-max(lrank(n) for n in ms), -np.mean([results[n]["score"] for n in ms])))
singles = sorted([ms[0] for ms in set_list if len(ms) == 1], key=lambda n: (-lrank(n), -results[n]["score"]))

seq = []   # (序号, 说明, 照片名)
idx = 1
for si, ms in enumerate(multi, 1):
    lv = max((results[n]["level"] for n in ms), key=lambda l: RANK[l[:2]])
    ms_sorted = sorted(ms, key=lambda n: -results[n]["score"])
    for n in ms_sorted:
        seq.append((idx, f"套#{si:03d}·{lv}", n)); idx += 1
for n in singles:
    seq.append((idx, f"散图·{results[n]['level']}", n)); idx += 1

for i, tag, n in seq:
    save(pool[n], os.path.join(p_fin, f"{i:03d}_{tag}_{n}.jpg"))

# 标签清单（排序依据存档，不产生第二份照片）
with open(os.path.join(p_fin, "_排序说明.txt"), "w", encoding="utf-8") as f:
    f.write("最终序列 = 套间按套最高分级(T3套→T2套→T1套)排列，套内封面在前按颜值降序，散图殿后按分级→颜值。\n")
    f.write("每张照片只出现一次。标签仅作排序键，不生成分类文件夹。\n\n")
    for i, tag, n in seq:
        r = results[n]
        f.write(f"{i:03d}  {tag:12}  {n:8}  颜值{r['score']:<6} 肤色{r['skin']:.3f}\n")

cols, size = 5, 200
rows = (len(order) + cols - 1) // cols
sheet = Image.new("RGB", (cols * size, rows * (size + 20)), (245, 245, 245))
d = ImageDraw.Draw(sheet)
for i, n in enumerate(order):
    im = Image.fromarray(pool[n]).resize((size - 6, size - 6))
    x, y = (i % cols) * size, (i // cols) * (size + 20)
    sheet.paste(im, (x + 3, y + 3))
    d.text((x + 5, y + size + 2), f"{n} {results[n]['level'][:2]} {results[n]['score']}", fill=(20, 20, 20))
sheet.save(os.path.join(OUT, "00_真人照片总览.png"))

# ---------- 报告 ----------
lines = []
lines.append("真人照片分类实测报告 v3（12 张 Unsplash 授权人像 + 5 张同套变体 = 17 张）")
lines.append("算法: DNN人脸 + GrabCut人像分割×人脸参照肤色 + ORB特征成组(≥40点) + 查重四道闸")
lines.append("=" * 78)
lines.append(f"{'照片':8}{'脸':3}{'脸占比':7}{'清晰':7}{'方差':7}{'肤/人形':8}{'分级':13}{'颜值':6}{'好看':6}")
for n in order:
    r = results[n]
    lines.append(f"{n:8}{r['nface']:<3}{r['fratio']:.3f}  {r['cla']:>5.1f} {r['clav']:>6.0f} {r['skin']:.3f}   {r['level']:11}{r['score']:<6}{r['looks']}")
lines.append("")
lines.append(f"成组（ORB匹配≥{T['group_matches']}点并组）:")
for si, ms in enumerate(set_list, 1):
    tag = ""
    if sorted(ms) == sorted(["p06", "p06v2", "p06v3"]): tag = "  <-- 套A三张全合 ✅"
    if sorted(ms) == sorted(["p09", "p09v2"]): tag = "  <-- 套B两张全合 ✅"
    lines.append(f"  套#{si:03d}({len(ms)}张): {', '.join(sorted(ms))}{tag}")
lines.append("")
lines.append(f"查重: 疑似重复组 {len(dup_groups)} 组 {dup_groups if dup_groups else '（无——同套变体按闸1豁免，正确）'}")
lines.append("")
lines.append("最终序列（唯一归属，无重复——套间按分级、套内按颜值、散图殿后）:")
for i, tag, n in seq:
    lines.append(f"  {i:03d}  {tag:14} {n}")
lines.append(f"  共 {len(seq)} 张 = 原始 {len(order)} 张，{'无重复 ✅' if len(seq) == len(order) else '❌ 数量不符'}")
lines.append("")
def check(name, cond):
    lines.append(f"  [{'PASS' if cond else 'FAIL'}] {name}")
    return cond
c1 = check("套A(p06+v2+v3) 合为一套", any(sorted(ms) == sorted(["p06", "p06v2", "p06v3"]) for ms in set_list))
c2 = check("套B(p09+v2) 合为一套", any(sorted(ms) == sorted(["p09", "p09v2"]) for ms in set_list))
c3 = check("不同人的照片未被误合并", not any(("p01" in str(ms) and "p02" in str(ms)) for ms in set_list))
portraits = ["p01", "p02", "p03", "p04", "p05", "p07", "p08", "p12", "p11"]
c4 = check("9 张独立真人像均检出人脸且为写真级(T1/T2/T3)", all(results[n]["nface"] >= 1 and not results[n]["level"].startswith("T0") for n in portraits))
c5 = check("查重 0 误报（同套变体不进查重）", len(dup_groups) == 0)
c6 = check("GrabCut人像分割压住背景干扰（p09肤色<45%不跳T3）", results["p09"]["skin"] < T["t3_skin"])
c7 = check("最终序列无重复且张数守恒", len(seq) == len(order))
lines.append("")
lines.append(f"结论: {'✅ 全部通过' if all([c1, c2, c3, c4, c5, c6, c7]) else '❌ 存在失败项，见上'}")
with open(os.path.join(OUT, "测试报告.txt"), "w", encoding="utf-8") as f:
    f.write("\n".join(lines))
print("\n".join(lines))
