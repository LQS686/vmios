# 卡顿定位与修复（2026-10-23 晚）

开机与触摸已经打通，但 iOS 在 SweetVM / 真机上"能用但很卡"。这份记录只回答三个问题：
卡在哪几层、每层怎么证明、改了什么。所有数字都是本机实测（K70 Pro 的日志 +
WSL 宿主 QEMU 对照跑），不是估计。

## 1. 结论：卡顿分五层，最大的一层不在 Guest

| # | 层 | 现象 | 证据 | 处理 |
|---|----|------|------|------|
| L1 | App 取帧 | 整机固定 4 fps，最高只能调到 11 fps | `BootConfig.fps = 4`、滑块 `setMax(11)` | 默认 30，范围 15–60 |
| L2 | 取帧变更检测 | 局部变化（光标、开关、点击高亮）可能十几帧都检测不到，画面"冻一下" | 256 个采样点、间隔 40 KB | 每 64 B 采样一个点 |
| L3 | CPU 虚拟化 | 2 个 vCPU 挤在 1 个 TCG 线程，系统守护进程/WindowServer/App 串行 | `threads=4`，只有 1 个 TCG 线程；宿主单核占用仅 60–68% | 默认 MTTCG（`tcgsingle=1` 可回退） |
| L4 | 宿主内存 | Guest 首次触页的缺页在 vCPU 线程里做，iOS 分配内存时整机停顿 | 5 分钟 50.7 万次 minflt，RSS 149 MB → 1.78 GB | `memory-backend-file,prealloc=on` |
| L5 | 输入 | 每个 MOVE 两次系统调用，最高 120 Hz 全打在 UI 线程 | `TouchSender.send()` 每次 seek+write | 合并到 8 ms，复用缓冲区 |
| L6 | Guest 渲染 | 无 GPU，CA 软件光栅 + 内核每帧 10.9 MB memcpy 到面板 | 既有测量 ~16.5 fps | 未改（需要 CI 内核；见 §5） |

L1 单独就能解释"不是画面渲染的卡"：Guest 哪怕跑 16 fps，App 只按 4 fps
把画面贴出来，用户看到的是每 250 ms 才动一下。触摸事件进得去、系统反应也有，
但画面反馈的节奏是 App 定的。这一条此前被"16.5 fps"的 Guest 测量掩盖了，
因为那个数字量的是 Guest 的 swap，不是屏幕上的帧。

## 2. 怎么测的

宿主 WSL（12 核）跑同一套镜像与 payload，参数对齐 App：

```
qemu-system-aarch64 -M virt,gic-version=3 -cpu cortex-a76 -smp 2 \
  -accel tcg,thread=<single|multi>,tb-size=512 \
  -object memory-backend-file,id=ram,size=4G,mem-path=guest-ram.bin,share=on[,prealloc=on] \
  -device sweet-ufs,file=ios16-root-2cpu.img -device sweet-touch,touchfile=...
```

每 2 s 采 `/proc/<qemu>/{stat,status,task/*/stat}`：

- `utime+stime` → QEMU 实际吃了多少宿主 CPU；
- `minflt/majflt` → 缺页次数（L4）；
- `threads` + 每线程 utime → 有几条 TCG 线程（L3）；
- Guest 进度用镜像尾部 SWEETLOG 环的 `total`（控制台字节数）与 300 s 截图对照。

### 基线（2 vCPU，thread=single，无 prealloc）

```
t= 60s cpu= 48.9%    t=120s cpu= 63.6%   t=210s cpu= 67.9%
minflt: 30,590 @2s → 507,503 @200s        (≈3,000/s，后期 ≈400/s)
VmRSS: 149 MB → 1.78 GB
threads=4，其中 TCG 线程 1 条，其余 3 条空转
SWEETLOG total @300s: 67,709 B
```

两个直接结论：

1. **宿主一个核只忙 60–68%**。如果卡顿是"CPU 算不过来"，它应该贴着 100%。
   空出来的时间说明 Guest 在等：等定时器、等 I/O 完成、等另一个 vCPU
   （而另一个 vCPU 在单线程 TCG 下根本没在跑）。
2. **50 万次缺页全发生在 QEMU 进程里**，而 QEMU 的 vCPU 是跑 Guest 的唯一线程。
   每次首次触页都要走宿主缺页 + f2fs 分配，这段时间 Guest 是整体停住的。
   这正好对应"打开 App、翻页时突然一顿"——那不是渲染慢，是内存页没准备好。

## 3. 改动

### App（`android/.../sweetvm/`）

- `BootConfig.fps`：默认 4 → 30；读取时把 <15 的旧值重置为 30（老安装也能修好）。
- `MainActivity.showAdvanced()`：滑块 1–11 → 15–60（步长 5）。
- `VmEngine.start()`：clamp 10–60；`memory-backend-file` 加 `prealloc=on`
  （快照恢复时跳过：`-incoming` 本来就会写满整块 RAM）；
  `-accel tcg,thread=multi` 成为 `cpus>=2` 时的默认，`tcgsingle=1` 回退单线程。
  启动时向 logcat 打一行 `engine cpus=N accel=... prealloc=... capture=Nfps`，
  真机上 `adb logcat -s sweetvm` 就能确认配置生效。
- `VmEngine.changed()`：采样步长 40 KB → 64 B（每 16 个 word 一个点），
  局部变化不再漏帧；`PROBE_STEP` 常量取代 `PROBE_WORDS`。
- `TouchSender`：MOVE 8 ms 合并 + 复用 5 字节缓冲；DOWN/UP 不合并。

### 宿主工具

- `tools/qemu-sweet.py --shared-ram` 同样加 `prealloc=on`，让宿主测试与 App 一致。

### 没有改的

- Guest 的 present 路径与软件光栅器：见 §5，需要内核构建，不能靠 payload 打补丁完成。

## 4. 验证

- APK：`android/app/build/outputs/apk/debug/app-debug.apk`（81.9 MB，arm64-v8a + x86_64）。
- 宿主 A/B：同镜像、同 payload、同 300 s，唯一差别是 `thread=single`（基线）
  vs `thread=multi + prealloc`（修复）。指标见 §4.1。
- 真机一键脚本：`python3 tools/sweetvm-device-test.py`（装 APK、起 VM、采样
  `engine ...`/`fps=` 行、截图、做一次上滑）。本轮没有设备接入（`adb devices` 为空）。安装后看顶部 `N fps`
  是否跟到设定值（默认 30）、logcat 的 `engine ... accel=tcg,thread=multi`，
  以及 App 启动/翻页是否还出现整秒级停顿。

### 4.1 A/B 结果（宿主，同镜像同 payload，各 300 s）

| | 基线 `thread=single`、无 prealloc | 修复 `thread=multi` + prealloc |
|---|---|---|
| QEMU 线程 | 4 条，1 条 TCG | 5 条，2 条 TCG（各 ≈45% 单核） |
| vCPU 并行 | 无（2 vCPU 轮流） | 有 |
| 前 60 s CPU | 单核 49–66% | 两线程合计 ≈73%，之后各 ≈15%（Guest 在等） |
| minflt | 30k@2s → 507k@200s | prealloc 启动即打满 ≈83 万（4 GB/4 KB），之后新增来自 TCG 代码页 |
| Guest 日志 | 67,709 B，`SWEET FB: swap` **0** 次 | 62,956 B，`SWEET FB: swap` **16** 次（首批 16 次 swap 的明细日志） |
| 300 s 截图 | 仍是控制台文字（未 present） | **iOS Setup「Hei」界面**，状态栏/电池/time 正常 |
| panic | 无 | 无 |

结论：在同一 5 分钟窗口里，修复版已经进入 CA 渲染/present 循环并显示 GUI，
基线还在控制台阶段。这是"虚拟化 + 宿主内存"两层的直接收益，
和 App 取帧层的 4→30 fps 修复叠加，才是"整体流畅"的完整答案。

注意：基线跑完后镜像被写脏，第二次用的是原始镜像的新副本；因此对比的是
"同一镜像的两次冷启动在 300 s 时到达的阶段"，不是逐帧基准。精确的
到 GUI 墙钟时间要跑满整个启动（15–20 min），本轮没做。

## 5. 还剩下的两层（需要内核 CI）

1. **present 拷贝**：`AppleCLCD::present()` 每帧把 1125×2436（10.9 MB）逐行
   memcpy 到 1080×2400 面板，30 Hz 就是 329 MB/s 的 Guest 侧不可缓存写。
   真正的修法是让 App 直接读 CA 的 surface（内核把 surface 的 PA/stride/seq
   写进 boot_args 的空字段，App 用 GPU 缩放上屏），Guest 不再拷。
   这需要一次内核构建，`xnu/patches/0087-*`。
2. **pset0 ticket lock**：MTTCG 下重负载（Setup/SystemAppMigrator）仍可能
   触发 300k 次自旋超时。`prealloc` 去掉了"锁持有者被宿主缺页卡住"这一类
   超时来源，但真正的修复是把超时改成可配置并在 panic 里打印持锁 CPU 的栈
   （同样是一次内核构建）。当前以 `tcgsingle=1` 作为兼容开关。

## 6. 复现

```sh
# 宿主：基线 / 修复各跑一次，采 5 分钟
python3 tools/qemu-sweet.py payload-ios-2cpu.bin out-base --smp 2 --tcg-single \
  --ufs ios16-root-2cpu.img --shared-ram --secs 300
python3 tools/qemu-sweet.py payload-ios-2cpu.bin out-fix --smp 2 \
  --ufs ios16-root-2cpu.img --shared-ram --secs 300
```

## 7. 环境事故记录（2026-10-24）

为了做 A/B，在 WSL 里复制了 3 份 17 GB 的根镜像（每份 + 4 GB RAM 文件），
把宿主 D: 写到 0 字节；WSL 的 ext4 随即报 EIO，`wsl` 无法启动。
处理：把 WSL 虚拟盘切成稀疏、把 `.wslconfig` 的 swap 关掉（WSL 默认 swap 盘
不必要地占空间），启动后删掉所有临时镜像；WSL 恢复，`/opt/qemu` 与
`/opt/ios-sweet` 完好。**注意**：`.wslconfig` 原先 283 字节的内容没有备份，
现在只剩 `[wsl2] swap=0`，需要按原样恢复 memory/processors 等设置。
D: 目前只剩 7.8 GB，之后不要再整盘复制 17 GB 镜像；测试请用快照，
或者先清理空间。
