"""把人体解析模型挂进 XcodeGen 工程描述。

转换成功才调用本脚本；转换失败时工程保持原样，App 回退到 Vision 方案。
单独成文件是为了避开 YAML 里 heredoc 的缩进陷阱。
"""
import sys

ANCHOR = ("      - path: PhotoSorter/Resources/labels_default.json\n"
          "        buildPhase: resources\n")
ADD = ("      - path: PhotoSorter/Resources/HumanParsing.mlpackage\n"
       "        type: folder\n"
       "        buildPhase: resources\n")


def main() -> int:
    path = sys.argv[1] if len(sys.argv) > 1 else "project.yml"
    with open(path, encoding="utf-8") as f:
        src = f.read()
    if "HumanParsing.mlpackage" in src:
        print("project.yml 已包含人体解析模型，跳过")
        return 0
    if ANCHOR not in src:
        print("::error::project.yml 锚点未找到，无法注入人体解析模型")
        return 1
    with open(path, "w", encoding="utf-8") as f:
        f.write(src.replace(ANCHOR, ANCHOR + ADD, 1))
    print("project.yml 已注入 HumanParsing.mlpackage")
    return 0


if __name__ == "__main__":
    sys.exit(main())
