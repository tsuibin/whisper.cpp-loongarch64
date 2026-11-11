# whisper.cpp on loongarch64 — 实测记录

在龙芯 3B6000M（AOSC OS 14.0.1）上用 whisper.cpp 做中文语音转写的完整记录：环境、命令、转写结果、性能与踩到的问题。

## 环境

| 项目 | 值 |
|---|---|
| 机器 | Loongson 3B6000M，8 核 |
| 系统 | AOSC OS 14.0.1 (Naïve) |
| 内核 | Linux 7.1.13-aosc-main-16k，loongarch64，页大小 16 KiB |
| 内存 | 14 GiB |
| whisper.cpp | 1.9.2（AOSC 源，\`oma install whisper.cpp\`） |
| ggml | 0.20.0（AOSC 源，上游 v0.20.0，2026-08-14 发布） |
| 模型 | ggml-small.bin，465 MB，多语种 |
| 模型校验和 | \`1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b\` |

## 后端情况

whisper.cpp 的算力全部交给 ggml，后端以插件形式运行时加载。AOSC 的 ggml 0.20.0 在 \`/usr/lib/ggml/\` 提供四个：

\`\`\`
libggml-cpu.so      644 K   已编译 LSX 向量内核（vld/vst/vfmadd.s），支持 LBT，无 LASX
libggml-blas.so      68 K   OpenBLAS
libggml-vulkan.so    50 M   No devices found
libggml-opencl.so   1.7 M   could find any OpenCL devices
\`\`\`

启动时实际加载结果：

\`\`\`
ggml_vulkan: No devices found.
load_backend: loaded Vulkan backend from /usr/lib/ggml/libggml-vulkan.so
pci id for fd 9: 0014:7a46, driver (null)
ggml_opencl: could find any OpenCL devices.
load_backend: loaded OpenCL backend from /usr/lib/ggml/libggml-opencl.so
load_backend: loaded CPU backend from /usr/lib/ggml/libggml-cpu.so
\`\`\`

即：**实际只有 CPU 后端生效**。LG200 没有可用的 Vulkan ICD（\`/usr/share/vulkan/icd.d/\` 里只有 lavapipe、intel、nouveau 等条目），OpenCL 只有 rusticl 但无设备。

## 测试音频

音频不是真人录音，而是用 \`espeak-ng -v cmn\` 合成的中文，再用 ffmpeg 转成 16 kHz 单声道 WAV。目的是验证链路是否通、输出格式是否正确，**不代表真人语音的准确率上限**。

| 文件 | 时长 | 原文 |
|---|---|---|
| \`test/zh-long.wav\` | 15.8 s | 今天下午三点在三楼会议室开项目评审会，请大家提前十分钟到场，并且带上这周的进度报告和测试结果。 |
| \`test/zh-short.wav\` | 5.4 s | 今天下午三点开会，记得带上笔记本电脑。 |

合成命令见 \`test/espeak-sources.txt\`。

## 转写命令

\`\`\`bash
whisper-cli -m ~/models/ggml-small.bin -f test/zh-long.wav -l zh -t 8 -np \\
  --prompt "以下是普通话的句子，使用简体中文。" -otxt -osrt -of test/zh-long
\`\`\`

一键复现：\`MODEL=/path/to/ggml-small.bin ./scripts/run-test.sh\`

## 结果

### zh-long.wav（15.8 s）

\`\`\`
[00:00:00.000 --> 00:00:06.200]  今天下午三点在三楼会议时开箱木评论会,
[00:00:06.200 --> 00:00:10.200]  请大家提前十分钟到场,
[00:00:10.200 --> 00:00:15.500]  并且开上车车的进步报告和设施结果。
\`\`\`

时间戳切分正确，句子边界基本对；错词集中在合成音不自然的地方（“会议室”→“会议时”、“项目评审会”→“评论会”、“带上这周”→“开上车车”、“测试结果”→“设施结果”）。

### zh-short.wav（5.4 s）

不加 \`--prompt\`：

\`\`\`
今天下午三點開會
記得按下訂閱鈴鐺喔
\`\`\`

第二行是**幻觉**（音频里没有这句，是 whisper 在训练数据里常见的结尾套路）。

加 \`--prompt "以下是普通话的句子，使用简体中文。"\` 后退化成：

\`\`\`
(词: 五天下午三天开会, 记得开放笔记得点哦!)
\`\`\`

结论：**短于 6 秒的音频不稳定**。加 prompt 能治繁体，但短音频上有概率让输出直接崩掉。

## 性能

| 场景 | 耗时（墙钟） |
|---|---|
| zh-short（5.4 s 音频），轻载 | 42.7 s |
| zh-long（15.8 s 音频），轻载 | 64.0 s |
| zh-short，浏览器 + Chromium 占负载 average 9.2 时 | 94.7 s |

两个关键点：

1. **whisper 固定按 30 秒窗口计算**，所以 5.4 s 和 15.8 s 的音频耗时差不多，短音频并不省时间。
2. 耗时刻度受系统负载影响很大，同一命令在 40 s 到 95 s 之间波动。估算长音频时按 **约 1.4～2 倍实时**（即 1 小时录音需要 1.5～2 小时）比较稳妥。

## 踩到的问题

1. **默认输出繁体**。不加 \`--prompt\` 时简体中文会被转成繁体（“今天下午三點開會”）。标准做法是加一句简体中文提示词。
2. **提示词会被复读**。音频极短或质量差时，模型会把 prompt 本身当成转写内容输出。
3. **短音频幻觉**。见上，5 秒级音频容易凭空补一句“记得按下订阅铃铛喔”这类话。
4. **Vulkan/OpenCL 后端能加载但无设备**，日志里两条 \`load_backend\` 看似成功，实际 ggml 拿不到设备，仍走 CPU。
5. ggml 版本落后上游约 9 个版本（0.20.0 vs 0.29.0），但目前对纯 CPU 转写没有影响。

## 文件说明

\`\`\`
test/zh-long.wav            测试音频（15.8 s）
test/zh-long.txt/.srt/.json 转写输出（文本 / 字幕 / 完整 JSON）
test/zh-short.wav           测试音频（5.4 s）
test/zh-short.txt/.srt      加 prompt 的输出（退化案例）
test/zh-short-noprompt.txt  不加 prompt 的输出（繁体 + 幻觉案例）
test/espeak-sources.txt     合成命令与原文
scripts/run-test.sh         复现脚本
\`\`\`
