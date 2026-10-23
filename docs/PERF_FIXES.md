# 卡顿定位与修复（2026-10-23 晚）

开机与触摸已经打通，但 iOS 在 SweetVM / 真机上"能用但很卡"。这份记录只回答三个问题：
卡在哪几层、每层怎么证明、改了什么。所有数字都是本机实测（K70 Pro 的日志 +
WSL 宿主 QEMU 对照跑），不是估计。

## 1. 结论：卡顿分五层，最大的一层不在 Guest

| # | 层 | 现象 | 证据 | 处理 |
|---|----|------|------|------|
| L1 | App 取帧 | 整机固定 4 fps，最高只能调到 11 fps | `BootConfig.fps = 4`、滑块 `setMax(11)` | 默认 30，范围 15–60 |
| L2 | 取帧变更检测 | 局部变化（光标、开关、点击高亮）可能十几帧都检测不到，画面"冻一下" | 256 个采样点、间隔 40 KB | 每 64 B 采样一个点 |
| L3 | CPU 虚拟化 | 2 个 vCPU 挤在 1 个 TCG 线程，系统守护进程/WindowServer/App 串行 | `threads=4`，只有 1 个 TCG 线程；宿主单核占用仅 60–68% | 单线程仍是默认；MTTCG 会 panic（`tcgmulti=1` 仅作试验），见 §4.2 |
| L4 | 宿主内存 | Guest 首次触页的缺页在 vCPU 线程里做，iOS 分配内存时整机停顿 | 5 分钟 50.7 万次 minflt，RSS 149 MB → 1.78 GB | `memory-backend-file,prealloc=on` |
| L5 | 输入 | 每个 MOVE 两次系统调用，最高 120 Hz 全打在 UI 线程 | `TouchSender.send()` 每次 seek+write | 合并到 8 ms，复用缓冲区 |
| L6 | Guest 渲染 | 无 GPU，CA 软件光栅 + 内核每帧 10.9 MB memcpy 到面板 | 既有测量 ~16.5 fps | 未改（需要 CI 内核；见 §5） |

L1 单独就能解释"不是画面渲染的卡"：Guest 哪怕跑 16 fps，App 只按 4 fps
把画面贴出来，用户看到的是每 250 ms 才动一下。触摸事件进得去、系统反应也有，
但画面反馈的节奏是 App 定的。这一条此前被"16.5 fps"的 Guest 测量掩盖了，
因为那个数字量的是 Guest 的 swap，不是屏幕上的帧。

### 1.1 手机侧的真实证据（从根镜像尾部的 SWEETLOG 环离线读出）

`.tools/ios16-root.img` 的环里覆盖最近 **2 次启动**、108 KB：

| 观测 | 数值 | 含义 |
|---|---|---|
| panic / `CRASH backboardd` / 未捕获异常 | **0 / 0 / 0** | 手机上的卡顿**不是**崩溃循环 |
| `SWEET FB: swap` 明细 | 16 | GUI 能 present，锁屏/主屏出得来 |
| 采样到的线程数 | SpringBoard **65**、backboardd 22、Setup 9、lsd 7、containermanager 5 | iOS 是重多线程系统 |
| `exec Preferences/MobileSlideShow/MobileSafari/AppStore` | **0** | 这些日志里原生 App 从未被拉起 |

65 个 SpringBoard 线程 + 22 个 backboardd 线程挤在 1–2 个 vCPU 上，而单线程
TCG 又把所有 vCPU 放在**一个宿主核**上时间片轮转——这就是"不是渲染"的那部分
卡顿：每次动画/触摸都可能排在这些线程后面。同一份日志也说明原生 App 的问题
是注册/拉起（0 次 exec），不是性能。

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
- **多线程 TCG 变成显式开关**：高级选项里一个复选框（默认关）。勾选后
  `iosCmdline()` 追加 `tcgmulti=1`，`VmEngine` 转成 `thread=multi` 并自动带
  2 s 锁超时；参数截断给这 34 字节留了空间。退出时若日志里出现 `panic(` /
  `Ticket spinlock`，对话框直接提示"关闭多线程 TCG 后重试"。
  这样真机上能用同一个 `fps=` 计数做 single/multi A/B，而不赌默认值。
- `VmEngine.start()`：clamp 10–60；`memory-backend-file` 加 `prealloc=on`
  （快照恢复时跳过：`-incoming` 本来就会写满整块 RAM）；
  `-accel` 仍是 `thread=single`：`tcgmulti=1` 打开多线程 TCG（试验开关）。
  启动时向 logcat 打一行 `engine cpus=N accel=... prealloc=... capture=Nfps`，
  真机上 `adb logcat -s sweetvm` 就能确认配置生效。
- `VmEngine.changed()`：采样步长 40 KB → 64 B（每 16 个 word 一个点），
  局部变化不再漏帧；`PROBE_STEP` 常量取代 `PROBE_WORDS`。
- `TouchSender`：MOVE 8 ms 合并 + 复用 5 字节缓冲；DOWN/UP 不合并。
- 取帧节拍：`Thread.sleep(33)` 会让"采样间隔 = 33 ms + 拷贝时间"并累积漂移，
  16 fps 的内容按 30 fps 采样会 beat/judder。改成单调 deadline + parkNanos，
  拷贝超时就重排下一拍（`VmEngine.startReader`）。

### 宿主工具

- `tools/qemu-sweet.py --shared-ram` 同样加 `prealloc=on`，让宿主测试与 App 一致。

### 没有改的

- Guest 的 present 路径与软件光栅器：见 §5，需要内核构建，不能靠 payload 打补丁完成。

## 4. 验证

- APK：`android/app/build/outputs/apk/debug/app-debug.apk`（81.9 MB，arm64-v8a + x86_64）。
- 宿主 A/B：同镜像、同 payload、同 300 s，唯一差别是 `thread=single`（基线）
  vs `thread=multi + prealloc`（修复）。指标见 §4.1。
- 真机一键脚本：`python3 tools/sweetvm-device-test.py`（装 APK、起 VM、采样
  `engine ...`/`fps=` 行、截图、做一次上滑，并把根镜像尾部的 SWEETLOG 环拉成
  `guestlog.txt`——QEMU 没有控制台 chardev，panic 只能从这里看到）。本轮没有设备接入（`adb devices` 为空）。安装后看顶部 `N fps`
  是否跟到设定值（默认 30）、logcat 的 `engine ... accel=tcg,thread=multi`，
  以及 App 启动/翻页是否还出现整秒级停顿。

### 4.1 A/B 结果（宿主，同镜像同 payload，各 300 s）

| | 基线 `thread=single`、无 prealloc | 修复 `thread=multi` + prealloc |
|---|---|---|
| QEMU 线程 | 4 条，1 条 TCG | 5 条，2 条 TCG（各 ≈45% 单核） |
| vCPU 并行 | 无（2 vCPU 轮流） | 有（但**不稳定**，见 4.2） |
| 前 60 s CPU | 单核 49–66% | 两线程合计 ≈73%，之后各 ≈15%（Guest 在等） |
| minflt | 30k@2s → 507k@200s | prealloc 启动即打满 ≈83 万（4 GB/4 KB），之后新增来自 TCG 代码页 |
| Guest 日志 | 67,709 B，`SWEET FB: swap` **0** 次 | 62,956 B，`SWEET FB: swap` **16** 次（首批 16 次 swap 的明细日志） |
| 300 s 截图 | 仍是控制台文字（未 present） | **iOS Setup「Hei」界面**，状态栏/电池/time 正常 |
| panic | 无 | 无（这一次；同一配置重跑会 panic，见 4.2） |

结论：在同一 5 分钟窗口里，MTTCG + prealloc 已经进入 CA 渲染/present 循环
并显示 GUI，基线还在控制台阶段。**但这次收益主要来自 MTTCG**，而 MTTCG
会 panic（4.2），所以它不能发布。

为了分清 prealloc 单独的作用，又跑了**可发布的单线程 + prealloc**（同镜像、
同 300 s，h4）：300 s 时仍是控制台文字，没有进入 GUI，也没有 panic。
所以：

- MTTCG = 启动快，但 2 vCPU 下会死锁 → 不可发布；
- prealloc = 启动速度上没有可测收益，价值只在"运行期不再在 vCPU 线程里
  首次触页"；它保留，但需要在真机上用帧间隔去证实（见 §6）；
- 单线程 + prealloc = 当前可发布的稳定配置，也是 App 的默认。

"整体流畅"只靠 App 取帧（4→30）是不够的，Guest 侧仍受单线程 TCG 限制，
真正解锁要 §5.2 的内核工作。

注意：基线跑完后镜像被写脏，第二次用的是原始镜像的新副本；因此对比的是
"同一镜像的两次冷启动在 300 s 时到达的阶段"，不是逐帧基准。精确的
到 GUI 墙钟时间要跑满整个启动（15–20 min），本轮没做。

### 4.2 反例：MTTCG 不能作默认

同一镜像、2 vCPU、prealloc 打开，第二次冷启动在 ~3 分钟时 panic：

```
Ticket spinlock(0xfffffe0007b90880) timeout after 3000001 ticks;
ticket: 0xca, nticket: 0xce, waiting for 0xcb,
current owner: 0xfffffe24d32fec10 (on CPU 1) ... @lock_ticket.c:386
handshake structure not initialized
```

24 MHz 计数下 3,000,001 tick = **125 ms**。票据 0xca..0xce 说明已有 4 个 CPU
在等 0xcb，持有者在 CPU 1 上 125 ms 没有释放，而且 panic 时拿不到它的
handshake/栈。prealloc 并不能消除它，因此 `VmEngine` 恢复 `thread=single`
默认。

**但 125 ms 不是死锁的证据。** 反汇编 `_ml_init_lock_timeout` 后确认 XNU 的
两个 boot-arg 就是锁超时：

```
slto_us   自旋锁超时（微秒）
tlto_us   ticket 锁超时（微秒，默认约 125 ms）
```

`_hw_lck_ticket_contended` 用 `_hw_spin_compute_timeout(policy)` 把
`tlto_us` 换成 absolutetime 作为 deadline。把 `tlto_us`/`slto_us` 提到
**2 s** 后，同一个 2 vCPU MTTCG 配置跑了 **460 s 没有 panic**（此前 ~3 分钟
必 panic），停在 userland 中段。也就是说：持有者只是被宿主 I/O / 调度拖过了
125 ms，2 s 足够它回来——这更像"TCG 下临界区被拉长"，不是内核死锁。

后续又跑了 900 s：**全程无 panic**（CPU 约 33%，两条 TCG 线程），但也没有
进入 GUI。这个镜像上 `backboardd` 每几分钟崩溃一次：

```
Terminating app due to uncaught exception 'NSInvalidArgumentException',
reason: '-[NSURL initFileURLWithPath:]: nil string parameter'
... 紧跟 IOHIDKeyboardFilter.plugin 的 dlopen 和 SweetHIDButtons 服务创建
```

900 s 内 3 次 `CRASH backboardd[...]`、`SWEET FB: swap` 0 次。这是**镜像/数据卷
状态问题**（宿主镜像是跳过 Setup、数据卷不完整的镜像；手机上数据卷初始化过，
UI 能起来），不是本次性能改动导致的，也不是 TCG 速度问题——它意味着宿主镜像
上 WindowServer 根本活不到出画面。

目前仍不把 MTTCG 设为默认：900 s 内没有进入 GUI，也还没有测到交互帧率，
无法证明 2 vCPU 的收益。`tcgmulti=1` 现在会自动追加
`tlto_us=2000000 slto_us=2000000`（`VmEngine`），保持一个开关即可试验。

### 4.3 其它两次失败的对照（避免误导后来人）

- **1 vCPU 镜像 + 2 vCPU payload，单线程 TCG**：11 分钟仍停在 Apple logo，
  面板只更新 57 次，无 panic。这是镜像与 payload 的 CPU 配对不匹配
  （该镜像是在单 CPU 时代准备的），不能用来评价单/多线程 TCG。
- **WSL 里无法挂载 HFS+**（内核没有 hfsplus 模块），所以"把 Setup 跳过的
  prefs 写回去"这条路在本机走不通；宿主上要验原生 App，只能在真机或
  有 HFS+ 挂载能力的环境里做。

## 5. 还剩下的两层（需要内核 CI）

1. **present 拷贝**：`AppleCLCD::present()` 每帧把 1125×2436（10.9 MB）逐行
   memcpy 到 1080×2400 面板，30 Hz 就是 329 MB/s 的 Guest 侧不可缓存写。
   真正的修法是让 App 直接读 CA 的 surface（内核把 surface 的 PA/stride/seq
   写进 boot_args 的空字段，App 用 GPU 缩放上屏），Guest 不再拷。
   这需要一次内核构建，`xnu/patches/0087-*`。
2. **pset0 ticket lock**：见 §4.2。`tlto_us`/`slto_us` 已经是现成的 tunable，
   不需要内核构建就能把 125 ms 提到 2 s 并避开 panic。仍建议一次内核构建
   修好 `hw_lck_ticket_timeout_panic` 的 CPU handshake（现在 panic 里拿不到
   持有 CPU 的 PC/LR，无法判断 2 s 以后是否还会卡）。在真机上测到
   MTTCG 的交互帧率收益之前，默认保持 `thread=single`。

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

## 8. 验收对照表（2026-10-24）

| 目标要求 | 状态 | 证据 / 缺口 |
|---|---|---|
| 定位卡顿根因 | ✅ | 6 层：取帧 4 fps、漏检、单 TCG 线程、锁 125 ms、缺页、输入系统调用；§1、§2、§4.2 |
| 区分性能瓶颈所在层面 | ✅ | §1 表格 + 手机环里的 65 SpringBoard 线程 / 0 crash |
| 确认根因后修复 | ✅ 可发布部分 | 取帧/探测/节拍/触摸/prealloc/锁超时；§3 |
| 修复后完整测试 | ⚠️ 部分 | 宿主 A/B、900 s 稳定、APK 与解码器自测已做；**真机未测**（无设备） |
| 运行正常且流畅 | ⚠️ 未验证 | 手机环显示 0 crash/16 presents，但没有 `fps=` 真机数据；需 `tools/sweetvm-device-test.py` |
| iOS 原生 App 可用 | ❌ 未达成 | 手机环里 `exec Preferences/Photos/Safari/AppStore` = 0；图标 "Waiting…"，属 MobileInstallation/SystemAppMigrator 注册问题 |
| 说明根因/方案/结果 | ✅ | 本文档 + NOTES.md 的 handoff |

**剩余工作的最短路径**

1. 接手机 → `python3 tools/sweetvm-device-test.py --native-app-check`（含 SWEETLOG
   拉取与"点开设置/照片"时的 `exec` 监视），用 `fps=` 判断
   流畅度是否达标；不达标时优先看 `capture` 是否 30、`accel` 是否 single、
   Guest 是否在 `SWEET FB: swap` 之外大量等待。
2. 原生 App：抓 `installd`/`mobile_installation_proxy` 的同步 XPC（参考 NOTES 里
   lsd 的 MG IOKit 等待），目标是让系统 App 的安装/注册完成；这一步与性能无关。
3. 进一步提升：内核 CI 做 present 零拷贝与 UFS 异步 I/O；MTTCG 已有 2 s 锁超时
   兜底，可在真机上用 `fps=` 对比 single/multi 后再决定是否改默认。
