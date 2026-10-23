# SWEET iOS 启动 / 图形栈逆向分析

日期：2026-10-23 · 目标：iPhone X 16.7.16 (20H392) userland + xnu-8796 (SWEET) on Redmi Note 10 Pro
手段：REA 6.7（artifact / Mach-O 证据链）+ 自建 Mach-O / dyld 共享缓存工具链 + 现有内核采样器日志
优先级：**先启动速度，再 GPU**

---

## 0. 结论（先看这一页）

| # | 现象 | 根因 | 证据强度 | 修复 | 预计收益 |
|---|---|---|---|---|---|
| 1 | 苹果 Logo 停 4–5 分钟 | **SpringBoard 主线程卡在 LaunchServices 的同步 XPC 上**，等 `lsd` 完成数据库初始化；一次启动里 90s / 210s / 330s 三次采样栈**完全相同**（≥240s 无进展） | 已证实（三次采样逐帧一致 + QEMU 侧交叉验证） | 先测 `lsd`，再消除其重建数据库的触发条件 / 降低 fsync 成本 | **200–300s（≥80%）** |
| 2 | 无 GPU 时每个进程多等 30s | QuartzCore `CAMetalContextCreate` 里 `IOAcceleratorES` 轮询 **300 × 100ms** | 已证实（反汇编到指令级，含文件偏移） | 共享缓存补丁 300 → 3 次 | **~30s/进程** |
| 3 | 内核到 launchd 要 31.7s | 未分解（无时间戳）；最大嫌疑是 HFS+ 挂载 / journal 回放 / catalog 查询在单槽轮询 UFS 上的小 I/O | 待测（已给埋点方案） | 埋点一次 → 按数据修 | 目标 31.7 → ≤10s |
| 4 | 0069 的 UFS 优化没生效 | `ufscache=1` / `ufswait=1` **不在启动命令行里**，驱动仍在整段 dcache 维护 + `delay(1)` 自旋轮询 | 已证实（README/日志 boot-args 均无这两个参数） | 加两个 boot-arg | 省 CPU/固定开销（延迟收益有限） |
| 5 | 界面 20–30fps、启动慢 | 没有 Metal 设备，CoreAnimation 走**软件光栅器**；每帧额外一次 10.96MB 内核拷贝（30Hz ≈ 329MB/s） | 二进制字符串 + 内核 present 代码 | 零拷贝/NEON/多核；GPU 只能做 2D blit | 30 → 50–60fps |
| 6 | 启动期 CPU 被白烧 | 34×`bluetoothd` + 35×`fairplayd.H2` 重启风暴；AKS 大量返回 `unsupported` | 已证实（日志计数） | 镜像侧禁作业 | 5–15s + 交互抖动 |

一句话：**这 4 分钟不是「CPU 太慢」，是一个真实的等待链**（SpringBoard → FrontBoard → LaunchServices → `lsd` → HFS+/UFS）。
所以先修等待链，再谈渲染优化；GPU 是独立议题，短期只能走「CPU 渲染 + 硬件 2D/扫描输出」而不是 Metal。

---

## 1. 方法与工具（可复现）

REA 在本机（Windows）只启用 `rea-artifact-graph`，`inspect_macho` / Hopper / Ghidra provider 均要求 macOS 或未配置，
因此本次用 REA 做**证据登记**（artifact 清单、SHA-256、格式判定），用三个新工具做**指令级**分析：

| 工具 | 作用 |
|---|---|
| `tools/macho-analyze.py` | 纯 Python Mach-O 解析 + Capstone 反汇编（符号表 / 导出表 / function starts / xref） |
| `tools/dsc-frames.py` | 把内核采样器日志里的裸地址，按进程 slide 解析成 `dylib+offset(+symbol)`（等价 `ipsw dyld a2s`，无需 macOS） |
| `tools/dsc-patch.py` | 在 split dyld 共享缓存里定位 VA → 子缓存文件偏移，校验后改写（带 undo 记录），已通过实机镜像实测 |

```sh
# REA：证据登记
rea inspect-artifact research/dsc-extract/QuartzCore
# 反汇编
python3 tools/macho-analyze.py dis research/dsc-extract/QuartzCore _CAMetalContextCreate
# 采样栈符号化
python3 tools/dsc-frames.py artifacts/lock-log.txt --only SpringBoard
# 共享缓存补丁（dry-run / 实写）
python3 tools/dsc-patch.py <cache_dir> --preset metal-wait-300ms
```

分析对象：`research/iosbin/{SpringBoard,backboardd,Setup,...}`、`research/dsc-extract/{QuartzCore,Metal,IOSurface,IOMobileFramebuffer,BackBoardServices,...}`、
`research/dsc.tar`（45 个 `dyld_shared_cache_arm64*` 成员，3.33GB，2710 个镜像）、以及 7 份手机启动日志。

---

## 2. 启动时间线（实测，不是估计）

> **⚠️ 2026-10-23 晚间更正：这些数据全部来自 SweetVM（QEMU TCG），不是 Redmi Note 10 Pro 硬件。**
> 每一份 `artifacts/*log*.txt` 都写着 `SWEET CPU: requested=1 selected=1 (limit=8)`（`lock-log` 是 `cpus=2`）、
> `vm_page_bootstrap: 76090 free pages`（≈1.19 GB）、DMA 在 `0xb33d8000`（低内存 ADT）、userdata `first block 0x22`
> ——这是 K70 Pro 上跑的 SweetVM，单核 TCG。
> 所以下面的 31.5s 和 ≥200s 都是**一核模拟**下的数字，不代表真机性能；`cpus=8` 只适用于硬件，
> VM 应该用 `cpus=2`（`NOTES.md` 已记录 2 vCPU 稳定，6/8 会撞锁超时，而 `lock-log` 那次正是 `cpus=2` 到锁屏）。
> 见 `BOOT_FIXES.md` §8 的 A/B 实测。

launchd 自己带墙钟（`1969-12-31 16:00:xx`，即开机后秒数）。7 次启动的首行日志：

| 日志 | launchd 启动 | Early boot complete |
|---|---|---|
| ios-clean | 31.743s | 36.225s |
| ios1 | 31.364s | 35.932s |
| nocc | 31.345s | 34.896s |
| pw | 31.390s | 34.982s |
| lock | 31.396s | 35.088s |
| spring | 31.527s | 35.276s |
| sampler | 31.536s | 35.253s |

于是（总时长按 README 的「4–5 分钟」；采样那次更慢）：

```
0 ─────────────── 31.5s ──── 36s ─────────────────────────────── ≥330s
  内核（XNU→launchd）  early-boot  SpringBoard 等 LaunchServices（lsd）
     31.5s (≈10%)       4.5s (≈1%)        ≥240s 无进展（占 80% 以上）
```

- 内核段：**31.3–31.7s，跨 7 次启动稳定**（说明是确定性开销，不是随机抖动）。
- early-boot 段：launchd 的 22 个 boot task（mount / keybag / usermanagerd / launchd_cache_loader …）只要 **4.5s**，很正常。
- 剩下全部时间在 SpringBoard 起来、但还没出第一帧之间——这就是「卡点」。
  `ios-clean` 那次到 330s 采样时仍无进展，所以该次启动 ≥ 5.5 分钟；成功到锁屏的
  `lock-log` 在 90s 采样时停在同一栈，说明这一段是每次启动都有的固定阻塞，只是结束点随 lsd 的工作量浮动。

---

## 3. 卡点一：SpringBoard 阻塞在 LaunchServices 同步 XPC（≥240s 无进展）

### 3.1 证据：三次采样，栈一字不差

内核采样器（patch 0054）在 **t≈90s / 210s / 330s** 各打一次全进程栈。`artifacts/ios-clean-log.txt`
（sample 0/1/2）里 SpringBoard 主线程 t0 的符号化结果**三次完全相同**：

```
mach_msg2_trap                    libsystem_kernel+0x1030   ← 在等 XPC 回复
 ← mach_msg2/overwrite/mach_msg    libsystem_kernel+0x12b18/0x12db8/0x1524
 ← dispatch_mach / xpc conn        libdispatch+0x36308/+0x36694, libxpc+0xe0ec
 ← NSXPCConnection 同步回复         Foundation+0x9a224/+0x33cb0/+0x326e0/+0x3261c
 ← LaunchServices 客户端           CoreServices+0xdcf34/+0x258d8/+0xb58e4/+0x1cbc0/+0xe2238/+0xbbb8
 ← 阻塞式锁/ulock 等待              libsystem_kernel+0x1ad0（syscall 515）
 ← 锁原语慢路径                     libsystem_platform+0x7140
 ← CoreServices                    CoreServices+0xb57b8/+0x1cbc0/+0xe2238/+0x77bc/+0x3c2bc
 ← FrontBoard                      FrontBoard+0x528bc
 ← dispatch / pthread              libdispatch+0x637a8/... libsystem_pthread
```

（`libsystem_kernel+0x1ad0` 处的指令是 `mov x16,#0x203; svc #0x80`，即 syscall 515 —— `os_unfair_lock` / pthread 互斥背后的阻塞原语。
函数名未在本机解析到符号，但调用方是 `libsystem_platform` 的锁慢路径，语义明确。）
其余行为 `dylib+offset` 级定位（框架确定、函数未符号化）；`CoreServices` 即 LaunchServices 框架本体。

结论：**SpringBoard 不是在渲染、也不是在算，而是在等一个「同步 XPC 回复」+ 一把 LaunchServices 客户端的锁**。
330s 时仍是同一帧 → 从 90s 到 330s 的 240s 里没有任何进展（成功启动的日志里这一段同样存在，只是更早结束）。

`lock-log.txt`、`sampler-log.txt` 里的另一次启动给出同样的栈（`CoreServices+0xb57b8 → dispatch_sync → FrontBoardServices`），可复现。

### 3.2 机制：谁没回话

调用的一端在 SpringBoard 的 LaunchServices 客户端，另一端只能是 **`lsd`**（LaunchServices daemon）。
日志显示 `exec lsd` 只发生 **1 次**、没有 crash，即 lsd 活着但在忙：

- QEMU 路径已经确认过同一链条：`lsd` 的 `performJournalRecovery` → `MIInstalledInfoGatherer`
  → `MGCopyAnswer` → `IOServiceMatching("IONetworkController")`（本机没有网络控制器）会**永久挂起**，
  并且 `/private/var/db/lsd` 始终为空；`SpringBoard` 则卡在 `_LSContextInitCommon`。
- 手机上能起来（4 分钟），说明 lsd 最终完成了；差异在于手机镜像里 MobileGestalt 缓存是有的（早前迁移启动生成过），
  所以 MG 查询走缓存而不是 IOKit。

那么手机上这 200s 花在哪：**lsd 重建 / 恢复 LaunchServices 数据库时的成千上万次小 I/O 与 fsync**。
触发「每次启动都重建」的常见原因有三个，按可能性排序：

1. `/private/var/db/lsd` 或 `systemgroup.com.apple.lsd` 容器不可写 / 被沙盒拒绝 → 每次启动重建；
2. `com.apple.migration` 的 `LastSystemVersion` 丢失 → 每次走升级迁移分支（已在 v14 规避，需回归确认）；
3. SQLite 事务的 fsync 在 HFS+ journal + 我们的 UFS 上极慢（见 §5.2 的 `ufsnosync` 实验）。

### 3.3 为什么「优化渲染 / 加 CPU 核」救不了启动

三次采样的栈完全相同，说明这段时间 CPU 是**空闲等待**：同一份日志里，backboardd 主线程在三个采样点都是
`mach_msg2 ← mach_msg ← CFRunLoopServiceMachPort`（run loop 空转），`CA::Render::Server::server_thread` 也是 mach_msg 空闲。
因此：

- 提高帧率、减少拷贝、加核 → 对启动时间**零收益**（对交互手感有收益）；
- 启动时间的杠杆只有两处：**让 lsd 早点回话**，以及**内核那 31.5s**。

### 3.4 修复（按性价比）

**P0-1 先量一次（1 次启动，成本最低）**
```sh
sweetsample=SpringBoard,lsd,backboardd,containermanagerd,installd
```
读 sample 0/1/2：若 lsd 停在 `MGCopyAnswer`/`IONetworkController`，走 P0-2；若停在 `sqlite3_step`/`write`/`fsync`，走 P0-3。

**P0-2 消除 MobileGestalt 的 IOKit 等待（若采样指向它）**
- 内核里补一个最小 `IONetworkController` 空壳服务（只需能匹配、能返回一组固定属性），让 MG 的查询立即返回而不是等 CFRunLoop 通知；
- 或沿用 QEMU 已验证的共享缓存补丁（`.09` 的 IOKit getter 直接返回 nil），并在手机镜像上同步。
- 参考：QEMU 路径 `NOTES.md` 已记录该补丁与 `sub_19c57c430` 的地址。

**P0-3 降低 lsd 的 I/O 成本（若采样指向 SQLite/fsync）**
1. 打开 0069 已实现但没启用的两项：`ufscache=1 ufswait=1`（见 §5.1）。
2. 新增 `ufsnosync=1`：在 `sweet_ufs.c` 的写路径跳过 `SYNCHRONIZE CACHE`（bring-up 阶段可接受掉电丢数据），
   只统计不阻塞；预计对 fsync 密集的 SQLite 收益最大。
3. 若确认是「每次重建」：在镜像里预置 `/private/var/db/lsd`（连同 `systemgroup.com.apple.lsd` 容器权限），
   并在 `sweet-root-tweaks.py` 里加一条自检：启动后 DB 目录为空则打印告警。

**验收**：SpringBoard 从 exec 到第一次 `SWEET FB: swap` 的间隔，目标 **< 30s**（现在 ~200s）。

---

## 4. 卡点二：没有 GPU 时 QuartzCore 硬等 30s

### 4.1 指令级证据

`CAMetalContextCreate` 是 `pthread_once` 包装，真正干活的是 block：

```asm
; QuartzCore, VA 0x18853e5f8  ___CAMetalContextCreate_block_invoke
0x18853e668  adrp/add  x19, "IOAcceleratorES"        ; ← 匹配的服务类名
0x18853e688  bl        IOServiceGetMatchingServices
...
0x18853e6b4  cmp       w21, #0x12b                   ; w21 = 已重试次数, 0x12b = 299
0x18853e6b8  cset      w8, hi                        ; w8 = (w21 > 299)
0x18853e6c0  tbnz      w8, #0, exit                  ; 找到服务 或 超过 299 次 → 退出
0x18853e6c4  add       w21, w21, #1
0x18853e6c8  mov       w0, #0x86a0 / movk w0,#1      ; 100000
0x18853e6d0  bl        usleep                        ; usleep(100 ms)
```

即 **300 次 × 100ms = 30 秒**，然后放弃、退回 CoreAnimation 的软件渲染器
（QuartzCore 里的字符串可作旁证：`CoreAnimation: Software renderer! Simulating crash!`、
`%d by %d image is too large for software renderer, ignoring`）。

每次 `CAMetalContextCreate` 都是 `pthread_once`（**每进程一次**）。任何用 CoreAnimation 的进程都会走这一步，启动期至少 backboardd 与 SpringBoard，
所以这是 30–60s 量级的确定性浪费（推断；backboardd 已被 QEMU 栈证实——WindowServer 主线程卡在这里，等它结束 SpringBoard 才继续）。

### 4.2 修复

```sh
python3 tools/dsc-patch.py <iOS根目录里的 dyld_shared_cache_arm64* 所在目录> --preset metal-wait-300ms
# VA 0x18853e6b4 -> dyld_shared_cache_arm64.03 @ file offset 0x17b26b4
#   cmp w21, #0x12b  ->  cmp w21, #3      (300 次 → 3 次, 30s → 0.3s)
```
已在本机用真实子缓存验证：定位 → 校验原字节 `bfae0471` → 写入 `bf0e0071` → 复核反汇编为 `cmp w21, #3`，
并生成 `.dsc-patch-undo.json` 可一键回滚。

**顺带处理一个 4 分钟的定时炸弹**：`IOSurface.framework` 的 `__iosConnectInitalize` 用
`mov w21, #-0xf1`（即 241 → 实际 240 次）× `sleep(1)` 等 `IOCoreSurfaceRoot`，合计 **240s**。
目前内核在 launchd 之前就 `registerService()`（日志 `SWEET SURF: IOCoreSurfaceRoot registered` 在第 64 行），
所以没触发；但只要哪天注册顺序变化，所有客户端都会各等 4 分钟。安全网：

```sh
python3 tools/dsc-patch.py <dir> --preset iosurface-wait-3s   # VA 0x1a3983c98, .11
```

（这两个补丁不需要重签名：SWEET 根卷未密封、AMFI 宽松，和镜像里已有的 MobileGestalt getter 补丁同一路数。）

---

## 5. 内核 31.5s（唯一还没分解的一段）

### 5.1 现成但没开的收益

`0069-sweet-ufs-faster.patch` 加了两个 boot-arg，**当前镜像的命令行里一个都没有**（README 与 7 份日志的
`boot-args = ...` 可查）：

| boot-arg | 现在的行为 | 打开后 |
|---|---|---|
| `ufscache=1` | 每条命令对整个 1MB bounce buffer 做 `flush_dcache64(len, TRUE)` | 只对真正要写的范围做 clean，回读只 invalidate 响应区 |
| `ufswait=1` | 命令完成后 `delay(1)` **忙等**（可睡眠上下文也忙等） | `assert_wait_deadline_with_leeway` + 200µs 粒度睡眠 |

加上这两项 **不需要改代码、不需要重编内核**，改 `tools/mkpayload.py` 的 `--cmdline` 即可。
注意它们的收益是**省 CPU 与每次 I/O 的固定开销**，不改变单条命令的完成延迟——真正的写延迟杠杆是 `ufsnosync` 和多槽流水线。

### 5.2 需要埋点才能定的部分

日志里有明确的重活，但没有时间戳：

- `jnl: b(1, 0): replay_journal: from: 695296 to: 3181568` —— **每次启动都回放 ~2.4MB 日志**（卷从未干净卸载），
  后面还跟着 `hfs: Removed 5 orphaned / unlinked files and 3 directories`；
- journal 回放 / 孤儿清理都要走 **catalog B-tree**：每次节点查找是独立的块 I/O，驱动只有 1 个命令槽、`delay(1)` 自旋等待、
  1MB bounce + memcpy；16GB 卷上几十万条目，这一段的 I/O 次数最可能是 31.5s 的主项；
- 控制台不是主项：**launchd 之前只打了 ~108 行**；从 launchd 到第一次 swap 之间累计约 1000 行（`FBCON_SCALE=2` 逐像素写 NC 帧缓冲），
  量级 1–2s，且发生在 31.5s 之后。

**埋点补丁（一次 CI，一次启动就能定案）**：

```c
/* kern/debug.c 的 kprintf 出口，或 pexpert 的 _cnputs 之前 */
uint64_t sweet_t0;                       /* 在 start.s/arm_init 里抓一次 mach_absolute_time */
uint32_t sweet_ts = 0;
PE_parse_boot_argn("sweetts", &sweet_ts, sizeof(sweet_ts));
if (sweet_ts) { char p[16]; snprintf(p, sizeof p, "[%6llu.%03llu] ",
    (mach_absolute_time()-sweet_t0)/1000000000ull, ((mach_absolute_time()-sweet_t0)/1000000ull)%1000); _cnputs(p); }
```

外加 UFS 统计（每 10s 在 `sweet_log_thread` 里打一行）：

```c
/* sweet_ufs.c */ struct { uint64_t rd, wr, sync, bytes, ns_wait, ns_max; } su_stats;
/* 命令完成处 */ su_stats.ns_wait += t1 - t0; if (t1-t0 > su_stats.ns_max) su_stats.ns_max = t1-t0; ...
IOLog("SWEET UFS: rd %llu wr %llu sync %llu MB %llu avg %llu us max %llu us\n", ...);
```

有了这两组数，31.5s 会立刻拆成「UFS 探测 X 秒 / HFS 挂载与回放 Y 秒 / 其余 Z 秒」，再决定投哪。

### 5.3 先做掉的三件小事（不依赖埋点）

1. **`ufsnosync=1`**：写路径跳过 `SYNCHRONIZE CACHE`（bring-up 可接受）。对 HFS+ journal 提交与 SQLite 影响直接。
2. **控制台限行**：`sweetconlines=200`，超过就只进环形日志不画屏幕（panic 仍画）。挡掉 launchd 之后那 ~1000 行的 NC 逐像素绘制（1–2s，并减少与 present 的带宽竞争）。
3. **`cpus=8`**：0078 已支持 8 核，但命令行还是 `cpus=6`，两颗 A76（2.3GHz）一直闲着。
   单线程启动代码（dyld/objc/LS）能快 20–30%。

---

## 6. 图形栈现状：为什么没有 GPU 也能出画面，代价是什么

事实链（都有代码/字符串/日志支撑）：

1. 内核只提供 `IOCoreSurfaceRoot` + `IOMobileFramebuffer`(AppleCLCD) 两个服务，**没有任何 `IOAccelerator*`**（`grep` 全补丁无命中）；
2. QuartzCore 找不到 `IOAcceleratorES` → `CAMetalContextCreate` 返回空 → CoreAnimation 使用**软件光栅器**；
3. 软件光栅器把图层画进 IOSurface（`1125×2436`，`bpr 4608`，11.2MB）；
4. `SwapEnd` 时内核把每个启用图层 **逐行 memcpy** 到 ABL 留下的帧缓冲（`stride 4320`，`Normal-NC`），
   `sweetfb_hz=30` 节流（60Hz tick 每 2 次呈现一次）。

每帧成本：`1125×2436×4 ≈ 10.96MB` 拷贝 × 30Hz ≈ **329MB/s 的不可缓存写**，再加 CA 自己的软件合成。
这就是「简单界面 20–30fps」的主因，也是发热与耗电的主因。

### 6.1 能立刻做的（不需要 GPU）

| 优化 | 做法 | 预期 |
|---|---|---|
| 帧缓冲改 write-combining | `pmap` 里把 `0x9c000000` 的 `CACHE_ATTRINDX_NORMAL/NC` 改成 WC（`ml_io_map` + `pmap_change_wiring`；WC 对顺序写吞吐高 2–4×） | present 拷贝 −50~70% |
| 呈现分核 | 把 2436 行按 6 等分交给 6 个 A55 并行 memcpy（workloop 里 fan-out/join） | 再 −3~5× |
| 消除 padding 拷贝 | 面板 stride 4320 vs surface bpr 4608：按行拷 4500 字节已是最小；若能让 CA 直接给 4320 的 bpr（IOSurface 属性里把 `bytes-per-row` 对齐掩码调成 64），可整块 memcpy | −5% |
| **零拷贝 flip（最优）** | 给 CA 的显示 surface 用**物理连续**内存池（`kmem_alloc_contig`，3×11.2MB=34MB，启动时预留），`SwapEnd` 只改 DPU 图层基址，不再拷贝 | present 成本 → ~0 |

零拷贝 flip 的前置条件：DPU 取图要走 SMMU（我们没建），所以要么改成物理连续 + 直接写 DPU 的 layer base 寄存器，
要么补一个最小 SMMU 映射。寄存器布局可对照 Qualcomm 下游 `msm` 的 `sde`/`dpu` 驱动（SM7150 同代）。
这是「用显示硬件代替 GPU 做最后一公里」的路线，收益比优化 memcpy 大一个数量级。

---

## 7. GPU 路线：三条，只有两条值得走

iOS 16 的 WindowServer 只认 Metal。要「真 GPU 加速」= 需要一个能让 `CAMetalContextCreate` 成功的
`IOAcceleratorES` 家族服务 + 与之匹配的 Metal 驱动。Adreno 618 不是 AGX，Apple 的 AGX 驱动/固件也不适用于它。
所以：

**A. 软件渲染路线（推荐，已在跑）**
不做 GPU，把 §6.1 做完 + 打开 8 核。目标 60fps@1080p 的静态界面。零架构风险。

**B. Adreno 当「2D 引擎」用（可选，2–4 人月）**
在 XNU 里写 KGSL 子集：SMMU + CP ringbuffer + 固件加载（`a630_sqe.fw` 等，需从 Android vendor 分区取），
只提交 **blit / fill / format-convert / rotate** 命令，不做 Metal、不做 3D。
用途：把 §6.1 的整帧拷贝、缩放、格式转换交给 GPU，CPU 只做 CA 软件合成。
参考：Mesa `freedreno`（a6xx 寄存器与命令流文档最全）、Linux `drivers/gpu/drm/msm` + `kgsl`、Adreno 的 zap shader 流程。
风险：固件/安全域（zap）、SMMU 上下文、功耗。收益：present 与合成带宽 −80%。

**C. 真 Metal/AGX 兼容层（劝退）**
需要同时逆向 AGX 的驱动 ABI 与 Adreno 的 ISA/命令流，还要实现 Metal 的整个资源/管线模型。
不是「再加一个驱动」的量级，不建议投入。

**建议**：A 立即做；B 只做 blit 子集并在 A 完成后评估；C 明确放弃。对外表述也建议改成
「CPU 渲染 + 显示硬件合成」，不要承诺 GPU 驱动。

---

## 8. 其他启动税（小但确定）

| 项 | 数据 | 处理 |
|---|---|---|
| 重启风暴 | 一次启动 483 次 `exec`；`bluetoothd` 34 次、`fairplayd.H2` 35 次 | 已处理：`sweet-root-tweaks.py` 的 `daemons()` 按可执行名删除这两个作业（`SWEET_KEEP_DAEMONS=1` 保留） |
| AKS 失败重试 | `securityd sel 10 -> 0xe00002c7` 反复出现（55 次 securityd 调用） | 让 AKS stub 对 sel 10 返回一个「有效但空」的 keybag，而不是 unsupported |
| 沙盒拒绝 | `SWEET Sandbox: ... privilege 1002/1007/12000 denied` | 逐条加白（logd/SpringBoard/rapportd 已在刷） |
| Jetsam | `Could not opt into 50 MB Jetsam high watermark: 22` | 补 `memorystatus_control` 的 Jetsam 分支，避免 launchd 降级策略 |

---

## 9. 路线图与验收

> **落地情况**：P0 的 1、2、7 与 P1 的 5 已经改成代码/镜像步骤，逐项改动与验证方法见
> [`BOOT_FIXES.md`](BOOT_FIXES.md)。P0 的 3、4 与 P1 的 6 需要一次真机启动的数据（本机当前无设备）。

**P0（本周：30–60s 已在手上，200s 级的要等采样确认）**
1. 打两个共享缓存补丁（30s/进程；240s 陷阱）。验收：`CAMetalContextCreate` 调用到返回 < 1s。
2. 命令行加 `ufscache=1 ufswait=1 cpus=8`（零代码）。验收：UFS 平均命令延迟下降、启动不回归。
3. 用 `sweetsample=SpringBoard,lsd,...` 跑一次，拿到 lsd 的栈 → 决定 P0-4 走哪条。
4. 按采样结果修 lsd（MG 空壳服务 / 预置 LS DB / DB 挪到 tmpfs）。验收：SpringBoard 到首帧 < 30s。

**P1（下周，收益 10–25s + 交互）**
5. 内核时间戳 + UFS 统计埋点 → 把 31.5s 拆开，按最大项修（journal 回放 / 目录扫描 / 轮询）。
6. present 路径：WC + 多核拷贝（或直接上零拷贝 flip）。
7. 清理重启风暴 + AKS/沙盒拒绝。

**P2（中期）**
8. 连续内存池 + DPU 直接扫描输出（零拷贝 flip）。
9. 评估 Adreno blit 子集（B 路线）。

**总体验收指标**（每项都要在 `logs/` 留一份启动日志）：
- `launchd hello` ≤ 12s；
- SpringBoard exec → 锁屏首帧可见 ≤ 10s（现在 ≥ 200s）；
- 冷启动到锁屏 ≤ 25s；
- 主屏滑动 ≥ 50fps（用 `SWEET FB: swap` 计数 / 30s 估算）。

---

## 10. 复现命令

```sh
# 1) 反汇编 Metal 等待
python3 tools/macho-analyze.py dis research/dsc-extract/QuartzCore ___CAMetalContextCreate_block_invoke

# 2) 采样栈符号化（三份日志结论一致）
python3 tools/dsc-frames.py artifacts/ios-clean-log.txt --only SpringBoard
python3 tools/dsc-frames.py artifacts/lock-log.txt      --only SpringBoard

# 3) 打补丁（先 dry-run）
python3 tools/dsc-patch.py research/dsc-test --preset metal-wait-300ms
python3 tools/dsc-patch.py research/dsc-test --preset metal-wait-300ms -y

# 4) 恢复
python3 tools/dsc-patch.py research/dsc-test --restore research/dsc-test/.dsc-patch-undo.json
```

---

## 11. 参考资料

- Apple 开源：`xnu-8796`（`vfs/vfs_cluster.c` 的 readahead、`bsd/hfs` 的 journal、`osfmk/arm/pmap`）、`dyld`（共享缓存格式与 `shared_region`）、`libdispatch`、`IOHIDFamily`
- `blacktop/ipsw`（dsc 解析/符号化）、`blacktop/darwin-xnu-build`（本项目 CI 用的构建链）
- `jprx/darwin-vm`（在 QEMU 上跑 iOS/macOS，单 vCPU 的取舍与本项目一致）
- Mesa `freedreno`（a6xx 命令流/寄存器）、Linux `drivers/gpu/drm/msm` 与 `kgsl`、Qualcomm SM7150 下游内核（`sde`/`dpu`、`ufs-qcom`、`cpufreq`）
- JEDEC UFSHCI（JESD223）命令/槽位模型；Apple TN1150（HFS+ 卷格式）、HFS+ journal 事务语义
- 本项目：`NOTES.md`（QEMU 路径的 lsd/MG 诊断）、`xnu/patches/0028/0046/0054/0056/0069`、`tools/sweet-root-tweaks.py`

---

### 附：本文新增/使用的工具

| 文件 | 说明 |
|---|---|
| `tools/macho-analyze.py` | Mach-O 符号/导出/反汇编/xref，Windows/Linux 可用 |
| `tools/dsc-frames.py` | 采样栈 → `dylib+offset(+symbol)`，按进程 slide 解析 split cache |
| `tools/dsc-patch.py` | split dyld 共享缓存的定点补丁（校验 + undo），含 `metal-wait-300ms`、`iosurface-wait-3s` 预设 |
