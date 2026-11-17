# CUTE Attention 到底有没有用

> 在 Intel Arc B390 上实测：**有帮助，端到端快 4–6.5%**。所有分辨率都会触发，包括 0.5MP 文生图。
> 本文数字全部来自本机（B390 / 16 GB / torch 2.13.0+xpu / omni_xpu_kernel 0.2.0b3+torch213.bmg）。

---

## 一、一句话结论

| 问题 | 答案 |
|---|---|
| CUTE attention 对速度有帮助吗？ | **有。端到端快 4–6.5%** |
| 文生图（0 参考图）会触发吗？ | **会**，`q_len ≥ 512` 就够，0.5MP（2040 token）也在内 |
| 值得为它单独折腾吗？ | **不值得。** 装上 omni 就自动生效，不用管 |
| 那 4 倍提速是哪来的？ | **int8 原生 GEMM**，跟 CUTE 基本无关（见第七节） |

---

## 二、CUTE attention 是什么

`omni_xpu_kernel` 里带了一套手写的 SYCL/DPAS 注意力内核，注册在 `torch.ops.cute_fmha`：

```
torch.ops.cute_fmha.sdp                  # 通用入口
torch.ops.cute_fmha.sdp_bhld_d128        # ← Qwen-Image 2.1 走这个（head_dim=128）
torch.ops.cute_fmha.sdp_bhld_d120
torch.ops.cute_fmha.sdp_minimax_h3_vae_d64
torch.ops.cute_fmha.sdp_wan22_cross
```

`ComfyUI-Intel-Arc-XPU` 插件的 `adapters/attention.py` 会拦截 ComfyUI 的 `optimized_attention()`，
形状匹配时把调用换成 CUTE 内核，不匹配就退回 PyTorch 的 `scaled_dot_product_attention`。

**它只替换 attention 这一件事**，不碰 GEMM、norm、RoPE。所以收益上限就是 attention 在总耗时里的占比。

---

## 三、什么时候触发

### 命中的分支：`general_d128`（`adapters/attention.py:613-624`）

```python
general_d128 = (
    _cute_bhld_general_enabled()      # 环境变量 OMNIXPU_CUTE_BHLD_GENERAL，默认 "1"
    and unmasked_contract             # mask is None 且非 causal、无 dropout、无 GQA、无 scale
    and b >= 1
    and heads >= 1
    and dim_head == 128
    and q_len >= 512                  # ← 唯一的长度门槛
    and kv_len >= 128
    and b * heads * q_len * dim_head <= 2^31 - 1
    and b * heads * kv_len * dim_head <= 2^31 - 1
)
```

门槛很宽松：**只要 `q_len ≥ 512` 且没有 mask**。Qwen-Image 2.1 的目标图那一段正好满足。

### 走回退的部分：带 causal mask 的文本段

Qwen 的 DiT 用 `block_causal_attention()`（`comfy/ldm/qwen_image21/model.py:199`）把序列切成若干 segment，
每段单独调一次 attention：

```python
segments.append((length, length + n, torch.ones((n, length + n), dtype=torch.bool).tril(length)))  # 文本段，有 mask
segments.append((length, length + h * w, None))                                                     # 图段，无 mask
```

**文本段带 mask → 一定走 PyTorch**。CUTE 内核只支持无 mask 的稠密注意力。
所以日志里永远是「CUTE 一次、fallback 一次」交替出现，这是正常的。

### 实测 token 数（从日志读出）

| 配置 | q_len（目标图） | kv_len（文本+目标） | CUTE |
|---|---|---|---|
| 0.5MP 文生图 | 2040 | 2709 | ✅ |
| 0.5MP + 3 参考图 | 2040 | 2709 / 4748 / 6787 | ✅ |
| 1.0MP 文生图 | 4128 | 4797 | ✅ |
| 1.0MP + 3 参考图 | 4128 | 4136 / 8270 / 12404 | ✅ |
| 2.0MP 文生图 | 8160 | 8829 | ✅ |

`kv_len - q_len = 669` 是文本 prompt 的 token 数（`resolution=1024` 时）。

---

## 四、微基准：单次调用快多少

同一份连续 `(B,H,L,D)` bf16 张量，`B=1 H=32 D=128`，预热 5 次、测 30 次取平均。
形状取自上面日志的真实值：

| 场景 | torch SDPA | CUTE | 每次省 | 相对提升 |
|---|---|---|---|---|
| 0.5MP（q2040 / kv2709） | 3.56 ms | 3.15 ms | **+0.41 ms** | **11.5%** |
| 1.0MP（q4128 / kv4797） | 12.58 ms | 11.97 ms | **+0.60 ms** | **4.8%** |
| 2.0MP（q8160 / kv8829） | 45.86 ms | 44.26 ms | **+1.60 ms** | **3.5%** |

**相对提升随尺寸变小** —— 小序列时 CUTE 的 tile 划分优势明显，大序列时两边都变成带宽瓶颈。

---

## 五、端到端 A/B 实测

方法：`OMNI_ATTN_BACKEND` 在 `cute` / `torch` 之间切换 → 重启 ComfyUI → 预热 2 次 →
连续跑 3–4 次取中位数。工作流固定，只改 seed。

| 配置 | `cute` | `torch` | 提升 |
|---|---|---|---|
| **0.5MP 文生图** | **10.9 s**（10.9/10.9/11.0/10.9） | 11.6 s（10.6/10.7/12.4/13.6） | **6.0%** |
| **1.0MP 文生图** | **24.3 s**（22.7/24.3/26.2） | 26.0 s（25.8/26.0/27.6） | **6.5%** |
| **2.0MP 文生图** | **60.1 s**（48.1/60.1/64.3） | 62.7 s（57.9/62.7/73.1） | 4.1% |
| **1.0MP + 3 参考图** | **115 s**（113.6/116.5） | 123 s | **6.5%** |

> 2.0MP 方差很大（DynamicVRAM 在反复换页），4.1% 这个数字置信度最低。
> 0.5MP 是唯一跑满 4 次且 `cute` 组方差极小的配置（10.9 ± 0.05 s），6% 这个值最可信。

### 为什么实测比微基准算出来的多

0.5MP 理论上只该省 `0.41 ms × 32 层 × 12 步 = 0.157 s`，占 10.9 s 的 1.4%，
但实测省了 0.7 s（6%）。

差在**布局转换**：PyTorch 路径拿到的是 BLD 张量，要先 `.view().transpose()` 成 BHLD 再喂 SDPA，
非连续布局会触发额外的 stride 处理甚至拷贝；CUTE 路径用 `as_strided` 构造零拷贝 BHLD 视图直接吃。
微基准里我两边喂的都是**已经连续**的 BHLD 张量，所以没体现出这部分。

---

## 六、attention 占总时间的比例

以 1.0MP 文生图为例（`q=4128, kv=4797`，32 层 × 12 步）：

```
attention 总耗时 ≈ 12.58 ms × 32 × 12 = 4.83 s
整次生成                              = 26.0 s（torch 路径）
                                       ────────
attention 占比                        ≈ 19%
```

2.0MP 时升到约 29%（`45.86 × 32 × 12 = 17.6 s / 62.7 s`），
但 CUTE 的相对优势掉到 3.5%，所以绝对省下 `1.60 × 32 × 12 = 0.61 s`。

---

## 七、那 4 倍提速是哪来的

**跟 CUTE 基本无关。** 拆开看（1.0MP 文生图，每 step）：

| 组件 | 装 omni 前 | 装 omni 后 |
|---|---|---|
| int8 反量化（192 层） | 1470 ms | **0** |
| bf16 GEMM | 2544 ms | **0** |
| int8 原生 GEMM（192 层） | 0 | **758 ms** |
| attention（32 层） | ~370 ms | ~355 ms（CUTE 省 15 ms） |
| rms_rope / adaln | 558 ms | 558 ms |
| **每 step** | **4942 ms** | **~1670 ms** |

**提速的绝大部分来自「不再反量化 + 走原生 int8 GEMM」**，attention 只贡献个位数百分比。

启动日志里那行 `Native ops: int8_tensorwise, asym_w4a8_int8` 才是关键，
`attention_adapter: applied` 只是锦上添花。

---

## 八、建议

### 默认什么都不用做
`OMNI_ATTN_BACKEND` 的默认值就是 `cute`，装上 omni 三包自动生效，收益 4–6%，画质风险低
（实测 0.5 / 1.0 / 2.0MP 及 3 参考图四种配置都没出问题）。

### 画质出问题时第一个关它
```powershell
[Environment]::SetEnvironmentVariable("OMNI_ATTN_BACKEND", "torch", "User")
```
重启 ComfyUI 即完全关闭 CUTE，代价只有 4–6% 的速度。

> B390 的 device id `0xb080` 不在 omni 的已知 SKU 表里，走的是
> `kernel_profile=generic-bmg` / `support=experimental-fallback`。
> 启动日志里会有一行警告：
> ```
> [WARNING] [OmniXPU] experimental capability-driven BMG D128 CUTE route enabled;
>           set OMNI_ATTN_BACKEND=torch to disable it if this workflow shows an issue
> ```
> 如果你在 1.0MP 以上看到花屏、条纹、模糊，**第一个该试的就是关掉 CUTE** ——
> 它是整条链路里唯一标着 `experimental` 的部分。

### 真正该调的旋钮不是它
`resolution`（参考图缩放）和出图分辨率的影响是**几十秒**量级，CUTE 是**零点几秒**量级。
详见 `WORKFLOW-NOTE.md` 第 ③ 节。

---

## 附：怎么自己验证

```python
# 1. 确认内核在
from omni_xpu_kernel import cute
assert cute.is_available()
print(hasattr(torch.ops.cute_fmha, "sdp_bhld_d128"))   # True
```

```powershell
# 2. 确认运行时真的走了 CUTE —— 查日志，别信工作流里的状态节点
Select-String -Path "$env:APPDATA\Comfy Desktop\logs\app.log" -Pattern "OmniXPU\] attention"
```

正常输出（每次生成只打印前 3 次，之后静默计数）：

```
[INFO] [OmniXPU] attention fallback: mask=torch.Size([669, 669]) (seq=669)   ← 文本段，带 mask
[INFO] [OmniXPU] attention CUTE_BHLD_D128 #1: heads=32 q=2040 kv=2709 dtype=torch.bfloat16
[INFO] [OmniXPU] attention fallback: mask=torch.Size([669, 669]) (seq=669)
[INFO] [OmniXPU] attention CUTE_BHLD_D128 #2: heads=32 q=2040 kv=2709 dtype=torch.bfloat16
[INFO] [OmniXPU] attention fallback: mask=torch.Size([669, 669]) (seq=669)
[INFO] [OmniXPU] attention CUTE_BHLD_D128 #3: heads=32 q=2040 kv=2709 dtype=torch.bfloat16
```

> ⚠️ **两个坑**：
> 1. **只打印前 3 次**（`route_call_count <= 3`，`attention.py:1176`）。想再看到就得重启 ComfyUI。
> 2. **别用工作流里的 `OmniXPU Status` 节点判断** —— 它没有输入，ComfyUI 会把它排在最前面执行，
>    那时计数全是 0；而且它的输出会被节点缓存，跑几次都返回同一份文本。**只有日志可信。**
