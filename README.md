# ComfyUI-ARC-BMG-XPU-Turbo

> **Qwen-Image 2.1 在 Intel Arc Battlemage 上的整合加速方案**
> 把 40% 白烧在反量化上的时间抢回来，把 OOM 变成能跑。

[![Platform](https://img.shields.io/badge/platform-Windows%20x64-blue)]()
[![GPU](https://img.shields.io/badge/GPU-Intel%20Arc%20BMG-0071C5)]()
[![torch](https://img.shields.io/badge/torch-2.13.0%2Bxpu-EE4C2C)]()
[![License](https://img.shields.io/badge/license-MIT-green)]()

---

## 这是什么

如果你用 Intel Arc 显卡（B390 / B580 / B570 / B770 等 Battlemage 架构）跑 ComfyUI 生成图片，
大概率遇到过这两件事：

1. **慢得离谱** —— 一张 0.5MP 的图要 40 多秒
2. **第二张就崩** —— 第一次能出图，第二次报 `UR_RESULT_ERROR_OUT_OF_RESOURCES`（level_zero error 40）

这两个问题的根因是一样的：**ComfyUI 官方对 XPU 硬编码了「不支持 int8 计算」**。

```python
# comfy/model_management.py:2154  supports_int8_compute()
if is_intel_xpu():
    return False          # ← 一票否决
```

后果是：int8 量化的权重**每次前向都要现场反量化回 bf16**，反量化完再算。
192 层的模型，光反量化就烧掉 **1,544 ms/step**，12 步白扔 **18.5 秒**。
更糟的是 `img_mlp.gate_up` 这一层反量化时峰值要多占 **805 MB** 显存 —— 这就是 OOM 的来源。

这个项目做的事很简单：**把 int8 计算在 XPU 上真正打开**，让它走原生 SYCL 内核，
不再反量化、不再占那 805 MB。

结果（B390 / 16 GB 实测）：

| 配置 | 原版 ComfyUI | 本项目 | 提升 |
|---|---|---|---|
| **0.5 MP 文生图**（960×544，12 步） | 42 – 47 s | **10.9 s** | **4.2×** |
| **1.0 MP 文生图**（1376×768，12 步） | 66 – 71 s | **24.3 s** | **2.9×** |
| **2.0 MP 文生图**（1920×1088，12 步） | ❌ OOM，跑不了 | **60 s** | 从不可用变可用 |

> 反直觉的一点：**升级后跑 1.0MP（24.3 s）比升级前跑 0.5MP（42–47 s）还快。**

---

## 免责声明 / 先说清楚

- **这不是我写的加速内核。** 真正的技术全部来自下面这些开源项目，本仓库只是把它们**整合**成
  一条对 Qwen-Image 2.1 开箱即用的路径，附带一份调好的工作流和实测数据。
- **只在 B390 上验证过**。其他 Battlemage 型号（B580 / B570 / B770）理论上同样受益
  （`omni_xpu_kernel` 的 wheel 是 `bmg` target，全系通用），但我没有卡去测。
- **只验证过 Qwen-Image 2.1**。其他模型（FLUX / SDXL / Wan 视频）请自行测试。

---

## 依赖的上游项目

| 项目 | 作用 | 许可证 |
|---|---|---|
| [wildersa/ComfyUI-Intel-Arc-XPU](https://github.com/wildersa/ComfyUI-Intel-Arc-XPU) | 总装：把 XPU 内核接到 ComfyUI 上，21 个 adapter | Apache-2.0 |
| [omni_xpu_kernel](https://github.com/wildersa/ComfyUI-Intel-Arc-XPU/releases) | 手写 SYCL/DPAS 内核（int8 GEMM、RMSNorm、RoPE、attention） | Apache-2.0 |
| [comfy-kitchen](https://github.com/comfyanonymous/ComfyUI) `xpu` backend | 把 xpu 后端插到 `comfy_kitchen` 的 registry 最前 | Apache-2.0 |
| [comfy-aimdo-xpu](https://github.com/xiangyuT/comfy-aimdo-xpu) | XPU 版动态显存卸载器（VBAR 机制） | GPL-3.0 |
| [ComfyUI](https://github.com/comfyanonymous/ComfyUI) | 本体 | GPL-3.0 |
| [ComfyUI-KJNodes](https://github.com/kijai/ComfyUI-KJNodes) | `VRAM_Debug` / `INTConstant` / `BOOLConstant` 节点 | GPL-3.0 |

**本仓库不打包任何二进制**，`install.py` 只负责从上游 release 下载并校验 SHA256。
所以本仓库自己可以是 MIT —— GPL 的义务只在「分发」时触发，而这里没有分发任何 GPL 代码。

---

## 环境要求

**只需要两样东西：一张 Intel Arc Battlemage 显卡，和一个 ComfyUI。**

| 项 | 要求 |
|---|---|
| 操作系统 | Windows x64 |
| GPU | Intel Arc Battlemage（B390 / B580 / B570 / B770） |
| 显存 | ≥ 12 GB（16 GB 舒适） |
| ComfyUI | ≥ 0.45.0，官方 Windows 便携版 / Comfy Desktop（两者都是 Python 3.13） |

剩下的**全部由 `install.py` 自动处理**：

- Python 版本 → 脚本会读取 ComfyUI venv 里的实际版本并校验，不匹配会明确告诉你（官方构建都是 3.13）
- PyTorch 版本 → 脚本检测到不是 `2.13.0+xpu` 就自动升级，连带 oneAPI 运行时一起装
- 3 个原生内核 wheel → 自动下载 + SHA256 校验
- custom node → 自动下载解压
- 启动参数、环境变量 → 自动写入
- 工作流 → 自动复制到 ComfyUI 的 workflows 目录

> 你**不需要**自己装 Python、不需要自己装 torch、不需要手动 pip install 任何东西。
> 只要 ComfyUI 能跑起来，跑一次 `install.py` 就行。

> **关于 torch 升级**：`omni_xpu_kernel` 的 wheel 文件名里带 `+torch213`，只跟 2.13.0 精确匹配。
> 如果你现在是 2.12.x，脚本会自动升级（约 2 GB 下载，30 分钟以上）。
> 已经有 2.13.0+xpu 的话这步会秒过。

---

## 快速开始

**一条命令。** 打开 PowerShell，粘贴这一行回车：

```powershell
powershell -ExecutionPolicy Bypass -c "irm https://raw.githubusercontent.com/XL233QAQ/ComfyUI-ARC-BMG-XPU-Turbo/main/install.ps1 | iex"
```

它会自己找到 ComfyUI、下载仓库、跑完安装。装完重启 ComfyUI 就行。

<details>
<summary>这条命令太长 / 被墙了？点这里看别的装法</summary>

**装法 B —— 下载 zip 手动解压（完全不需要 git 和网络工具）**

1. 浏览器打开 `https://github.com/XL233QAQ/ComfyUI-ARC-BMG-XPU-Turbo/archive/refs/heads/main.zip`
2. 解压到 `<ComfyUI>\custom_nodes\ComfyUI-ARC-BMG-XPU-Turbo\`
3. 在解压出来的目录里，右键 `install.ps1` → **使用 PowerShell 运行**
   （或者在这个目录开 PowerShell 跑 `powershell -ExecutionPolicy Bypass -File install.ps1`）

**装法 C —— 已经在 ComfyUI 的 custom_nodes 里了**

```powershell
cd "<你的ComfyUI>\custom_nodes\ComfyUI-ARC-BMG-XPU-Turbo"
powershell -ExecutionPolicy Bypass -File install.ps1
```

**只想看看它会做什么，不真的改东西** —— 任何装法后面都加 `-DryRun`：

```powershell
powershell -ExecutionPolicy Bypass -File install.ps1 -DryRun
```

</details>

> **为什么不用 `git clone`？** 因为很多人的 Windows 上根本没装 git。
> `install.ps1` 用 HTTP 下载 zip，不需要 git、不需要管理员权限。

### 安装脚本会做这些事

`install.ps1` 只是个引导器：下载仓库 → 找一个 Python → 交给 `install.py`。
真正干活的是 `install.py`：

1. 找到 ComfyUI 根目录和它的 venv python（支持 Comfy Desktop 和便携版两种布局）
2. **校验 ComfyUI venv 的 Python 版本**（wheel 是 cp313 的，不匹配会明确报错）
3. 检查 `torch == 2.13.0+xpu`，不匹配就**自动升级**（`-SkipTorch` 可跳过）
4. 从 `wildersa/ComfyUI-Intel-Arc-XPU` 的 release 下载 3 个 wheel，**逐个校验 SHA256**
   - 走 16 线程分段 Range 下载（26.6 MB 约 95 秒，单线程要 73 分钟）
   - GitHub 直连失败自动换 `gh-proxy.com` / `ghfast.top` 镜像
5. 安装 3 个 wheel（`--no-deps`，不动依赖树）
6. 把 `ComfyUI-Intel-Arc-XPU` 这个 custom node 放到位
7. 修改 Comfy Desktop 的 `installations.json`，往**目标安装**的 `launchArgs` 加
   `--enable-dynamic-vram --reserve-vram 4`
   - 保留原有的 `--enable-manager`
   - **只改当前这个 ComfyUI 对应的条目**，不会波及你同时装的 AI Video 等其它安装
   - 改前自动备份成 `installations.json.arc-turbo.bak`
8. 设置用户环境变量 `OMNI_ATTN_BACKEND=cute`
9. 把工作流复制到 ComfyUI 的 `user/default/workflows/`

### 命令行选项

| 选项 | 作用 |
|---|---|
| `-DryRun` / `--dry-run` | 只打印计划，不做任何修改（**不下载任何东西**） |
| `-SkipTorch` / `--skip-torch` | 跳过 torch 升级（已经手动升过就用这个） |
| `-NoDownload` / `--no-download` | 用本地 `wheels/` 里已有的 wheel，不联网 |
| `-TargetDir <path>` | 指定仓库解压到哪（默认放到 ComfyUI 的 `custom_nodes/` 下） |

### 装完怎么确认真的生效了

重启 ComfyUI，打开工作流跑一次，看 **「OmniXPU 状态」** 那个节点：

```
Attention calls: cute=960 esimd=0 torch=0
```

`torch=0` 就说明原生内核全接上了。或者去启动日志里搜 `Native ops:`，
应该看到 `int8_tensorwise` 出现在 **Native** 那一侧而不是 `emulated`。

---

## 模型下载

工作流需要 3 个文件，放到 ComfyUI 的 `models/` 下：

| 文件 | 大小 | 放到 |
|---|---|---|
| `qwen_image_2.1_int8_convrot.safetensors` | 7.26 GB | `models/diffusion_models/Qwen-Image-2.1/` |
| `qwen3vl_8b_int8_convrot.safetensors` | 9.35 GB | `models/text_encoders/Qwen-Image-2.1/` |
| `qwen_image_2.1_vae_bf16.safetensors` | 0.68 GB | `models/vae/Qwen-Image-2.1/` |

> **为什么必须是 int8 版？** bf16 版扩散模型 14.23 GB + 文本编码器 17.4 GB = **31.6 GB**，
> 16 GB 卡装不下。**不是选错了量化，是没得选。**
>
> int8 本身几乎无损：实测权重往返误差 **0.94%**（SNR **40.5 dB**），肉眼看不出。
> 参考：EasyCache 阈值 0.05 对应 37.08 dB，已经算「视觉无损」了。

---

## 性能基准

所有数字来自 **Intel Arc B390 / 16 GB / Windows 11 / torch 2.13.0+xpu / Python 3.13.12**，
ComfyUI 0.45.3，12 步，EasyCache 0.05，热启动（模型已在显存里）。

### 文生图（0 参考图）

| 输出 | 原版 | 本项目 | 提升 |
|---|---|---|---|
| 0.5 MP（960×544） | 42 – 47 s | **10.9 s** | **4.2×** |
| 1.0 MP（1376×768） | 66 – 71 s | **24.3 s** | **2.9×** |
| 2.0 MP（1920×1088） | OOM | **60 s** | — |

### 带参考图（3 张 2048×1152）

`resolution` 这个参数（每张参考图缩放到多大）是**影响最大的旋钮**，
因为它直接决定 prefix 的 token 数：

| `resolution` | 每张参考图 | 每张 token | 3 张总 token | 耗时 |
|---|---|---|---|---|
| **1024**（默认） | 1376×768 | 4,128 | 16,512 | 95.7 – 177.2 s |
| **768** | 1024×576 | 2,304 | 11,040 | **27.4 – 71.2 s** |
| 512 | 672×384 | 1,008 | 7,152 | 21.4 – 54.7 s |
| 384 | 512×288 | 576 | 5,856 | 16.6 – 40.9 s |

> 从 1024 降到 768，耗时从 ~125 s 掉到 ~42 s，**而画质差别几乎看不出来** ——
> 参考图只是用来提取「长什么样」的语义，768 已经够。

### 提速来源归因

以 1.0MP 文生图为例，每 step：

| 组件 | 装 omni 前 | 装 omni 后 |
|---|---|---|
| int8 反量化（192 层） | 1470 ms | **0** |
| bf16 GEMM（192 层） | 2544 ms | **0** |
| int8 原生 GEMM（192 层） | 0 | **758 ms** |
| attention（32 层） | ~370 ms | ~355 ms |
| rms_rope / adaln | 558 ms | 558 ms |
| **每 step** | **4942 ms** | **~1670 ms** |

**93% 的提速来自「不再反量化 + 走原生 int8 GEMM」。**
CUTE attention 只贡献 4–6%，详见 [docs/CUTE-ATTENTION.md](docs/CUTE-ATTENTION.md)。

### 怎么确认真的生效了

启动日志里搜 `Native ops`：

```
# 装之前（int8 全部走模拟）
Using mixed precision operations
Native ops:  , emulated ops: convrot_w4a4, mxfp8, nvfp4, int8_tensorwise, ...

# 装之后（int8 走原生内核）
Using mixed precision operations
Native ops: int8_tensorwise, asym_w4a8_int8 , emulated ops: ...
```

还有这些也应该出现：

```
[INFO] comfy-aimdo inited for GPU: Intel(R) Arc(TM) B390 GPU (VRAM: 16858 MB)
[INFO] DynamicVRAM support detected and enabled
[INFO] [OmniXPU] omni_xpu_kernel 0.2.0b3+torch213.bmg - available: sdp, norm, rotary, linear_fp8, int8, layout
[INFO] [OmniXPU] quantized_matmul_adapter: applied
[INFO] [OmniXPU] attention[cute]: rebound 57 by-value imports across sys.modules
[INFO] [OmniXPU] attention CUTE_BHLD_D128 #1: heads=32 q=2048 kv=2709 dtype=torch.bfloat16
```

---

## 工作流说明

`workflows/Qwen-Image-2.1-MultiRef-BMG-XPU.json` —— 60 节点 / 44 连线 / 5 分组。

**默认是纯文生图模式**（6 个 LoadImage 全部 BYPASS）。

| 分组 | 内容 |
|---|---|
| ① 模型 | UNETLoader / CLIPLoader / VAELoader / QwenImage21Cache |
| ② 参考图（可整对删） | 6 组 LoadImage + Set/Get_ref_image_N |
| ③ 参数（改这里） | ResolutionSelector / steps / resolution / prompt / negative |
| ④ 采样 / 输出 | TextEncode / KSampler / VAEDecode / VRAM_Debug / SaveImage |
| ⑤ 运行状态（可选） | OmniXPU Status → Preview as Text |

### 想加参考图

选中任意一个 `LoadImage` 节点按 **Ctrl+B** 取消 BYPASS，上传图片即可。
支持 1–6 张，多参考图用 `Set_ref_image_N` / `Get_ref_image_N` 配对传送。

**别忘了同时把 `resolution` 调对** —— 这是最容易踩的坑，见下面 Troubleshooting。

### 主要可调参数

| 参数 | 默认 | 说明 |
|---|---|---|
| `ResolutionSelector.megapixels` | **0.5** | 出图分辨率。1.0 更清晰但慢 2.2 倍 |
| `INTConstant.steps` | **12** | 步数 |
| `INTConstant.resolution` | **1024** | ★ 参考图缩放尺寸。**没有参考图时这个参数不起作用** |
| `QwenImage21Cache` | auto / int8 | KV prefix 缓存 |
| `EasyCache.reuse_threshold` | **0.05** | 0.05 视觉无损（37 dB）；0.1 更快但开始漂移；0.2+ 明显变脸 |
| `VRAM_Debug.unload_all_models` | **False** | 打开会连模型一起卸，下一张冷启动多花 55 s |

完整说明见工作流里的 MarkdownNote（右上角那张长条），或 [docs/WORKFLOW-NOTE.md](docs/WORKFLOW-NOTE.md)。

---

## Troubleshooting

### 装完还是慢 / `Native ops` 还是空的

按顺序查：

1. `torch` 版本对不对：`python -c "import torch; print(torch.__version__)"` → 必须是 `2.13.0+xpu`
2. `omni_xpu_kernel` 在不在：`python -c "import omni_xpu_kernel as k; print(k.is_available())"` → 必须 `True`
3. 启动日志里有没有 `[OmniXPU] ... applied`。如果全是 `skipped`，看 `OMNI_*` 环境变量是不是被设成了 0
4. **改完环境变量必须重启 ComfyUI**，只重载页面没用

### `ImportError: DLL load failed while importing _C`

**不要** `from omni_xpu_kernel import _C`。这个包需要先注册 DLL 搜索路径，走公开 API：

```python
import omni_xpu_kernel as k
k.is_available()          # 会顺带完成 DLL 注册
from omni_xpu_kernel import int8
```

### 第二张图报 `UR_RESULT_ERROR_OUT_OF_RESOURCES`

先确认 `launchArgs` 里有 `--enable-dynamic-vram --reserve-vram 4`。
如果还不行，把 `VRAM_Debug` 的 `unload_all_models` 打开（代价是每张图冷启动）。

### 带参考图时特别慢（100 秒以上）

99% 是 `resolution` 还是默认的 **1024**。改成 **768**，耗时立刻从 ~125 s 降到 ~42 s。
这个参数只影响参考图缩放，不影响出图尺寸。

### 画质异常：花屏、条纹、模糊

**第一个该试的是关掉 CUTE attention**：

```powershell
[Environment]::SetEnvironmentVariable("OMNI_ATTN_BACKEND", "torch", "User")
```

重启 ComfyUI。代价只有 4–6% 的速度。

> 原因：B390 的 device id `0xb080` 不在 omni 的已知 SKU 表里，走的是
> `kernel_profile=generic-bmg` / `support=experimental-fallback`。
> 启动日志里会有一行：
> ```
> [WARNING] [OmniXPU] experimental capability-driven BMG D128 CUTE route enabled;
>           set OMNI_ATTN_BACKEND=torch to disable it if this workflow shows an issue
> ```
> 这是整条链路里唯一标着 `experimental` 的部分。

### `WARNING: Potential Error in code: Torch already imported`

**这是预期行为，不是故障。** omni 必须在 ComfyUI 初始化前导入 torch 才能挂上 XPU 分配器钩子
（`runtime_bootstrap.py:502`）。装上 omni 后出现这行是正常的。

### Comfy Desktop 自动"修复"回旧版 torch

`installations.json` 里有个 `lastVerifiedTorchStack.packages.torch` 字段，
如果它写的是 `2.12.1+xpu`，Desktop 的自动更新可能会尝试装回旧版。

处理：把 `autoUpdateComfyUI` 设成 `false`，或者升级后手动更新这个字段。

### `triton` 相关报错（只在独立脚本里出现）

独立脚本里调 `comfy_kitchen` 会走 triton 后端，Windows 上炸
`UnicodeDecodeError: 'gbk' codec can't decode byte`。手动关掉：

```python
import comfy_kitchen as ck
ck.registry.disable("triton")
```

ComfyUI 主进程里会自动关（`comfy/quant_ops.py:41`），不用管。

---

## 目录结构

```
ComfyUI-ARC-BMG-XPU-Turbo/
├── install.ps1                                  # 一键安装入口（不需要 git）
├── install.py                                   # 真正的安装逻辑（597 行）
├── publish.ps1                                  # 上传到 GitHub（不需要 git）
├── pyproject.toml                               # Comfy Registry 元数据
├── LICENSE                                      # MIT + 第三方组件清单
├── README.md                                    # 本文件
├── docs/
│   ├── WORKFLOW-NOTE.md                         # 工作流完整说明（10 节）
│   └── CUTE-ATTENTION.md                        # CUTE attention 实测报告
├── workflows/
│   └── Qwen-Image-2.1-MultiRef-BMG-XPU.json     # 调好的工作流
└── examples/                                    # 示例图（待补）
```

---

## 已经发布到哪了

| 位置 | 地址 | 状态 |
|---|---|---|
| GitHub 仓库 | https://github.com/XL233QAQ/ComfyUI-ARC-BMG-XPU-Turbo | ✅ 公开 |
| Comfy Registry | https://registry.comfy.org/nodes/comfyui-arc-bmg-xpu-turbo | ✅ 已提交 `1.0.2`（`NodeVersionStatusPending`，等官方扫描） |

装好 ComfyUI-Manager 后可以在 Manager 里搜 `ARC Bmg XPU Turbo` 或 `arc-bmg-xpu-turbo`。

---

## 怎么自己发一份（fork 之后想换个名字/仓库）

本仓库自带 `publish.ps1`，**不需要 git、不需要 gh CLI**，只走 GitHub REST API。
`XL233QAQ` 占位符会在上传前自动替换成你的真实用户名。

### 第一步：拿一个 token

1. 打开 https://github.com/settings/tokens/new
2. **Note** 填 `ARC BMG XPU Turbo`，**Expiration** 选 7 天就够
3. **Scope 勾上整个 `repo` 分组**（这是唯一必须勾的）
4. 点 Generate，复制那串 `ghp_...`（**只显示一次，关掉就看不到了**）

### 第二步：预演（不需要 token，不联网）

```powershell
cd C:\AI_omni\ComfyUI-ARC-BMG-XPU-Turbo
powershell -ExecutionPolicy Bypass -File publish.ps1 -DryRun
```

会打印将要上传的 11 个文件清单，让你确认没有漏东西、也没有混进不该传的。

### 第三步：正式上传

```powershell
powershell -ExecutionPolicy Bypass -File publish.ps1 -Token ghp_你的token
```

脚本会依次做：

1. 用 token 调 `/user` 确认身份，拿到你的用户名
2. **把 `README.md` / `install.ps1` / `pyproject.toml` 里的 `XL233QAQ` 替换成你的用户名**
3. 仓库不存在就在你账号下创建（自动带描述）
4. 逐个文件通过 contents API 上传
5. 设置仓库描述 + 10 个 topics（`comfyui` / `intel-arc` / `battlemage` / `xpu` / `int8` …）

**之后改了文件要再同步**，加 `-Update`：

```powershell
powershell -ExecutionPolicy Bypass -File publish.ps1 -Token ghp_你的token -Update
```

### 可选参数

| 参数 | 作用 |
|---|---|
| `-DryRun` | 只列文件，不联网不上传（**不需要 token**） |
| `-RepoName <name>` | 换仓库名（默认 `ComfyUI-ARC-BMG-XPU-Turbo`） |
| `-Private` | 建成私有仓库 |
| `-Update` | 仓库已存在，同步文件 |

脚本自动跳过 `wheels/`、`.git/`、`__pycache__/`、`*.log`、`*.zip`、`*.whl` 等不该上传的东西。

### 上 Comfy Registry（让用户在 ComfyUI-Manager 里能搜到）

本项目已经发布过了，`[tool.comfy] PublisherId = "xl233qaq"` 已填好，直接：

```powershell
pip install comfy-cli
comfy node publish --token <你的 PAT>
```

PAT 在 https://registry.comfy.org 的账号设置里生成，形如 `pat-xxxxxxxx-...`。
**每次发新版本要先改 `pyproject.toml` 的 `version`** —— 同一个版本号不能发两次（会返回 `The node version already exists`）。

两个坑：

1. `supported_os` / `supported_accelerators` **不是自由填的**，要从 `classifiers` 推：
   ```toml
   classifiers = [
       "Operating System :: Microsoft :: Windows",
       "Environment :: GPU :: Intel Arc",
   ]
   ```
   合法值只有 `Operating System :: Microsoft|POSIX|MacOS|OS Independent` 和
   `Environment :: GPU :: NVIDIA CUDA|AMD ROCm|Intel Arc`、`NPU :: Huawei Ascend`、`GPU :: Apple Metal`。
   写错了整条发布请求会 400（`supported os is invalid`），**而且 node 会被创建出来但版本缺失**。
2. `comfy node publish` 在没有 git 的机器上会打印
   `Warning: Not in a git repository or git not installed. Zipping all files.`
   然后按 `.comfyignore` 打包**整个目录** —— 所以 `.comfyignore` 里必须挡住
   `wheels/`、`.ruff_cache/`、`__pycache__/`、`*.log` 这些，否则 27 MB 的 wheel 会被打进 zip。

---

## 相关文档

- [docs/WORKFLOW-NOTE.md](docs/WORKFLOW-NOTE.md) —— 每个控件的详细说明、实测耗时表、Set/Get 对照表
- [docs/CUTE-ATTENTION.md](docs/CUTE-ATTENTION.md) —— CUTE attention 值不值得开、触发条件、A/B 数据

---

## 上游生态

Intel Arc 上还有这些项目值得关注：

| 项目 | 说明 |
|---|---|
| [IntelGpu-ComfyUI-Collection](https://allanmeng.github.io/IntelGpu-ComfyUI-Collection/) | 社区维护的 Arc 生态索引，每 2 小时刷新 |
| [ComfyUI-XPUSYS-Monitor](https://github.com/allanmeng/ComfyUI-XPUSYS-Monitor) | 顶部菜单栏实时显示 GPU/CPU/内存 |
| [HQH-XPU](https://github.com/hqh330/HQH-XPU) | A770 整合包，含 INT4 量化和两阶段清理 |
| [intel/llm-scaler](https://github.com/intel/llm-scaler) | Intel 官方的 BMG 推理镜像 |

---

## Contributing

最有用的贡献是**在其他 Battlemage 型号上的实测数据**（B580 / B570 / B770）。
如果你测了，请开 issue 附上：

- GPU 型号 + 显存
- `torch.__version__` / `omni_xpu_kernel.__version__`
- 0.5MP / 1.0MP / 2.0MP 文生图的耗时
- 启动日志里 `Native ops:` 那一行

---

## License

MIT —— 见 [LICENSE](LICENSE)。

本仓库**不包含**任何第三方二进制。运行时依赖的组件许可证列在 LICENSE 文件末尾，
其中 `comfy-aimdo` 和 ComfyUI 本体是 GPL-3.0（自己用不触发义务，只在分发时触发）。

---

## 致谢

- [wildersa](https://github.com/wildersa) —— 整个 XPU 内核栈的作者，技术含量最高的部分全在这里。
  这个项目目前 **0 star**，但它让 16 GB 的 Arc 卡能干 30 GB 的活。
- [xiangyuT](https://github.com/xiangyuT) —— comfy-aimdo-xpu
- [kijai](https://github.com/kijai) —— ComfyUI-KJNodes
