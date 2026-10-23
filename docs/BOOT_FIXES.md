# SWEET 启动修复记录（第一批）

日期：2026-10-23 · 对应分析：[`BOOT_ANALYSIS.md`](BOOT_ANALYSIS.md) · 目标机：Redmi Note 10 Pro (sweet) + iPhone X 16.7.16 userland

这一份只写**已经改了什么、怎么验证、怎么回滚**。分析过程、采样栈和反汇编证据都在 `BOOT_ANALYSIS.md`，这里不重复。

---

## 0. 一页结论

| # | 问题 | 状态 | 改动 | 预计收益 |
|---|---|---|---|---|
| 1 | 无 GPU 时每个进程多等 30s | **已落地 + 已在 VM 实测**（2/2 出帧，原始 0/2） | 共享缓存 `metal-wait-300ms` | 每个创建 Metal 上下文的进程 **−29.7s** |
| 2 | `IOSurface` 兜底等 240s | **已落地**（同上） | 共享缓存 `iosurface-wait-3s` | 若触发 **−237s** |
| 3 | `ufscache` / `ufswait` 写在驱动里但没进命令行 | **已落地** | `--profile device` 带 `ufscache=1 ufswait=1` | 少整段 dcache 维护、少自旋烧 CPU |
| 4 | 两颗 A76 一直闲着 | **已落地** | `cpus=8`（0078 早已支持） | 多 2 核，渲染/编译约 +10~20% |
| 5 | 内核 31.5s 完全不能分解 | **工具就绪**，等一次计时启动 | 内核 0083 `sweetts=1` + `tools/boot-timeline.py` | 直接得到「哪一段静默了多少秒」 |
| 6 | 200s+ 的 lsd 等待不知道卡在哪 | **工具就绪**，等一次采样启动 | 内核 0084 `ufsstats=1` + `--profile sample` | 定量 UFS 命令数/延迟/睡眠比 |
| 7 | 重启风暴（bluetoothd / fairplayd.H2） | **已落地** | `tools/sweet-root-tweaks.py` 的 `daemons()` | 每次启动少 60+ 次 exec 与其日志 I/O |
| 8 | present 路径每帧 10.96MB 内核拷贝 | **未动** | — | 需要真机帧率数据才能判断瓶颈在哪 |

一句话：**能离线确定的两处 30s/240s 等待、两个失效的启动参数、一颗闲置的核、一场重启风暴，都已经改成代码**；
剩下两件（31.5s 内核段、lsd 的 200s）本身是「测不出来」的问题，这一批交付的是**测出来的手段**，不是猜出来的补丁。

---

## 1. 共享缓存的两处 GPU 等待

### 1.1 证据（指令级，`BOOT_ANALYSIS.md` §3）

| 站点 | 库 | 未滑动 VA | 原指令 | 原语义 |
|---|---|---|---|---|
| `___CAMetalContextCreate_block_invoke` | QuartzCore | `0x18853e6b4` | `bf ae 04 71` = `cmp w21, #0x12b` | 轮询 `IOServiceMatching("IOAcceleratorES")` **300 次**，每次 `usleep(100ms)` |
| `__iosConnectInitalize` | IOSurface | `0x1a3983c98` | `15 1e 80 12` = `movn w21, #0xf1` | 计数从 **−241** 起，`sleep(1)`，**240 次**后放弃 |

第一处是实打实每次都付的：没有 GPU 时 QuartzCore 等满 30s 才退回软件渲染。第二处是兜底（内核在 launchd 之前就发布了
`IOCoreSurfaceRoot`），正常情况下不触发，留着是为了防止启动顺序回归。

### 1.2 改法

| 站点 | 新指令 | 新语义 | 文件内偏移 |
|---|---|---|---|
| QuartzCore | `bf 0e 00 71` = `cmp w21, #3` | 3 次 = 300ms | `dyld_shared_cache_arm64.03` @ `0x17b26b4` |
| IOSurface | `75 00 80 12` = `mov w21, #3` | 3 次 = 3s | `dyld_shared_cache_arm64.11` @ `0x139fc98` |

**为什么留 3 次而不是 0 次**：让「真出现 GPU」的那天仍然能成功，代价只是 300ms；改成 0 次等于把这条路径拆掉，
以后接上 GPU 要重新逆向一遍。

### 1.3 集成方式

`tools/mkiosroot.sh` 在把 cryptex 共享缓存硬链接进 `/System/Library/Caches/com.apple.dyld` 之后，**构建镜像时自动打**：

```sh
sudo python3 tools/dsc-patch.py --root "$work/root" --presets all -y \
     --undo-out "$out.dsc-undo.json"
```

- `SWEET_DSC_FIX=0` 构建一个原样镜像（A/B 对比用）。
- 撤销记录写在镜像**外面**（`ios16-root.img.dsc-undo.json`），不污染镜像。
- 硬链接意味着改一次同时改了 cryptex 里和 Caches 里两份视图。

工具本身是幂等的：已经是目标字节就报 `already patched` 并跳过，所以重复构建/重复执行都安全。

### 1.4 验证

```sh
# 只看状态，不写
python3 tools/dsc-patch.py --root /mnt/iosroot --presets all --check

# 期望输出：两个站点 current 都是 bf0e0071 / 75008012
```

离线自测（本机已跑通完整往返：打补丁 → 幂等 → 回滚）：

```sh
python3 tools/dsc-patch.py research/dsc-test --presets all --check
python3 tools/dsc-patch.py research/dsc-test --presets all -y --undo-out /tmp/undo.json
python3 tools/dsc-patch.py research/dsc-test --restore /tmp/undo.json
```

### 1.5 风险

共享缓存不重新签名。SWEET 根卷是 unsealed、AMFI 宽松（`0036-sweet-amfi-cs-signed.patch`），镜像里
MobileGestalt getter 早就是同样处理。唯一真实风险是**字节改错位置**——工具先校验 `expect` 再写，写完立刻 read-back
比对，不匹配就中止，不会写出一个「半个补丁」的镜像。

---

## 2. 启动参数：从四条副本变成一个真相源

### 2.1 改动

```diff
-debug=0xc serial=3 cpus=6 ... sweetfb_hz=30
+debug=0xc serial=3 cpus=8 ... sweetfb_hz=30 ufscache=1 ufswait=1
```

原来这份命令行同时写在 `README.md`、`docs/IOS_ROOT_WSL.md`、`android/.../MainActivity.java` 的提示里，
以及每个人凭记忆敲的构建命令里——所以 0069 早就实现了 `ufscache`/`ufswait`，却一直没被传进去。
现在唯一来源是 [`tools/bootargs.py`](../tools/bootargs.py)，打包用 `mkpayload.py --profile NAME`。

| profile | 用途 | 长度 |
|---|---|---|
| `device` | 日常启动：8 核、缓存写、睡眠等待、30Hz 软面板 | 255 字节 |
| `timing` | `device` + `sweetts=1 ufsstats=1 ufsstatsecs=5` | 290 |
| `sample` | `timing` + `sweetsample=SpringBoard,lsd,backboardd,containermanagerd` | 347 |
| `qemu` / `probe` | 只测内核（TCG 单核、`rd=md0` / 无根） | 55 / 36 |

**上限 607 字节**：shim payload 头的 boot-args 字段是 608 字节（`tools/mkpayload.py: BOOT_LINE_LENGTH`），
Android App 也在同一位置截断（`MainActivity.truncateCmdline`）。`bootargs.py` 的自检会在超限时直接报错，
而不是让内核悄悄收到半条命令行。

```sh
python3 tools/bootargs.py --list        # 所有 profile 与长度
python3 tools/bootargs.py timing        # 打印出来
python3 tools/bootargs.py timing --add sweetiolog=1
```

### 2.2 每个参数对哪个补丁

| 参数 | 内核补丁 | 作用 |
|---|---|---|
| `ufscache=1` | 0069 | 只 clean 命令真正用到的 DMA 段（UTRL/UCD/PRDT/BAOUNCE），不再整段 sync |
| `ufswait=1` | 0069 | 可睡眠上下文里用 `assert_wait_deadline` 等完成，不再 `delay(1)` 自旋 |
| `cpus=8` | 0078 | `SWEET_SMP_MAX_CPUS` 8，`mpidr 0x600/0x700` 是两颗 A76 |
| `sweetts=1` | **0083（新）** | 每行控制台输出加 `[秒.毫秒]` 前缀 |
| `ufsstats=1 ufsstatsecs=5` | **0084（新）** | 每 5s 一条 UFS 统计 |
| `sweetsample=a,b,c` | 0054 | 采样指定进程的内核栈 |

### 2.3 风险

`cpus=8` 会把两颗 A76 混进同一个 cluster，调度器把它们当同构核用（没有 P/E 分组）。这不会更慢，
但「省电」这件事在 bring-up 阶段本来就不成立。回退：`--cmdline` 里把 `cpus=8` 改回 `cpus=6` 重新打包即可，
不用重编内核。

---

## 3. 内核计时与 UFS 统计（新增 0083 / 0084）

这两个补丁是**为了回答「31.5 秒花在哪」而写的**，不改任何行为，只在 `sweetts=1` / `ufsstats=1` 时才工作。

### 3.1 0083 `sweetts=1`：控制台时间戳

- 挂点：`osfmk/console/serial_console.c:_cnputs()` 已经无条件调用 `sweet_log_append()`（`bsd/dev/sweet_ufs.c`），
  这一处同时收**内核 printf 和守护进程写 `/dev/console`**，所以一份时间戳覆盖整条启动链，包括 userland。
- 前缀固定 13 字节：`[` + 6 位秒 + `.` + 3 位毫秒 + `] `，所以一段输出需要的环形缓冲可以**一次原子预订**
  （`os_atomic_add_orig(&sweet_log_total, size + prefixes*13)`），不会和其他 CPU 的控制台写入交错破坏环形缓冲。
- 时间源：`mach_absolute_time()` → `absolutetime_to_nanoseconds()`。ARM 通用定时器从**复位**开始计数，
  所以时间轴起点是上电，而不是第一条日志。超过 999999 秒（11.5 天）饱和。
- 开销：关掉时零成本（一个 `if`）；打开时每行多 13 字节和一次 `CNTVCT` 读。

### 3.2 0084 `ufsstats=1`：命令统计

在 `ufs_scsi()` 里从**门铃写入到完成**计时（`mach_absolute_time()`），统计：

- `cmds` / `rd` / `wr` / `bytes`：控制器实际被要求做什么
- `avg` / `max`：区间平均与历史最大延迟
- `slept`：有多少条命令真的睡了下去（`ufswait=1` 是否生效）
- `errors`：超时与 UPIU 失败

输出形如：

```
SWEET UFS: 1200 cmds (900 rd/300 wr, +300), 8192 KiB (+2048), avg 410 us, max 12000 us, slept 1100, errors 0
```

**怎么读**：`slept/cmds` 接近 1 说明 `ufswait` 确实把自旋换成了睡眠；如果这个比值很低，说明大部分 I/O 发生在
中断上下文或者持有抢占级的地方，那 UFS 延迟只能靠减少命令数（合批/缓存）来改，靠睡眠没有用。
`max` 远大于 `avg` 说明有长尾（单个 12ms 的命令在 1200 条里就会拖出 14s 的总和），这才是要抓的东西。

### 3.3 `tools/boot-timeline.py`：把日志变成结论
```sh
tools/sweet-log-pull.sh logs/boot.txt
python3 tools/boot-timeline.py logs/boot.txt                 # 最大的 8 段静默
python3 tools/boot-timeline.py logs/boot.txt --around 200    # 200s 前后 10s 的逐行
python3 tools/boot-timeline.py --bin logs/area.bin           # 直接读分区尾部原始区域
```

它把每段静默归因成「**静默前最后一行 → 静默后第一行**」：前者是导致等待的东西，后者是终于把它叫醒的东西。
实测样例（合成日志，用于自测）：

```
  25.837 s  5.480 -> 31.317  [SWEET HID]
            before L44    SWEET HID: key service 39 ready
            after  L45    AppleCLCD: frame buffer 1080x2400 at 0x9c000000
```

没有时间戳的旧日志会明确提示要用 `--profile timing` 重跑，而不是输出一张空表。

### 3.4 这两个补丁怎么在本机验证（没有内核构建环境）

内核在 Windows 上编不了，但这两处新增代码不依赖内核状态，所以可以切出来单独编译、单独跑：

```sh
python3 tools/test-sweet-ufs.py            # --src research/xnu/work
#   [ok] sweetts prefix
#   [ok] ufsstats counters
#   all harness checks passed
```

它从 `bsd/dev/sweet_ufs.c` 里按标记切出 `sweet_ts_prefix` / `sweet_log_append` / `ufs_stat` /
`ufs_stats_thread`，用桩替换 `mach_absolute_time`、锁、`tsleep`，然后断言：

- 前缀恒为 **13 字节**（少一个字节会让后面每一行都错位）；
- 一行一个前缀、跨 chunk 的行不会被重复加前缀；
- 毫秒是截断不是四舍五入，6 位秒字段饱和；
- `ufsstats` 的 cmds/rd/wr/bytes/avg/max/slept/errors 数值与区间增量都算对。

编译用 `-Wformat=2 -Werror=format`，所以统计行里的 `%llu` 类型不匹配会直接编译失败，
而不是在手机上打出 `0`。


---

## 4. 重启风暴：删掉两个永远不可能成功的作业

`bluetoothd` 和 `fairplayd.H2` 在一次启动里被 exec 30–35 次（本次日志 7 次 / 4 次，看启动长短），
每次失败都往控制台环形缓冲写十几行、再由 UFS 落到分区：

- 蓝牙射频是高通的，没有 Apple 的 BT 固件与控制器驱动，`bluetoothd` 不可能成功；
- `fairplayd.H2` 需要硬件 AES 协处理器，AppleKeyStore 每个 selector 都返回 `0xe00002c7`（`kIOReturnUnsupported`）。

`tools/sweet-root-tweaks.py` 新增 `daemons()`：按**可执行文件名**（不是 label）从
`System/Library/xpc/launchd.plist` 里摘掉这两个 LaunchDaemon，并打印实际删掉的 label；
如果镜像里没有匹配到，会明确警告「label 和预期不同」，而不是静默什么都不做。

- 保留开关：`SWEET_KEEP_DAEMONS=1` 跑同一个脚本即可原样保留。
- 已用合成 plist 单测：两个作业被摘除、无关作业保留、开关生效。

---

## 5. 重建与验证流程

```sh
# 1) 内核：新补丁 0083/0084 需要重编（push 到 xnu/patches/** 触发 CI，产物照旧）
#    产物：xnu/out/kernel.development.sweet

# 2) 根镜像：重建时会自动打共享缓存补丁（已有镜像不重烧则这两处不生效）
#    tools/mkiosroot.sh OS.dmg SYSTEMOS.dmg APPOS.dmg ios16-root.img
python3 tools/dsc-patch.py --root /mnt/iosroot --check     # 若要单独核对现有镜像

# 3) payload：用 profile，不要手敲命令行
python3 tools/mkadt.py shim/out/sweet.adt --highmem
python3 tools/mkpayload.py xnu/out/kernel.development.sweet shim/out/sweet.adt \
        shim/out/payload.bin --profile device
shim/build.sh ../shim/out/payload.bin

# 4) 烧写与启动
fastboot -S 512M flash userdata ios16-root.img
fastboot boot shim/out/shim-boot.img
```

**要做一次计时启动**（这是拿 31.5 秒答案的那一步）：

```sh
python3 tools/mkpayload.py ... --profile timing     # 加 sweetts=1 ufsstats=1
fastboot boot shim/out/shim-boot.img
# 看到锁屏后：进 recovery 拉日志
tools/sweet-log-pull.sh logs/boot.txt
python3 tools/boot-timeline.py logs/boot.txt --gaps 12
```

**要做一次采样启动**（这是拿 lsd 栈的那一步）：

```sh
python3 tools/mkpayload.py ... --profile sample     # 加 sweetsample=SpringBoard,lsd,backboardd,containermanagerd
# 起来后拉日志，把 SWEET SAMPLE 段交给符号化工具
python3 tools/dsc-frames.py logs/boot.txt --only lsd
```

### 回滚

| 改动 | 回滚 |
|---|---|
| 共享缓存补丁 | 用 `mkiosroot.sh` 给的 `<img>.dsc-undo.json` 跑 `dsc-patch.py --restore`；或 `SWEET_DSC_FIX=0` 重建 |
| 启动参数 | `--profile device` 之外用 `--cmdline` 原样传旧串 |
| 内核 0083/0084 | 从 `xnu/patches/` 移走这两个文件重编；两个 boot-arg 不传时行为与改动前完全一致 |
| 作业删除 | `SWEET_KEEP_DAEMONS=1` 重跑 root tweaks |

---

## 6. 还差真机的两件事

这两件不是没做，是**必须先有数据**，否则就是猜：

### 6.1 内核 31.5 秒

`--profile timing` 跑一次，`boot-timeline.py` 会直接给出最大的几段静默。按结果分三种走法：

| 观测 | 判断 | 下一步 |
|---|---|---|
| 静默前一行是 HFS/journal 相关，且 `ufsstats` 显示 cmds 数巨大 | 小 I/O 数量问题 | HFS 挂载期加大 read-ahead / 合并 cluster 读 |
| 静默前一行是 HFS，但 cmds 不多、`max` 很大 | 单命令长尾 | 查 UFS 单命令超时/重试，考虑多槽 |
| 静默里 `ufsstats` 完全没动 | 不是 UFS | 看是不是 `IOSurface`/`AppleCLCD` 的服务等待或某个 `tsleep` |

### 6.2 lsd 的 200 秒

`--profile sample` 跑一次，拿到的是 `lsd` 自己的栈（而不是 SpringBoard 等它的栈）。三种可能：

| 采样栈 | 判断 | 下一步 |
|---|---|---|
| `lsd` 在 sqlite/fsync | LaunchServices 数据库重建，每次写入都等 I/O | 预置一份已建好的 LS 数据库进镜像，或把 `lsd` 的 DB 放到 tmpfs |
| `lsd` 在 `mach_msg` 等别的服务 | 依赖链在更下游 | 换采样名单，继续往下追 |
| `lsd` 根本没在跑，栈是空的 | 不是 lsd 慢，是它起不来 | 回头看它为什么起不来（沙盒拒绝 / 缺少 entitlement） |

---

## 7. 这一批没有动的东西

- **present 路径**（`AppleCLCD::swap()` 逐行 `memcpy` + `sweetfb_hz=30` 节流）：改成 WC 映射或多核拷贝都能省 CPU，
  但省下来的是**帧时间**，不是**启动时间**，而且需要真机帧率分布才能证明它值得改。留到启动链干净之后。
- **GPU**：三条路线的结论在 `BOOT_ANALYSIS.md` §5，短期只有「CPU 光栅 + 硬件 2D/扫描输出」可行。
- **AKS selector 10 失败**（`0xe00002c7`）：这是没有硬件 AES 的必然结果，不是 bug；能做的只是让上层不再重试
  （`fairplayd.H2` 已删）。

---

## 8. SweetVM 上的实测 A/B：这两个共享缓存补丁到底有没有用

2026-10-23 晚，K70 Pro 接入后补做的实验。**先纠正一个前提**：`artifacts/` 里全部的启动日志都不是
Redmi Note 10 Pro 硬件，而是这台手机上的 SweetVM（QEMU TCG）。判据是三行日志：

```
SWEET CPU: requested=1 selected=1 (limit=8)          # 不是 cpus=6/8
vm_page_bootstrap: 76090 free pages                  # 76090 × 16K ≈ 1.19 GB
SWEET UFS: ... first block 0x22 ... DMA at 0xb33d8000  # 低内存 ADT，不是硬件高内存
```

App 侧对应 `-M virt,gic-version=3 -cpu cortex-a76 -smp <cpus> -accel tcg,thread=single,tb-size=512`，
其中 `<cpus>` 直接取自命令行的 `cpus=N`，内存是 3 GB 文件后端（XNU 只用 ADT 声明的 1.19 GB）。

### 8.1 方法

同一个 payload、同一个 16 GB 镜像，**唯一差别是镜像里那 8 个字节**：

```sh
python3 tools/image-patch.py find .tools/ios16-root.img     # 不挂 HFS，扫 dyld_v1 + 校验站点
python3 tools/phone-patch.py status                          # 手机镜像上两个站点的真实字节
python3 tools/phone-patch.py patch                           # 4 KiB 块读回→校验→改 4 字节→写回→读回
python3 tools/vm-probe.py run.csv 340 5                      # 每 5 s 读 SWEETLOG 头(total/seq)与尾部
python3 tools/compare-runs.py a.csv a.log b.csv b.log        # 按 flush 序号对齐，不看壁钟
```

计时用**内核自己的 flush 序号**（日志线程每 10 秒刷一次，序号即 guest 的 10 秒刻度），
不用壁钟：TCG 的执行速度会漂，但 guest 时间是 usleep 的计量单位。

### 8.2 结果

| 运行 | 镜像 | 日志字节 | 最后 seq | 出帧（`SWEET FB: N swaps`） |
|---|---|---|---|---|
| base1 | 原始 | 65 888 | 22 | **无** |
| base2 | 原始 | 70 356 | 30 | **无**（跑到 300 s guest 也没有） |
| patch1 | 已打 | 65 704 | 23 | 有，seq 21（≈210 s guest） |
| patch2 | 已打 | 68 172 | 24 | 有，seq 22（≈220 s guest） |
| vm2cpu | 已打 + `cpus=2` | 65 988 | 22 | 有，seq 22（≈220 s guest） |

两次原始、两次已打，结果一致：**打补丁的两次都在 ~210 s guest 开始出帧（1000/2000 swaps），
原始镜像的两次都一帧没有**，其中 base2 跑到的 guest 时间比两次已打补丁的都长，仍然没出帧。
差额约 90 s guest，和「每个进程 300×100 ms = 30 s」乘以两三个进程（backboardd / SpringBoard）吻合。

也就是说：`NOTES.md` 里那句「全 iOS 渲染 surface 但卡在开机 logo」——**其中相当一部分就是这两个等待**，
补丁后 VM 已经进入呈现循环。

### 8.3 lsd 的栈（P0-3 的答案）

补丁后的日志里有完整的采样（`SMP lsd[92]`），符号化结果在
[`artifacts/vm-lsd-stacks.txt`](../artifacts/vm-lsd-stacks.txt)：

- 主线程 `t0`：`mach_msg` ← `libxpc`（它自己的 XPC 服务循环，空闲）
- 工作线程：`CoreServices+0x118cc0` ← CoreFoundation，另一条在 `CoreServices+0x21ff8` ←
  `libsystem_malloc`（分配），还有一条在 `UserManagement`
- 没有任何一条在等一个「内核里不存在的服务」

结论：lsd **不是在等谁，而是在单核 TCG 上算 LaunchServices 数据库**。所以「预置 LS 数据库 / 挪 tmpfs」
仍然是候选，但优先级要排在「给 VM 多一个 vCPU」之后。

### 8.4 加 vCPU 没有用，原因在 `thread=single`

按 `--profile vm`（`cpus=2`）重建 payload 又跑了一次（`tools/bootargs.py vm`），结果和 1 核那两次几乎一样：
`65 988` 字节 / seq 22 / 约 220 s guest 出帧。原因看 App 的 QEMU 参数就明白：

```
-accel tcg,thread=single,tb-size=512
```

`thread=single` 让**所有 vCPU 在同一个宿主线程里轮转**，加 `-smp` 只是让多个 guest 核分时复用同一个宿主核，
吞吐不变。`NOTES.md` 里"2 vCPU 稳定、6/8 撞 pset0 ticket lock"也就解释得通：MTTCG 下锁语义被打破，
而单线程模式本来就不该指望多核。截图确认这次是**黑屏 + 一条竖线**（`artifacts/vm-2cpu-screen.png`），
不是锁屏——**能出帧 ≠ 画面正确**，这是渲染路径的问题，和启动卡点分开看。

所以顺序应该是：

1. **减少 guest 侧的等待与工作量**（已做的共享缓存补丁正是这一类，实测有效）。
2. **MTTCG**：要让多核对 VM 有意义，必须用 `thread=multi`，代价是先修 SWEET 的 pset0 ticket lock
   （`-accel tcg,thread=multi` 下 install/Setup 负载会死锁，见 `NOTES.md`）。这是下一个真正的性能杠杆。
3. **LS 数据库手术**：单核下 lsd 仍然拖着启动，但只有在 MTTCG 不可行时才值得做镜像侧改造。
4. 渲染黑屏：另开一条线（FB 像素格式 / surface 内容 / 是否 display off）。

### 8.5 注意

- 上面这些数字是**一核 TCG** 的，不能当成真机（SM7150 八核）的启动时间。
  `README` 的 `--profile device`（`cpus=8`）是给硬件用的；VM 用 `cpus=2`。
- 采样器（0054）在 VM 里已经把 `lsd`、`containermanager`、`backboardd`、`SpringBoard` 的栈打全了，
  下一次「sampler 启动」不必重复配命令行，现有 payload 就带着 `sweetsample=...`。

---

## 9. 卡顿与"上划无反应"（2026-10-23 深夜，K70 Pro 实机）

欢迎页已经出来了（`artifacts/vm-welcome-2.png`，希腊语的 "Σαρώστε προς τα επάνω για άνοιγμα"）。
剩下两个症状各自有独立根因，**都不是"手势参数调不好"**。

### 9.1 卡顿：宿主每秒只取 4 帧

`VmEngine.startReader()` 用 `1000/fps` 的节奏把 guest 的 1080×2400 帧缓冲整块拷进 Bitmap，
而 `fps` 的默认值是 **4**（`BootConfig.load` 的 `getInt(KEY_FPS, 4)`，上限 15，设置页"画面采样"滑杆 1–12）。

实测 guest 自己的出帧速度（读内核日志里每 1000 次 present 打一行的计数）：

```
7000 swaps -> 9000 swaps in 121 s   =>  16.5 fps
```

也就是 **guest 能出 16.5 帧，宿主只显示 4 帧**：看到的卡顿里约四分之三是采样丢帧，不是渲染慢。

处理：`shared_prefs/sweetvm.xml` 的 `fps` 改成 15（等价于设置页把"画面采样"拉到最大，然后重启 VM）。
改完显示帧率贴近 guest 上限，剩下的是 guest 侧 16.5 fps 的天花板——那是单线程 TCG + 软件光栅的账，
要再快只能走 `thread=multi`（会撞 pset0 ticket lock，见 §8.4）或者减小渲染分辨率（要同时改 ADT、内核和 App）。

### 9.2 上划无反应：触摸控制器根本没被初始化

日志里的一行就是答案：

```
SWEET TOUCH: TLMM reset=0 irq=0 vdd90=0; voting L11C through RPMh
SWEET RPMH: rsc=0x18220000 ... DRV=2 id=0xffffffff solver=0xffffffff config=0xffffffff TCS=63 ncpt=31
SWEET RPMH: unsupported RSC geometry/revision
SWEET RPMH: enable failed errno=19
SWEET TOUCH: L11C RPMh enable failed 19; probes skipped
```

`sweet_rpmh_vreg_enable("ldoc11", 3200)` 读 PMIC 的 RPMh 寄存器，QEMU 没有模拟这个块，
读回全是 `0xffffffff`，几何检查失败返回 `ENODEV(19)`，触摸驱动于是 `goto out` —— 探针一次都没发出去，
GT9896 从未上线。所以不是"滑动识别不出来"，是**根本没有触摸事件**（点击也不会有）。

反证：`artifacts/nocc-log2.txt` 那次同一个 VM 里探针是好的——`probe raw 0x4022: 39 38 39 36`（"9896"）、
`selected GT9896 Yellowstone, 1080x2400, poll=10ms`，而且真的上报过
`SWEET HID: touch 0 down at 540,2200`。那次的内核还没有这段电源投票（日志里一条 `SWEET RPMH:` 都没有），
所以这是**后来引入的回归**，不是 VM 做不到。

修复：[`xnu/patches/0085-sweet-touch-probe-without-rail.patch`](../xnu/patches/0085-sweet-touch-probe-without-rail.patch)
——把电源投票降级为"尽力而为"：失败就打一行 `L11C vote failed N; probing anyway` 继续探测。
真机上电源真没上，探针自己会失败并打出来，语义没有变差；VM 里则恢复到 nocc-log2 那次的成功路径。

验证：补丁在干净树上 `patch -p1` 应用后与工作文件逐字节一致（同 0083/0084 的做法）。

> 注意：**不要用 `sweetkeys=1` 绕输入**。SPMI 按键驱动在 VM 里读 PMIC 会直接 panic
> （`panic(cpu 0): Kernel data abort`，`artifacts/vm-hidtest-1.png`），所以 `sweethidtest`
> 那条"定时按 Home"的路子在 VM 里走不通；App 也是因为这个把 `sweetkeys=0` 写死进默认参数。

### 9.3 现在的状态

| 项 | 状态 | 生效条件 |
|---|---|---|
| 启动速度 | 已快很多（共享缓存补丁，§8） | 已生效 |
| 卡顿 | 采样 4 → 15 fps | 已生效（重启 App 后） |
| 上划 / 点击 | 需重编内核（0085） | `xnu/patches/**` 触发 CI，替换 payload |

---

## 10. 触摸打通后的性能账（2026-10-23 深夜）

触摸已经可用：驱动侧两处修复见 §11；实测 `SWEET HID: touch 0 down/up` 成对出现，
一次上划真的把 Setup 从 Hello 页推进到了「选择国家或地区」。

此后用户反馈"响应很慢"。查下来**不是采样率的问题，是 guest 侧每帧的工作量**：

| 事实 | 数据 | 出处 |
|---|---|---|
| guest 里没有任何 GPU 设备 | `IOAccelerator` / `Metal` / `IOGPU` 在整份内核日志里出现 **0 次** | 本轮启动日志 |
| 合成走软件光栅 | CoreAnimation 退回软渲染（正因为如此才要打 §1 的 30s 等待补丁） | `BOOT_ANALYSIS.md` §3 |
| 渲染尺寸大于面板 | surface `1125x2436`（`bpr 4608`），面板 `1080x2400` | `SWEET FB: swap … 1125x2436 fmt 0x42475241` |
| 每次 present 一次整帧拷贝 | 内核按行 `memcpy`，1080×4×2400 = **10.4 MB/帧**，只裁剪不缩放 | `SweetFramebuffer.cpp` `swap()` |
| guest 出帧速度 | 语言切换动画期间 **16.5 fps**（7000→9000 swaps / 121 s） | §9.1 实测 |

所以"加个 GPU 加速"这条路在这里不成立：QEMU `-M virt -cpu cortex-a76` 是纯 CPU 模拟，没有 GPU 设备可直通；
就算有，iOS 侧也没有 Adreno 的驱动栈。Apple 的渲染路径在这个 guest 里只有软光栅器一条。

### 10.1 三个真正的杠杆

| 杠杆 | 作用 | 代价 |
|---|---|---|
| **降低渲染分辨率**（canvas 1125×2436 → 750×1624，@2x 而不是 @3x） | 光栅化像素 2.74 Mpx → 1.22 Mpx，**−55%** | 要同时改 ADT（canvas）、内核（`fLogical`/`SweetFramebuffer` 的缩放）、App（`Payload.FB_W/H` + 面板读取尺寸） |
| **MTTCG**（`-accel tcg,thread=multi` + `-smp N`） | 多 vCPU 真正并行，理论上线性提速 | 要重编 QEMU 引擎；且现在会撞 SWEET 的 pset0 ticket lock（`NOTES.md`），需先修锁 |
| **present 只在内容变化时拷贝** | 静态界面省掉 10.4MB/帧 | 日志显示 present 本来就是事件驱动的（本次启动只有 17 次 swap），静态屏没有浪费，收益有限 |

也就是说：**要明显变快，只能动分辨率或 MTTCG，两者都需要重新构建**（内核 / 引擎 / APK），
本机没有 Xcode 与 Android SDK，无法产出。已把 App 侧的两处改进写进源码（`VmEngine`：采样上限 15→30，
且帧未变化时跳过 10MB 拷贝），等有构建环境时一起编进去。

### 10.2 本机能做的（已做）

- App 采样上限从 15 提到 30：guest 16.5 fps 时，15 fps 硬顶会稳定丢帧，30 上限可以"多取不漏"。
- 帧未变化时跳过 `copyPixelsFromBuffer`：静态页面不再每 tick 拷 10.4 MB。
- 说明：这两条只在**重编 APK** 后生效，当前手机上的 APK 仍是旧逻辑（fps 走设置里的滑杆，最大 12）。

---

## 11. 触摸：控制器上线 + 抬手释放（2026-10-23 深夜，K70 Pro）

两条独立故障叠在一起，直接症状都是"上划没反应"。

### 11.1 触摸控制器从未被初始化

`SWEET RPMH: unsupported RSC geometry/revision` → `enable failed errno=19` →
`SWEET TOUCH: L11C RPMh enable failed 19; probes skipped`。QEMU 没有模拟 PMIC 的 RPMh 寄存器
（读回全 `0xffffffff`），电源投票返回 `ENODEV`，驱动于是 `goto out`，GT9896 一次探针都没发出去。

反证：`artifacts/nocc-log2.txt`（旧内核，日志里一条 `SWEET RPMH:` 都没有）探针是成功的，
还上报过 `SWEET HID: touch 0 down at 540,2200` —— 说明这是**后来引入的回归**，不是 VM 做不到。

修复：[`0085`](../xnu/patches/0085-sweet-touch-probe-without-rail.patch)，把投票降级为"尽力而为"。

### 11.2 抬手事件被当成"无新帧"

修好探针后能看到 `down`，但永远看不到 `up`：QEMU 的 GT9896 模型只在 `touch_down` 时把报文头
`b[0]` 的 bit7（数据有效）置上，抬手时给的是 `b[0]=0`；而驱动把 bit7 清零当成
"no new touch frame: retain current contacts"，于是手指永远按着，任何手势都结束不了。

修复：[`0086`](../xnu/patches/0086-sweet-touch-release-on-empty-frame.patch)（驱动：空帧释放触点），
再加 `vm/qemu/sweet_touch.c` 的模型侧修复（抬手补发一帧 `b[0]=0x80, b[2]=0` 的有效空帧）。
两者各自独立可用，编其中任意一个都能解决。

### 11.3 没有构建环境时的落地方式

本机没有 Xcode（内核）与 QEMU 交叉工具链（引擎），所以上面两处**先按内核二进制改了**：
[`tools/kernel-patch.py`](../tools/kernel-patch.py) 带站点字节校验和 undo。

| preset | VA | 改动 | 等价源补丁 |
|---|---|---|---|
| `touch-skip-rail-vote` | `0x74E9AAC` | `cbz w0` → `b`（跳到探测路径） | `0085` |
| `touch-release-on-empty-frame` | `0x74EA06C` | `b epilogue` → `b 0x74EA1A4`（`touch_report(0,x,y)`） | `0086` |

第二处能成立是因为跳转点上 `w0` 仍是 `touch_read` 成功返回的 0（即 `mask = 0`），
而 `x1/x2` 在目标处会被装成 `&x[]`/`&y[]`，正好构成一次"释放全部触点"的调用。

实测（`payload-vm-touch.bin`）：`selected GT9896 Yellowstone, 1080x2400, poll=10ms`，
`SWEET HID: touch 0 down/up` **成对出现**，一次上划把 Setup 从 Hello 页推进到「选择国家或地区」。

> 不要用 `sweetkeys=1` 绕输入：SPMI 按键驱动在 VM 里读 PMIC 会直接 panic
> （`panic(cpu 0): Kernel data abort`），`sweethidtest` 那条路在 VM 里走不通。

---

## 12. MTTCG：App 侧的开关与已验证的部分

`VmEngine` 原来把 `-accel tcg,thread=single` 写死，于是 `-smp N` 只是让多个 vCPU 在**一个宿主线程**里
轮转——这就是 §8.4 里 `cpus=2` 毫无变化的原因。现在改由命令行里的 `tcgmulti=1` 决定：

```java
boolean mttcg = cmdline.contains("tcgmulti=1");
cmd.add(mttcg ? "tcg,thread=multi,tb-size=512" : "tcg,thread=single,tb-size=512");
```

XNU 不认识这个 boot-arg，会忽略；所以 A/B 只需要换 payload，不用重编 APK。
profile 见 `tools/bootargs.py vm-mttcg`（`cpus=2 tcgmulti=1`）。

已验证（K70 Pro）：

- QEMU 真的跑在 MTTCG 上：`/proc/<pid>/cmdline` 有 `tcg,thread=multi`，进程 5 个线程。
- **没有死锁**：`NOTES.md` 里"MTTCG 撞 pset0 ticket lock"在多轮启动中**没有复现**，
  guest 一路走到 `SWEET FB: 1000 swaps`（已进入呈现循环）并继续 exec 服务。
- 同一壁钟时刻的日志进度：1 核单线程 5 分钟 ~34 KB，2 核 MTTCG 5 分钟 ~48 KB。
  **这只是粗测**，不是严谨 A/B（两次运行的镜像状态不同），要下结论需要同一镜像各跑一轮。

### 12.1 卡顿的账（§10 的结论没有变）

即使 MTTCG 能提速，瓶颈仍是"TCG 模拟软光栅 1125×2436"。要明显变快，分辨率那条（§10.1 第一行）
才是主菜。这次没有动分辨率。

---

## 13. 产物（2026-10-23 冻结）

| 产物 | 位置 | sha256 |
|---|---|---|
| SweetVM APK（fps≤30 / 帧未变不拷贝 / `tcgmulti` 开关） | `.tools/frozen/sweetvm-0.2.0-mttcg-debug.apk` | `94a4d709c968c2038ad365815bbb8bc2abfaed7a4528dcd0da48597d29cf059f` |
| payload：2 核 + MTTCG + 触摸双补丁 | `.tools/frozen/payload-vm-mttcg.bin` | `2101873d820a0493d12062afc7b974f488fbe82fb8e8b3f3cce96dc16736bfed` |
| payload：1 核 + 触摸双补丁（保守） | `.tools/frozen/payload-vm-touch.bin` | `f8946745caef11e40fa53909ceb832a767ae0a49a86cfcd31a6a84722c0f5d4f` |
| 根镜像（已打 §1 的两处共享缓存补丁） | `.tools/ios16-root.img`（undo: `*.undo.json`） | 原地 8 字节，未记录哈希 |

`.tools/` 不进版本库；重建方式见 `android/README.md` 与 `tools/kernel-patch.py` 的 docstring。
