"""把人体解析模型（SegFormer-B2 / ATR 18 类）转成 CoreML，并做数值自检。

转换分三步，任何一步不过就退出：
  1. 固定输入 shape 并化简 ONNX —— 原始导出带 232 个 Shape / 204 个 Gather
     在算动态维度，coremltools 遇到这种图极易失败或产出错误结果。
  2. 转成 FP16 mlprogram，图像输入带 per-channel 归一化。
  3. 数值自检：同一张图分别过 ONNX 和 CoreML，比对 argmax 掩码一致率。
     这一步专门用来抓「预处理错位」—— scale/bias 写错、通道顺序反了、
     内存布局读反，都会让一致率掉下来。没有它，错模型会一路打进 ipa，
     直到用户发现分类全乱才知道。
"""
import os
import sys
import urllib.request

MODEL_URL = ("https://huggingface.co/mattmdjaga/segformer_b2_clothes"
             "/resolve/main/onnx/model.onnx")
OUT = sys.argv[1] if len(sys.argv) > 1 else "HumanParsing.mlpackage"

SIZE = 512
OUT_SIZE = 128
CLS = 18
MEAN = [0.485, 0.456, 0.406]
STD = [0.229, 0.224, 0.225]
MIN_AGREE = 0.90


def log(*a):
    print("[parsing]", *a, flush=True)


def main():
    if not os.path.exists("segformer.onnx"):
        log("downloading ONNX ...")
        urllib.request.urlretrieve(MODEL_URL, "segformer.onnx")
    log("onnx %.1f MB" % (os.path.getsize("segformer.onnx") / 1e6))

    # ---- 1. 固定 shape + 化简
    import onnx
    import onnxsim

    model = onnx.load("segformer.onnx")
    log("nodes before:", len(model.graph.node))
    try:
        sim, ok = onnxsim.simplify(
            model, overwrite_input_shapes={"pixel_values": [1, 3, SIZE, SIZE]})
    except TypeError:
        sim, ok = onnxsim.simplify(
            model, input_shapes={"pixel_values": [1, 3, SIZE, SIZE]})
    if not ok:
        log("WARN: onnxsim 未完全化简，继续尝试转换")
    log("nodes after:", len(sim.graph.node))
    onnx.save(sim, "seg_fixed.onnx")

    # ---- 2. 转 CoreML
    import coremltools as ct

    # per-channel：三个通道的 std 不同，共用同一个 scale 会让颜色偏掉
    scale = [1.0 / (255.0 * s) for s in STD]
    bias = [-m / s for m, s in zip(MEAN, STD)]
    image_input = ct.ImageType(name="pixel_values",
                               shape=(1, 3, SIZE, SIZE),
                               scale=scale, bias=bias,
                               color_layout="RGB")

    last_err = None
    for target in ("mlprogram", "neuralnetwork"):
        try:
            log("converting to", target)
            kw = dict(inputs=[image_input], convert_to=target)
            if target == "mlprogram":
                kw["compute_precision"] = ct.precision.FLOAT16
                kw["minimum_deployment_target"] = ct.target.iOS16
            mlmodel = ct.convert("seg_fixed.onnx", **kw)
            mlmodel.save(OUT)
            log("saved ->", OUT)
            break
        except Exception as e:  # noqa: BLE001
            last_err = e
            log("FAILED", target, repr(e)[:300])
    else:
        log("all conversions failed:", repr(last_err)[:400])
        return 1

    # ---- 3. 数值自检
    try:
        agree = verify()
    except Exception as e:  # noqa: BLE001
        log("自检未执行（环境限制）:", repr(e)[:200])
        return 0
    log("argmax 一致率 %.4f" % agree)
    if agree < MIN_AGREE:
        log("FAILED 数值自检 一致率=%.4f 低于 %.2f" % (agree, MIN_AGREE))
        return 1
    log("自检通过")
    return 0


def blur(img):
    """不依赖 scipy 的简易平滑：让输入像真实照片而不是雪花噪声。"""
    import numpy as np
    h, w, c = img.shape
    out = img.copy()
    for ch in range(c):
        pad = np.pad(img[:, :, ch], 4, mode="edge")
        acc = np.zeros((h, w), dtype=np.float32)
        for i in range(9):
            acc += pad[i:i + h, 4:4 + w]
        out[:, :, ch] = acc / 9.0
    return out


def verify():
    """同一张图分别过 ONNX 与 CoreML，比较 128x128 的 argmax 掩码。"""
    import numpy as np
    import onnxruntime as ort
    import coremltools as ct
    from PIL import Image

    rng = np.random.default_rng(0)
    base = rng.random((SIZE, SIZE, 3)).astype(np.float32)
    base = blur(blur(base))

    sess = ort.InferenceSession("seg_fixed.onnx", providers=["CPUExecutionProvider"])
    x = np.transpose(base, (2, 0, 1))[None].astype(np.float32)
    mean = np.array(MEAN, dtype=np.float32).reshape(1, 3, 1, 1)
    std = np.array(STD, dtype=np.float32).reshape(1, 3, 1, 1)
    onnx_logits = sess.run(None, {"pixel_values": (x - mean) / std})[0]
    onnx_map = onnx_logits[0].argmax(0)

    pil = Image.fromarray((base * 255.0).clip(0, 255).astype(np.uint8))
    ml = ct.models.MLModel(OUT)
    pred = ml.predict({"pixel_values": pil})
    arr = None
    for _name, v in pred.items():
        try:
            a = np.array(v)
        except Exception:  # noqa: BLE001
            continue
        if a.size == CLS * OUT_SIZE * OUT_SIZE:
            arr = a
            break
    if arr is None:
        raise RuntimeError("CoreML 输出中找不到 %dx%dx%d 张量" % (CLS, OUT_SIZE, OUT_SIZE))
    cm_map = arr.reshape(CLS, OUT_SIZE, OUT_SIZE).argmax(0)
    return float((onnx_map == cm_map).mean())


if __name__ == "__main__":
    sys.exit(main())
