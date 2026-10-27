"""Convert mattmdjaga/segformer_b2_clothes (ATR 18-class human parsing) to CoreML.

Best effort: this runs as a standalone CI job. If it fails, the iOS build still
produces an IPA - the app falls back to the colour-based exposure estimate and
the parsing model is wired in a later release.
"""
import os
import sys
import urllib.request

MODEL_URL = ("https://huggingface.co/mattmdjaga/segformer_b2_clothes"
             "/resolve/main/onnx/model.onnx")
OUT = sys.argv[1] if len(sys.argv) > 1 else "HumanParsing.mlpackage"

MEAN = [0.485, 0.456, 0.406]
STD = [0.229, 0.224, 0.225]


def main():
    if not os.path.exists("segformer.onnx"):
        print("downloading ONNX ...", flush=True)
        urllib.request.urlretrieve(MODEL_URL, "segformer.onnx")
    print("onnx size %.1f MB" % (os.path.getsize("segformer.onnx") / 1e6))

    import coremltools as ct

    scale = 1.0 / (255.0 * STD[0])
    bias = [-m / s for m, s in zip(MEAN, STD)]
    image_input = ct.ImageType(name="pixel_values",
                               shape=(1, 3, 512, 512),
                               scale=scale, bias=bias,
                               color_layout="RGB")

    last_err = None
    for target in ("mlprogram", "neuralnetwork"):
        try:
            print("converting to", target, flush=True)
            mlmodel = ct.convert("segformer.onnx",
                                 inputs=[image_input],
                                 convert_to=target,
                                 compute_precision=ct.precision.FLOAT16
                                 if target == "mlprogram" else None)
            mlmodel.save(OUT)
            print("OK ->", OUT, target)
            return 0
        except Exception as e:  # noqa: BLE001 - report and try the next target
            last_err = e
            print("FAILED", target, repr(e)[:400], flush=True)
    print("all conversions failed:", repr(last_err)[:600])
    return 1


if __name__ == "__main__":
    sys.exit(main())
