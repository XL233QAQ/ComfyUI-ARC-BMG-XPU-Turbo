## Qwen-Image 2.1 · 多参考（ARC BMG XPU Turbo）

在 **Intel Arc Battlemage（B390 / B580 / B570 / B770）** 上跑 Qwen-Image 2.1 多参考生成。
结构和 MiniMax H3 那条多参生视频一样：**左边只放「要调的东西」**，
值通过 `Set_xxx` → `Get_xxx` 送到右边采样区，中间不用拉长线。

> **默认是文生图模式**：6 个 `LoadImage` 全部 **BYPASS**（紫色），
> 打开工作流直接点运行就是纯文字出图，不需要任何图片。

### ① 怎么加参考图

选中要用的 `LoadImage` 节点，按 **Ctrl+B** 取消 BYPASS（变回彩色），
点节点上的 `choose file to upload` 选图。**用几张就启用几个**，
其余保持 BYPASS。启用 1 个就是 1 张参考图，3 个就是 3 张。

**想整组删**：整对删掉 `LoadImage` + `Set_ref_image_N` + `Get_ref_image_N`。
`TextEncodeQwenImage21` 的 `images` 是最多 16 路 autogrow，min=0，删了不报错。
**只删 LoadImage 会留下悬空的 Get，别这么干。**

### ② 能调的控件（都在「③ 参数」框里）

| 控件 | 节点 | 默认 | 作用 |
|---|---|---|---|
| **输出比例** | `ResolutionSelector` · aspect_ratio | 16:9 | 只有开了「自定义尺寸」才生效 |
| **输出像素量** | `ResolutionSelector` · megapixels | 0.5 | 0.5MP@16:9 = **960×544** |
| **对齐倍数** | `ResolutionSelector` · multiple | 32 | Qwen 要求 32 的倍数，别改 |
| **步数** | `INTConstant` · steps | 12 | 8 也行，12 细节更好 |
| **参考图缩放** | `INTConstant` · resolution | 1024 | ★★ **最关键：决定参考图占多少 token** |
| **正向提示词** | `PrimitiveStringMultiline` | — | 可在词里点名「参考图 1 / 2」 |
| **负向提示词** | `PrimitiveStringMultiline` | 空 | cfg=1 时基本不起作用，留空即可 |
| **自定义尺寸？** | `BOOLConstant` · custom_size | 开 | 开 = 用上面的比例+像素量出图 |

> **cfg 和种子没有做成控件**：`cfg` 在 Qwen 2.1 蒸馏版上必须恒为 1.0（改了就崩），
> 直接写死在 KSampler 里；种子交给 KSampler 自带的 `control_after_generate = randomize`。

### ③ ★ 最重要的旋钮：`resolution`

**它只作用于参考图，不影响出图尺寸。** 每张参考图先缩到约 `resolution × resolution`
像素再喂模型，token 数按 `(宽/16) × (高/16)` 算：

| resolution | 每张参考图缩成 | 每张 token | 3 张合计 | 实测耗时（0.5MP / 12 步） |
|---|---|---|---|---|
| **1024** ← 默认 | 1376×768 | 4,128 | 16,512 | **95.7 – 177.2 s** |
| **768** | 1024×576 | 2,304 | 11,040 | **27.4 – 71.2 s** |
| 512 | 672×384 | 1,008 | 7,152 | 21.4 – 54.7 s |
| 384 | 512×288 | 576 | 5,856 | 16.6 – 40.9 s |

对比：**0 张参考图 @ 0.5MP 只有 2,040 token**（约 10.5 s）。
3 张 @ resolution 1024 是它的 **8.1 倍**。**参考图才是 token 大头，不是出图尺寸。**

> **实用建议**：3 张以上参考图时把 `resolution` 降到 **768**，
> 从 158 s 降到约 42 s，参考图的材质/结构信息基本还在。
> 降到 512 更快，但小字和细纹会糊。

### ④ megapixels → 实际分辨率（multiple=32）

| MP | 16:9 | 1:1 | 9:16 | 4:3 |
|---|---|---|---|---|
| 0.4 | 864×480 | 640×640 | 480×864 | 736×576 |
| **0.5** | **960×544** | 736×736 | 544×960 | 832×640 |
| 0.6 | 1056×608 | 800×800 | 608×1056 | 928×672 |
| 0.8 | 1216×672 | 928×928 | 672×1216 | 1056×800 |
| 1.0 | 1376×768 | 1024×1024 | 768×1376 | 1184×896 |
| 1.5 | 1664×928 | 1248×1248 | 928×1664 | 1440×1088 |
| 2.0 | 1920×1088 | 1440×1440 | 1088×1920 | 1664×1248 |

### ⑤ 实测性能（B390 / 16 GB / 12 步 / 0 参考图）

| 输出 | 升级前（原版 ComfyUI） | 升级后（本工作流） | 提升 |
|---|---|---|---|
| 0.5 MP（960×544） | 42 – 47 s | **10.5 – 10.8 s** | **约 4×** |
| 1.0 MP（1376×768） | 66 – 71 s | **21.6 s** | 约 3× |
| 2.0 MP（1920×1088） | **OOM，跑不了** | **67.9 – 69.7 s** | 从不可用变可用 |

> 反直觉的一点：**升级后跑 1.0MP（21.6 s）比升级前跑 0.5MP（42–47 s）还快。**

### ⑥ 为什么快：int8 走原生内核

这个工作流用的是 int8_convrot 量化模型（扩散 6.76 GB + 文本编码器 8.71 GB），
bf16 版要 31.6 GB，16 GB 卡装不下 —— **不是选错了量化，是没得选**。

问题是 ComfyUI 原版对 XPU 硬编码了 `supports_int8_compute() = False`，
int8 权重会**每次前向现场反量化**：192 层共 **1,544 ms/step**，12 步白烧 **18.5 秒**，
而且 `img_mlp.gate_up` 一层就要额外 805 MB 显存 —— 这就是 OOM 的来源。

装上 omni 三包后启动日志从：

```
Native ops:  , emulated ops: convrot_w4a4, mxfp8, nvfp4, int8_tensorwise, ...
```

变成：

```
Native ops: int8_tensorwise, asym_w4a8_int8 , emulated ops: ...
```

`Native ops` 里有 `int8_tensorwise` = 真的走原生 SYCL 内核了。

### ⑦ 省显存：EasyCache + VRAM_Debug

| 节点 | 位置 | 干什么 | 怎么调 |
|---|---|---|---|
| **EasyCache** | `Get_model` → **EasyCache** → `KSampler` | 估算「这一步的变化量」，变化小就复用上一步残差、**整步跳过不算** | `reuse_threshold` 默认 **0.05**（无损） |
| **VRAM_Debug** | `VAEDecode` → **VRAM_Debug** → `SaveImage` | 每跑完一张，`torch.xpu.synchronize()` + `empty_cache()` + `gc.collect()` | `empty_cache` / `gc_collect` 保持开；`unload_all_models` 默认**关** |

**EasyCache 阈值实测**（6 图 / 0.5MP / 12 步 / seed 固定）：

| threshold | 跳步 | 耗时 | 加速 | PSNR | 结论 |
|---|---|---|---|---|---|
| 无 | 0/12 | 169.4 s | 1.00× | — | 基线 |
| **0.05** | 2/12 | 143.1 s | 1.18× | **37.08 dB** | ★ **视觉无损，默认值** |
| 0.1 | 4/12 | 132.9 s | 1.27× | 33.75 dB | 均衡，可接受 |
| 0.2 | 5/12 | 114.8 s | 1.48× | 29.70 dB | 画质明显漂移 |
| 0.3 | 6/12 | 106.7 s | 1.59× | 27.90 dB | 换了一张相似的图 |

> **EasyCache 会破坏可复现性**：同 seed 同 prompt，开/不开、不同阈值都出不同的图。
> 需要严格复现时把它 BYPASS（Ctrl+B）。

> **为什么要 VRAM_Debug**：Intel Arc 上「第一张能跑、第二张报
> `UR_RESULT_ERROR_OUT_OF_RESOURCES`（level_zero error 40）」几乎都是
> PyTorch XPU 分配器把释放过的块攥着不放。`unload_all_models` 打开会连模型一起卸，
> 下一张冷启动多花约 55 s，所以默认关 —— **只在显存真不够时再打开。**

### ⑧ 运行状态：OmniXPU Status → Preview as Text

`OmniXPUStatus` 是 OmniXPU 插件**唯一**注册的节点，不参与生成，只吐诊断文字。
接一个内置 `PreviewAny`（显示名 "Preview as Text"）就能印在画布上。

```
[103] OmniXPUStatus ──STRING──> [104] PreviewAny
```

**跑完一次后** `PreviewAny` 上显示：

| 行 | 正常值 |
|---|---|
| `GPU` | `Intel(R) Arc(TM) B390 GPU (16858 MB)` |
| `omni_xpu_kernel` | `0.2.0b3+torch213.bmg` |
| `available` | 至少要有 `norm, rotary, int8` |
| `runtime providers` | `active (mode=auto)`，两个都 `active` |
| `comfy_kitchen XPU` | `available (50 capabilities)` |
| `[+] / [-]` 行 | `[+]` 越多越好 |

> ⚠️ **这个节点有两个先天缺陷，别指望它实时刷新**：
>
> 1. **它没有输入**，所以 ComfyUI 会把它排在最前面执行 —— 采样还没开始，
>    计数全是 0，`Attention calls` 那行（只有非 0 才打印）根本不出现。
> 2. **它的输出会被节点缓存**（没输入、也没有 `IS_CHANGED`），
>    第一次算出来是什么，后面就一直返回什么，**改了参数也不会更新**。
>
> 想要它刷新，**改一下任意一个上游参数**（比如步数）让整个图重新执行，
> 或者点 ComfyUI 的 `Refresh Node Definitions`。
> 真要确认 CUTE 是否生效，**看启动日志更可靠**：
> ```
> app.log 里搜 "OmniXPU] attention"
>   [OmniXPU] attention[cute]: rebound 57 by-value imports   ← 补丁装上了
>   [OmniXPU] attention CUTE_BHLD_D128 #1: heads=32 q=4128 kv=4136   ← 真的在跑
>   [OmniXPU] attention fallback: mask=torch.Size([667, 13071])      ← 带 mask 的走回退
> ```

**CUTE 什么时候触发**（源码 `adapters/attention.py:613-624` 的 `general_d128` 分支）：

```python
general_d128 = (mask is None and dim_head == 128
    and q_len >= 512 and kv_len >= 128   # ← 门槛就这么宽
    and not is_causal and not dropout_p ...)
```

| 场景 | q_len | kv_len | CUTE？ |
|---|---|---|---|
| 0.5MP 0 图 | 2040 | 2709 | ✅ |
| 1.0MP 0 图 | 4128 | 4797 | ✅ |
| 1.0MP + 3 图 | 4128 | 4136 / 8270 / 12404 | ✅ |
| 文本段（带 causal mask） | — | — | ❌ 永远走 PyTorch |

> 实测 CUTE 端到端快 **4–6.5%**（0.5MP 10.9s vs 11.6s）。完整数据见
> `docs/CUTE-ATTENTION.md`。
>
> **那 4 倍提速来自 int8 原生 GEMM，不是 CUTE attention** —— CUTE 只省零点几秒。
> 别搞混这两件事。

**排障速查**：
- `comfy_kitchen XPU: unavailable` → omni 三包没装好
- 某行以 `[!!]` 开头 → 那个 adapter 挂了
- 想看 CUTE 真实调用 → 查 `app.log`，别信这个节点

**不想要就整组删掉**（选中 ⑤ 组里两个节点按 Delete），对生成零影响。

### ⑨ Set / Get 对照表

| Set | Get | 类型 | 送到 |
|---|---|---|---|
| `Set_model` | `Get_model` | MODEL | EasyCache → KSampler.model |
| `Set_clip` | `Get_clip` | CLIP | TextEncodeQwenImage21.clip |
| `Set_vae` | `Get_vae` ×2 | VAE | TextEncodeQwenImage21.vae + VAEDecode.vae |
| `Set_ref_image_0…5` | `Get_ref_image_0…5` | IMAGE | TextEncodeQwenImage21.images.image_N |
| `Set_prompt` | `Get_prompt` | STRING | TextEncodeQwenImage21.prompt |
| `Set_negative` | `Get_negative` | STRING | TextEncodeQwenImage21.negative_prompt |
| `Set_resolution` | `Get_resolution` | INT | TextEncodeQwenImage21.resolution |
| `Set_width` / `Set_height` | `Get_width` / `Get_height` | INT | EmptyLatentImage.width / height |
| `Set_custom_size` | `Get_custom_size` | BOOLEAN | ComfySwitchNode.switch |
| `Set_steps` | `Get_steps` | INT | KSampler.steps |

> Set/Get 是 KJNodes 的**纯前端虚拟节点**，不参与后端执行，
> 所以 `/object_info` 查不到它们，但画布上完全正常。
> 想看某条线连到哪：右键 `Get_xxx` → `Go to Set_xxx`。

### ⑩ KV Cache（`QwenImage21Cache` 节点）

| 配置 | 8 步 | 峰值显存 | 耗时 |
|---|---|---|---|
| **auto / int8** ← 当前 | ✅ | 11.38 GB | **342 s** |
| gpu / int8 | ✅ | 10.55 GB | 468 s |
| cpu / default | ✅ | 11.08 GB | 517 s |
| gpu / default | ❌ OOM | 13.57 GB | — |
| auto / default | ❌ OOM | 15.02 GB | — |

KV Cache **不是「缓存放哪」，是「要不要缓存」**。6 图 + resolution 1024 时
缓存本体要 12.1 GB（int8），显存腾不出来，所以前两种其实都没建成缓存，
每步都在重算前缀。想真正吃到缓存：参考图降到 2–3 张，或 `resolution` 降到 512。

> 装了 omni 之后这条路径才真正可用 —— 日志里能看到
> `Model KVCacheModel prepared for dynamic VRAM loading. 110MB Staged.`
