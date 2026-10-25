# vmios working notes

### >>> ACTIVE: CA 宿主光栅化（性能整改）(2026-10-25) <<<

**17:47 崩溃根因找到并修复：插件上传 memcpy 越界（不是热限频/光栅）。**
- 证据链：崩溃前最后一条 `replaceRegion tex=32x40 fmt=30 region=0,0
  32x40 bpr=576 bytes=0x107886674`；`bpr*height=23040` 字节，但源指针在
  一个 32 KiB 只读 LAYERKIT 映射（0x107884000–0x10788C000）尾部，只剩
  ~1.4 KiB。`storeUpload` 盲拷正好跨过映射末尾 → far 落在其后的空洞
  （多次崩溃 far 都是该映射结束页）。这是 **guest 侧插件逻辑问题**。
- 修复：`SweetMetal.m` 新增 `sweet_readable_extent()`，用 `mincore`
  逐 4 KiB 页探测可读范围，只拷贝可读前缀（calloc 补零），越界时打印
  `upload short ...`。不引入会崩的 mach_vm_* 调用。
- 结果：payload `payload-4cpu-perf6.bin`（md5 c7f16557…）启动后到
  t≈360 **backboardd 0 次崩溃**（此前每次 Setup 首帧 t≈137–226 必崩），
  CA 持续出帧（host `frame 256 draws=10 px=5.9M`），copies 涨到 262。
- 注意：帧间隔 `frame ms` 是 **两次 flush 的间隔**，不是光栅耗时；实测
  flush 本身 2.4–119 ms（`host flush ... ms=`），所以宿主不是串行瓶颈。
  单 draw 6–125 ms（分带多线程光栅已启用）。
- 画面仍常见全黑，需区分是 display 休眠/Setup 黑色相位，还是 staging
  拷贝/呈现问题；下一步用一帧内容校验（stage 首像素 vs 面板）。

**17:05 性能量化：手机热限频是当前硬上限；宿主侧已优化 ~2x。**
- **热限频硬证据**：thermal `step_wise` 把 `scaling_max_freq` 压到
  cpu4=1.708GHz（硬件 3.148）、cpu5/6=1.401（2.956）、
  cpu7=1.363（3.302）；cpu2/3=1.708。soc 温度 ~59–66°C，边充边跑。
  TCG 只能拿到约 40–54% 主频，这是“响应慢”的最大原因。
- **已改（APK/插件）**：
  1) 插件默认静默日志（`sweetmetal_verbose=1` 才打开逐调用 trace）；
  2) 宿主纹理解码缓存跨帧复用（仅上传纹理，按 uploadGen 失效）：
     decodes 从 ~26/帧 降到 ~2.8/帧；
  3) native 光栅器加不透明纯色快路径；
  4) 修 `covered` 未初始化就 `goto done` 的 UB（这是 px 出现
     负数/3.2e12 的根因）；JNI 返回值改 jlong；
  5) QEMU 用 `taskset f0` 固定到 cpu4–7（含 X4 大核）；
     宿主光栅线程 `taskset -p 0f` 固定 cpu0–3（实测落在 cpu3）。
- **实测**：单 draw 5–76ms（改前 50–198ms）；帧耗时随内容
  224–633ms 到 1.3–3.0s（Setup 页面每帧 6–14 draw，5.8–16.9M px，
  且被限频）。copies 仍受 display 休眠/Setup 动画影响。
- **结论**：继续堆软件优化前，需要散热（停止边充边跑、暂停 VM 降温），
  否则同一个 SoC 只有一半频率。软件下一步：光栅按行分带做 2–4 线程，
  用上目前空闲的 cpu0–1；再减少 Setup 全屏层的重复绘制。

**16:40 Setup 真机推进：Hello→语言→地区；触摸必须“慢按”。**
- **真实 UI 状态**：不是锁屏，是 Setup Assistant Hello 页；底边上滑
  （从 guest y≈2340 起）才能进入语言列表。之后已选语言（变西班牙语）
  并进入“选择国家/地区”（España 行已按下，出现 Cambiando idioma…），
  语言切换触发 SpringBoard 重启（t=1036），屏幕随后又黑。
- **触摸根因**：`adb input tap` 的 down/up 太快，sweet-touch 每 10ms
  （guest 时间）轮询 touch.bin，常只看到 up（状态未变）→ 事件被丢弃。
  日志证据：t=805.864 之后所有 tap 都没有 `SWEET HID: touch`，只有
  长滑动/慢按能到 guest。**操作规则：所有点击用
  `input swipe x y x y 600`（同点位 600ms）**，滑动用 2–3s。
- **渲染残影**：语言列表→地区页后，旧语言文字叠在新区块上（Deutsch/
  Русский/Português/Italiano/한국어），白底正常；属脏区/清屏或旧图层
  未移除，待查。
- **宿主内存是当前性能瓶颈**：重启后长时间运行，手机 MemFree ~172MB、
  swap 已用 ~6GB，QEMU 3GB prealloc + guest-ram.bin 页缓存；表现为
  copies/出帧从 10–14fps 掉到 0–1fps、Android SystemUI 时钟冻结。
  VmEngine 目前按 **totalMem≥6GB** 决定 prealloc，应改为按
  **availMem** 判断，并考虑重启 VM 释放压力。
- backboardd 崩溃：probe3（仅数字日志 + 普通 memcpy）运行 16 分钟
  未再崩溃（语言/地区切换也存活）；此前 probe1/2 的 `far=0xa` 崩溃是
  插桩引入（`mach_vm_region`/`%s` label 日志），已移除。原始 LAYERKIT
  页边界崩溃与 contig 失败/时序相关，尚未复现，继续观察。

**16:12 backboardd 崩溃环是“进不了桌面”的直接原因；已加 upload 探针。**
- 真实状态（guest 日志 + 截图交叉验证）：设备停在 **Setup Assistant 的
  Hello 页**（底部提示语言在匈牙利语/瑞典语/罗马尼亚语间循环，说明是
  Setup 的 hello 动画，不是锁屏）。拖拽能被 guest 收到
  （`SWEET HID: touch down/up`），但 UI 不前进。
- 原因：**每次 Setup 启动 ~30 s 后 backboardd 必崩**（t=183、t=412），
  crash dump `sig 11 ... far` 落在只读 tag 51（VM_MEMORY_LAYERKIT）
  映射末尾的下一页空洞；两次 pc/lr/bt 完全相同。崩溃后
  `exec backboardd` → `exec SpringBoard` → `exec Setup` 重启，
  显示 off/on，回到 Hello 页（fps=0、copies 停住的窗口就是 display off）。
- 崩溃前最后一条插件日志固定为 `newTextureWithDescriptor` →
  `setLabel:`，15 ms 后 SIGSEGV。pc 在 dyld 共享缓存（很可能是
  libsystem memcpy）。推测：CA 随后用 `replaceRegion:...withBytes:`
  上传，`storeUpload` 的 `memcpy(bpr*height)` 读取调用方缓冲区越界。
- 已插桩（`sweet-4cpu-probe.adt` / `payload-4cpu-probe.bin`，md5
  d7b6aa3b…）：replaceRegion 入口记录 tex/region/bpr/bpi/bytes；
  `sweet_readable_extent()` 用 `mach_vm_region` 探测源缓冲区连续可读
  范围并截断拷贝，越界时打印 `upload short ... need/readable`；
  `setLabel:` 转发时打印 label 字符串（限 64 条）。
- 另发现宿主 `frame ... px=-5203509138`（负的覆盖像素数），说明有
  几何/裁剪异常的大 draw；宿主侧 dst 尺寸上限仍是 65535×65535，
  后续需在 `CaCompositor.onDraw` 增加 alloc/面积硬校验。

**15:51 900×1948 低分辨率试验失败：guest 黑屏不出帧。**
- 同一 4 vCPU SMC recipe，ADT canvas/fb 900×1948 + `sweetfb_w/h=900`
  （display-scale 仍为 3）：guest 启动、4 条 TCG 线程忙，但 copies 停在
  27、屏幕全黑。逻辑尺寸从 1125/3=375×812 变成 900/3=300×649，
  iOS 显示初始化/UI 不匹配；降分辨率必须同时保持逻辑尺寸
  （调整 display-scale，或只降 canvas 不降 logical size）。
- 已恢复 1125×2436 的 4 vCPU 最佳配置（`payload-4cpu-stopped-smc.bin`，
  md5 c7a3496f…），交互 10–12 fps。
- 低分辨率产物保留：`sweet-4cpu-900.adt`、`payload-4cpu-900.bin`
  （md5 8121319f…），后续按正确的 display-scale 再做。

**15:41 6 vCPU 对照：6 条 TCG 线程都跑，但没有收益；4 vCPU 仍最佳。**
- 同一 recipe（ADT 6 节点、仅 cpu0 running、QMP SMC、`-smp 6`、MTTCG）：
  QMP 设 6 个 CPU 成功、6 条 TCG 线程 50–68%，但 guest 面板 copies 仅
  35、启动/出帧明显落后于 4 vCPU（4 vCPU 同时段 copies 160、交互
  10–12 fps）。多出的 2 核被小核/热/锁争用吃掉。
- 最佳配置维持 **4 vCPU + 无 offload**：`payload-4cpu-stopped-smc.bin`
  （md5 c7a3496f…），交互 10–12 fps，2–2.5× 于 1 vCPU。
- 6 vCPU 产物 `payload-6cpu-smc.bin`（d7b0ce22…）保留备查。

**15:36 多核打通：4 vCPU 4/4 initialized，交互 10–12 fps。**
- **ADT state 是 boot_cpu 的关键**：只把 cpu0 标 `running`、其余 `stopped`，
  XNU topology 才能找到 boot CPU；SWEET CPU 驱动随后通过 PSCI 启动
  stopped 的从核：日志 `requested=4 selected=4`、`cpu=1/2/3 CPU_ON
  rc=0 ... came alive`、`4/4 CPUs initialized`。之前“全部 running”的
  修改是错的（`topology_info.boot_cpu == NULL` panic），已回退。
- **QEMU/PSCI**：`-S` 启动 + QMP `query-cpus-fast` 对每个 CPU
  `qom-set psci-conduit=1`（SMC）+ `cont`；guest 留在 EL1（不开
  virtualization，避开 EL2 下 CPU0 早期异常）。主控 SMC 由 QEMU
  ersatz-EL3 处理。
- **实测性能**：4 条 TCG 线程 60–74%；Setup/锁屏交互 **10–12 fps**
  （1 vCPU 为 3–5 fps），copies 211→399，copy ~1.1 ms，约 2–2.5×。
- **present offload 在 4 vCPU 下反而更慢**（1–3 fps，doorbell/拷贝串行），
  最佳配置是 **4 vCPU + 无 offload**；1 vCPU offload 已被超过。
- 产物：`sweet-4cpu-stopped.adt`、`payload-4cpu-stopped-smc.bin`
  （md5 c7a3496f…）、带 QMP SMC 的 APK。设备当前跑这个最佳配置。
- 渲染：Setup 加载页的渐变是平滑全屏的（之前三条竖缝是另一个动画
  相位）；锁屏状态栏偏暗红/壁纸仍不完整，继续查。
- 下一步：按同一 recipe 试 6 vCPU（ADT 6 节点、仅 cpu0 running、
  `-smp 6`、QMP SMC），看是否继续提升/热限制；再优化渲染。

**15:17 QMP 硬证据：EL2 路径下 CPU0 先进异常，从核停在 reset。**
- app 新增 QMP 诊断（`Snapshot.probeCpus`，启动 40 s 后 `info registers -a`）：
  4 vCPU SMC+EL2+RW=1 启动时
  `CPU#0 PC=check_exception_stack PSTATE=EL1h`（内核异常循环），
  `CPU#1 PC=0 PSTATE=EL2h` 且寄存器全 0（从核停在 EL2 reset，PSCI
  CPU_ON 没有把它启动）。即 CPU0 在跑到 PSCI/CA 之前已异常，多核
  bring-up 的真正阻塞是 **XNU 在 EL2 环境下的早期 fault**，不是调度。
- 修复方向：要么给内核补 EL2 适配（CI 内核），要么在 QEMU 侧避免把
  guest 置于 EL2（PSCI conduit/loader 的机器补丁）；1 vCPU 无 EL2 路径
  正常。设备已恢复 `0097m-offload`（1 vCPU + quiet + offload）。
- 渲染：渐变块 3 条竖缝仍待查（先与旧 m5b 本地光栅同帧对比）。
- 当前可用性能：1 vCPU offload 3–5 fps，画面可见状态栏/电量/home indicator。

**15:12 多核：HCR_EL2.RW 修复让 4 vCPU 从“早期异常”推进到 userland。**
- 关键修复：EL2→EL1 的 stub 原来把 `HCR_EL2` 清零，**RW 位=0 使 EL1
  变成 AArch32**，`eret` 报 Illegal Execution State。改为
  `HCR_EL2=0x80000000`（RW=1）后，SMC 内核 + `virtualization=on`
  （QEMU conduit=SMC）+ 4 vCPU 能跑到 userland（ring 到
  `fairplayd.H2`，约 t=440），不再是早期 fault。
- 但还没到 CA/GUI：app 的 `copies=2`、`fps=0`，仍只有 1 条 TCG 线程忙；
  ring 的 `SWEET CPU` 行无时间戳（1/1），无法确认本次是否 4 核；
  `hw.ncpu` 插件日志尚未出现（backboardd 未到 CA 初始化）。
- 下一步：在更早的 userland 进程/内核里拿本次 `N/N CPUs`，并看
  `fairplayd`/utun 之后的停顿是 daemon 等待还是从核未启动。
- 设备已恢复 **1 vCPU + quiet + offload**（`0097m-offload`）。
- 渲染：渐变块 3 条竖缝仍待查。

**15:01 多核 `-kernel` 方案在宿主复现为早期 Data Abort，暂不可用。**
- 宿主 QEMU（4 vCPU、HVC payload、`--kernel-stub`、`-d int`）：
  CPU0 在 EL1 反复 Data Abort（FAR 0x220/0x158，ESR 0x96000006），
  说明 68 字节 raw stub 经 `-kernel` 装载后没有走到内核入口（异常向量
  在 0，取指落到 0x200）。也就是说 `arm_load_kernel` 的 PSCI 配置虽然
  走了，但 raw stub 的装载/入口不对；手机 4 vCPU 也停在早期，与此一致。
- 结论：多核下一步应改 **QEMU 机器侧**（在 loader 启动路径里显式设置
  CPU `psci-conduit=HVC` 和第二从核 powered-off/reset 状态），或给
  Android 引擎打同款补丁；不再用 `-kernel` raw stub 这条路。
- 当前设备：`payload-0097m-offload`（1 vCPU、quiet、present offload）
  运行中；offload 已验证（completion 增长、copies 2→464、fps 3–5）。
- 渲染：渐变块 3 条竖缝待查（host 纹理上传/采样或行跨页边界）。

**15:00 当前可用：1 vCPU + quiet + present offload；多核仍停在早期。**
- offload 已验证：`offload completed` 持续增长、copies 2→464、fps 3–5，
  画面有正确状态栏和中间渐变块（渐变块带 3 条竖缝，待查）。
- 多核：`-kernel stub.bin` 已接进 app（cpus>=2），QEMU 命令行确认
  `-kernel .../stub.bin`、无 virtualization；但 4 vCPU HVC 启动 60 s 时
  仍只有 1 条 TCG 线程忙、`hw.ncpu`（插件新增的用户态日志）未出现，
  guest 停在早期。下一步用宿主 QEMU `--kernel-stub --qemu-debug` 抓第一个
  异常/PC，确认 PSCI conduit 与从核 reset 状态；仍可能需要 QEMU 机器补丁
  或 Android 引擎重建。
- 设备现在运行 `payload-0097m-offload`（1 vCPU offload），这是已验证配置。

**14:58 多核：loader boot 跳过 arm_load_kernel 是根因；`-kernel` 已接上但 CPU 数仍待证。**
- QEMU 用 `-device loader` 启动时不会调用 `arm_load_kernel`，CPU 的
  `psci-conduit` 保持 DISABLED，所以 HVC/SMC 都不被接管。把 68 字节 stub
  作为 `-kernel` 传给 QEMU 可以走 `arm_load_kernel`（app 的 `VmEngine`
  在 `cpus>=2` 时已改成 `-kernel stub.bin`，并去掉 stub loader 和
  `virtualization=on`）。真机 4 vCPU + HVC payload 能启动，但 65 s 时
  `copies=2`、仍只有 1 条 TCG 线程忙；ring 里的 `SWEET CPU` 行没有时间戳，
  无法确认是本次启动。下一步要在**本次启动**里拿到 `N/N CPUs initialized`
  的带时间戳证据，再判断从核是否起来。
- 直接用 `-global ...psci-conduit=2` 会触发早期 Data Abort（stub 入口
  未走通），不可用；`virtualization=on` 的 EL2 路径 stub `eret` 报
  Illegal Execution State（SPSR/ELR 已反汇编确认正确），也暂不可用。
- 当前设备已恢复到 **1 vCPU + quiet + present offload**（payload
  `0097m-offload`，md5 22af99fd…），offload completion 正常增长。
- 渲染缺陷：offload 画面出现中间灰白渐变块 + 3 条竖直缝
  （`.tools/shot-offload2.png`），下一步与本地光栅同帧对比定位。

**14:47 present offload 真机验证成功；渲染异常定位到渐变块。**
- `payload-0097m-offload.bin`（quiet 插件 + `sweetfb_offload=1`）+ 新 APK：
  `-device sweet-fb` 生效，app 日志 `offload completed=1,2,3… status=0`
  持续增长，`copies` 从 2 涨到 464，fps 3–5。guest 不再执行每帧
  10.9 MB 的 present memcpy（由 QEMU sweet-fb 在宿主做）。
- 画面：状态栏时间/电量/home indicator 正确；中间出现一块 **灰白渐变矩形，
  带 3 条竖直缝**（见 `.tools/shot-offload2.png`）。这是下一个渲染缺陷，
  怀疑 host 内部纹理上传分块/采样或行跨页时的边界。
- **多核仍阻塞在 EL2 入口**：`virtualization=on` 时 QEMU 从 EL2 进入；新
  EL-drop stub（`Payload.java` 68 字节）能把异常从 EL1 的 0x200 改变为
  `eret` 的 Illegal Execution State（ELR 0x40200024），从核仍未启动。
  SMC + virtualization=on 的 4 vCPU 也停在早期。下一步查 stub 的
  SPSR/ELR 编码，或试 `-cpu max`/其它 EL 配置；host QEMU 可复现。
- 1 vCPU 走新 stub 的 EL1 路径正常（本次 offload 启动就是），stub 对
  `virtualization=off` 安全。

**14:15 多核 PSCI 与 present offload 的下一轮测试已备好（设备掉线，未跑）。**
- **PSCI 根因（宿主 QEMU 复现）**：4 vCPU + `--qemu-psci` 在 CPU0 反复
  `Undefined Instruction`（ELR `check_exception_stack`、向量 +0x200）。`hvc #0`
  在 EL1 且未实现 EL2 时是未定义指令；QEMU virt 需要 `virtualization=on`
  才会把 HVC 接到 PSCI。`VmEngine` 现在对 `cpus>=2` 使用
  `virt,gic-version=3,virtualization=on`。mkadt 已把全部 CPU 标 running。
  待测 payload：`payload-4cpu-psci-quiet.bin`（md5 60d8f3ac…，4 CPU 节点、
  PSCI HVC、quiet 插件）。
- **present offload**：内核已确认初始化（`SWEET FB: native present command at
  0x9d000000`），协议（命令区 0x9d000000、doorbell 0x0f000000、completed@12）
  与 QEMU `sweet_fb.c` 完全一致；但 app `present=native` 时 `copies` 冻结。
  APK 已加诊断：completion 序号变化时打印 `offload completed=... status=...`。
  待测 payload：`payload-0097m-offload.bin`（md5 22af99fd…，quiet 插件）。
- **插件日志**：`sweet_log`（每个 Metal selector 的 console 写）默认关闭，
  `payload-0097l.bin`（md5 22c748b1…）是 quiet 1 vCPU 基线，用来量 fps 收益。
- **设备状态**：14:14 起再次从 adb 掉线。设备上最后一次成功部署的是 m5b 对照
  payload（a3150f27），APK 仍是旧构建；回连后先装新 APK，再按测试目标换 payload。
- 已知问题：quiet 运行里 backboardd 在 t=263 崩过一次（heap far，在 stage
  创建之前）；镜像健康度需用 m5b 对照重新确认。

**13:53 多核的真正卡点：guest SMP bring-up，不是调度。**
- 之前 2/4 vCPU “只有一条 TCG 线程忙” 的直接原因已找到：`mkadt.py` 把
  cpu1..N 的 DT `state` 写成 `stopped`，XNU 的 topology 只算 1 个 CPU
  （旧 ring 的 `requested=1 selected=1`）。**已修**：所有 CPU 都写 `running`。
- 修后 4 vCPU（普通 payload 和 `mkpayload --qemu-psci` 两版）都会在早期
  SMP 启动卡住：ring 的 `total` 停在 593538 不再前进，只有 1 条 TCG 线程
  100%，其余 3 条 0%。说明 **app 里的 QEMU 从核没有起来，kernel 在等 CPU**，
  不是“4 核都在但调度不用”。
- 下一步要修的是 QEMU/ADT 的 CPU 匹配：MPIDR Aff0 vs Aff1、PSCI HVC/SMC、
  以及 host QEMU 已有的 qemu-psci 补丁要进 Android 引擎；修好后再测
  2/4 vCPU 的真实收益。当前 app 的 QEMU 多核不可用。
- 当前最佳可用配置仍是 **1 vCPU + native 宿主光栅 + staging + drawable 拷贝**
  （`payload-0097i.bin`，md5 91049ce6…，约 5 fps，可见状态栏/电量/时间）。

**13:41 多核与 present offload 的实测结论。**
- **2 vCPU MTTCG（ADT 2 CPU 节点 + cpus=2，2 s 锁超时）**：能启动到 CA，
  t=451 仍在 SweetMetal 渲染，无 ticket lock panic；但 QEMU 只有一条 TCG 线程
  占 96%，第二条 **0%**——CA/present 仍是串行，2 vCPU 没有收益。2cpu payload
  `payload-0097i-2cpu.bin`（md5 5c2239d8…）保留备查。
- **present offload（`sweetfb_offload=1`，app 日志 `present=native`）**：guest
  的 swap 继续、宿主 native 绘制 5–47 ms、stage copy 6.9 ms，但 app 的
  `copies` 冻结在 22，滑动后也不增长——QEMU sweet-fb 没有回写 completion
  序号，reader 永远等不到新帧。与文档“未真机验证”一致，**offload 目前不可用**，
  已回退到 guest present。offload payload `payload-0097j.bin`（md5 a9a26fcb…）。
- **当前最佳可用配置**：1 vCPU + native 宿主光栅 + staging + drawable 拷贝
  （`payload-0097i.bin`，md5 91049ce6…），可见 iOS 状态栏/时间/电量，
  交互约 **5 fps**，无 panic。宿主绘制 5–47 ms，stage copy 6–9 ms，
  剩余瓶颈是 guest 串行 CA 编码 + 内核每帧 10.9 MB present memcpy。
- 待查渲染异常：背景/壁纸仍大面积黑色，status bar 文字颜色正确；下一步对比
  host raster 与本地光栅的同一帧，定位是 clear/stage 内容还是图层混合。

**13:27 里程碑：宿主光栅链路可见、稳定、快。**
- 修正 IOMobileFramebufferOpen 失败（conn=0）后的呈现路径：插件把 staging
  **memcpy 到 CA drawable**，由 guest 窗口服务器 present；拷贝实测 **6.2–8 ms**
  （11 MB，TCG 下约 1.5 GB/s）。
- 宿主逐像素循环改为 **native C（JNI，`libsweetraster.so`）**：全屏绘制
  **6–42 ms**（debug APK 无法 AOT；Java 版本 1.1 s）。页表校验
  `map validate pages=676 bad=0`，staging 是我方独占内存，宿主不再写 CA surface。
- 真机截图已有正确 iOS 状态栏（时间/电量/home indicator）；交互滑动实测
  **约 5 fps**，无 panic。staging 的 drawable 拷贝与宿主绘制都不是瓶颈，
  剩余限制是 guest 侧 CA 编码 + 内核 present 的串行工作。
- 产物：`payload-0097i.bin`（md5 91049ce6…）；APK 含
  `lib/arm64-v8a/libsweetraster.so`（NDK r27）。

**下一步：2 vCPU MTTCG。** 2cpu payload 正在构建；重点看 CA 编码/present 是否
并行化、ticket lock 是否稳定（2 s 超时已在 cmdline）。

**12:05 状态：宿主光栅跑通，但写 CA surface 会打崩 guest；已改为 staging。**
- AOT（`adb shell cmd package compile -m speed -f dev.hackios.sweetvm`）把全屏
  host draw 从 1.2 s 降到 **11–21 ms**；这也说明之前 1.2 s 主要是 debug APK
  的解释执行，不是算法本身。
- 宿主收到的页表已核对：surface 6 首页 `0xf1e94000`、surface 5 首页
  `0xc4590000` 与内核 `SWEET SURF: ... create id` 日志完全一致，页表内容没错。
- 但真实写入后 guest 立刻 panic：`cache_lookup_path` 数据异常，`far`
  是像素值；同时 calaccessd 等用户进程崩溃。同负载 DRY_RUN（只算不写）
  6 分钟无此 panic，因此是宿主写 surface 触发的内存破坏，而非光栅数学。
  可能原因：surface 生命周期/所有权或页表在写入期间的归属；尚未定位到
  具体页。
- 规避方案（已实现，**未真机验证**）：插件自建一块 1125x2436 的
  staging IOSurface（`IOSurfaceCreate`，长期 Lock 持有），全尺寸绘制的
  HOST 与本地光栅都写它，`endEncoding` 后直接 present 它；宿主不再写任何
  CA drawable。文件 `vm/metal/SweetMetal.m` 的 `sweet_stage_ensure`。
  bundle `vm/metal/build/SweetMetalAccel.sgb`（141291 B），payload：
  `shim/out/payload-0097e.bin`（md5 53838009…）、
  `shim/out/payload-0097e-2cpu.bin`（md5 6a40f330…）。APK 无需改动。
- 设备 12:04 从 adb 掉线（未回连），真机验证暂停。回连后顺序：
  1) 推 0097e，AOT 后启动，确认不再 panic、`SWEETMETAL: stage id=...` 出现、
     画面与 fps；2) 若稳定，再测 2 vCPU（0097e-2cpu，ADT 已带 2 个 CPU 节点）。
- 另：设备 prefs `mttcg=true` 但 cmdline 是 `cpus=1`，多核从未真正启用；
  2cpu payload 已备好。AOT 编译每次安装 APK 后都要重做。

**11:35 更新：找到并修复宿主链路的三处实际缺陷。**
1. 设备上安装的 APK 是 10-24 20:33 的旧包（改名前 `dev.hackios.sweetvm`），不含
   `CaCompositor`；本地重建的 payload 又只带了 `debug=...cpus=1` 的基础 cmdline，
   缺 `gpu_wire=1 sweetmetal=1`。现在 APK 用
   `gradle -PvmiosAppId=dev.hackios.sweetvm assembleDebug` 覆盖安装（签名一致，
   16 GiB 数据保留），payload 用设备 m5a payload 的完整 300 字节 cmdline 重打。
2. 设备 prefs 里 `mttcg=true`，但 payload 是 `cpus=1`，所以此前从未真正跑过多核。
3. 宿主 `sweetgpu-host` 在 `onTexture` 处 OOM（一次 1.16 GB 分配）：根因是插件
   `sweet_ca_batch()` 填好 `struct sweet_ca_header` 却**没有 memcpy 到发送缓冲区**，
   顶点直接写在 `message+88`，宿主读到未初始化栈数据。3888 B 纹理块头部正确、
   280 B 绘制批次头部全错，正好对应这一处。已补 `memcpy(message, &header, ...)`
   （bundle md5 `9cd790df…`，payload `879908e5…`）。
   同时宿主对 `total/width/height/bpr/pixels` 加硬上限，避免再次被异常消息打崩。

**11:30 观测（修复前）：** 76 次“全屏 dest=5/6 + 143x307 fmt550 内部纹理”占
本地光栅 85 s（约 1.13 s/次），其余绘制合计 <0.2 s；宿主已收到 map/flush 但
每帧都回退本地。已新增：内部堆纹理 ≤1 MiB 时按 RGBA8 上传给宿主（
`SWEET_CA_F_UPLOAD_TEX`+`F_INTERNAL`，每次使用都传，无版本计数），目标是让
全屏合成在宿主完成。

**结论（已测）：卡顿的根因是 TCG 里的逐像素光栅化，不是显示/上传。**
m5a 那一轮（09:xx UTC）实测：416 次 draw 的光栅化共 208.7 s（观察窗口约
900 s）；其中 216 次纯色 96.9 s、103 次 fmt550 143x307 纹理 94.9 s、15 次
fmt115 256x1 25 s；全屏绘制单次 3.3–6.8 s（约 2.2 µs/像素）。present 拷贝
只占约 1.3 ms，说明瓶颈完全在 guest 侧的光栅循环。

**已落地（单元验证完成，真机未验证）：宿主接管 CA 光栅化**
- 内核 `xnu/patches/0097-sweet-gpu-ca-draw.patch`（commit `f201a24`，CI run
  `40153613944` success，产物 `.tools/dl/xnu-0097/kernel.development.sweet`）：
  0x101 改为**异步入队**（不再每条等待 ack）；新增 0x103 flush（sendWait 等
  host ack）、0x104 surface page map（把 16 KiB 页表按 ≤480 页/条经 wire op 5
  发给宿主，解决 IOSurface 物理页离散、宿主无法按 PA 寻址的问题）；0x102
  仍返回线性/段数信息。wire op：3=fill、4=CA draw、5=texmap、6=flush。
- 插件 `vm/metal/SweetMetal.m`：把每个 draw batch 解码成规范 8-float 顶点
  （x,y,u,v,r,g,b,a，88 字节头 + 96 字节/三角，40 三角/条）经 0x101 入队；
  纹理按 (surface id) 走页表、上传纹理按版本号分块（3800 B/条）发送；每个
  encoder `endEncoding`/commit 前调用 0x103 flush；宿主不可寻址（堆上离屏
  纹理、未映射 surface、传输失败）自动回退本地光栅。编译通过
  （`tools/build-sweetmetal.sh`，bundle 140955 B，md5 495a3278…）。
- 宿主 `android/.../CaCompositor.java`（新增）+ `GpuWireServer.java`（op 4/5/6
  分发、flush 回 8 字节 ack）：把 guest RAM 文件按 512 MiB 窗口 mmap，按页表
  直接读写真实像素（无影子拷贝）；行内片段数学与插件完全一致（source-over、
  blend 46 亮度混合、双线性采样、top-left 填充规则）；按帧缓存解码后的
  纹理。APK 编译通过（`gradle assembleDebug`）。

**产物：** `shim/out/sweet-0097.adt`（148684 B）、
`shim/out/payload-0097.bin`（16799664 B，md5 d62d4993…）、
APK `android/app/build/outputs/apk/debug/app-debug.apk`。

**下一步（真机验证顺序，尚未执行）：**
1. `adb install -r` 新 APK（保留 app 数据）；备份现有 `files/payload.bin`。
2. push payload-0097.bin，run-as cp 覆盖；md5 校验。
3. 启动 VM，`tools/phone-log-monitor.py` 实时看日志；预期内核出现
   `SWEET GPU: map surface …`、`flush seq … result 0x0`、`draw seq …`，
   插件日志 `SWEETMETAL: host map …` 且 `raster … ms=` 行显著减少。
4. 对比帧时间/fps；若仍慢再考虑 GLES 后端（协议不变，只换宿主执行器）。
5. 待查渲染缺陷：插件把 src_mapped 的 IOSurface 一律按 RGBA8 解码
   （`tex_internal=1`），但日志里出现 fmt=550(BGR10_XR)，颜色可能因此偏色；
   宿主目前镜像同一规则，需先确认 IOSurface 实际格式再统一修正。

**未验证/风险：** 宿主路径尚未在任何一次真机启动中跑过；`0x101` 异步入队后
若 flush 超时，插件最多容忍 2 次失败后永久回退本地光栅；混合路径（同帧部分
宿主、部分本地）在重叠区域可能次序不一致（罕见）。

### >>> 上一阶段: 真机回归 + 实时日志 + CA 绘制链路 (2026-10-25) <<<

**真机恢复可用。** Xiaomi 14 Pro (eb72c928) 已连接；安装包
dev.hackios.sweetvm 0.2.0 为 DEBUGGABLE，app 内部持有 16 GiB
ios16-root.img 与 payload.bin，`adb run-as` 可读写，`adb exec-out run-as
... dd` 可拉取镜像尾部 4 MiB 日志环。新增 `tools/phone-log-monitor.py`：
轮询环头 total，只解码并输出新增字节，实时流式，不再固定 sleep 盲等。

**payload 替换流程（md5 已验证一致）：** `mkadt.py --qemu --gpu-wire
--canvas-width 1125 --canvas-height 2436 --gpu-bundle
vm/metal/build/SweetMetalAccel.sgb`；`mkpayload.py
.tools/dl/xnu-0096/kernel.development.sweet ADT OUT --cmdline "<原 payload
的 cmdline>"`（手机不用 --qemu-psci）。安装：adb push 到
/data/local/tmp -> chmod 644 -> run-as cp 到 files/payload.bin；不要用
`adb shell run-as ... sh -c 'cat >'`（只传入 1016 字节）。旧 payload 备份
在 files/payload-before-m4o.bin。

**已修根因（backboardd SIGABRT）：** 读取
MTLRenderPipelineDescriptor.description 会格式化我们伪造的 MTLFunction
并在 backboardd 内 abort（t≈196，sig 6，随后 formattedDescription:）。
现只读 vertexDescriptor 的 attributes/layouts 与 colorAttachments[0] 的
pixelFormat/混合参数，整段 @try 保护。

**插件新增：** fixed_* 管线打印 pso attr/lay/color0；渲染通道目标为
IOSurface 时用 IOSurfaceLookup+Lock 映射，LoadActionClear 直接写该
surface（真实像素，非伪造 UI），endEncoding 解锁释放。真机当前 payload
m4q (md5 0cef9e36…) 用于验证映射/清屏，日志走 phone-log-monitor。

**下一步：** 等真机 CA 首次 dest=5 绘制（约 t≈200），用 pso attr/lay 与
256 字节 vb 转储定死顶点布局（m4l 数据推测 stride 48：position float4@0,
texcoord0 float2@16, texcoord1 float2@24, color half4@32），据此实现
solid/textured 三角形光栅化；Ghidra 正在分析 QuartzCore
(ghidra-scripts/FindCAVertexLayout.java)。

**M4q 实测（2026-10-25, 真机）确认：** pso 顶点描述符为 buffer 1、
stride 48：attr0 Float4@0（位置，像素坐标）、attr1 Float2@16（uv0，
归一化）、attr2 Float2@24（uv1）、attr3 Half4@32（顶点色）。另有 stride 16
的简化管线（Float2 位置 + Half4 颜色）。IOSurface 映射成功：
`mapped dest=5 1125x2436 bpr=4544 base=…`，LoadActionClear 写 0 后整块面板
变黑（真机截图），证明“插件写 IOSurface → 内核 present → 面板”链路成立。
CA 依次绘制：全屏黑色底、顶部渐变带、全屏渐变、0.07 黑色压暗层、
framebuffer 采样，然后才是文字/图标；纹理都绑在 fragment texture 3，
上传格式 A8(fmt1)/BGRA8(fmt80)/RGBA16F(fmt115)/R32Float(fmt55)。

**M4r/M4s（CPU 光栅化，已实现）：** 按 pso 元数据逐三角形填充，双线性
采样上述纹理，src-over 预乘混合写入 IOSurface；同时修复了 half→float
比例错误（原实现大 1024 倍）。真机验证截图见 `.tools/gputest/shots/`。

**M4t/M4u/M4v/M4w 实测（2026-10-25，真机，观察）：**
- 面板字节序已实证为 **RGBA**：向 guest 面板内存 y=1200 写入
  `FF 00 00 FF`，真机出现纯红条；因此光栅器写 RGBA8 是对的，
  壁纸发暗红不是“面板 R/B 交换”。
- 根因（已由日志链定死）：本插件写入的所有 IOSurface/离屏纹理都是
  **RGBA8**，但采样时按“声明的像素格式”解码。显示面 `surface 6`
  声明 fmt 554（BGR10_XR→默认按 BGRA8 解），离屏 143x307/64x102 声明
  fmt 550（按 packed B10G10R10 解）。CA 的壁纸降采样链
  `downsample_8_frag_lph`/`downsample_blur_vert_lph`/`downsample_4_frag_lph`
  因此读到 R/B 交换且乱码的像素，再全屏合成，形成白/粉巨柱与逐帧变亮。
- 修复：`SweetTexture` 增加 `rendered` 标记（`setTargetTexture:` 置位），
  `SweetRaster.tex_internal` 对“本进程写的 IOSurface（sid≠0）或已渲染
  离屏纹理”置 1，采样一律按 RGBA8 解；`bytesPerPixel` 改用
  `sweet_texel_bpp`；补 554/555=4bpp；`drawPrimitives` 三角带奇偶换向。
- 新增函数常量捕获：swizzle 的真实 setter 会把值存入全局表
  （`sweet_fc_store`），`SweetFunction` 在 `newFunctionWithDescriptor`
  时快照，`SweetPipeline -copyConstantsFromFunction:` 取片元函数常量，
  绘制时读 `fc_blend_function` 并实现 blend 46（亮度^4 vibrant）。
  pso 创建日志新增 `pso fc blend/tex/dst/img`，raster 日志新增 `blend=`。

**下一步：** m4x（仅往返格式修复）真机回归截图，确认壁纸色调恢复；
再上 m4y（格式修复 + 常量捕获 + blend 46）对照。之后处理剩余缺陷：
状态栏时间重复、时间后深色矩形、四角绿色残块、左侧竖条、电量颜色。

### >>> ACTIVE (superseded, 2026-10-24): PROJECT RENAMED TO vmios; DEBUG ON THE PC <<<

The project is now **vmios** (see `README.md`, `CREDITS.md`, `docs/NAMING.md`).
The Android app is `dev.vmios.sweetvm`; user-facing and host-side names use
`vmios`, while the guest ABI keeps the frozen `sweet` prefix by design.

**Environment change:** the user has taken the phone, so device logging is no
longer available. The PC path is the way forward: WSL + QEMU (`tools/
qemu-sweet.py`, sweet-ufs/sweet-fb devices, the 16 GiB `.tools/ios16-root.img`)
can boot the same payload, and QEMU's gdbstub allows stepping the guest
kernel and userland. Ghidra 12.1.4 + Temurin 21 are installed for static RE
(`.tools/run-ghidra-quick.cmd`, `.tools/run-ghidra-process.cmd`).

**Cleanup done (measured):** 21 stale `~/qrun-*` QEMU runs were deleted
(WSL home 53 -> 15 GiB), the WSL vhdx was converted to sparse (D: free
13 -> 45 GB), and on E: ~5 GiB of extracted archives, old CI artifacts, old
kernel trees, APK build output and ring dumps were removed. The legacy
hackiosx website was dropped with the rename.

**Where the GPU work stands:** the virtual Metal device is the guest's system
default device, CoreAnimation's Metal context initializes, trace traps cover
CA's queues/buffers/encoders, and guest userspace -> kernel -> virtio wire ->
host GPU -> guest panel was proven on the phone (magenta fill). The open
blocker is CoreAnimation's WindowServer: SpringBoard has a real window tree
(wallpaper + root scene), but WindowServer submits swaps with layer id 0 and
never runs its Metal render pass (details below under "Next blocker").

**PC debugging environment (verified present):** WSL has the patched
QEMU 8.2.0 with the SWEET devices at
`/opt/qemu/build/qemu-system-aarch64` (`-device sweet-ufs`,
`sweet-fb`, `sweet-touch`; source tree `/opt/qemu`). The staged Android
engines come from `/opt/qemu/build-android3` (arm64) and
`/opt/qemu/build-android-x643` (x86_64); the two older build trees were
deleted. The 16 GiB `.tools/ios16-root.img` and `tools/qemu-sweet.py`
are the local boot inputs. Local checkout directory is still
`E:\桌面\hackios` (the `E:\hackios` junction and `sdk.dir` depend on it);
the repository and app identity are vmios.

**CORRECTION (2026-10-25): the local QEMU runs never got past
`sweet_keys_init`.** `tools/sweet-log.py` decodes the whole 4 MiB ring, but
only the first `total` bytes belong to the current boot; everything after is
stale content from earlier phone boots (SpringBoard stacks, 2000 swaps,
iOS daemons). The m3m payload's boot-args had no `sweetkeys=0`, so
`sweet_keys_init` mapped the phone PMIC at 0xc440000 and its first read,
`ldr w8,[x8]` at `sweet_keys_init+0xac`, was an external data abort
(FAR 0xffffffe34f67ec000). QEMU then sat in the panic debugger trap
(`handle_debugger_trap`, printing over serial); the panel showed that panic,
not iOS. Fixes: `tools/bootargs.py` VM profile now has `sweetkeys=0`
(QEMU has no PM6150L), the image's log area is zeroed before local boots,
and the payload is built with `cpus=1` to match `-smp 1`.
New local payload: `.tools/gputest/payload-local-m3n.bin`
(md5 888d95447cd43dd0e67bf9d0e8553cc5, same m3m.adt with the display probe).
Treat a ring as current-boot-only up to `meta["total"]`.

**LOCAL QEMU BOOT WORKS (2026-10-25, measured).** With `rd=ufsroot0` in the
payload cmdline (the Android app adds it itself, the launcher did not), the
guest boots for real: t=30.4 s `SWEET UFS: "userdata" on LUN 0 ... 16384 MiB`,
`BSD root: ufsroot0`, launchd at t=30.9 s, dyld shared cache mapped, all iOS
daemons spawn, and the log ring flushes (`.tools/gputest/payload-local-m3q.bin`,
md5 9c55b5a523d7564629bad7d06de4c24d, m3m.adt, console deliberately NOT muted
so the panel shows kernel printf). `cpus=1` matches `-smp 1`. This also proved
the earlier "local boot" evidence was stale phone data: read only
`meta["total"]` bytes of the ring.

**Display state now measured in-guest.** backboardd (pid 55) loads SweetMetal
at t=54.8 s and CA's EAGLServer renderer initializes (queues, pipelines,
supportsFamily...). IOMFB sequence: `display on` t=67.595 -> SwapBegin/SwapEnd
(0x46c) t=67.79 -> `display off` t=67.795; `display on` again t=111.53. From
then on backboardd calls SwapEnd ~30x/s with mask 0 (first record after the
second on: mask=0x80000007, layer 0 id 0); the plugin records **zero**
`presentDrawable`, `drawPrimitives`, `setRenderPipelineState` calls - CA's
compositor never encodes a draw, so `finish_update` has no primary surface
(`IOMFBDisplay::finish_update` only calls swap_set_layer for layers 0 when the
update carries one, and always clears layers 1/2 with NULL). QuartzCore slide
in that boot: 0x38fec000 (base 0x1c1270000), from the plugin's probe.

**XNU version audit (2026-10-25, user asked).** Userland is iOS **16.7.16
(20H392, iPhone10,3/10,6)** (`research/ipsw-x/BuildManifest.plist`); the kernel
is **xnu-8796.141.3 / Darwin 22.6.0** (`research/xnu/xnu-xnu-8796.141.3`,
CI base macOS 13.5, blacktop/darwin-xnu-build pinned SHA). Both are the same
Darwin 22.6 / xnu-8796 generation; the same kernel+userland reached
SpringBoard/Setup on the phone and backboardd+all daemons on the PC, with no
kernel/userland ABI panic. The local kernel matches CI `SHA256SUMS`
(d3179592...c9a0f) and contains the newest patches' fingerprints
(`installer armed for %s`, `SWEET GPU: fill surface`, `SWEET FB: rec mask`,
`SWEET UFS: statistics`). Decision: keep 8796.141.3 + patches 0001-0096.

**Current display root cause (2026-10-25, gdb-verified).** The canvas fix
(`--canvas-width 1125 --canvas-height 2436`; the ADT used to say 1080x2400)
made CA allocate a real display drawable and stop swapping empty records:
`SWEET FB: swap ... layer 0 surface 5 1125x2436 fmt 0x62336138 bpr 4544`,
present mask 0x1. The drawable object is valid (gdb: `+0x18 = 0x465/0x984`
= 1125x2436, `+0x20 = 0x62336138`, and render_display receives it non-null).
But `CA::OGL::Renderer::render` is **never called** (breakpoint set at its
entry is never hit; the next stop is the next frame's render_display).
`render_display` gates it on `renderer->vtable+0x358(frame)`, which is
`CA::OGL::MetalContext::make_buffer_current(Surface*)`; that calls
`MetalContext::get_surface(surface, true)` and returns false when it is NULL.
gdb at `get_surface` for the 1125-wide drawable shows the failure at
0x188346e74: `ctx+0xa20` (max renderable size) is **0** while w=1125/h=2436,
so `max < width` rejects it before any texture is created (no
`texture from iosurface id=5/6` log). The MetalContext at 0x103808e00 has the
right vtable (MetalContext+0x10) but its +0xa18/+0xa20/+0xa28 are all zero,
even though `new_metal_context` writes them at 0x18848871c..0x18848876c and
clamps +0xa20 to >=0x2000; this instance therefore did not go through that
initialization block (or bailed inside it). The plugin now reports
maxTextureDimension2D 16384 / 3D 2048 / cube 16384 / array 2048 and real
texture width/height/pixelFormat, but the context field stayed 0.

**Compositor shaders recovered (2026-10-25).** The display draws are the
QuartzCore uber-shaders `fixed_vert_lph_spc` + `fixed_frag_lph_cpf`, loaded
from `/System/Library/Frameworks/QuartzCore.framework/default.metallib`
(1,014,944 bytes, MTLB v1.2). The plugin dumped the file as hex to the guest
console at library load; the host rebuilt it as `research/ca-metallib.bin`
(Apple artifact, keep out of git). Upstream `llvm-dis` 18 rejects the Apple
AIR ("Invalid encoding"), so the interface was read from the bitcode metadata
strings: vertex inputs `position` (float4) plus optional `point_size`,
`texcoord0/1A/1B` gated by function constants (`vtx_attr_has_texcoords`,
`vtx_attr_has_point_size`, `fc_vertex_layout`, `fc_texcoord_count0/1`,
`fc_has_texture_matrix`, `fc_has_chroma_matrix`); vertex buffers include
`mvp_matrix` (float4x4), `texture_matrix`, `chroma_matrix`, `fc_generic`;
fragment config is `CA::OGL::Metal::FragmentShaderConfig` (image descriptors,
`texture_function`, `blend_function`, `destination_function`, attachments
0..2, color params, sampler). Observed display draws at runtime: dest=5,
triangle list with 6 indices, positions/texcoords in buffers bound via
`setVertexBufferOffset:atIndex:`, constant config via
`setFragmentBufferOffset:atIndex:` (now captured), source textures are the
CPU uploads (glyph atlases 552x358 fmt=1 and 763x79 fmt=1, gradient strips
256x1 fmt=115, icon 32x32 fmt=80). Both vertex and fragment SPIs are now
recorded in SweetMetal.

**Function constants (2026-10-25).** The display draws are specializations of
`fixed_vert_lph_spc`/`fixed_frag_lph_cpf`, created through
`newFunctionWithDescriptor` with an `MTLFunctionConstantValuesInternal`
object per pipeline. `-description` only prints the object address, so the
constants (notably `fc_vertex_layout`, `fc_texcoord_count0/1`,
`fc_has_texture_matrix`) are not visible that way. The per-draw fragment
config buffer (`setFragmentBufferOffset:atIndex:`) is all zero for the first
draws, and the vertex buffers hold 4xfloat4 values plus a changing parameter;
the geometry is generated in the specialized vertex shader. Next: introspect
the constant-values object's ivars/raw memory from the plugin (private class
in backboardd) to recover the exact specialization, then implement that
vertex layout + fragment blend in the compositor. The metallib and both
shader bitcode blobs are in `research/` (`ca-metallib.bin`,
`fixed_vert_lph_spc.bc`, `fixed_frag_lph_cpf.bc`); Apple AIR needs Apple's
LLVM to disassemble.

**Earlier static findings kept:** `thread_body` only runs a null timer;
`add_vsync_source` chooses the CADisplayTimer path; the sampler stack shows
the render loop is `IOMFBServer::vsync_callback -> Server::render_for_time ->
display render_update -> finish_update -> SwapEnd` (backboardd t6), and
SpringBoard is healthy inside SetupAssistant (not hung).

**Earlier static findings kept:** `thread_body` only runs a null timer;
`add_vsync_source` chooses the CADisplayTimer path; `IOMFBServer` never
registers IOMFB notifications (no selector-72 call in the ring). Static targets
already decompiled: `timer_callback`, `Display::render_display`,
`DisplayLink::update_paused_locked`.

# iOS 16 on sweet (Redmi Note 10 Pro, SM7150) - historical notes

### >>> ACTIVE: VIRTUAL GPU M2 — GUEST METAL DEVICE IS THE SYSTEM DEFAULT (2026-10-24) <<<

**Measured on Xiaomi 14 Pro (`eb72c928`), payload `.tools/gputest/payload-phone-m2u.bin`
(m2v adds the compute-pipeline override), image `files/ios16-root.img` in the app.**

- Patch 0091 (PID-1 vfs context) installs the plugin every boot at ~31 s:
  `install .../AGXMetalA11.bundle/Info.plist (723) -> 0`,
  `install .../SweetMetal (92336) -> 0`, `bundle install done (0)`.
- Metal loads it in backboardd: `SWEETMETAL: bundle loaded`,
  `initWithAcceleratorPort`, and both `_MTLAddDevice` conformance asserts pass.
- **The probe device is the system default:** a libdispatch self-probe inside
  backboardd reports `MTLCreateSystemDefaultDevice() = 0x...` with
  `name=SweetMetal` (iOS has no `MTLCopyAllDevices`; `dlsym` returns NULL).
  Sampled in ring m2-ring21/30: `probe[queue] default=0x104740000 name=SweetMetal`.
- CoreAnimation's `CA::WindowServer::EAGLServer::renderer()` ->
  `CA::OGL::new_metal_context()` now completes its whole setup against the
  plugin: `newCommandQueue`, `setLabel:`, `setSubmissionQueue:`,
  `setCompletionQueue:`, `queue.device`, `newDepthStencilStateWithDescriptor:`,
  `newLibraryWithURL:error:`, `newPipelineLibraryWithFilePath:error:`,
  `supportsFamily:` Apple1..8, pipeline states by name (`Pw40aXm_*`, `Siri*`),
  textures/buffers, render+blit encoders, `copyFromTexture:...`,
  `generateMipmapsForTexture:`, `replaceRegion:...`.
- SpringBoard's MPSCore also runs: it loads functions by descriptor
  (`D8F18H`, `U16P3F3H/V`, ...) and builds compute pipeline states. The abort
  `MPSKernel MTLComputePipelineStateCache unable to load function D8F18H`
  (message recovered from `MPSCore` `MPSLibrary.mm:550`) was
  `-[_MTLDevice newComputePipelineStateWithDescriptor:options:reflection:error:]`
  running the real Metal implementation on the fake device. Overriding the
  compute/render pipeline creators fixed it: ring m2-ring30 has **0 SpringBoard
  crashes** through 150 s of boot.
- All fake objects live in `vm/metal/SweetMetal.m` (device + queue/buffer/
  encoder/opaque/function traps). Unknown selectors get a wide generic
  signature, log `SWEETMETAL: call <sel>`, and return zero. The ring reader is
  `tools/sweet-log.py artifacts/<name>.bin artifacts/<name>.txt`.
- **Host GPU output to the guest panel works (M3a, measured).** The kernel's
  `gpuwiretest=1` thread sends OP_CLEAR over the virtio wire; GpuWireServer
  renders with EGL/GLES on the Adreno, reads the colour back, and paints a
  red band plus a moving white bar straight into the guest panel surface
  through the shared `guest-ram.bin` (guest PA 0x9c000000, QEMU RAM base
  0x40000000, stride 4320). The phone shows the band over the console text
  (`artifacts/m2-screen7.png`; host log `panel blit color=#ffff0000`).
  Panel memory order is R,G,B,A, not B,G,R,A as the fourcc suggests.
  The plugin can also `IOSurfaceLookup(1)` the panel from backboardd and
  sees `1080x2400 bpr=4320`, so the default-surface port/mapping is fine.
- **Guest userspace -> kernel GPU channel works.** `initWithAcceleratorPort:`'s
  port returns `MACH_SEND_INVALID_DEST` (0x10000003) after registration, so
  the plugin opens its own `IOAcceleratorES` user client with
  `IOServiceOpen`. On the 0091 kernel it sends selector 0x100 (fill surface
  {id, colour, x, y, w, h}) from `commitAndWaitUntilSubmitted` for render
  passes whose colour attachment is `LoadActionClear` on an IOSurface-backed
  texture: measured `fill surface 7 color=#000000 -> 0x0` for chronod's
  423x423 frames (ring m3-ring3).
  `xnu/patches/0092-sweet-gpu-wire-forward.patch` adds the kernel half:
  SweetGPU resolves the surface's physical address and forwards an OP_FILL
  (header + {pa, w, h, stride, colour, x, y}) through
  `sweet_gpu_wire_send()` in SweetVirtioConsole; GpuWireServer paints that
  rectangle into the guest RAM file.
- **End to end, measured on the phone (kernel 0092, run 40096458536):**
  the plugin's self-test asks the service to fill panel surface 1 at 200x200:
  `SWEET GPU: fill surface 1 pa 0x9c000000 seg 0x9e4000 result 0x0` in the
  guest, `sweetgpu-host: fill request=1 pa=0x9c000000 200x200 color=#ff00ff`
  on the host, and a magenta square appears in the top-left of the screen
  (`artifacts/m3-screen1.png`). The same path fires for CA's render-pass
  clears (`fill surface 7 color=#000000` for chronod). Kernel CI pitfalls
  fixed on the way: 0092 must be based on post-0091 SweetGPU.cpp, and a
  literal newline inside the IOLog string breaks the C++ compile.
- **Known limit:** IOSurface buffers from `sweet_surface_create` are
  physically segmented (chronod's 423x423 surface starts at 0xd0d14000 with
  a 0x4000 first segment), so the one-PA fill is refused
  (`result 0xe00002d7`) for everything except the panel, which is a single
  physical range. A scatter/gather wire message (32+ segments) is the next
  step if CA surfaces must be filled.
- **Next blocker: the WindowServer compositor never draws its display.**
  After context init WindowServer encodes one batch and never calls
  `CA::OGL::MetalContext::flush()`; the IOMFB swaps carry an empty layer
  mask (`swap()`'s per-layer log never fires, though the 0x46c record
  offsets were verified against IOMobileFramebuffer's `_kern_SwapEnd`).
  chronod does submit full 423x423 frames through the traps, so the client
  path works; the display compositor path is the open question.
  `EAGLServer::renderer()` selects the Metal renderer when
  `CAMetalContextCreate` succeeds (GL is only the fallback), and backboardd
  has the full OpenGLES stack loaded, so both APIs are in play.
- **RE tooling (2026-10-24):** Ghidra 12.1.4 + Temurin JDK 21 are installed
  under `.tools/ghidra` and `.tools/jdk21` (GitHub downloads need the local
  proxy `-x http://127.0.0.1:7897`; direct is ~60 KB/s). REA's Windows Ghidra
  provider only accepts PE, so drive Ghidra directly:
  `.tools/run-ghidra-quick.cmd <addr...>` imports
  `research/dsc-extract/QuartzCore` with `-noanalysis` and runs
  `ghidra-scripts/DecompileNoAnalysis.java` (Disassembler + DecompInterface).
  Windows paths must be ASCII; `E:\vmios` is a junction to the project dir.
- **CA display link findings (decompiled):** `IOMFBServer::thread_body` only
  creates a CFRunLoopTimer with `null_timer` and runs the loop.
  `IOMFBServer::add_vsync_source` has two modes: a CADisplayTimer calling
  `IOMFBServer::timer_callback`, or a mach-port runloop source from
  `IOMobileFramebufferGetVSyncRunLoopSource` (which would call
  `registerNotificationPort`; the 0093 kernel logs show it is never called).
  CA therefore uses the CADisplayTimer path, and both timer_callback and
  vsync_callback converge on the server vtable +0x1b8. `present()` and the
  `sweetfb_noconsole` console mute both live in `AppleCLCD::present`, which
  runs only from `vsyncFired` when `fDirty && count % fFlushTicks == 0`; the
  console is still drawing, so present() appears never to run. Patch 0095
  adds `present`/`vsync` counters (and mutes the console at start) to
  confirm this.
- **Measured with 0095/0096 on the phone:**
  - The console mute now works from boot: the panel is black instead of
    filling with kernel text, and the host GPU's 200x200 magenta square is
    the only content (`artifacts/m6-screen1.png`).
  - `present()` does run (`present 1`, 601, 1201 ... = every ~20 s at 30 Hz)
    and the first record has `mask=0x80000007`, but the raw dump shows
    every layer surface id at record+0x54..0x60 is **0** and most of the
    0x46c record is zero (`rec 050 00000001 00000000 ...`). So CA's
    WindowServer really is submitting empty swaps; the mask words are stale
    leftovers, not layer enables.
  - SpringBoard has real UI: pid 26 reports 3 windows -
    `_SBWallpaperSecureWindow` (2 sublayers), `SBStatusBarReusePoolWindow`,
    `SBRootSceneWindow` (1 sublayer). A CATransaction nudge
    (setNeedsDisplay/setAlpha/commit/flush) produced no server-side Metal
    work and no non-empty swap.
  - Rendering the window tree with `-[CALayer renderInContext:]` into the
    panel surface aborts SpringBoard (removed). Treat UI rendering from the
    injected dylib as unsafe.
  - Conclusion: the layer tree exists in SpringBoard, but backboardd's
    render server never composites it and never submits layers; the Metal
    renderer stays idle after its 75 s init batch. The next step is to find
    why the render server receives no usable update (client CA::Context ->
    server connection, or the server's update/timer path), using Ghidra on
    `CA::Render::Server` / `CA::Context::commit_transaction`.

### >>> PREVIOUS: VIRTUAL GPU M0 PROVEN ON XIAOMI 14 PRO (2026-10-24) <<<

**Stable state restored:** phone payload is `.tools/frozen/payload-vm-mttcg.bin`
one guest CPU, App is at home. The last experimental payload was M0 only.

**M0 result (measured):** `xnu/patches/0089-sweet-gpu-discovery.patch` registers an
`IOAcceleratorES` IOService with `MetalPluginName=AGXMetalA11` and
`MetalPluginClassName=AGXA11Device`. On the phone, CoreAnimation found it and
made four `IOUserClient` calls before aborting:

```
SWEET GPU: IOAcceleratorES registered
SWEET GPU: sel=6 struct-in=16
SWEET GPU: sel=2 struct-out=536
SWEET GPU: sel=0 struct-out=64
SWEET GPU: sel=4 struct-out=32
CRASH backboardd sig 6 ... AGXMetalA11+0x90ad0
```

The crash is `AGX::Device<...>::~Device()` during failed initialization (PC is
inside libsystem_kernel abort; AGX frame at `0x209e7ad0`). Current stub returns
zero output structures, so this proves service discovery/plugin selection, not
a working GPU.

**Static ABI evidence:** `Metal` loads a plugin by reading
`MetalPluginName`/`MetalPluginClassName`; `IOGPU.framework` passes the
`IOAcceleratorES` connection as `acceleratorPort` to
`IOGPUMetalDevice initWithAcceleratorPort:`. AGXMetalA11 is the matching plugin.
There is no `ParavirtualizedGraphics` framework in the iOS 16.7 cache, so no
Apple paravirtual GPU shortcut.

**Next M1:** reverse `IOGPUDevice` create/config/shared-memory selectors and
return valid 536/64/32-byte structures plus shared-memory mappings, so
`AGXA11Device` completes init. Only after that implement command queue/resource
calls and host GLES/Vulkan clear/blit. Host GPU cannot be used before the Guest
Metal device exists.

**Other experiments (not shipped):** 2x 750x1624 makes `backboardd` turn the
display off with no swaps (iOS rejects the mode). MTTCG with two guest CPUs
starts both 2/2 CPUs but stalls post-userland without FB swaps. Gunyah crosvm is
blocked by SELinux on `/dev/gunyah`; QEMU's Gunyah accelerator needs a custom
kernel and is not available on stock. QEMU 11.1.2 host port is in progress
(custom device API migration). Full performance numbers remain in
`docs/PERF_FIXES.md` section 9.

### >>> STUTTER ROOT CAUSED AND FIXED (2026-10-23 late): docs/PERF_FIXES.md <<<

The "runs, but is very laggy, and not just rendering" report had five independent
causes. All the ones that live outside the guest are fixed; the APK is rebuilt.

1. **App sampling: 4 fps default, 11 fps ceiling** (`BootConfig.fps = 4`,
   `seek.setMax(11)`). The guest's 16 fps was irrelevant: the screen only
   refreshed 4 times a second. Default is now 30, 15-60 range, old saved
   values below 15 are reset to 30.
2. **Frame change probe too sparse**: 256 words, one every 40 KB, so a caret or
   toggle could go undetected for many ticks. Now every 64 bytes.
3. **2 vCPUs on one TCG thread** (`thread=single`): guest daemons,
   WindowServer and apps serialize; host CPU measured at only 60-68% of one
   core while the guest crawled. MTTCG was briefly made the default, then a
   second cold boot PANICKED on pset0's ticket lock after 3,000,001 ticks
   (=125 ms at 24 MHz, owner on CPU 1, no debugger handshake), so the default
   is single again and `tcgmulti=1` stays an experiment. The timeout is a
   boot-arg: XNU parses `tlto_us`/`slto_us` (us) in ml_init_lock_timeout; with
   2 s the same MTTCG boot ran 460 s without a panic (owner was just slow, not
   dead). VmEngine now always appends both (2 s), and tools/bootargs.py `vm`
   carries them. No measured MTTCG speed win yet, so single stays the default.
4. **Guest RAM page faults inside the vCPU thread** (507k minflt, RSS
   149 MB -> 1.78 GB in 5 min). `memory-backend-file,...,prealloc=on,
   prealloc-threads=4` moves that to startup.
5. **Touch move path** did seek+write per MOVE at up to 120 Hz; coalesced to
   8 ms and the 5-byte record buffer is reused.

**Measured A/B (WSL host, same image/payload, 300 s each):** the baseline
(single, no prealloc) and the shippable single+prealloc run both ended on
console text at 300 s; an MTTCG+prealloc run showed the iOS Setup "Hei" GUI at
300 s, but a repeat of that configuration panicked. So the speedup is MTTCG's,
and MTTCG is not shippable until the kernel lock work lands. Prealloc stays for
runtime smoothness but has no measured boot effect. App input is
still unverified on the phone (no device attached this session).

**Phone ring read offline (2026-10-24):** `.tools/ios16-root.img`'s SWEETLOG
holds two boots and 108 KB: 0 panic / 0 backboardd crash / 0 app execs, 16
SWEET FB swaps, and sampler blocks for SpringBoard **65 threads**, backboardd
22, Setup 9, lsd 7. So the phone's stutter is not a crash loop; it is 87
system threads on 1-2 vCPUs time-shared on one host core (plus present cost),
and native apps have never been exec'd (registration).

**App-vs-guest metric:** the 5 s logcat line now carries `ticks=`, `copies=`,
`copy_avg_us=` and `copy_max_us=` next to `fps=`. A high `fps` with a low copy
time means the guest is the limit; a high copy time means the app's 10.4 MB
blit is. The device script parses and reports both.

**Low-RAM guard:** 3 GB prealloc is only used when the phone reports >= 6 GB
of RAM (and never on snapshot resume), so the app cannot be killed for taking
resident memory on a small device.

**Boot-args regression test (no device):** `python3 tools/test-bootargs.py` compiles the shipped `Payload` on the JVM, packs a real payload, and asserts the lock timeouts and `cpus=2` land in boot_args, including at MainActivity's 607-byte limit. This is the bug that shipped once (timeouts appended after writeImages).

**Native-app check:** `tools/sweetvm-device-test.py --native-app-check` waits for
you to tap Settings/Photos and polls the guest ring for `exec Preferences`
etc.; no exec within 120 s means registration is still missing (exit 5).

**MTTCG is now an explicit toggle** (advanced options, default off): it appends
`tcgmulti=1`, VmEngine adds the 2 s lock timeouts and reserves the boot-arg
space for them, and the exit dialog says to turn it off if the guest log shows
a panic/ticket timeout. This is how the phone can A/B single vs multi with the
same fps counter.

**Frame pacing:** the capture loop now keeps a monotonic deadline with
LockSupport.parkNanos instead of Thread.sleep(33); the old loop added the
10.4 MB copy time to every interval and beat against a 16 fps guest.

**Guest log on the phone:** QEMU runs without a console chardev, so
`vm/serial.log` is empty and the app's log screen showed nothing. `SweetLog`
reads the kernel's 4 MiB SWEETLOG ring out of the root image (header block +
ring at the partition tail); `VmEngine.tail()` and the log dialog use it, and
the device test script pulls the same tail with `run-as dd` into
`guestlog.txt`. Verified against `.tools/ios16-root.img` (printed the last
600 bytes of a real boot). This is what makes a panic visible without a PC.

**Resume:** prealloc is skipped on `-incoming` (a snapshot restore writes the
whole RAM block anyway); logcat gets `engine cpus=N accel=... prealloc=...
capture=Nfps` so a device session can confirm the config. The app also logs
`fps=N frames=N uptime=N` every 5 s. APK 07:38; `tools/sweetvm-device-test.py`
installs it, boots, samples those lines, and swipes once (`--reinstall` if the
signature changed; it does NOT push the 16 GB image).

**Also tried:** the 1-vCPU-era image with a 2-vCPU payload stalls at the Apple
logo for 11 min (mismatched pairing, no panic); WSL has no hfsplus module, so
the Setup-skip prefs cannot be written into an image on this host. The
qrun-setup1 snapshot cannot be restored any more: "Missing section footer for
arm_gicv3" (the GIC migration format changed since 17:29). A shipping-config
run (2 vCPU, thread=single, prealloc) stayed on console text at 300 s; an
MTTCG+2 s-timeout run survived 460 s and then a full 900 s with no panic but no
GUI: that image's backboardd crash-loops on
`-[NSURL initFileURLWithPath:]: nil string parameter` (3 crashes / 15 min, 0
SWEET FB swaps), right after IOHIDKeyboardFilter dlopen / SweetHIDButtons. An
incomplete data volume, not the performance change; the phone (Setup run) did
render the lock/home screen.

**Environment incident 2026-10-24:** three 17 GB image copies filled host D: to
0 bytes and WSL died with EIO. Recovered by sparse-converting the VHD, setting
`[wsl2] swap=0` in `.wslconfig` (original 283-byte file was NOT backed up and is
lost), and deleting the copies. /opt/qemu and /opt/vmios are intact; D: has
7.8 GB free, so no more full-image copies on this host.

**Still open:** the guest-side present copy (10.9 MB/frame, needs kernel 0087
offloaded present) and the pset0 ticket-lock timeout under heavy install load
(needs a rebuild to make the timeout configurable). Native app launch (Settings
etc.) is still blocked on first-boot system-app registration, not on
performance - the home-screen icons that are placeholders have nothing to
launch. APK: `android/app/build/outputs/apk/debug/app-debug.apk` (81.9 MB,
2026-10-24 00:01). Next device session: install it, check the top bar reads
~30 fps (not 4), launch an app, and if the kernel panics add `tcgsingle=1`.

### >>> BOOT / GPU ANALYSIS (2026-10-23): docs/BOOT_ANALYSIS.md <<<

**Measured:** 7 boots reach launchd at 31.3-31.7 s, launchd's early-boot tasks finish at 35-36 s, and the remaining ~200 s is SpringBoard blocked in a LaunchServices sync XPC (`__ulock_wait`-class syscall 515 + `mach_msg2`). The 90 s / 210 s / 330 s samples in `artifacts/ios-clean-log.txt` show the **same stack three times**; `lock-log.txt` reproduces it. So the 4-minute logo is a wait chain (SpringBoard -> FrontBoard -> CoreServices -> lsd), not CPU work: backboardd and `CA::Render::Server` are idle in the same samples.

**Disassembled hard timeouts in the shared cache:** QuartzCore `___CAMetalContextCreate_block_invoke` polls `IOAcceleratorES` x300 with `usleep(100 ms)` = **30 s per process** (VA `0x18853e6b4`, `dyld_shared_cache_arm64.03` @ file 0x17b26b4); `IOSurface __iosConnectInitalize` waits **240 x 1 s = 4 min** for `IOCoreSurfaceRoot` (VA `0x1a3983c98`, `.11`) — latent only, the kernel registers the service before launchd today.

**Not enabled yet:** 0069's `ufscache=1` / `ufswait=1` are missing from the command line, and `cpus=6` although 0078 supports 8 (the two A76s are idle).

**New tools:** `tools/macho-analyze.py` (Mach-O symbols/export/disasm/xref), `tools/dsc-frames.py` (symbolicate sampler backtraces against the split cache without macOS), `tools/dsc-patch.py` (unslid VA -> subcache offset, verify + write + undo; presets `metal-wait-300ms`, `iosurface-wait-3s`, tested on the real cache).

**Next:** (1) boot with `sweetsample=SpringBoard,lsd,backboardd,containermanagerd` and pull the log to see where lsd actually sits; (2) add kernel timestamps (`sweetts=1`) and UFS counters to split the 31.5 s before launchd; (3) apply the Metal wait patch at image build.

### >>> BOOT FIXES LANDED (2026-10-23 late): docs/BOOT_FIXES.md <<<

**Shipped:** (a) `tools/mkiosroot.sh` now patches the split shared cache during the build (`dsc-patch.py --presets all`, `SWEET_DSC_FIX=0` to skip, undo sidecar next to the image); `dsc-patch.py` grew `--root/--presets/--check/--undo-out`, is idempotent and verifies by read-back (round trip tested on `research/dsc-test`). (b) boot-args now come from one place, `tools/bootargs.py` (`--profile device|timing|sample|qemu|probe`, 255–347 bytes vs the 607-byte limit) and `mkpayload.py --profile`; `device` adds `ufscache=1 ufswait=1 cpus=8`, so 0069's options finally reach the driver. (c) kernel `0083-sweet-console-timestamps.patch` (`sweetts=1`: fixed 13-byte `[ssssss.mmm]` prefix injected in `sweet_log_append`, one atomic reservation per chunk, covers kernel and `/dev/console`). (d) kernel `0084-sweet-ufs-stats.patch` (`ufsstats=1 ufsstatsecs=5`: cmds/rd/wr/bytes/avg/max/slept/errors from doorbell to completion). (e) `tools/boot-timeline.py` (+ `tools/sweetlog.py` shared decoder) turns a timed log into "largest silences and what surrounded them". (f) `sweet-root-tweaks.py: daemons()` removes the `bluetoothd` and `fairplayd.H2` LaunchDaemons by executable name (30–35 exec attempts per boot, impossible hardware), `SWEET_KEEP_DAEMONS=1` keeps them.

**Verified offline:** both patches apply cleanly on a 8796.141.3 tree with 0001–0082 applied and reproduce the working file byte for byte; `mkiosroot.sh`/`sweet-root-tweaks.py` pass `bash -n`; payload builds with `--profile device`; daemon removal unit-tested on a synthetic `launchd.plist`; timeline tool tested on a synthetic log and degrades cleanly on `phone-klog3.bin` (no prefixes).

**Still needs the phone:** a `--profile timing` boot (splits the 31.5 s) and a `--profile sample` boot (lsd's own stack). No device attached in this session, so neither has been run.

### >>> FIRST MEASUREMENT ON THE PHONE (2026-10-23 late): vmios, not the Note 10 Pro <<<

**The device that connected is the VM host, and the earlier "hardware" numbers were the VM.** K70 Pro (shennong/pineapple, Android 16) with `dev.vmios.sweetvm` installed, a 16 GiB `ios16-root.img` and `payload.bin` in app storage. Every log in `artifacts/` says `SWEET CPU: requested=1 selected=1`, `vm_page_bootstrap: 76090 free pages` (~1.19 GB), `DMA at 0xb33d8000` and userdata `first block 0x22` — QEMU `-M virt -cpu cortex-a76 -smp N -accel tcg,thread=single,tb-size=512`, where `N` is the `cpus=` from the payload. Corrected in `BOOT_ANALYSIS.md` §2 and written up in `BOOT_FIXES.md` §8.

**A/B on the shared-cache patch (4 runs, same payload/image, only 8 bytes differ):** base 0/2 runs reached the present loop (65 888 B/seq 22 and 70 356 B/seq 30); patched 2/2 did (65 704 B/seq 23, 68 172 B/seq 24), both at ~210-220 s guest. So `metal-wait-300ms` lands in the VM: the "renders surfaces but sits on the boot logo" state was partly the 30 s usleep loop. `-smp` and the wait are the only variables; `tools/vm-probe.py` + `tools/compare-runs.py` did the timing off the SWEETLOG flush counter, not the wall clock.

**Two new tools that made it possible without mounting HFS anywhere:** `tools/image-patch.py` scans a raw image for `dyld_v1` and resolves the site through each member's mapping table (member_start + VA is wrong — the VA→file offset lives in the mapping info); `tools/phone-patch.py` does the 4 KiB read/modify/write through `run-as` + base64 (adb on Windows mangles binary and MSYS mangles `/sdcard/...`).

**cpus=2 does not help:** rebuilt with `--profile vm`, same numbers as 1 vCPU. `thread=single` round-robins every vCPU on one host thread, so `-smp` buys nothing; MTTCG is the only real lever and it still deadlocks SWEET's pset0 ticket lock. Screenshot after 6 min: black screen with one vertical line (`artifacts/vm-2cpu-screen.png`) — frames are being presented, the content is not a lock screen, so rendering is now a separate line of work.

**lsd answered (P0-3):** `artifacts/vm-lsd-stacks.txt` — main thread idle in its own XPC loop, workers inside `CoreServices+0x118cc0`/`+0x21ff8` (CF + malloc) and `UserManagement`. lsd is not waiting on a missing service; it is building the LaunchServices database on one emulated core.

### >>> ANDROID VM / QEMU PATH (2026-10-23, separate from the phone port) <<<

**State:** added an experimental Android app (`android/`, vmios) that runs the
same SWEET kernel under QEMU TCG. A new QEMU sysbus device
(`vm/qemu/sweet_ufs.c`) presents the raw 16 GB HFS+ root as GPT `userdata`, so
the unmodified `sweet_ufs.c` driver mounts it. Guest RAM is file-backed
(`guest-ram.bin`); the app reads the 1080x2400 panel at offset `0x5c000000`.
Host/root build notes are in `vm/README.md` and `docs/IOS_ROOT_WSL.md`.

**Verified:** x86_64 Android 15 AVD: demo payload reaches
`*** SWEET userspace: init running as PID 1 ***`; a 64 MB HFS+ test root through
the app's `-device sweet-ufs` logs `SWEET UFS: "userdata" ... 64 MiB`, mounts,
and runs PID 1; immersive display, controls auto-hide and stop work. Host QEMU:
the iPhone X 16.7.16 root built from IPSW mounts via the UFS device and
SpringBoard/backboardd start (single-core TCG; clean lock-screen render not
confirmed). APK: `android/app/build/outputs/apk/debug/app-debug.apk`
(arm64-v8a + x86_64 engine assets, targetSdk 28, debug signed).

**Fixes made along the way:** Android QEMU cannot use patchelf-rewritten Termux
libs (linker segfault in `prelink_image`); the engine is extracted unchanged and
targetSdk 28 keeps exec-from-app-data. `mkadt.py` now emits the QEMU
`/sweet-ufs` node and has `--no-product`; `qemu-sweet.py` has
`--qemu/--ufs/--shared-ram`. `tools/validate-repo.py` now works on Windows
(UTF-8 output, Git Bash instead of WSL bash). The iOS data ark needed
`-ActivationState Activated` after the first boot.

**Update 2026-10-23 late:** touch is now implemented as a QEMU GENI SE7 +
GT9896 model (`vm/qemu/sweet_touch.c`, chardev 5-byte packets), the kernel's
RPMh vote is stubbed with `tools/patch-qemu-input.py`, and the app (v0.2.0)
reaches `SWEET TOUCH: selected GT9896 Yellowstone` end to end. SMP: PSCI is
switched SMC->HVC by `tools/patch-qemu-psci.py`; QEMU MPIDRs use Aff1 via a
virt affinity patch; 8/8 CPUs start, but full iOS with 6/8 vCPUs hits lock
timeouts. 2 vCPUs is the stable bring-up choice. Full iOS renders surfaces
(`SWEET FB: swap ... surface ...`) but stalls at the boot logo; disabling
Control Center bundles and thermalmonitord and patching IOMFB `fPowerOff=0`
did not produce a home screen. Next: backboardd/SpringBoard scene/display-link
and activation/power path; keys via SPMI/PMIC; then home-screen verification.

**Latest display diagnosis (2 vCPU):** the `/dev/null` tee
(`sweetnull=backboardd,SpringBoard`) shows only duplicate HID plugin class
warnings from backboardd and `SWEET Sandbox: SpringBoard privilege 1007
denied`; SpringBoard asks AKS and then goes idle. backboardd creates two
1125x2436 surfaces and swaps (`SWEET FB: swap ... surface ...`), then sends
display off; disabling Control Center bundles and thermalmonitord removed
the earlier LaunchServices/CCS lock but the panel still shows the Apple boot
logo. A binary patch that forces the IOMFB `fPowerOff` store to 0
(`SweetFramebuffer.cpp` case 12, kernel VA 0x7a69bfc in 0081) prevents the
fade-to-black but does not produce a lock/home scene. The next probe is a
sampler for `mobileactivationd` and an IOKit trace around FrontBoard/
backboardd, plus a real power-key path; `sweetnull` did not yield SpringBoard
error text beyond the sandbox line.

**Stack diagnosis (2026-10-23, 2 vCPU, `ipsw dyld a2s` with each process's
live shared-cache slide):** the earlier "boot logo" is not a display bug.
SpringBoard's main thread waits in `FBSystemShell -> BKSSystemShellService ->
BKSDisplayServicesStart -> BKSDisplayGetMainScreenInfo` (sync XPC to
backboardd) while backboardd's WindowServer main thread retries
`CAMetalContextCreate` on the never-present `IOAcceleratorES`. After that
retry ends, SpringBoard proceeds to `SBApplicationController init ->
LSApplicationWorkspace addObserver -> LaunchServices DMFSupport::
reloadAllPolicies -> _LSContextInitCommon`, then blocks on the LaunchServices
database lock. lsd's own stack shows why: `_LSServerMain ->
+[_LSInstallProgressService beginListening] -> performJournalRecovery ->
dispatch_sync`, whose worker is in
`MIInstalledInfoGatherer _groupContainersDictionary ->
+[MIContainer groupContainerURLsForBundleIdentifier:persona:error:]` and is
waiting for a synchronous XPC reply; `/private/var/db/lsd` stays empty and
lsd makes no progress for 15+ guest minutes. CPU goes idle. Sampling lsd
with its slide then pinpointed the wait: `__GenerateBuiltInAppInstallSessionID
-> MGCopyAnswer("re6Zb+zwFKJNlkQTUeT+/w")` enters libMobileGestalt's
`MGIOKitSupport` path, `IOServiceMatching("IONetworkController")`, and spins
forever in a CFRunLoop notification wait (no network controller exists in
QEMU; the notification source never fires, so the "giving up" timeout is
never reached). This is why lsd's journal recovery never finishes.

The image also had **no `systemgroup.com.apple.mobilegestaltcache`
container or MG cache plist**, because `MobileGestaltMigrator` never ran
(the root has `com.apple.migration LastSystemVersion` set from the start).
Seeding a synthetic cache with the right CacheVersion/CacheUUID/length did
not stop the live IOKit query. Workaround now under test: patch the shared
cache function `sub_19c57c430` (cache file `.09`, file offset 0xe24430,
unslid VA 0x19c57c430) to `mov x0, xzr; ret` so that IOKit getter returns
nil instead of waiting. Expected: MI records get a nil device ID, lsd
finishes recovery, SpringBoard's `_LSContextInitCommon` returns. Verify by
sampling lsd/SpringBoard and watching for new swaps/scene rendering.
Next: if MG then writes a valid cache, drop the patch; otherwise also
implement SPMI/PMIC or an IONetworkController stub for parity with the phone.

**Setup / data-volume progress (2026-10-23 later):** the QEMU root had been
built with the Setup-skip prefs from its very first boot, while the phone
reached Setup on v12/v13 and only skipped it from v14. The empty data volume
showed no `/private/var/db/dslocal` user records, no personas and no
`systemgroup.com.apple.mobilegestaltcache`, so the user/identity chain could
never initialize. Removed `com.apple.purplebuddy.plist`,
`com.apple.purplebuddy.notbackedup.plist`, `com.apple.migration.plist` and the
managed-configuration override to let Setup run. The synthetic MG cache and
the `.09` IOKit-getter patch above stay in the image for now; MG never
rewrote the seeded plist.

With Setup enabled, usermanagerd still failed with "Set Foreground ID +
multiuser in commpage" because `_host_set_multiuser_config_flags` in this
kernel is a stub returning KERN_NOT_SUPPORTED (46) - the build has
CONFIG_MULTIUSER off. `tools/patch-kernel-multiuser.py` rewrites that 8-byte
stub (`mov w0,#46; ret` -> `mov w0,#0; ret`); it fakes success without
programming the commpage, so it is a bring-up workaround. After the patch
usermanagerd logs success and containermanagerd's MCMUserIdentityCache stops
blocking: lsd completes `performJournalRecovery` (main thread returns to its
CFRunLoop) and SpringBoard moves from `BKSDisplayServicesStart` to
`-[BKSSystemShellService _checkIn]`, where it waits for backboardd.

**`_checkIn` is a data-migration wait, not a display deadlock:** disassembly
shows `-[BKSSystemShellService _checkIn]` calls
`-[remoteTarget checkInAndWaitForDataMigration:completionBlock:]`. Deleting
`com.apple.migration.plist` to enable Setup also removed
`LastSystemVersion`, so the boot ran the full upgrade migration from an empty
version and SpringBoard waited for it; the backboardd CFPreferences KVO stack
was unrelated. The display kept swapping (~19000 at 30 Hz) throughout.
`/private/var/db/lsd` and `dslocal/nodes/Default/users` stay empty, so user
records are not persisted yet.

Fix under test: keep Setup enabled (no purplebuddy prefs) but restore
`LastSystemVersion=20H392` in `com.apple.migration.plist`, so
`checkInAndWaitForDataMigration` returns immediately. The same kernel now has
the `tools/patch-kernel-multiuser.py` success stub and the MG IOKit-getter
patch; with lsd/MCM unblocked this should let SpringBoard create its scene and
launch Setup. The proper source fix for the multiuser host call is
`xnu/patches/0082-sweet-multiuser-host-flags.patch` (use the iOS branch that
calls `commpage_update_multiuser_config`), matching Apple's XNU host.c; it
needs a CI kernel build. Replace the binary stub with it once the QEMU path
reaches the desktop.

**MILESTONE 2026-10-23: real iOS lock screen rendered in QEMU.** With
LastSystemVersion restored (skips `checkInAndWaitForDataMigration`), Setup
enabled, the multiuser kernel stub and the MG IOKit-getter patch, SpringBoard
created surfaces and rendered the iPhone X lock screen (clock, 2% battery,
Emergency, "iPhone Unavailable"), and Setup launched as pid 183
(`artifacts/cap-setup2.png`). This is the first real iOS UI under QEMU beyond
the boot logo. Touch downs reach the kernel (`SWEET HID: touch 0 down at
540,2150`), but the unavailable lock screen ignored both a slow swipe-up and
an Emergency tap, so the next wall is the lock/disabled state rather than
rendering.

The QEMU-specific lock prefs from the earlier display experiments
(`SBAutoLockTime`, `SBDeviceLockBlocked`, `SBDisableAutoLock`,
`SBLockScreenAutoLockTime` = 0) were not present on the working phone image
and caused the "iPhone Unavailable" lock state; removing them let SpringBoard
dismiss the lock screen and bring Setup to the foreground. The next boot
rendered the Setup Assistant "你好 / 向上轻扫以打开" Hello screen, and a tap
plus a swipe-up animated it through the multi-language greetings
(`artifacts/cap-info.png`, `artifacts/cap-lang2.png`). Touch injection works:
a tap on the (i) button triggered the Hello animation, and a swipe advanced
it. The lock-screen keybag state itself was fine (keybagd first-unlock
analytics; AKS lock state 0x4).

Setup was then skipped the same way as the working phone v14: wrote
`com.apple.purplebuddy.plist` (SetupDone/SetupFinishedAllSteps/SetupVersion
11/daemonizeNeedsToRun false), the purplebuddy.notbackedup mini-buddy flags
false and the managed-configuration cloud-config flag false, keeping
LastSystemVersion=20H392 and the patched kernel/MG cache. That boot reached a
normal no-passcode lock screen; a swipe-up unlocked it and the **SpringBoard
home screen** rendered with Photos, App Store, Settings and the
Phone/Safari/Messages dock (`artifacts/cap-unlock.png`). Two app slots still
show "Waiting..." placeholders because skipping `LastSystemVersion` also
skipped the SystemAppMigrator that installs/registers the system apps.
The current boot (`qrun-migrate`) re-enables that migration with
`installd`/datamigrator sampling; if it hangs again in a CA commit, the next
fixes are the display-filter/CFPreferences stall or installing through
MobileInstallation directly.

**2-vCPU migration panic:** re-enabling the migration with 2 vCPUs panicked
the kernel after ~4 minutes: `Ticket spinlock(0xfffffe0007689880) timeout
after 300000 ticks ... current owner ... (on CPU 0)... handshake structure
not initialized @lock_ticket.c:386`; panicked task backboardd pid 55. The
home-screen boot with the migration skipped is stable on 2 vCPUs. The
one-time install is therefore retried with `cpus=1` / `-smp 1` (payload
`payload-ios-mig1.bin` = kernel-mu + 1-CPU ADT) to avoid the cross-CPU ticket
lock; expect a much slower install. If it completes, restore
LastSystemVersion=20H392 and go back to 2 vCPUs for interaction.

**APK + 1-vCPU install status:** the APK rebuilt successfully with the
cpus/MTTCG change
(`android/app/build/outputs/apk/debug/app-debug.apk`, 81.9 MB) using
`ANDROID_HOME=/opt/android-sdk` and JDK 17 (`jlink` is missing from the
Java 21 JRE). The 1-vCPU migration ran 12 minutes without a panic, but never
reached SpringBoard: `installd` (pid 141) sat in a synchronous XPC and the
job was respawned repeatedly (~26 mentions), so the system-app install is an
XPC/MobileInstallation stall, not just TCG slowness. Stopped it and restored
LastSystemVersion=20H392 for the stable 2-vCPU home. The new APK installs
and launches on the x86_64 AVD (UI up; a System UI ANR was emulator load,
not the app); the demo-run smoke test remains.

**Home apps still placeholders:** on the stable 2-vCPU home, a clean
unlock + tap on Settings produced no `Preferences` exec and no app launch
after 45 s; the icons above show "Waiting...". The apps are not registered
by MobileInstallation/SystemAppMigrator, so the icon tap has nothing to
launch. The current boot (`qrun-setup2`) re-enables Setup (purplebuddy prefs
removed) and keeps the migration skipped; the plan is to swipe past the
Hello animation and complete enough of Setup to create the mobile user and
install/register the system apps. This is the intended iOS first-boot path
and the remaining prerequisite for native app use/IPA installation.

**Scheduler ticket-lock deadlock under MTTCG:** selecting a language in Setup
(or running SystemAppMigrator) on 2 vCPUs with `tcg,thread=multi` panics in
`hw_lck_ticket_timeout_panic`; the spinlock at 0xfffffe0007b90880 is
`_pset0 + 0x100` (the default processor-set ticket lock), owner on CPU 0,
waiter on CPU 1, 3,000,000-tick timeout. The migration-skipped home boot is
light enough to avoid it; 1 vCPU avoids cross-CPU contention but the install
stalls in an `installd` sync XPC. Workaround under test: 2 vCPUs with
**single-threaded TCG** (`tools/qemu-sweet.py --tcg-single`; the app's
`VmEngine` now always passes `-accel tcg`), which serializes vCPUs so the
scheduler lock cannot deadlock. Setup is booting at `qrun-setup3`.

**Host touch reconnects:** the QEMU socket chardev delivers only the first
client; after that client disconnects, later connections are not delivered to
`sweet-touch` (the Setup language taps were lost for this reason, not a guest
bug). The Android app keeps its socket open, so it is unaffected. For host
gesture scripts use `tools/sweet-touch-proxy.py QEMU_SOCKET CONTROL_SOCKET`:
it holds one QEMU connection and forwards 5-byte packets from short-lived
clients on the control socket. jprx/darwin-vm, the reference iOS/macOS QEMU
project, also runs with a single vCPU (no `-smp` in `run.sh`); our
2-vCPU single-threaded TCG Setup test (`qrun-setup4`) continues to see whether
serialized TCG avoids the pset0 ticket lock without falling back to 1 vCPU.

The proxy still saw only the first touch batch reach the guest:
`sweet_touch_receive` never called `qemu_chr_fe_accept_input()`, so the
chardev was not re-armed after a receive. Added the call and rebuilt
`/opt/qemu/build/qemu-system-aarch64`; continuous gestures are retested at
`qrun-setup5`. The Android engine assets need the same rebuild before the
app-side touch is equally reliable.

**Shared touch file (replaces the app chardev):** `sweet-touch` now also takes
a `touchfile` property; `sweet_touch_sync_file()` preads the same 5-byte record
before each report and applies it when it changed, so guest input no longer
depends on chardev flow control. The Android app passes
`sweet-touch,touchfile=<vmDir>/touch.bin` and `TouchSender` writes the record
to that file; `tools/qemu-sweet.py --touchfile FILE` does the same on the host
(`--touch` still works for the proxy). All three QEMU builds (host, arm64
Android, x86_64 Android) and the APK were rebuilt with this change.

**`-accel tcg` is MTTCG, not single-threaded TCG.** QEMU 8.2 defaults
`tcg` to `thread=multi` on aarch64, so the earlier "2-vCPU single-threaded TCG"
tests (`qrun-setup5`, the app's `-accel tcg`) actually ran MTTCG. The phone
reproduced the pset0 ticket-lock panic on the 16 GB iOS boot with 2 vCPUs
(panicked task logd, owner on CPU 0, waiter CPU 1), and the host Setup test
panicked the same way in fseventsd. `tools/qemu-sweet.py` and `VmEngine` now
pass `tcg,thread=single` explicitly, but the stable bring-up remains **1 vCPU**
(as jprx/darwin-vm does). The phone was switched to the 1-CPU ADT payload
(`payload-ios-mig1.bin`, kernel-mu) and boots the full 16 GB image with
`-smp 1`.

**Xiaomi 14 Pro full-VM result (2026-10-23):** the app auto-adopts
`files/ios16-root.img` (16 GiB) and `files/payload.bin`, QEMU loads the payload
at 0xb0000000 with a 3 GB shared RAM file, and the guest boots XNU 8796 with
`SWEET CPU: 2/2 CPUs initialized` (2-vCPU payload) before the panic. With the
1-vCPU payload the boot reaches the Apple logo and SpringBoard startup.
The app cached the extracted engine by versionCode only, so a rebuilt engine
could be masked by a stale `files/engine-<abi>`; `EngineAssets` now includes
`lastUpdateTime` in the marker.

**Quick resume:** QEMU's `file:` migration transport saves the paused VM
(guest RAM + device state) and `-incoming file:...` restores it. Verified on
the host with the custom UFS/touch devices: a 4 GB VM snapshot is 1.1 GB after
zero-page skipping, saving takes ~18 s at ~530 MB/s, and restoring the
Setup-greeting state took ~20 s instead of a 19-minute TCG boot. The app's
stop dialog now offers "保存快照并退出"; the home screen shows
"快速启动 iOS（快照）" when the payload/root mtime, cmdline and engine
fingerprint still match (`Snapshot.java`, QMP socket `vm/qmp.sock`).
The 3 GB guest RAM file moved from external FUSE storage to internal
`files/vm/guest-ram.bin`, and TCG now runs with `thread=single,tb-size=512`.

App side: `VmEngine` now derives `-smp N` and `tcg,thread=multi` from the
payload's `cpus=N`, and `ensureQemuArgs` no longer forces `cpus=1`, so the
imported 2-vCPU iOS payload runs with the configuration proven here. The APK
rebuild is pending: the Gradle wrapper cannot download AGP 8.7.3 offline
(cached Gradle lives at `/opt/gradle/gradle-8.9`, but the plugin marker is
not in the local cache). A datamigrator
stackshot from the
migration-enabled boot confirms it was blocked in a CoreAnimation
transaction commit (`CA::Render::Message::send_message`) while backboardd's
main thread sat in CFPreferences KVO delivery; `_checkIn` was waiting for
this migration, not for the display.

**Xiaomi 14 Pro bring-up (2026-10-23):** ADB over USB works after killing the
WSL adb server that held Windows port 5037. Device `23116PN5BC` (shennong),
Android 16 / SDK 36, arm64-v8a, 4 KB pages, 58 GB free. `app-debug.apk`
installs and launches (targetSdk 28); the engine self-test boots the demo
payload on the phone (`SWEET CPU: 1/1 CPUs initialized`, AppleCLCD 1080x2400,
HID touch registered), so the arm64 QEMU engine and framebuffer path work on
the real device. adb-created files in the app's external dir were unreadable
to the app, so `BootConfig` now falls back to `filesDir`/payload.bin and
filesDir/ios16-root.img; a payload copied there via `run-as` is auto-detected
(`payload.bin · 15.8 MB`). The 16 GB patched root is being copied to Windows
and pushed for the full iOS VM. Touch chardev reliability/shared-file work is
still pending for the app.

**Remaining:** home screen/interaction proof, hardware keys, native IPA
install, bundling (16 GB + Apple licensing), Xiaomi 14 Pro device test;
phone-side USB networking/GPU/black-app leftovers untouched.

## Agent handoff / active work (2026-10-15, latest)

### >>> UPDATE 2026-10-18 (read first, then the 10-17 handoff below) <<<

**STATE at end of 2026-10-18 (evening):**
- On the phone: userdata = **image v15** (`/run/media/dipa/android/vmios-ipsw/ios16-root-20H392-v15.img/.simg`; = v14 + `/private/var/preferences/SystemConfiguration/preferences.plist` with one network service "USB Ethernet": Interface DeviceName ue0 Type Ethernet, IPv4 Manual 192.168.7.2/24 router 192.168.7.1, DNS 1.1.1.1 8.8.8.8, set "Automatic" as CurrentSet). Fallback image v14 (v12/v13 deleted).
- Kernels: **0078** = all 8 cores (`cpus=8`, cpu6/7 = A76, homogeneous SMP; mkadt now emits 8 CPU nodes; ADT `shim/out/sweet-0078hi.adt`); **0079** = display off/on via IOMFB selector 12 kern_RequestPowerChange(state) (fade over 6 vsyncs, then black; verified: power button gives "SWEET FB: display off/on"); **0080** = `SWEET NET: <proc> route add/delete/change ...` and `... add/delete address ...` trace (built, `shim/out/shim-boot-0080s.img`, NOT booted yet).
- **Internet over USB: not working yet.** Host side is ready (temporary iptables: FORWARD accept for 192.168.7.0/24 + MASQUERADE, comment "vmios"; lost on host reboot). With v15 the phone sent no DNS and no outbound traffic (only mDNS/ARP) -> configd probably did not apply the service (or did, without default route/DNS). Next: boot 0080s on v15, watch `SWEET NET` lines (does configd add 192.168.7.2 / default route on ue0?). If configd ignores ue0 (not an IOKit IONetworkInterface; configd 1241.140.6 source in `research/configd-1241`, SCNetworkInterface createInterface needs IONetworkInterface -> controller (IOMACAddress, SelfNamed) -> bus), add IOKit stand-ins and/or rename the ifnet to en*.
- Live log listener (`nc -ukl 5140`) may still be running, writing `logs/live-0078s.txt`.

**LIVE LOG over USB (0077, boot 0077s): no more recovery round-trips.** Boot an image with `sweetusb=2`, run `tools/sweet-usbnet.sh logs/live-NAME.txt` on the PC: it waits for the phone's CDC-ECM interface, sets 192.168.7.1/24 (sudo) and prints/saves the kernel console the phone streams every 100 ms as UDP to 192.168.7.1:5140 (starts with the last 64 KiB). `ping 192.168.7.2` checks the link. Current image: `shim/out/shim-boot-0077s.img` (kernel 0077, ADT sweet-0069hi, cpus=6, sweetfb_noconsole=1, sweetfb_hz=30, sweetusb=2). The recovery pull (`tools/sweet-log-pull.sh`) is still the way after a panic/hang before USB comes up.

**🎉 USB networking works (boot 0076s, 18:24 local): `ping 192.168.7.2` from the PC answers in ~1 ms, 0 % loss (200-packet burst, 1500-byte frames, 512/1024-byte frames).** 0075: CDC-ECM function (bulk 0x81/0x01, interrupt 0x82 NETWORK_CONNECTION; host MAC 02:00:5e:77:ee:01) + kernel ethernet ifnet `ue0` (legacy output, header strip like if_fake) with 192.168.7.2/24 set from the kernel (proto_plumb + SIOCAIFADDR on an in-kernel socket). 0076: received frames into one cluster mbuf (mbuf_allocpacket gave a first mbuf of length 0 -> panic "Failed mbuf validity check: len -14"). Host side (Linux cdc_ether, interface `enp0s20f0u3u1`): `nmcli dev set IF managed no; sudo ip addr add 192.168.7.1/24 dev IF; sudo ip link set IF up`. Boot image `shim/out/shim-boot-0076s.img` (`sweetusb=2`). iOS itself does not see ue0 yet (configd needs an IONetworkInterface in IOKit).

**USB device mode works (boot 0074s, 17:45 local): the host enumerates the phone at high speed as `1209:0001 vmios "Sweet iOS (USB bring-up)"`.** 0072 read-only probe: ABL leaves the USB30_PRIM GDSC and all 7 USB clocks on, DWC3 v3.20a (GSNPSID 0x5533320a) in device mode (GCTL 0x00112000), halted (DCTL RUN_STOP 0, DSTS 0x00d3de04), event buffer still at ABL's 0xfdfc8000, QUSB2 PHY alive. 0073 (`sweetusb=2`): DCTL soft reset, own event buffer (polled, interrupt masked), ep0 DEPSTARTCFG/SETEPCONFIG/SETTRANSFRESOURCE, setup TRB, RUN_STOP; control-transfer state machine as Linux ep0.c; descriptors: vendor class, no data endpoints. It ran but no event came: **0074** forces the VBUS session in the Qualcomm wrapper (QSCRATCH 0xa6f8800: HS_PHY_CTRL |= UTMI_OTG_VBUS_VALID(20)|SW_SESSVLD_SEL(28), SS_PHY_CTRL |= LANE0_PWR_PRESENT(24), as Linux dwc3_qcom_vbus_override_enable) -> connect + enumeration. Image `shim/out/shim-boot-0074s.img`. Black Phone app: main thread waits in -[VMVoicemailManager fetchAccounts] (sync XPC; voicemail needs the modem).

**Navigation works (boot 0071s on v14, log `logs/boot-0071s.txt`):** swipe up from the bottom edge returns to the home screen; app switcher works. Two fixes: **0070** pid_hibernate (syscall 435 was nosys on the macOS config -> SIGSYS killed SpringBoard in -[SBToAppsWorkspaceTransaction _didComplete] when an app left the foreground; the only CONFIG_EMBEDDED-only entry in syscalls.master); **0071** touches starting within 48 px of an edge carry kIOHIDDigitizerEventFromEdgeTip (UIKit `_UIEventHIDTouchEdgeTypeForHIDEvent` reads the digitizer EventMask 0xb0007 bits 0x800/0x1000/0x2000/0x40000). Diagnosed, not fixed: Settings (Preferences) SIGTRAP in PodcastsUI func_1cdc47c58: force-unwrap of `URL.volumeTotalCapacity` (nil on our HFS+ root). Phone/Photos/Messages show black (MobilePhone launches, no crash) - next: stack samples via boot-arg `sweetsample=MobilePhone,MobileSlideShow,MobileSMS,SpringBoard` (image `shim/out/shim-boot-0071s.img`).

**🎉🎉 MILESTONE 2026-10-18 ~15:30 local: iOS 16.7 SPRINGBOARD HOME SCREEN ON THE PHONE** (boot `shim/out/shim-boot-0069s.img` = kernel 0069 + ADT `shim/out/sweet-0069hi.adt`, image **v14**; log `logs/boot-0069s-v14-HOMESCREEN.txt`). Home screen with a few apps, Settings opens, Control Center / lock screen / notification center work, touch + buttons work, 6 A55 cores (`cpus=6`), `sweetfb_noconsole=1 sweetfb_hz=30`. Known issue: cannot leave Settings (home gesture / AssistiveTouch home do nothing) - to investigate.
What it took today (in order): 0058 HID services (Apple IOHIDFamily-1915 user client), 0059 iPhone X identity (hw.product etc.), 0060 SPMI keys + GENI touch, 0061 1125x2436 presented display, 0062 RPMh L11C touch power + IOPMPowerSource battery, 0063 GENI FIFO packing (Goodix GT9896), 0064 PRIV_WORK_INTERVAL grant (SpringBoard "Failed to create work interval"), 0065 SMP via PSCI (6 A55), 0066 crash map regions, 0067 console mute without cons_ops write, 0068 IOSurface lookup of an already-mapped surface returns base -1 (backboardd snapshot crash), 0069 UFS log flush 10 s. Image v13: CommCenter removed from launchd.plist, BKNoWatchdogs. **Image v14** = v13 + Setup skipped (`/var/mobile/Library/Preferences/com.apple.purplebuddy.plist` SetupDone/SetupFinishedAllSteps true, SetupVersion 11, daemonizeNeedsToRun false; purplebuddy.notbackedup mini-buddy flags false; managedconfiguration.notbackedup LockdownActivationIndicatesCloudConfigurationAvailable false; springboard MCForceShowCloudConfigurationUI false) + mobileactivationd data ark seeded (`/private/var/containers/Data/System/D90C94C4-F94E-4FCF-8A28-A93BE3846D8E/Library/internal/data_ark.plist`, -ActivationState Activated etc.) + MediaToolbox D22/D221/Default SubServerConfiguration StartRecorderServer=false (mediaserverd crash loop: portrait-filter prewarm called NULL GL). **Activation:** ADT /chosen certificate-production-status 0, effective-production-status-ap 0, certificate-security-mode 1, effective-security-mode-sep 1 -> mobileactivationd's native Hactivation branch (Codex `codex/activation/report.md`; alternative 4-byte daemon patch documented there). Fallback image v13; v12 deleted.

**🎉 TOUCH WORKS (boot 0063u on image v13, 2026-10-18 ~13:15 local):** tapping (i) on Setup's Hello opens the device-info sheet; swipe-up is recognised (spinner, then back to Hello - under investigation). Chain: RPMh L11C vote (0062, `bsd/dev/sweet_rpmh.c`) -> GT9896 @0x5d on GENI SE7 (0063 fixed FIFO packing: register address went out byte-swapped) -> sweet_hid_touch -> SweetHIDTouch -> backboardd. Battery icon OK (0062 SweetBattery IOPMPowerSource, static 100 %). **Image v13** (= v12 + CommCenter jobs removed from launchd.plist + `BKNoWatchdogs`=true and `FBLaunchWatchdogExceptions{com.apple.purplebuddy:100}` in /var/mobile/Library/Preferences/com.apple.springboard.plist): Setup no longer killed by the scene-create watchdog (it blocked in CoreTelephony getSubscriptionInfo -> CommCenter, Codex `codex/setup/report.md`; that report also lists how to skip Setup: SetupDone/SetupFinishedAllSteps/SetupVersion=11 in com.apple.purplebuddy.plist + activation check). v9 deleted, fallback = v12. Input latency ~1 min with 1 CPU -> Codex task 11 = SMP via PSCI (`codex/smp/`).

**INPUT WORKS (boot 0060u on a freshly flashed v12, log `logs/boot-0060u.txt`):** power, volume up, volume down reach iOS (PMIC -> sweet_keys.c -> SweetHIDButtons -> backboardd). Power locks/unlocks (screen "off" shows the kernel console because the panel never really turns off). **Device identity fixed: iPhone X** (home indicator, Face-ID-style Setup). Earlier test (0059u, `sweethidtest=15` fake Home presses) advanced Setup from Hello to the language list.
- **0058** HID: `iokit/Kernel/arm/hid/`: IOHIDEventServiceUserClient + IOHIDEventServiceQueue + IOHIDEvent compiled UNCHANGED from Apple IOHIDFamily-1915.140.3 (= exact version of the iOS 16.7 IOHIDLib, clone in `research/iohid-1915`) over our minimal IOHIDEventService (SweetHID.cpp: SweetHIDButtons consumer page 0x0C power 0x30 / vol 0xE9/0xEA / menu 0x40; SweetHIDTouch digitizer collections). C hooks `sweet_hid_key(key, down)` (0 power, 1 vol+, 2 vol-, 3 home) and `sweet_hid_touch(finger, down, x, y)`. HID logs go to IOLog. Boot-arg `sweethidtest=N` = fake Home press every N s.
- **0059** identity: hw.machine/hw.model/hw.target/hw.product from the ADT (macOS-config kernel used to answer "iPad8,6"/"Redmi Note 10 Pro"). mkadt: root compatible `D22AP|iPhone10,3|xiaomi,sweet|...`, model iPhone10,3, target-type D22, `/product` copied from the real D22AP device tree (`research/ipsw-x/d22ap.adt`, extracted from the IPSW, NOT in git), `/buttons home-button-type 2`. Codex report `codex/mg/report.md`: MG ProductType = sysctl **hw.product** (unrecognized -> iPod), HWModelStr = hw.target, HomeButtonType = `/buttons/home-button-type`; disk cache `/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches/com.apple.MobileGestalt.plist` (keyed by build + UUID only -> stale iPod answers survived; reflashed clean v12 to clear it).
- **0060** drivers by Codex (`codex/input/hw-report.md`): `bsd/dev/sweet_keys.c` (SPMI arbiter v5 observer reads, PON 0x810 bits KPDPWR/RESIN SID0, PM6150L GPIO2 SID4 0xc110; works), `bsd/dev/sweet_touch.c` (GENI SE7 I2C @0xa84000, starts 45 s after boot). Touch result: SE7 fw ok (proto 3) but **0x5d and 0x38 both time out -> touch IC unpowered** (L11C LDO needs an RPMh vote). Codex task 8 = RPMh client (`codex/rpmh/`), task 7 = battery (`codex/battery/`).
- **0061** (CI 39117078444): red status bar "rdar:45025538" = UIKit "No status bar visual provider for screen" (360x800 pt is no real iPhone). AppleCLCD now presents **1125x2436** (iPhone X) and shows the centered 1080x2400; touch mapped the same; ADT canvas 1125x2436. `sweetfb_native=1` reverts.
- Images: `shim/out/shim-boot-0060b.img` (0060 + /buttons ADT `sweet-0060hi.adt`). Next: 0061 image with ADT from current mkadt.

### >>> HANDOFF 2026-10-17 late (read this first) <<<

**STATE: iOS 16.7 Setup.app "Hello" screen is ON THE PHONE** (boot `shim/out/shim-boot-0057u.img` on image v12). Photo `/run/media/dipa/android/vmios-work/MILESTONE-setup-hello-2026-10-17.jpg`. SpringBoard + backboardd + Setup run; nothing crashes in the GUI path. Remaining crash/relaunch loops: installcoordinationd (should be fixed by 0057, unverified), mediaserverd (VirtualAudio removed in v12, unverified), mobileactivationd (~100/boot, not analysed), bluetoothd + fairplayd.H2 relaunch constantly (no hardware).

**What is on the phone now:** userdata = image **v12** (`/run/media/dipa/android/vmios-ipsw/ios16-root-20H392-v12.img` + `.simg` + `.sha256`; v9 kept as fallback, v8/v10/v11 deleted or superseded). Kernel **0057** (`xnu/out-0057`, CI `39067532732`). ADT **`shim/out/sweet-0057hi.adt`** (QEMU twin `research/q0057-hi.adt`). Boot image **`shim/out/shim-boot-0057u.img`**. Boot args: `debug=0xc serial=3 cpus=1 keepsyms=1 -enable_kprintf_spam -noprogress rd=ufsroot0 unentitled_ios_sim_launch=1 ignition_level=1 wdt_test=no_user_checkin ufsrw=1 rootrw=1 launchd_unsecure_cache=1 wdt=-1`.

**Build a phone image** (kernel K, ADT A): `python3 tools/mkpayload.py $K $A shim/out/payload-X.bin --cmdline "$B" && (cd shim && ./build.sh ../shim/out/payload-X.bin && cp out/shim-boot.img out/shim-boot-X.img)` then check `python3 tools/unpack_bootv2.py shim/out/shim-boot-X.img shim/out/check-X && cmp shim/out/check-X/ramdisk shim/out/payload-X.bin`. QEMU smoke test: `python3 tools/mkpayload.py $K research/q0057-hi.adt $S/csq/payloadX.bin --ramdisk $S/csq/root-fork.img --cmdline "debug=0xc serial=3 cpus=1 keepsyms=1 -enable_kprintf_spam -noprogress rd=md0"` + `PATH=~/swift/usr/bin:$PATH python3 tools/qemu-sweet.py ... --secs 40 --kernel $K --fail-on-panic` (S = scratchpad; root-fork.img lives in the session scratchpad csq/ dir and may be gone in a new session).

**Kernel workflow:** edit `research/bt28/xnu/...` (keep the pre-edit copy in `research/preNNNN/`), syntax check `python3 tools/xnu-cc.py research/run28.log research/bt28 <file>`, make `xnu/patches/NNNN-*.patch` with `diff -u pre bt28 | sed` path rewrite, add new/changed files to `research/check-patch-order.py` list, run it (must say applied + MATCH), commit + push -> GitHub Actions `xnu` builds (~8 min) -> `gh run download <id> -R dipa-studio/vmios -n xnu-kernel -D xnu/out-NNNN`. **Repo is PUBLIC since 2026-10-17** (private macOS runner minutes ran out: "recent account payments have failed"); public = free runners. Commit trailer: only `Co-Authored-By: dipa-studio <183933817+dipa-studio@users.noreply.github.com>`.

**Phone workflow (user does buttons, Claude runs commands):**
- Boot test kernel: phone in fastboot -> `fastboot boot shim/out/shim-boot-X.img`. NEVER `fastboot getvar`.
- **Read logs WITHOUT filming:** after a test the user holds Power+VolDown -> fastboot -> `fastboot boot recovery/recovery.img` (OrangeFox, temp) -> wait for `adb shell true` -> `tools/sweet-log-pull.sh /run/media/dipa/android/vmios-work/logs/<name>.txt` (reads the 4 MiB console ring the kernel keeps in the last 1025 blocks of userdata; patch 0047). Then `adb reboot bootloader` brings the phone back to fastboot without the user.
- **Flash a root image:** `fastboot flash -S 512M userdata <img>.simg` (7 min, 25 chunks). After a big flash the Xiaomi ABL fastboot hangs: next `fastboot boot` stalls at "Sending" -> the USER must re-enter fastboot by hand (Power+VolDown). Do not retry commands against the hung ABL. A flash right after `adb reboot bootloader` once failed on chunk 1 (USB protocol error): just retry. User must NOT unplug during flash (once interrupted at 25/25 -> reflash).
- **Edit the phone root without reflashing (same-length only):** find the file's raw offset in the local image (it is one extent; search the image for its first 4 KiB), compare with `adb exec-out dd if=/dev/block/sda34 ...`, then `adb push` changed 4 KiB blocks and `dd of=/dev/block/sda34 seek=... conv=notrunc,fsync`, read back. Recovery kernel has no hfsplus.
- **Pull the whole phone root** (12 min): `adb exec-out "dd if=/dev/block/sda34 bs=1048576 count=16384" > img`; mount ro with udisksctl or `sudo mount -t hfsplus -o loop,ro`. To write into a pulled image: `sudo fsck.hfsplus -fy` first (volume is never cleanly unmounted -> Linux mounts ro even with -o force), then `sudo mount -t hfsplus -o loop,force`.
- Making images: copy latest img with `cp --sparse=always`, mount rw with force, change, `sync; umount`, `sha256sum`, `img2simg`. Keep only the latest image + one fallback on the SSD (/home is ~98% full; big work files live in `/run/media/dipa/android/vmios-work/`, old kernels/images archived in `.../vmios-work/archive/`).

**Diagnostics built into the kernel (all SWEET-only):** persistent console log (0047, boot-arg sweetlog=0 off; flush every ~1 s); `|name| text` copies of /dev/null writes for processes in `sweetnull` (default backboardd,SpringBoard; 0048); `IOK name:` IOKit lookup/open trace for `sweetiolog` (default backboardd,SpringBoard; 0049/0054, 400 lines max); `SWEET Sandbox: proc op N` (0050); `STR ...` heap text dump on SIGABRT/SIGTRAP for `sweetscan` (default backboardd,SpringBoard; 0051/0053) - this is how NSException/BSAssert reasons were found; `SMP name tN pc .. bt ..` user stack sampler for `sweetsample` (default SpringBoard,backboardd; first at 90 s then every 120 s, 40 samples, 16 frames; 0054/0055); `SWEET FB: N swaps` every 1000 swaps; `CRASH name ...` crash reports (0043/0044). Symbolicate cache addresses with `ipsw dyld a2s research/dsc/dyld_shared_cache_arm64 <addr - slide>`; main-binary addresses: addr - mh + 0x100000000.

**Patches added today (0046-0057, all CI-built):** 0046 IOSurface (IOCoreSurfaceRoot) + IOMobileFramebuffer (AppleCLCD on /arm-io/disp0) + arm-io nubs; 0047 persistent log; 0048 /dev/null tee; 0049 IOKit trace; 0050 permissive "Sandbox" MAC policy; 0051/0053 heap text on crash; 0052 RENAME_SWAP via exchangedata on HFS; 0054/0055 sampler, swap counter, AKS selectors 35 (extended device state = 17) and 101; 0056 panel copy from the vsync timer at 10 Hz (sweetfb_hz) instead of every swap; 0057 no config_ext_resolver (ACL group entries resolve without memberd). ADT (tools/mkadt.py): /arm-io/disp0, /chosen/display-scale 3, /chosen/unique-chip-id (synthetic 0x5357454554000001) + chip-id 0x8015 -> IOPlatformUUID A9683613-3704-53F2-95D0-98A8FB574E78. Image v9-v12: /private/var/containers/{Bundle,Data/System,Shared/SystemGroup,Temp}; launchd.plist StandardOut/ErrorPath renamed to ...PatX (pointing jobs at /dev/console stops them launching: EACCES); v12: LastSystemVersion=20H392 in plain /var/mobile/Library/Preferences/com.apple.migration.plist (stops the 1-hour data migration that ran every boot), VirtualAudio.plugin moved to /Library/Audio/Plug-Ins/HAL.disabled/.

**Codex helper** (`codex exec --skip-git-repo-check -m gpt-6.1-sol -c model_reasoning_effort=high -s workspace-write -C /run/media/dipa/android/vmios-work/codex -o OUT "$(cat task.md)" < /dev/null`, run detached with setsid nohup; config already defaults to gpt-6.1-sol high). Reports in `/run/media/dipa/android/vmios-work/codex/`: mediaserverd-report.md, installcoordinationd-report.md (-> 0057), ufs-performance.md (ranked UFS speed plan), **ufs/0058-sweet-ufs-faster.patch** (READY, not yet applied: ufslogsecs default 10 s log flush batching, optional ufscache=1 directional cache ops, optional ufswait=1 spin-then-sleep; syntax-checked, host-stub verified; see ufs/README.md). Apply it as patch 0058 after review.

**Claude safety-classifier note:** several messages about QuartzCore renderer selection / writing an HFS reader tool were cut off by an automatic classifier (false positives, user agrees). Keep those topics short or let them be; they are not blockers now (rendering already works).

**NEXT STEPS (in order):**
1. **Input** (Setup stuck on Hello): touch + power + volume as IOHIDEventService/IOHIDDevice services backboardd matches (log shows backboardd matching IOHIDDevice with DeviceUsagePairs and IOService with HIDServiceSupport=true). Phone hardware: Goodix/Focaltech touch over I2C/SPI (check live DT `dtb/`), buttons via PMIC (pon) and GPIO keys. Start with a fake HID service (e.g. power button via a timer or boot-arg) to learn the ABI, then real drivers.
2. **Device identity**: MobileGestalt reports iPod + Home button. Add /product node / product-type (iPhone10,3, D22AP), device class iPhone, home-button-less (Face ID) properties in mkadt; find exact MG keys (MGIOMFBSupport.c, `IODeviceTree:/product` lookups seen in backboardd trace).
3. **Battery**: AppleSmartBattery/IOPMPowerSource style service (status bar shows empty red battery).
4. Apply Codex 0058 (UFS speed), consider cpus>1, check whether installcoordinationd/mediaserverd loops are gone, analyse mobileactivationd.
5. Hide kernel console over the GUI when not debugging: boot-arg sweetfb_noconsole=1 (but then panics are not on screen).

- **🎉 MILESTONE: iOS GUI ON THE PHONE - Setup.app "Hello" screen (2026-10-17 ~21:30 UTC, boot 0057u on image v12).** Photo: `/run/media/dipa/android/vmios-work/MILESTONE-setup-hello-2026-10-17.jpg` (animated "dobar d(an)" hello lettering, status bar "iPod" + battery icon, bottom "Pritisnite Home za otvaranje" = "Press Home to open" (locale hr), (i) button). Rendered by iOS 16.7 SpringBoard/Setup through CoreAnimation -> backboardd -> kernel IOSurface (IOCoreSurfaceRoot) -> kernel AppleCLCD swaps -> ABL panel memory. What made it: data migration finally skipped (v12: `LastSystemVersion` 20H392 in the plain `/var/mobile/Library/Preferences/com.apple.migration.plist`; ADT `/chosen/unique-chip-id` + `chip-id` for IOPlatformUUID), 0057 (no ext resolver -> ACL containers work), plus everything before (0046 display/IOSurface, 0050 Sandbox policy, display-scale 3, containers dirs, RENAME_SWAP, AKS 35/101, 10 Hz present).
  **Missing (next work, in rough order):**
  - **Input: no touch, no power button, no volume buttons** (no HID drivers; backboardd looks for IOHIDDevice / HIDServiceSupport services). Setup is stuck on "Hello".
  - **Device identity: it thinks it is an iPod with a Home button** (status bar "iPod", "Press Home to open"): MobileGestalt has no product/model identity (no /product node, product-type, etc.) - give it iPhone10,3 / home-button-less (Face ID class) identity.
  - **No battery detection** (no battery/charger/PMIC service; status bar battery shows empty/red).
  - Locale came up Croatian (hr) - harmless.
  - Performance: cpus=1, polled UFS (Codex UFS patch in progress: `codex/ufs/`), backboardd presents at 60 Hz.
- **README refreshed (2026-10-17):** read the full notes and updated the public overview through patch 0045, v7 hardware observations and prepared v8 diagnostics. Documents real Apple userspace, the missing display/IOSurface GUI work, limited security services, highmem, persistent userdata root, current tooling and build examples. Documentation only; no kernel build, tests, flashing or phone boot performed.

- **v11 still migrated (boot 0056u, 20:32 UTC, `logs/boot-0056u-v11.txt`).** On iOS kCFPreferencesCurrentHost lands in the plain plist: all DMEnvironment setters (setLastBuildVersionPref, setUserDataDispositionPref, ...) use CurrentHost and the phone's `/var/mobile/Library/Preferences/com.apple.migration.plist` holds DMUserDataDisposition; datamigrator's XPC service runs with `_RoleAccount: mobile`. **Image v12** = v11 + `LastSystemVersion` = 20H392 added to that plain `com.apple.migration.plist` (keeps DMUserDataDisposition, 501:501 0600) + `/Library/Audio/Plug-Ins/HAL/VirtualAudio.plugin` moved to `/Library/Audio/Plug-Ins/HAL.disabled/` (Codex: stops the mediaserverd SIGSEGV loop; untested). **installcoordinationd loop explained (Codex `codex/installcoordinationd-report.md`):** os_crash "Failed to create data directory" EACCES for `/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.installcoordinationd/Library/InstallCoordination`: `Library`/`Library/Caches` in the container are ACL-only (uid/gid 0xfffffffe, mode 0000, ACE for group GUID ...012B = gid 299 systemusers); with `config_ext_resolver` the kernel asks an identity resolver (memberd/opendirectoryd) that iOS does not run -> EWOULDBLOCK -> ACE skipped -> EACCES. **Patch 0057**: drop config_ext_resolver from FILESYS_BASE (compatibility UID/GID<->GUID mapping is used instead), likely fixes other ACL-protected containers too. Codex task 3: UFS driver performance design (`codex/ufs-performance.md`).
- **mediaserverd SIGSEGV loop explained (Codex report `/run/media/dipa/android/vmios-work/codex/mediaserverd-report.md`):** the fault (FAR 0x390) is in the HAL plug-in `/Library/Audio/Plug-Ins/HAL/VirtualAudio.plugin/VirtualAudio` (ApplyBeamFormerPreference <- VirtualAudio_PlugIn::SetPropertyData <- HALS_AHPPlugIn::ObjectSetPropertyData <- AudioObjectSetPropertyData <- MediaExperience vaemVADSerializationListener): the default virtual audio device ('vdef', VirtualAudioDevice_Default) does not exist (no audio hardware/driver, no /product/audio). Proposed workaround for GUI bring-up: move VirtualAudio.plugin out of /Library/Audio/Plug-Ins/HAL/ in the next root image (untested). v11 reflashed OK after an interrupted flash (USB unplugged at chunk 25/25). Codex task 2: installcoordinationd crash loop.
- **ROOT CAUSE of the endless migration: no IOPlatformUUID (2026-10-17).** datamigrator's `-[DMMigrator isMigrationNeededWithBuildVersion:lastBuildVersion:clientPID:]` gets lastBuildVersion from `-[DMEnvironment lastBuildVersionPref]` = `CFPreferencesCopyValue("LastSystemVersion", "com.apple.migration", kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)` -> a ByHost file. The phone had `/var/mobile/Library/Preferences/com.apple.migration.plist` (only DMUserDataDisposition) and NO `Preferences/ByHost` directory at all. On arm XNU publishes IOPlatformUUID (gethostuuid) only from `/chosen/unique-chip-id` (8 bytes) + `/chosen/chip-id` (4 bytes) (IOPlatformExpertDevice::generatePlatformUUID, called from IOPlatformExpert::start); the SWEET ADT had neither, so every CurrentHost preference write failed. Fix: mkadt adds `unique-chip-id` = 0x5357454554000001 (synthetic) and `chip-id` = 0x8015 -> UUID `A9683613-3704-53F2-95D0-98A8FB574E78` (same SHA1 namespace computation as the kernel). ADT `shim/out/sweet-0057hi.adt`, boot image `shim/out/shim-boot-0056u.img` (0056 kernel + 0057hi ADT, QEMU OK). **Image v11** = v10 + `Preferences/ByHost/com.apple.migration.<UUID upper and lower>.plist` {LastSystemVersion: 20H392} (501:501, dir 0755 files 0600). Flashing v11 2026-10-17 ~20:10 UTC. Codex (gpt-6.1-sol high) analysing the mediaserverd SIGSEGV loop in `/run/media/dipa/android/vmios-work/codex/` (report `mediaserverd-report.md`).
- **v10 did NOT stop the migration (boot 0056n on v10, 19:18 UTC, `logs/boot-0056n-v10.txt`):** datamigrator + migrationpluginwrapper ran again, backboardd drew the progress UI (13000+ swaps in ~5 min). So `com.apple.DataMigration.plist`/LastSystemVersion is not the deciding input. What is known about the decision (datamigrator XPC service `DataMigration.framework/XPCServices/com.apple.datamigrator.xpc/com.apple.datamigrator`, strings): `Migration sentinel present. Migration necessary.` (sentinel `/private/var/datamigrator/migrate`, created and removed by datamigrator itself; absent in v10), `System build version changed from %@ to %@. Migration necessary.` / `...unchanged... not necessary`, `Disposition dictionary with build version %@ is out of date relative to current build version %@`, `SyntheticDidUpgrade`, DMUserDataDispositionManager; previous build source not found yet (not in the binary's plain strings; likely in DataMigration.framework's DMUserDataDispositionManager / preferences domain `com.apple.migration`). backboardd calls `DMPerformMigrationIfNeeded` and holds SpringBoard in `checkInAndWaitForDataMigration` until it returns. NEXT: find where the previous build version / disposition dictionary is stored (disassemble DataMigration.framework DMUserDataDispositionManager + datamigrator's isMigrationNeeded path), write it into the image; or get datamigrator's os_log out (OS_ACTIVITY_DT_MODE needs a launchd env change).
- **Data migration never records completion -> skip it (image v10, 2026-10-17).** Boot 0056n (18:16 UTC, `logs/boot-0056n.txt`, 30 min): 10 Hz panel copies, backboardd still presents at ~60 Hz (107k swaps), SpringBoard still in `BKSSystemShellService _checkIn` at sample 14. Every migration run takes 1+ hour on cpus=1 and repeats each boot. DataMigration decides from `/var/mobile/Library/Preferences/com.apple.DataMigration.plist` key `LastSystemVersion` (vs ProductBuildVersion 20H392); the pulled phone root (21:01 local) had NO such file. **v10** = that pulled phone state + fsck.hfsplus -fy (volume was marked not cleanly unmounted -> Linux mounts it read-only even with -o force; fsck found only hard-link counts + minor volume header, repaired) + `com.apple.DataMigration.plist` {LastSystemVersion: 20H392} (501:501 0600). `/run/media/dipa/android/vmios-ipsw/ios16-root-20H392-v10.img` (+ .sha256, .simg); v8 files deleted, v9 kept as fallback.
- **Repo made PUBLIC (2026-10-17, user request) so GitHub-hosted macOS runners are free:** the 0056 CI run was refused ("recent account payments have failed or your spending limit needs to be increased"). Checked before: no device dumps, serials, IMEI or Apple binaries in the history (.gitignore keeps backup/, dtb/, recovery/, research/ out); commit author emails are public now. 0056 rerun `39056660104` passed -> `xnu/out-0056`, QEMU OK, image `shim/out/shim-boot-0056n.img` booted 18:16 UTC.
- **Boot 0055n (17:16 UTC, ~65 min, `logs/boot-0055n.txt`): migration bar reached 99% in ~30 min (was ~60), then crawled.** Root cause of the slowness: backboardd presents the progress UI at ~58 Hz (**167,000 swaps in ~48 min**) and AppleCLCD copied the full 10 MB frame into the panel on every swap -> ~600 MB/s memcpy on the single CPU (cpus=1), starving everything (polled UFS I/O too). Sampler (16 frames): **SpringBoard waits in `-[BKSSystemShellService _checkIn]`** (synchronous BSXPC call to backboardd, from FBSystemShellInitialize <- SBSystemAppMain) - backboardd holds the system shell check-in until the data migration ends, so the migration is the gate to SpringBoard UI. **Patch 0056**: swap only records the latest swap record; the vsync timer copies it to the panel every 60/sweetfb_hz ticks (default 10 Hz); `SWEET FB: N swaps` every 1000.
- **Boot 0054n (16:53 UTC, ~12 min, `logs/boot-0054n.txt`, patch 0054 sampler):** the data migration runs AGAIN on every boot (it completed once in the 0053s run) - completion is not being recorded. backboardd keeps swapping the progress UI (3700+ swaps in ~10 min, `SWEET FB: N swaps`). Sample during migration: SpringBoard main thread blocked in a synchronous XPC call (`mach_msg2_trap <- dispatch_mach_send_and_wait_for_reply <- xpc_connection_send_message_with_reply_sync <- -[BSXPCServiceConnectionMessage _sendSynchronously:] <- BSXPCServiceConnectionProxy ...`). Unsupported AKS selectors seen: 101 `aks_assert_consume`, 93 `aks_get_internal_info`, 34 `_aks_stash_load` (datamigrator), **35 `aks_get_extended_device_state`** (SpringBoard, chronod, remindd, searchd, symptomsd...). **Patch 0055**: AKS 35 answered like 17 (same DER device state), 101 succeeds; sampler backtraces 16 frames, 40 samples (~80 min).
- **MILESTONE: FIRST iOS PIXELS ON THE PANEL (boot 0053s long run, 15:33 UTC, ~60 min; photos IMG_20261017_183029/183222/183419; log `/run/media/dipa/android/vmios-work/logs/boot-0053s-long.txt`, 407 KB, 1428 flushes).** The iOS data-migration boot screen (Apple logo + progress bar) was shown and the bar advanced to full in ~60 minutes. It is drawn by **backboardd through our kernel display path**: `SWEET SURF: backboardd create id 2/3 1080x2400 fmt 0x42475241 (BGRA) bpe 4 bpr 4352 size 10452992 keys 11`, IOSurface sels 9, 27, 5, 34 and traps 2/3 (lock/unlock), IOMFB SwapBegin (4) / SwapEnd (5, 1132-byte struct) / GetLayerDefaultSurface (3) / 68 / 55, then `SWEET FB: swap N layer 0 surface 2|3 1080x2400 ... a 0,0 1080x2400 b 0,0 1080x2400` alternating (double buffering; only the first 16 swaps are logged). Triggered by `com.apple.datamigrator` (AKS sels 101/93/34 return unsupported) and `com.apple.migrationpluginwrapper`. Probably ProgressUI-style CoreGraphics drawing into IOSurfaces (no GPU used). After the migration: SpringBoard and backboardd stay up (exec once each, no crash), nothing new drawn; crash loops only for mediaserverd, installcoordinationd, mobileactivationd (~108 each in the hour); bluetoothd and fairplayd.H2 relaunch constantly (no hardware). Kernel console text overlays the image (sweetfb_noconsole=1 would hide it).
- **MILESTONE: SpringBoard and backboardd both stay up (boot 0053s on v9, 15:29 UTC, `logs/boot-0053s.txt`).** With /chosen/display-scale = 3: `exec SpringBoard` once, `exec backboardd` once, no CRASH for either; MobileGestaltHelper reads IOMFB size/dot pitch; backboardd opens AppleCLCD (sels 57,15,22,29,33,79,74 as before). No IOSurface creates and no swaps: backboardd keeps polling `IOProviderClass IOAcceleratorES` (-> 0 found) and AGXAccelerator/IOAcceleratorESLegacy - no GPU, so no CoreAnimation renderer yet. Log goes quiet after ~47 s (only 47 flushes): the system idles. NEXT WALL: CoreAnimation rendering without a GPU (CPU path) so the window server produces frames.
- **SpringBoard's invalid mode = scale 0 (boot 0053n, 15:19 UTC, `logs/boot-0053n.txt`, heap scan):** `FBSDisplayMode cannot be configured as requested : <FBSDisplayMode: ...; infxinf@0x (1080x2400/0) 60Hz sRGB SDR>` - pixel size and 60 Hz are fine, scale is 0. libMobileGestalt (MGIOMFBSupport.c, sub_19c560a54) reads `display-scale` (u32, default 0) and `display-rotation` from **IODeviceTree:/chosen**, pixel size via IOMobileFramebufferGetDisplaySize (MobileGestaltHelper sel 8/28 in the log). mkadt now adds `/chosen/display-scale` = 3 (1080x2400 @3x = 360x800 pt). ADT `shim/out/sweet-0054hi.adt` (QEMU `research/q0054-hi.adt`), image `shim/out/shim-boot-0053s.img` = 0053 kernel + 0054hi ADT. Possible catch: MobileGestalt may have cached scale 0 in `/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/...`.
- **MILESTONE: backboardd survives and opens the display (boot 0052n on v9, 15:07 UTC, `logs/boot-0052n.txt`).** No `CRASH backboardd`. It walks `IODeviceTree:/arm-io` children, matches IOMobileFramebuffer, `open AppleCLCD type 0 -> 0x0`, calls IOMFB selectors 57, 15, 22, 29, 33, 79 (GetBlock, out 1580/40), 74 (SupportedFrameInfo), 12, 6, 27, 17, 84, 50; opens IOCoreSurfaceRoot (sel 13); looks for AGXAccelerator / IOAcceleratorES / IOAcceleratorESLegacy (none, repeatedly), `IODeviceTree:/product` (none, repeatedly), `/buttons`, aop-smart-cover, IOPMrootDomain. No swaps yet. **SpringBoard now gets past display discovery** and dies (sig 5) in `-[FBSDisplayMode _initWithWidth:height:preferredScale:scaleOverride:refreshRate:gamut:hdr:rotation:virtual:validityCheck:]+580` <- `_initWithCADisplayMode:scale:rotation:` <- `FBSDisplayConfiguration _initWithImmutableDisplay:` <- `FBSDisplaySource initWithDisplay:` <- `FBSDisplayMonitor` (slide 0x14504000): "FBSDisplayMode cannot be configured as requested". Checks: width/height >= 2, preferredScale > 0, scaleOverride >= 0, refreshRate non-zero, valid gamut/HDR/rotation. Suspects: refresh rate 0 (IOMFB timing blocks answered with zeros) and/or scale 0 (MobileGestalt main-screen-scale; no /product node in the ADT). **Patch 0053**: heap text scan also on SIGTRAP and for SpringBoard (default sweetscan list backboardd,SpringBoard) to read the exact mode description.
- **Image v9 (2026-10-17) = v8 + `/private/var/containers/{Bundle,Data/System,Shared/SystemGroup,Temp}` (root:wheel 0755; on iOS these live on the data volume, absent from the rootfs) + launchd.plist with StandardOutPath/StandardErrorPath renamed to ...PatX (the in-place phone fix; daemons' stdout reaches the log via the 0048 /dev/null tee).** `/run/media/dipa/android/vmios-ipsw/ios16-root-20H392-v9.img` SHA256 aa9f9139...6e67, `.simg` 12,145,303,864 bytes; written through `sudo mount -t hfsplus -o loop,force`. **Patch 0052** (`xnu/patches/0052-sweet-hfs-rename-swap.patch`, CI `39042761826` -> `xnu/out-0052`, QEMU OK, image `shim/out/shim-boot-0052n.img`): vn_rename falls back to VNOP_EXCHANGE when VNOP_RENAMEX(RENAME_SWAP) returns ENOTSUP for two regular files on one volume (HFS exchange swaps data and cnode descriptors = swap semantics). Flashing v9 started 2026-10-17 ~15:00 UTC.
- **backboardd EXCEPTION FOUND (boot 0051n, 14:41 UTC, `logs/boot-0051n.txt`, patch 0051 heap scan):** `*** Terminating app due to uncaught exception 'NSInvalidArgumentException', reason: '*** -[NSURL initFileURLWithPath:]: nil string parameter'`. First-throw stack (slide 0x337f0000): `+[NSURL fileURLWithPath:]` <- `-[BSSystemContainerForCurrentProcessPathProvider libraryPath]` <- `cachesPath` <- backboardd main+0x1d858 (StartWindowServer, shader cache path). BaseBoard: libraryPath = `BSSystemSharedResourcesDirectoryForIdentifier` = `BSSystemSharedDirectoryForIdentifier(id)` + "/Library"; that calls `container_system_path_for_identifier` (libsystem_containermanager -> `_container_legacy_lookup` -> containermanagerd XPC), which returned NULL (BaseBoard logs "Error getting shared system container ..."). With 0050 the sandbox denials are gone. containermanagerd.log.0 in the pulled (pre-0050) image: "Did not receive any persona attributes", "Expected to find at least one persona", notify_register_dispatch failed 9; `/private/var/containers` does NOT exist in the root image (on iOS it lives on the data volume). usermanagerd does create kernel personas 99/199/1000, but fails to save `/private/var/keybags/usersession.kb` and `persona.kb`: "Failed to atomically swap writing file: Operation not supported (45)" (HFS has no RENAME_SWAP). NEXT: create `/private/var/containers` (and check what containermanagerd needs for system group containers), fix or emulate RENAME_SWAP on HFS, then re-check backboardd.
- **Disk housekeeping (2026-10-17):** /home was at 4 GiB free. Moved (not deleted) `xnu/out-0010..0044` and old `shim/out/*.img`/`payload-*.bin` (everything before 0046) to `/run/media/dipa/android/vmios-work/archive/{xnu,shim-out}` (6.3 GiB); /home now 8.7 GiB free. Large work files (phone-root.img 16 GiB, logs, tracev3 dumps) live in `/run/media/dipa/android/vmios-work/`. **Patch 0051** (`xnu/patches/0051-sweet-crash-heap-strings.patch`, CI `39041440935`): on SIGABRT of a process in boot-arg `sweetscan` (default backboardd) the crash log prints heap text runs as `STR ...` (to find the NSException reason). Boot 0051n 14:41 UTC.
- **Boot 0049n (14:11 UTC, `logs/boot-0049n.txt`, patch 0049 trace): backboardd's IOKit lookups before it dies** (each run): `IODeviceTree:/arm-io/pearl-sep` -> none, matching ApplePearlSEPDriver -> none, `IOService:/IOResources/AppleKeyStore` open OK, matching IOHIDDevice (DeviceUsagePairs) / `HIDServiceSupport` notifications, `usb-drd,t8027` notification; **never any IOMobileFramebuffer / display lookup** - the exception happens before display detection. launchd (tracev3) shows backboardd's mach lookups denied with `error = 159: Sandbox restriction`: com.apple.mobilegestalt.xpc, com.apple.iohideventsystem, com.apple.system.notification_center, com.apple.logd, containermanagerd, ACCHWComponentAuthService, oscard. libsystem_sandbox uses `__mac_syscall("Sandbox", op, arg)` (ops: 1 init, 2 check, 3 note, 4 container path, 5/6/7/8 extensions, 0x15 check_bulk, ...); with no policy named "Sandbox" every call gets ENOPOLICY. **Patch 0050** (`xnu/patches/0050-sweet-sandbox-policy.patch`): built-in permissive MAC policy "Sandbox" in sweet_amfi.c (mpo_policy_syscall returns 0, container/extension ops ENOENT; logs first use of each op as `SWEET Sandbox: proc op N`).
- **Phone root pulled (16 GiB, 12 min, `adb exec-out dd if=/dev/block/sda34`) to `/run/media/dipa/android/vmios-work/phone-root.img` (loop-mounted ro at /run/media/dipa/iOSRoot).** No .ips crash reports. logd tracev3 (Persist, LZ4 `bv41` blocks, decompressed strings in `vmios-work/tracev3/all.txt`): /private/var/db/uuidtext is EMPTY so only launchd's own messages are readable. Findings: v8 launch failure = `Service could not initialize: posix_spawn(/usr/libexec/backboardd), error 0xd - Permission denied` (xpcproxy exit 78) - /dev/console not openable for the mobile user; backboardd[98] spawned `com.apple.MTLCompilerService` before SIGABRT; **launchd denies many mach lookups with `error = 159: Sandbox restriction`** (mediaserverd -> com.apple.backboard.display.services, remoted, mobiletimerd -> sleepd, identityservicesd -> apsd) and **tccd exits OS_REASON_SANDBOX "profile not found"** - no Sandbox kext/profiles on SWEET; likely cause of many daemon crash loops (next wall after the display). CF's uncaught-exception text never reaches stderr for daemons (no CF handler; libc++abi prints only the type). **Patch 0049** (`xnu/patches/0049-sweet-iokit-trace.patch`): `IOK name: ...` console lines for registry path lookups, child iterators, matching (with result count/class), matching notifications and IOServiceOpen of the processes in boot-arg `sweetiolog` (default backboardd), max 400 lines.
- **CONFIRMED: launchd StandardOut/ErrorPath=/dev/console stops backboardd from launching.** After the in-place rename (boot 0047n-b, log `logs/boot-0047n-b.txt`) backboardd launches again and dies as on v7: sig 6, `___pthread_kill <- abort <- demangling_terminate_handler <- _objc_terminate <- std::terminate <- _dispatch_client_callout <- _dispatch_once_callout <- main+0x9334` (window-server dispatch_once). It never opened AppleCLCD or IOCoreSurfaceRoot (no `SWEET FB/SURF: backboardd` lines) -> throws before/at display detection. **Patch 0048** (`xnu/patches/0048-sweet-devnull-tee.patch`, CI `39037749668` -> `xnu/out-0048`, image `shim/out/shim-boot-0048n.img`): writes to /dev/null by processes named in boot-arg `sweetnull` (default `backboardd,SpringBoard`) are printed as `|name| text`. Boot 0048n (13:48 UTC, log `logs/boot-0048n.txt`): only `|backboardd| libc++abi: terminating due to uncaught exception of type NSException` (CF's reason line goes to os_log, not stderr, despite CFLOG_FORCE_STDERR/OS_ACTIVITY_DT_MODE). Next: pull the whole 16 GiB root from recovery (`adb exec-out dd if=/dev/block/sda34`) to `/run/media/dipa/android/vmios-work/phone-root.img` and read ReportCrash .ips files / logd tracev3 for the exception reason.
- **Persistent log WORKS (boot 0047n on v8, 13:31 UTC; pulled from OrangeFox: 70 KB, 111 flushes, `/run/media/dipa/android/vmios-work/logs/boot-0047n.txt`).** In 3 min **backboardd was never exec'd** (v7 ran it), ~70 bare `exec xpcproxy`, SpringBoard loops on FBSDisplayMonitor (no display), mediaserverd sig 11 loop, locationd, lockdownd sig 5. Suspect the v8 plist (StandardOut/ErrorPath=/dev/console on backboardd). **In-place plist edit from recovery (no reflash):** launchd.plist is one extent at image/partition byte offset 0x1e025f000 (195 blocks; verified bytes identical on phone vs local v8 mount); renamed StandardOutPath->StandardOutPatX and StandardErrorPath->StandardErrorPatX (same length, both jobs) in blocks 68 and 105 via `adb push` + `dd of=/dev/block/sda34 seek=... conv=notrunc,fsync`, read back VERIFIED. Phone now differs from local v8 image in those 2 blocks (files in `/run/media/dipa/android/vmios-work/`). Test boot 0047n 13:38:42 UTC. Recovery kernel has no hfsplus (raw block edits only).
- **Patch 0047: persistent console log (CI `39036478663` -> `xnu/out-0047`, QEMU no panic; phone image `shim/out/shim-boot-0047n.img` = 0047 + sweet-0046hi.adt + 0045n cmdline).** `_cnputs` (all console output: kernel printf + daemons' /dev/console) also appends to a 4 MiB ring in sweet_ufs.c; after the UFS partition is ready and writable (ufsrw=1) a thread writes new ring blocks + header to the LAST 1025 blocks (4 KiB) of userdata every ~1 s and SYNCHRONIZE CACHE (prints `SWEET LOG: console log to the last 4100 KiB ...`). Read: phone to fastboot -> `fastboot boot recovery/recovery.img` (OrangeFox) -> `tools/sweet-log-pull.sh OUT.txt` (adb dd of that area + `tools/sweet-log.py`). Not yet verified on the phone. Panics after the last flush are not in it (screen still shows them). 2x font attempt reverted: XNU's v_scale only scales the progress icon.
- **Boot 0046n on v8 (13:05 UTC, VID_20261017_150522_HSR_120):** phone prints `SWEET SURF: IOCoreSurfaceRoot registered` and `SWEET FB: AppleCLCD 1080x2400 stride 4320 at 0x9c000000, default surface 1` (nubs + match work on hardware). Visible userspace: early boot tasks, launchd_cache_loader, `exec SpringBoard`; no `exec backboardd` / `SWEET FB: backboardd` line seen in the readable frames (video blurry). Frame 00:47: lower half of the screen shows OLDER console text (16:01:12) below newer lines -> unconfirmed hint that a swap copied an old snapshot of the panel (CA reads the default/displayed surface = panel memory). SpringBoard still dies in `-[FBSDisplayMonitor _initWithBookendObserver:transformer:]+1160` (sig 5, slide 0x30960000). **Shim: 2x console font** (`shim/loader.c` Video.v_depth scale field = 1) so phone videos are readable; image `shim/out/shim-boot-0046b.img` = 0046n + 2x font.
- **Patch 0046: built-in IOSurface + IOMobileFramebuffer (2026-10-17, offline, NOT phone-tested).** `xnu/patches/0046-sweet-iosurface-iomfb.patch`: new `iokit/Kernel/arm/SweetSurface.{h,cpp}` (IOCoreSurfaceRoot + IOSurfaceRootUserClient: sel 13/0/4/34/35, traps 0-5, wired buffers mapped into the caller, per-client refs) and `SweetFramebuffer.cpp` (AppleCLCD : IOMobileFramebuffer on /arm-io/disp0: sizes, swap = CPU copy of enabled layers into the ABL panel memory, 60 Hz vsync via sendAsyncResult64WithOptions(CanDrop), panel memory published as the default IOSurface, kernel text console paused on the first swap only with `sweetfb_noconsole=1` (default keeps the console: pausing switches it to serial and would hide panics)); SweetPlatformExpert creates nubs for /arm-io children (not gic) attached to the platform expert (IOPlatformDevice::compareName casts its provider to IOPlatformExpert, so nubs under the arm-io nub never matched - first CI build showed that in QEMU). mkadt: /arm-io/disp0 {device_type display-subsystem, compatible sweet,display, canvas-width 1080, canvas-height 2400}. CI `39021572169` -> `xnu/out-0046`. **QEMU** (`research/q0046-hi.adt`, RAM disk init, msgbuf): `SWEET SURF: IOCoreSurfaceRoot registered`, `SWEET FB: AppleCLCD 1080x2400 stride 4320 at 0x9c000000, default surface 1`, init alive, no panic. Phone image **`shim/out/shim-boot-0046n.img`** (SHA256 9c4d2fe9..., CI `39024108588` with the review fixes: swap bounds check, zeroed 64-bit async ref, port release, 1.5 GiB wired budget, ref leak/race fixes; QEMU re-checked) = 0046 kernel + `shim/out/sweet-0046hi.adt` + the 0045n cmdline; boot it on image v8 (backboardd/SpringBoard log to console) and film. Expected new console lines: `SWEET SURF: <proc> create id ...`, `SWEET FB: backboardd sel N ...`, `SWEET FB: swap ...`. Open question for the next wall: QuartzCore's IOMFB server builds its renderer from Metal first (`CAMetalContextCreate`), GLES only when enabled; how the CPU renderer gets selected on a device without a GPU is not yet established.
- **IOSurface values ABI (offline RE, `/run/media/dipa/android/vmios-work/iosurface-values.md`) - TODO in SweetSurface (0046 only accepts and drops values, so IOSurfaceCopyValue always returns NULL):** sel 9 SetValue in = {u32 id, u32 pad, IOCFSerialize([value, key]) or ([dict] = merge)}, sel 0xb RemoveValue in = {u32 id, u32 pad, key\0} (empty key = remove all); both out 4 bytes = new generation, client accepts only (gen+2)|1. Kernel after each change: gen = (gen+2)|1 (odd, never 0) -> state+0x20, serialized size (>=1) -> state+0x28. sel 0xa in {u32 id, u32 0, u8 0}, out {u32 ?, u32 gen, serialized non-bulk dict}; too small -> 0xe00002db + needed size (client retries x16). sel 0x1b in 0x88: bulk struct 0x70 @0, u64 valid size @0x70, u64 changed mask @0x78, u32 id @0x80 -> copy masked fields into state+0x30 (bit0 32B @0, bit1 16B @0x20, bit2 8B @0x30, bits3-10 1B @0x38..0x3f, bits11-14 24B @0x40/4B @0x58/8B @0x5c/1B @0x64).
- **IOMFB display matching confirmed (offline RE, `/run/media/dipa/android/vmios-work/iomfb-match.md`):** the framework never matches on "AppleCLCD"; any registered IOMobileFramebuffer subclass works. `iomfb_match_callback` reads only `dfr`/`AppleTV`/`external` (CFBoolean, service itself, no parents); internal main display = all absent/false (type 0, name "primary"). Display count = /arm-io children whose device_type starts with "display-subsystem" (count 0 -> CreateDisplayList returns NULL; more nodes than services -> 30 s wait). IOMobileFramebufferOpen fails only on IOServiceOpen failure; canvas-width/height read as 4-byte CFData from the IOService-plane parent (optional). CopyProperty = IORegistryEntrySearchCFProperty on the service only. Patch 0046 (disp0 node, `external`=false, AppleCLCD : IOMobileFramebuffer) fits all of this.
- **IOMobileFramebuffer swap + notification ABI (2026-10-17, offline).** Swap record = fb+0x18, **0x46c bytes**, zeroed by SwapBegin and sent whole by `kern_SwapEnd` = IOConnectCallStructMethod(sel 5, rec, 0x46c, no output). **SwapBegin** = sel 4, no input, 1 scalar out = swap id (stored at rec+0x50). `kern_SwapSetLayer(fb, layer<4, IOSurfaceRef, CGRect a, CGRect b, flags)`: rec+0x54+4*layer = **IOSurface id**; rec+0x104 bit layer = layer enabled (rec+0x108 bit cleared); rect a (int x,y,w,h, scaled) at rec+0x64+16*layer, rect b at rec+0xc4+16*layer; rec+0x114+4*layer = transform from flags&0xf; flag bits 5/31/6/7/8/9 set bytes rec+0x2ca/0x2cc/0x2e3/0x2e5/0x2e6/0x467+layer. A NULL surface only sets the enable bit with zero id. SwapWait = sel 6 scalars [swap id, timeout, 0].
  - **Notifications**: `IOMobileFramebufferScheduleWithDispatchQueue`/`GetRunLoopSource` create an IONotificationPort and `IOConnectSetNotificationPort(conn, type, port, 0)` (kernel `registerNotificationPort`). `kern_EnableNotifications(fb, type, cb, ctx)` = **sel 72 scalars [NotifyCallbackFuncs[type], fb, type, 0]** -> the kernel keeps an async reference {port, func, refcon=fb} per type and fires it with `sendAsyncResult64`. Types: 0 HotPlug, 1 Power, 3 FrameInfo (args[0] = mask of 31-bit keys, args[1] u32, then values), 4 CRC, **5 Vsync**: 6 args, each a 32-bit half in a u64 slot: (ts lo, ts hi), (t2 lo, hi) passed through the time-ingest helper, (t3 lo, hi); the framework then calls the client's vsync callback(fb, ts, t2', t3, ctx). Vsync callbacks are dropped while the notification port has queued messages.

- **IOSurface.framework user-client ABI reversed (2026-10-17, offline, step 2 of the GUI plan).** `ipsw dyld disass research/dsc/dyld_shared_cache_arm64 --image IOSurface` (selector scan script: scratchpad `selscan.py`).
  - Connect (`_iosConnectInitalize`, pthread_once): `IOServiceGetMatchingService(IOServiceNameMatching("IOCoreSurfaceRoot"))`, retried with sleep(1) up to 241 times (a missing service stalls every client ~4 min, no crash); `IOServiceOpen(type 0)`; then **sel 13** (no inputs, struct out 0x18 bytes = `_ioSurfaceLimits`) and requires u16 at out+0x16 == 1 (ABI version); out+0 = offset/plane-base alignment mask, out+4 = bytes-per-row alignment mask (used as (x+m)&~m), +0..+0x14 also copied into IOSurface remote-method init, otherwise logs and closes the connection.
  - **Create = sel 0**: scalar in [parent id or 0], struct in = `IOCFSerialize(props, kIOCFSerializeToBinary)` (OSUnserializeBinary format; keys IOSurfaceWidth/Height/BytesPerRow/BytesPerElement/PixelFormat/AllocSize/PlaneInfo/CacheMode/IsGlobal/...), struct out **0xa68 bytes** ("lock result"). **Lookup = sel 4**: scalar in [id], same struct out. LookupFromMachPort = sel 0x22 (scalar in [port name]); CreateMachPort = sel 0x23 (scalar in [id, options], scalar out [port name]).
  - Lock result (copied to client+0x68, size 0x68 + planes*0x80, min 0xe8): 0x00 u64 base address **mapped in the caller's task**; 0x08 u64 task VA of a per-surface shared state page (+0 u64 registry id, +8/+0xa u16 bound accel ids, +0xc u32 seed, +0x14 u8 tiled, +0x20 u32 value generation, +0x24 YCbCr matrix, +0x28 u32 non-bulk values size, +0x2d u8 displayable, +0x2e u8 sysmem-only, +0x30 0x70 bytes bulk attachments); 0x10 u64 task VA of timestamp page (4 u64 indexed timestamps, +0x20 detach code); 0x18 u32 surface id; 0x1c u32 alloc size; 0x20 width; 0x24 height; 0x28 bytes per row; 0x2c buffer offset; 0x30 pixel format; 0x34 u32 (dcache flush length); 0x38 plane count; 0x40 u16 bytes/element; 0x42 u8 element width; 0x43 u8 element height; 0x44 cache mode; 0x4c u8 subsampling; 0x4d u8 prohibit-use count; 0x50 parent id; 0x54 slice count; 0x58 u64 trace id; 0x60 u64 protection options; planes[n] at 0x68+n*0x80 (+0 width, +4 height, +8 bytes/row, +0xc offset, +0x14 size, +0x18 u16 bpe, +0x1a/+0x1b u8 element w/h, +0x1c u8 component count, +0x1d address format, +0x54 u8 compression type (non-zero -> no CPU base address)).
  - **Traps** (IOConnectTrapN -> `IOUserClient::getTargetAndTrapForIndex`): 0 IncrementUseCount(id, category), 1 DecrementUseCount(id, category), 2 **Lock**(id, options, &seed_out), 3 **Unlock**(id, options, &seed_out), 4 Release(id), 5 Release after a failed create/lookup setup (id).
  - Other selectors: 5 SetYCbCrMatrix, 6 WrapClientImage, 7 WrapClientMemory, 9 SetValue (serialized), 0xa UpdateNonBulkValueCache (struct in 9), 0xb RemoveValue, 0xc BindAccel, 0x11 SetSurfaceNotify (async), 0x12 RemoveSurfaceNotify, 0x13 Log, 0x14 SetPurgeable, 0x15 SetOwnership, 0x16 SetTiled, 0x18 SetTimestamp, 0x19 GetTileFormat, 0x1a CopyDataValueBytes, 0x1b SetBulkAttachments (struct 0x88), 0x1e/0x2e-0x31 (via outlined helpers), 0x1f SetCompressedTileDataRegionMemoryUsed, 0x20 GetGraphicsCommPageAddress, 0x21 SetIndexedTimestamp, 0x24-0x26/0x2d IOSurfaceAccelerator, 0x27-0x29 shared events, 0x2a SignalEvent, 0x2b Set/InitDetachModeCode, 0x2c SetOwnershipIdentity, 0x32-0x34 data properties.
  - => SWEET kernel service: class/name **IOCoreSurfaceRoot** + IOSurfaceRootUserClient; minimum = sel 13, 0, 4, 9/0xa/0xb (values), traps 0-5, 0x22/0x23 later for cross-process surfaces (CA sends surfaces to backboardd by mach port). Memory: IOBufferMemoryDescriptor per surface, mapped into each task with createMappingInTask; ids from a global table.

- **Image v8: daemon logs on the console.** `tools/patch-launchd-plist.py IN OUT LABEL...` rewrites launchd.plist (binary, plistlib): renames every `_PanicOnCrash` to `_PanicOnCrasX` and gives the listed jobs `StandardOutPath`/`StandardErrorPath` `/dev/console` (devfs console is 0622, writable by mobile) plus `OS_ACTIVITY_DT_MODE=YES` (os_log mirrored to stderr) and `CFLOG_FORCE_STDERR=1`. v8 = v7 + that plist for com.apple.backboardd and com.apple.SpringBoard, written through the mount (796310 bytes, root:80 0644), SHA256 in `ios16-root-20H392-v8.img.sha256`, `.simg` ready; boot with `shim/out/shim-boot-0045n.img`. Goal: see backboardd's uncaught exception text and the window server's display probing. ODDITY (unresolved): the v5 raw-image rename at offset 0x1e025f000 is present in the v5-v7 image bytes, but the plist read through a Linux mount of v7 still had the original `_PanicOnCrash` keys; filefrag shows the file as one extent. Never patch file contents through raw offsets again; write through the mount.
- **IOMobileFramebuffer.framework reversed (step 1 of the GUI plan).** `ipsw dyld disass research/dsc/dyld_shared_cache_arm64 --image IOMobileFramebuffer`.
  - Display discovery (`IOMobileFramebufferCreateDisplayList` -> `getDisplayListNumber`): iterates children of `IODeviceTree:/arm-io`, counts nodes whose `device_type` is "display-subsystem" or "ext-display-subsystem" (or `compatible` "paravirtualizedgraphics,gpu"); then `iomfb_populate_display_infos` adds an IOServiceAddMatchingNotification(IOServiceFirstMatch, **IOServiceMatching("IOMobileFramebuffer")**) and runs the run loop up to 30 s until that many services matched. `iomfb_match_callback` reads service properties `dfr`, `AppleTV`, `external` (CFBoolean) and names displays (external ones "%s-%d").
  - `IOMobileFramebufferOpen(service, task, type, &fb)`: `__ioMobileFramebufferAlloc` (CFPreferences com.apple.iokit.IOMobileGraphicsFamily: canvas_width/height, override_display_width/height, override_panel_width/height, benchmark, enable_ktrace), `IOServiceOpen(service, task, type)` (GetMainDisplay passes type 0), `getEDTProperty` reads `canvas-width`/`canvas-height` from the service's IODeviceTree parent, then fills a table of `kern_*` function pointers.
  - User client selectors (`kern_*` -> IOConnectCall*): 3 _kern_GetLayerDefaultSurface[ScalarMethod_stub]; 4 _kern_SwapBegin[ScalarMethod_stub]; 5 _kern_SwapEnd[StructMethod_stub]; 6 _kern_SwapWaitWithTimeout[ScalarMethod_stub] _kern_SwapWait[ScalarMethod_stub]; 7 _kern_GetID[ScalarMethod_stub]; 8 _kern_GetDisplaySize[ScalarMethod_stub]; 10 _kern_SetTVOutMode[ScalarMethod_stub]; 11 _kern_SetWSSInfo[ScalarMethod_stub]; 12 _kern_RequestPowerChange[ScalarMethod_stub]; 13 _kern_EnableStatistics[ScalarMethod_stub]; 14 _kern_SetFlags[ScalarMethod_stub]; 15 _kern_SetDebugFlags[ScalarMethod_stub]; 16 _kern_SetTVOutSignalType[ScalarMethod_stub]; 17 _kern_SetGammaTable[StructMethod_stub]; 18 _IOMobileFramebufferIsMainDisplay[ScalarMethod_stub]; 19 _kern_SetWhiteOnBlackMode[ScalarMethod_stub]; 20 _kern_SwapSignal[ScalarMethod_stub]; 22 _kern_SetDisplayDevice[ScalarMethod_stub]; 23 _kern_SetDigitalOutMode[ScalarMethod_stub]; 24 _kern_GetHDCPDownstreamState[StructMethod_stub]; 25 _kern_GetDigitalOutState[ScalarMethod_stub]; 26 _kern_printDisplayRegs[ScalarMethod_stub]; 27 _kern_GetGammaTable[StructMethod_stub]; 28 _kern_GetDotPitch[ScalarMethod_stub]; 29 _kern_GetDisplayArea[StructMethod_stub]; 30 _kern_EnableDisableDithering[ScalarMethod_stub]; 31 _kern_SetUnderrunColor[ScalarMethod_stub]; 33 _kern_EnableDisableVideoPowerSavings[ScalarMethod_stub]; 34 _kern_SetVideoDACGain[ScalarMethod_stub]; 35 _kern_SetLine21Data[ScalarMethod_stub]; 41 _IOMobileFramebufferEnableMirroring[ScalarMethod_stub]; 42 _IOMobileFrameBufferGetMirroringCapability[StructMethod_stub]; 43 _IOMobileFramebufferSetRenderingAngle[StructMethod_stub]; 44 _IOMobileFramebufferSetMirrorContentRegion[StructMethod_stub]; 47 _kern_HDCPSendRequest[ScalarMethod_stub]; 48 _kern_HDCPGetReply[ScalarMethod_stub]; 49 _kern_SurfaceIsReplaceable[ScalarMethod_stub]; 50 _kern_SetBrightnessCorrection[ScalarMethod_stub]; 51 _kern_SetColorRemapMode[ScalarMethod_stub]; 52 _kern_SwapCancel[ScalarMethod_stub]; 53 _IOMobileFramebufferSetCanvasSize[ScalarMethod_stub]; 54 _IOMobileFramebufferGetMatrix[Method_stub]; 55 _IOMobileFramebufferSetMatrix[Method_stub]; 56 _IOMobileFramebufferKernelTests[StructMethod_stub]; 57 _kern_GetColorRemapMode[ScalarMethod_stub]; 66 _kern_SPLCSetBrightness[ScalarMethod_stub]; 67 _kern_SPLCGetBrightness[ScalarMethod_stub]; 68 _kern_SetParameter[Method_stub]; 69 _kern_SwapSetColorMatrix[StructMethod_stub]; 72 _kern_DisableNotifications[ScalarMethod_stub] _kern_EnableNotifications[ScalarMethod_stub]; 73 _kern_ChangeFrameInfo[ScalarMethod_stub]; 74 _kern_SupportedFrameInfo[Method_stub]; 75 _kern_FactoryPortal[StructMethod_stub]; 77 _kern_GetCurrentAbsoluteTime[ScalarMethod_stub]; 78 _kern_SetBlock[Method_stub]; 79 _kern_GetBlock[Method_stub]; 80 _kern_GetLinkQuality[ScalarMethod_stub]; 81 _kern_SwapCancelAll[ScalarMethod_stub]; 82 _kern_GetProtectionOptions[ScalarMethod_stub]; 83 _kern_CopyLayerDisplayedSurface[ScalarMethod_stub]; 84 _kern_SetContrast[StructMethod_stub]; 85 _kern_GetBufBlock[Method_stub]; 86 _IOMFBGainEncoderFinishEncoding[Method_stub]; UNKNOWN {}
  - => Kernel needs: an `/arm-io` child node with device_type "display-subsystem" (+ canvas-width/height) and an IOService of class **IOMobileFramebuffer** (subclass name match) attached under it, opened with type 0, implementing at least GetDisplaySize(8), IsMainDisplay(18), GetID(7), GetLayerDefaultSurface(3), SwapBegin(4)/SwapEnd(5 struct)/SwapWait(6), Enable/DisableNotifications(72), frame info(73/74), CopyLayerDisplayedSurface(83), plus IOSurface for the swapped buffers. NEXT: CoreAnimation's AppleDisplay/IOMFBDisplay usage of these (constructor, first swap, vsync), then IOSurface.framework's IOSurfaceRoot selectors.
- **GUI PLAN (decided 2026-10-16): CPU rendering + kernel IOMobileFramebuffer.** User: CPU rendering is fine for now (goal = prove the GUI runs), may later research an Apple-style GPU driver for the Adreno 618 -> keep display output and renderer separable. QuartzCore findings (symbols from the cache's .symbols subcache: `ipsw dyld symaddr research/dsc/dyld_shared_cache_arm64 --image QuartzCore`; strings: `ipsw dyld macho ... QuartzCore --strings`):
  - Renderers: `sw_new_context` (CA::OGL::SWContext, full CPU renderer incl. blur, images, IOSurface-backed surfaces, make_buffer_current(WindowServer::Surface)), `gles_new_context`, `metal_new_context`, `new_null_context`. Env knobs include CA_ENABLE_OGL, CA_DISPLAY_TYPE, CA_FORCE_LOCAL_SERVER, CA_FORCE_TIMER, CA_CANVAS_WIDTH/HEIGHT, CA_MAIN_DISPLAY_SCALE/ORIENTATION, CA_DISABLE_RENDER, CA_ALWAYS_RENDER (selection logic not traced yet).
  - `-[CAWindowServer _detectDisplays]` (0x1884e3150) iterates static tables `open_funcs`/`count_funcs` = AppleCLCDDisplay, AppleRGBOutDisplay, AppleWirelessDisplay only; each `count()` = `display_count_of_type(IOMFBDisplayType)` over **`IOMobileFramebufferCreateDisplayList()`**, `open(i)` = `create_display_of_type` -> `CA::WindowServer::AppleDisplay(CFString name, ..., IOMFBDisplayType)` (an IOMFBDisplay driven by IOMFBServer: vsync_callback, frame_info_callback, swaps). `CA::WindowServer::VirtualDisplay` exists but is never auto-detected (explicit API only). => the main display MUST come from an IOMobileFramebuffer kernel service.
  - NEXT: reverse IOMobileFramebuffer.framework: IOMobileFramebufferCreateDisplayList / IOMobileFramebufferOpen (service matching, display type property), the user-client selectors used by IOMFBServer (display size/modes, swap begin/set-layer/end with IOSurface ids, vsync notifications), then the IOSurface kernel side (IOSurfaceRoot user client: create/lookup/lock, memory mapping) that both IOMFB swaps and CA surfaces need. Kernel: SWEET IOMobileFramebuffer service that copies the swapped IOSurface to the 1080x2400 framebuffer at 0x9c000000.
- **logd fixed; backboardd = DISPLAY WALL (boot 0045n on v7, 21:08:57 UTC, frames VID_20261016_230850 00:55-01:28, slide 0x4c3ec000, `research/crash-0045n-v7.txt`).** No `CRASH logd` any more; new daemons run (runningboardd, WirelessRadioManagerd, networkserviceproxy, dasd, cloudpaird, magicswitchd, atc, askpermissiond, ManagedSettingsAgent, containermanagerd uses AKS 0/17). New: locationd sig 11 at CFRunLoopAddSource+132 (NULL source) from its main+0x2af138 in a dispatch_once. **backboardd** sig 6: abort <- std::terminate <- _objc_terminate <- dispatch_once <- main+0x9334 = the "start %{public}@..." wrapper (0x100009264) for **"window server"** (block 0x10000a770 -> dispatch_once body 0x10001d7f0 = StartWindowServer): MTLSetShaderCachePath, `[CAWindowServer serverWithOptions:@{kCAWindowServerDisableUpdatesOnMainDisplay: @YES}]`, `setRendererFlags:`, **`mainDisplay`** -> `displayId` -> `[CADisplay displayWithDisplayId:]`, setWindowServerDisplay:, bounds, pointScale, currentMode, preferredScale, nativeOrientation, touchScales... With no display, mainDisplay is nil and it throws. (HID system and GS start fine before it.) SpringBoard dies on the same missing display (FBSDisplayMonitor). QuartzCore display backends (from the cache's .symbols subcache, `ipsw dyld str`): `CA::WindowServer::AppleCLCDDisplay` (IOMobileFramebuffer hardware) and **`CA::WindowServer::VirtualDisplay`** (open(), new_server, clone_update). `CA_DISPLAY_TYPE` and `CA_FORCE_LOCAL_SERVER` strings exist in QuartzCore but have no direct xref (likely read via a table of CA_* env names). NEXT: find how CA::WindowServer::Server enumerates displays (IOMobileFramebuffer services vs VirtualDisplay / CA_DISPLAY_TYPE) and choose: (a) kernel IOMobileFramebuffer service + IOSurface, or (b) a VirtualDisplay rendered by CA's CPU path (CA::OGL::SW) and copied to the framebuffer.
- **watchdogd + CommCenter + identityservicesd fixed (boot 0045n on v6, 20:41:30 UTC, frames VID_20261016_224133 00:39-01:13, slide 0x20fec000).** `SWEET WDT: watchdogd sel 0 in 0/0 out 1/0 -> ok`, no watchdogd/CommCenter/identityservicesd crashes (CommCenter/identityservicesd now call AKS 0/17/7). usermanagerd boot task runs (UMD_INIT creates primary session uid 501 "mobile", personas 99 System and 199 Default registered with the kernel); `Failed to atomically swap writing file /private/var//keybags/usersession.kb: Operation not supported (45)` (HFS lacks the atomic swap rename; non-fatal so far). Remaining: SpringBoard (FBSDisplayMonitor, no display), backboardd (uncaught exception), mediaserverd, lockdownd (crash inside obfuscated code, main+0x4c1b4?), logd. **logd**: main+0x18160 = `BUG IN LIBTRACE: Failed to migrate directory` from 0x10001801c(dir 0): 0x100016538 requires the dir to exist with uid/gid/mode from the table at 0x10002df14 (0: /private/var/db/diagnostics 272:272 0751, 1: /private/var/db/uuidtext 272:272 0755, 2: /private/var/db/diagnostics/timesync 272:272 0755) plus a `.migrated` file, else XPC "operation 6" to a helper and crash. **Image v7** = v6 + those dirs/markers (also in mkiosroot.sh), SHA256 in `ios16-root-20H392-v7.img.sha256`, `.simg` ready. Boot with `shim/out/shim-boot-0045n.img`.
- **Exit-reason text works (boot 0044n, frames VID_20261016_221726 00:32-00:53, slide 0x22d5c000).** CommCenter/identityservicesd: `couldn't dlopen libobjc-trampolines.dylib: dlopen(/usr/lib/libobjc-trampolines.dylib, 0x0106): tried: '/usr/lib/libobjc-trampolines.dylib' (no such file, not in dyld cache)`: the file only exists in the OS cryptex and dyld does not search cryptexes at ignition_level=1. 19 cryptex files have no root counterpart (OS: DriverKit dyld cache + .symbols, VisualTestKit, libffi-trampolines, libobjc-trampolines, libstdc++ 6.0.9 + 2 symlinks; App: SafariSupport.bundle, AuthenticationServicesAgent, com.apple.Safari.History, passwordbreachd, safarifetcherd, webbookmarksd, webinspectord, webpushd) -> hard-linked (symlinks copied: Linux hfsplus cannot hard-link symlinks); `tools/mkiosroot.sh` does it generically. watchdogd still crashed: the `-wdt_no_pmu` / `/arm-io/wdt no-pmu` check (0x10000a01c) only runs when os_variant_has_internal_diagnostics; otherwise 0x100009b18 looks up IOServiceMatching("IOService") + IOPropertyMatch {IOPMUPrimary: 1} (NSConstantDictionary) and crashes if absent, then IORegistryEntrySetCFProperty(boot stage 0xff) (failure only logged). Patch **0045**: IOWatchdog sets IOPMUPrimary = 1 and accepts setProperties; CI `38961814194` -> `xnu/out-0045`. **Image v6** = v5 + the 19 cryptex links, SHA256 7c610c6a...297a, `ios16-root-20H392-v6.simg` (full flash needed). Boot image `shim/out/shim-boot-0045n.img` (0045 + sweet-0044hi.adt). Still open: SpringBoard (no display), backboardd (uncaught exception, reason none), mediaserverd (Fig NULL dict), logd (main+0x18160), lockdownd (main+0x4c1b4).
- **System survives daemon crashes (boot 0043p, video frames VID_20261016_215006 00:25/00:42/00:54).** With the v5 plist patch no panic: launchd keeps launching (runningboardd, powerd, tccd, healthd, peopled, cryptexd, routined, aksd, mediaremoted, familynotificationd, nanoprefsyncd, navd, cloudpaird, passd, amsaccountsd, accessoryupdaterd, wcd ...). Shared cache slide that boot 0x406b4000 (`research/crash-0043p.txt`). watchdogd still crashed at main+0xb82c from the PMU step: `-wdt_no_pmu` is only honored when os_variant_has_internal_diagnostics; customer builds read `no-pmu` from IODeviceTree:/arm-io/wdt (IORegistryEntrySearchCFProperty) -> mkadt adds /arm-io/wdt {no-pmu}. **cryptexd** sig 6: abort_with_payload <- os_crash_fmt <- `__darwin_arm_secure_boot_chip.cold.7` ("panic: failed to get crypto algorithm") <- `_img4_chip_select_personalized_ap`: reads /chosen use-ddi-secure-boot, allow-ecid-mismatch, crypto-hash-method ("sha1" | "sha2-384"), /chosen/asmb lp-smb0/1 -> mkadt adds crypto-hash-method "sha2-384". **identityservicesd** sig 6 = same `_objc_fatal` in imp_implementationWithBlock as CommCenter (block trampolines; message needed). lockdownd sig 5 at main+0x4c1b4. Patch **0044**: crash report adds `CRASH name reason ns N code X: text` (exit reason description = abort_with_payload text). CI `38959096811` -> `xnu/out-0044`, QEMU OK. Image `shim/out/shim-boot-0044n.img` = 0044 + `shim/out/sweet-0044hi.adt` (wdt no-pmu, crypto-hash-method) + cmdline (wdt=-1, no -wdt_no_pmu).
- **First symbolicated daemon crashes (boot 0043u on journaled v4, 19:38:53 UTC; video frame chat image 36; transcribed in `research/crash-0043u.txt`; shared cache slide 0x40d60000 for every process).** (Gemini's video transcription invented values, use frames only.) `tools/sweet-crash.py research/dsc/dyld_shared_cache_arm64 x research/crash-0043u.txt`:
  - **watchdogd** pc main+0xb82c (`_os_crash` trap helper) from 0x100009bb0 = set PMU boot stage via IORegistry (no PMU) -> fix: boot-args `wdt=-1 -wdt_no_pmu` (Apple's own test mode writes "%s wdt=-1 -wdt_no_pmu"; watchdogd logs "skipping setting PMU boot stage because -wdt_no_pmu found in boot-args or no-pmu found in EDT"). Kernel effect of wdt=-1: sched hygiene debug off, zone_exhausted_timeout -1 (harmless).
  - **SpringBoard** sig 5 in `-[FBSDisplayMonitor _initWithBookendObserver:transformer:]+1160` <- `+[FBDisplayManager sharedInstance]` <- `FBSystemShellInitialize` <- `SBSystemAppMain`: no main display. GUI WALL: display service (IOMobileFramebuffer / CoreAnimation display).
  - **backboardd** sig 6: abort <- std::terminate <- _objc_terminate (uncaught exception; message not shown).
  - **CommCenter** sig 6: `_objc_fatal` in `imp_implementationWithBlock` (from `+[_PFRoutines initialize]`, CoreData): objc block trampolines cannot be allocated -> likely kernel gap (trampoline page remap); will hit many processes.
  - **mediaserverd** sig 11: CFDictionaryGetValue(NULL) in FigNotificationListenerStartNotifications (routing session manager).
  - **logd** sig 5 at its main+0x18160 (bt main+0x9dfc); lockdownd sig 5 (not yet symbolicated).
  - Image v5 = v4 + launchd.plist (`/System/Library/xpc/launchd.plist`, contiguous at image offset 0x1e025f000, 1456980 bytes) with the 7 `_PanicOnCrash` keys renamed `_PanicOnCrasX` in place (raw image patch, no metadata change) -> `diff-v4-v5.simg` = 7 blocks; v5 SHA256 78f96974...185a. Boot image `shim/out/shim-boot-0043p.img` = 0043 + `wdt=-1 -wdt_no_pmu`.
- **0043 console crash reports (QEMU verified); image `shim/out/shim-boot-0043u.img`; NEXT: flash v4 + boot 0043u.** Boot 0042u (video photo IMG_20261016_211646): short exec lines work; watchdogd crashes with NO `SWEET WDT:` line (fails before its first IOWatchdog call: lookup or IOServiceOpen, or elsewhere); lockdownd, SpringBoard, mediaserverd, CommCenter, identityservicesd, backboardd, watchdogd all crash repeatedly ("Too many corpses being created" = corpse limit, no crash reports). AKS callers: lockdownd (0, 7), imagent/sleepd (0, 17, 7), backboardd (0, 17), UserEventAgent (0, 7, 102, 103 -> unsupported). Patch **0043**: `sweet_crash_log` (osfmk/kern/exception.c, called from proc_prepareexit for crash exits on the current proc) prints `CRASH name[pid] sig S code (exc<<32|code) sub X slide SR mh MH`, `CRASH name pc lr sp fp far`, `CRASH name bt` (10 fp frames); AKS sel 103 notify_state_is_set -> 0. CI `38954520419` -> `xnu/out-0043`. QEMU test: init forks, child `brk #1`: `CRASH launchd[2] sig 5 code 0x600000001 sub 0x1000004f0 slide 0x0`, pc correct, parent keeps running (pid 1 crashes panic before proc_prepareexit, so test with a child). `tools/sweet-crash.py CACHE ROOT [report]` symbolicates typed-in CRASH lines (`ipsw dyld a2s` with addr - slide; main binary offsets = addr - mh + 0x100000000).
- **v3 reflashed 18:50-18:55 UTC (`research/flash-userdata-v3b.log`, 24/24 OKAY); 0042u booted 19:01:17 UTC on the clean disk (`research/boot0042u-2.log`), SLOW MO VID pending (watchdogd failure reason).** ABL hangs on the first `fastboot boot` after every big flash; user re-enters fastboot. User gave standing approval to reflash/boot without asking (memory standing-flash-approval). Commits now end with `Co-Authored-By: dipa-studio <183933817+dipa-studio@users.noreply.github.com>` (user request; never a Claude trailer).
  - watchdogd flow: connect_to_kext (0x100005408): IOServiceGetMatchingService("IOWatchdog") fails -> "failed to discover" + _os_crash; IOServiceOpen(type 1) fails -> "IOServiceOpen failed with error : 0x%x" + _os_crash. Then sel 0 (out 1 scalar): 0 -> "userspace monitoring disabled", 0x100009bb0, sleep 2, exit(0); nonzero -> "userspace monitoring enabled", normal operation.
  - **Image v4 (JOURNALED):** `tools/mkiosroot.sh` now does `mkfs.hfsplus -J`, mounts with `-o loop,force`, adds the /System/Library/Caches/com.apple.dyld hard links (44) and /private/var/keybags/systembag.kb (0700/0600 root). Built from the IPSW dmgs (OS 087-86698-044, SystemOS 087-86593-047, AppOS 087-86715-047) -> `/run/media/dipa/android/vmios-ipsw/ios16-root-20H392-v4.img` SHA256 fba4aeae...ec0f9 + `.simg`. Header: attr 0x80002100 (unmounted, journaled), journal info block 129, journal 8 MiB at 532480 flagged need-init. Linux `fsck.hfsplus -n` reports "Volume header needs minor repair" on any fresh journaled volume even after -y (quirk). QEMU: 64 MB journaled test root (`rd=md0 rootrw=1`, 0042 kernel): `hfs: Initializing the journal (joffset 0x3000 sz 0x80000)` -> mounted -> init runs, no panic. NEXT: flash v4 (full), boot 0042u.
- **SPRINGBOARD STARTS (boot 0041u 18:39:53 UTC, photo IMG_20261016_204142).** backboardd, bluetoothd, fairplayd.H2, SpringBoard (pid 111, crashed: "Too many corpses"), xpcproxy run; `SWEET AKS: backboardd sel 0 -> 0`, `sel 17 in 1/0 out 0/4096 -> 0`. Panic: watchdogd[113] exited, namespace 2 subcode 5 (SIGTRAP = its _os_crash): watchdogd crashes on purpose when IOServiceGetMatchingService("IOWatchdog") fails ("connect_to_kext() unexpectedly failed") or IOServiceOpen(type 1) fails ("IOServiceOpen failed with error"); IOWatchdog DOES register (QEMU msgbuf: `SWEET WDT: IOWatchdog registered`), cause not on screen yet -> need video. Note `wdt_test=no_user_checkin` makes watchdogd log "detected testing boot-args to not run, exiting" (path not reached here?). **HFS CORRUPTION:** `hfs_swap_BTNode: offset #0 invalid (0xBC1D) (blockSize 0x2000 numRecords 81)`, `node=19677 fileID=4` (catalog), `hfs_mark_inconsistent` repeated. Likely cause: non-journaled HFS + unclean panics while writing (0038e wrote a 2.7 GB core then panicked; every boot since ends in panic). Plan: reflash v3 (clean), longer term HFS journaling. Patch **0042**: one short `exec NAME` console line instead of the 3-line "Allowing spawn of iOS binary" notice; CI `38949451276` -> `xnu/out-0042`; image `shim/out/shim-boot-0042u.img` (same cmdline as 0041u).
- **LAUNCHD DAEMONS RUN (boot 0039u, 18:29:13 UTC, photo IMG_20261016_203052).** With `launchd_unsecure_cache=1` all boot tasks pass and launchd starts LaunchDaemons (pids > 100: identityservicesd 114 and lockdownd 106 crash, "Too many corpses being created"). Fatal: `watchdogd: ERROR: failed to discover watchdog KEXT service` -> exit (namespace 2 = signal, subcode 5) -> `_PanicOnCrash` panic. watchdogd: IOServiceMatching("IOWatchdog"), IOServiceOpen type 1, IOConnectCallScalarMethod sel 0/1 (check in)/3/4 (disable/enable userspace monitoring)/5, IOConnectCallStructMethod sel 2 (1 KiB in) and 9 (small out); VM path ("detected virtual machine environment and no watchdog KEXT found, exiting...") only when it detects a VM. Console also flooded with `hfs: set hardlink bit on vol=iOSRoot cnid=321318` (Linux-made hard links lack kHFSHasLinkChainBit; repaired only in memory on each lookup). Patches **0040** (`iokit/Kernel/arm/SweetWatchdog.cpp`: IOWatchdog + IOWatchdogUserClient, all selectors succeed with zeroed outputs, each logged once as `SWEET WDT: ...`) and **0041** (sweet_hfs hfs_catalog.c: the three link-repair printfs limited to 8 per boot); CI `38948245372` PASSED -> `xnu/out-0041` (QEMU regression OK). Image `shim/out/shim-boot-0041u.img` (0041 + sweet-0038hi.adt + ufsrw rootrw + launchd_unsecure_cache=1) booted 18:39:53 UTC (`research/boot0041u.log`), photo pending.
- **v3 FLASHED + keybag passes; next wall AMFI (launchd_cache_loader).** User said "flash, nothing to lose": `fastboot -S 512M flash userdata ios16-root-20H392-v3.simg` 17:51:52-17:57:01 UTC, 24/24 chunks OKAY (`research/flash-userdata-v3.log`). userdata = v3 (SHA256 fa84274c...22df) until the next rw boot. ABL fastboot then hung ("Sending" forever, `reboot bootloader` timed out) until the user re-entered fastboot by hand (common Xiaomi ABL crash). Boot 0038e 18:06:15 UTC (`research/boot0038e-3.log`), photos IMG_20261016_200812/200838: keybag OK, then boot tasks tzinit (`Bad zoneinfo link`, resets to system partition, OK), finish-restore, finish-demo-restore, sysstatuscheck, prng_seedctl (`failed to load kernel prng seed`, `failed to load virtual random (-147)`, AllowCrash), auearlyboot, then **launchd_cache_loader: `abort: Unable to find AMFI`** -> 2.7 GB core written to /cores in 91 s -> launchd panic `launchd_cache_loader[22] exited -- exit reason namespace 7 subcode 0x1`. launchd_cache_loader: SecStaticCodeCheckValidity of /System/Library/xpc/launchd.plist with detached .sig, then IOServiceMatching("AppleMobileFileIntegrity") + IOServiceOpen type 0 + IOConnectCallMethod sel 6 (1 scalar = 1, struct in = cdhash) = trust the cdhash, then sends the cache to launchd. Boot-arg `launchd_unsecure_cache=1` skips signature + AMFI ("Using unsecure cache"); the value is parsed with strtoul base 10 (helper 0x100002da8), so a path = 0 = off: boot 0039w (18:17:13 UTC, `=/System/Library/xpc/launchd.plist`, photo IMG_20261016_202008) still aborted `Unable to find AMFI` (core dump now skipped: `Failed to generate core file ... error 14`, so 0039 works). Image `shim/out/shim-boot-0039u.img` uses `launchd_unsecure_cache=1`. Patch **0039**: do_coredump = 0 on SWEET (kern.coredump sysctl still works); CI `38945267341` -> `xnu/out-0039` (_do_coredump now in __common). Image `shim/out/shim-boot-0039w.img` = 0039 + sweet-0038hi.adt + ufsrw rootrw + `launchd_unsecure_cache=/System/Library/xpc/launchd.plist`. TODO later: real AppleMobileFileIntegrity IOService (sel 6 trust cdhash etc.).
- **Image v3 ready, awaiting user "flash".** Boot 0038w 17:38:10 UTC, photo (chat image 30): `SWEET AKS: keybagd sel 0 -> 0x0`, `sel 14 out 1/0 -> 0x0` (x2), `MKB_INIT: mount is with NO CPROTECT ... does not support Data Protection`, `System Keybag loaded`; then keybagd still opens /private/var/keybags/systembag.kb (0x100012d3c, for BackupKeyBagKeys) -> ENOENT, `no-effaceable-storage` not set -> `Can't load the keybag. tears in rain... Time to die` -> `FATAL KEYBAG ERROR: kb_load` -> reboot -> Halt/Restart Timed Out panic. Fix: ADT `/defaults/no-effaceable-storage` (mkadt.py; `shim/out/sweet-0038hi.adt`, `research/q0038-hi.adt`, QEMU OK) + file `/private/var/keybags/systembag.kb` (0600 root, dir 0700; XML plist {KeyBagKeys: data}). **v3 image** `/run/media/dipa/android/vmios-ipsw/ios16-root-20H392-v3.img` = v2 + that file, fsck OK, SHA256 fa84274c...22df; `ios16-root-20H392-v3.simg` (img2simg: zero blocks become FILL chunks, so a full flash overwrites every block the rw boots changed). Flash: `fastboot -S 512M flash userdata ios16-root-20H392-v3.simg`, then boot `shim/out/shim-boot-0038e.img` (0038 + sweet-0038hi.adt + ufsrw=1 rootrw=1).
- **0038 AppleKeyStore (CI 38938744130 PASSED -> `xnu/out-0038`; QEMU msgbuf: `SWEET AKS: AppleKeyStore registered (no passcode, unlocked)`; phone image `shim/out/shim-boot-0038w.img` booted 17:38:10 UTC, `research/boot0038w.log`, photo pending).** QEMU full kernel log trick (fb.txt is only the last screen): `llvm-nm KERNEL | grep _msgbufp` -> `--hmp "x /1gx ADDR"` gives struct msgbuf address (static, 0xfffffe0007b56678 on 0038) -> `--hmp "x /3gx STRUCT"` gives bufc (3rd quad) -> `--hmp "memsave BUFC 0x20000 \"FILE\""` (quote the file name), `tr -d "\0" < FILE`. Same inputs give the same addresses. Boot 0037w 17:08:35 UTC, photo IMG_20261016_191052: bindfs fixed mount; mount-phase-1/2 pass; `cc_fips_test` boot task: all corecrypto FIPS POST tests PASSED in userspace; then keybag boot task `keybagd --init`: `MKB_INIT: FATAL KEYBAG ERROR: failed to load system bag`, `Could not get options entry from the device tree` (x2, IODeviceTree:/options = NVRAM, non-fatal), `REBOOTING INTO RECOVERY MODE` -> reboot -> panic `Halt/Restart Timed Out @IOPlatformExpert.cpp:884` (no restart path on SWEET).
  - keybagd (static libaks): load_devicebag (0x100012c30) calls aks_get_system (sel 14, 0-1 scalar in, 1 out) and loads /private/var/keybags/systembag.kb only if the result is 0xe00002f0 (NotFound); any other error -> fatal; SUCCESS -> skip the file (userspace-reboot path). systembag.kb is a plist {KeyBagKeys}; decrypted with effaceable storage unless IODeviceTree:/defaults has `no-effaceable-storage`. Image has no /private/var/keybags. has_data_protection: statfs of /private/var; no cprotect on our HFS -> device-bag volume mapping skipped.
  - libaks connection: IORegistryEntryFromPath / IOServiceMatching("AppleKeyStore"), IOServiceOpen type 0, then selector 0 (no args) must succeed.
  - **AppleKeyStore selector map (iOS 16.7 AppleKeyStore.framework, via `ipsw dyld disass`):** 0 open, 2 create_bag, 3 save_bag, 4 unload_bag, 5 set_system_with_passcode, 6 load_bag, 7 get_lock_state (1 in, 1 out; bit 2 = unlocked since boot), 9 unlock_device, 10 wrap_key, 11 unwrap_key, 12 unlock_bag/test_stashed_kek, 13 lock_bag, 14 get_system, 15 change_secret_se, 16 internal_state, 17 get_device_state (1 in, struct out <=4K: DER SET of SEQUENCE{UTF8 key, INTEGER}: ss state, sls lock_state (MKBGetDeviceLockState returns it), sb backoff, sbo, sfa failed attempts, sfao, sgs generation, sas assertions, sgpe grace, srcd countdown, sr reserved), 18 recover_with_escrow_bag, 19 obliterate_class_d, 20 drain_backup_keys, 21/22 set/clear_backup_bag, 23 get_bag_uuid, 24 rewrap_key_for_backup, 26/27 assert_hold/drop, 30/31 set/get_configuration, 33-37 stash, 38 auth_token_create, 40 generation, 41 fdr_hmac_data, 42 verify_password, 43 _aks_operation, 44 remote_session, 49/50 signing keys, 51/53/54 stash enable/persist/escrow, 55 unload_session_bags, 57/58 remote peer, 59-62 smartcard, 63 migrate_s_key, 65 set_keybag_for_volume_with_cookie_persona, 66/67 sync bags, 68 copy_volume_cookie_persona, 69-73 se_*, 74-79/84/85/99 fv_* (FileVault/VEK), 80/81 absinthe, 82 make_public_backup_bag, 83 drop_auxiliary_auth, 86 kext get/set options, 87 invalidate_bag, 88-91/94/95/106/107 se_*, 92 lower_iteration_count, 93 get_internal_info, 96-98/117 keybag_persona create/list/delete, 100/101 assert promote/consume, 102/103 notify_state set/is_set, 104 fairplay, 105 change_secret_epilogue, 108 delete_xart_leak, 110-113 backup volume, 114 sealed_hashes_set, 115 prewarm_sps, 118-128 AKSIdentity*/AKSGetLastUser.
  - Patch **0038**: `iokit/Kernel/arm/SweetKeyStore.cpp` (class AppleKeyStore on IOResources, IOUserClientClass AppleKeyStoreUserClient; personality in KernelConfigTables.cpp): 0/4/5/9/12/13/26/27/55/102 success, 14 -> handle 0, 7 -> 0x4, 17 -> DER state (ss 4, sls 0), others kIOReturnUnsupported; logs `SWEET AKS: <proc> sel N arg0 in a/b out c/d -> ret` for every call.
  - Tools: shared cache copied to `research/dsc/` (git-ignored; ipsw needs a writable dir for its .a2s symbol cache); `ipsw dyld disass research/dsc/dyld_shared_cache_arm64 --image AppleKeyStore|MobileKeyBag`; scratchpad `annot2.py BIN DIS FIXUPS` annotates llvm-objdump output with strings and import names (`ipsw macho info --fixups`).
- **0037 bindfs (phone boot 0037w pending photo).** Boot 0036mw 16:57:47 UTC, photo IMG_20261016_190102: WRITABLE ROOT WORKS: `/dev/ufsroot0 on / (hfs, local, noatime)` after mount_hfs update (GetMasterBlock EBUSY harmless), coredump of mount written to /cores (rw). Then `mount: failed to mount /private/preboot/5CBE3601.../usr/standalone/firmware -> ...: Operation not supported by device (19)` -> exit 74 -> launchd panic `mount[2] exited`. Cause: the macOS-derived config had nullfs but no bindfs (ENODEV = unknown fs type). Caller passes env 0 -> bind not required, ENOENT (missing source dir) tolerated. Patch **0037** adds `bindfs` to FILESYS_BASE in MASTER.arm64.sweet; CI `38936550483` -> `xnu/out-0037` (bindfs_vfsops present; QEMU probe regression OK). Image `shim/out/shim-boot-0037w.img` (0037 + sweet-0036hi.adt + ufsrw=1 rootrw=1) booted 17:08:35 UTC (`research/boot0037w.log`). NOTE: userdata has now been modified by rw boots; it no longer equals the v2 image, so sparsediff with v2 as OLD is not safe any more (full reflash or a new baseline needed).
- **0036 phone: launchd boot tasks run; mount -P 1 needs /chosen/boot-manifest-hash.** Boot 0036hr 16:15:32 UTC, photo IMG_20261016_185236: platform check passes; fsck boot task runs (`fsck: not booting main or diagnostic OS. Skipping fsck on OS container`); mount-phase-1: `failed to get filesystem info` x2 (no IODeviceTree:/filesystems/fstab, non-fatal), `mount: data volume missing, but not required in env: 0`, mount_hfs update of /: `GetMasterBlock: Error 16 opening /dev/ufsroot0` (EBUSY, mounted block dev, non-fatal) then mount() EROFS (read-only boot) -> `mount: / failed with 1`; then `failed to get boot-manifest-hash` -> errx exit 66 -> launchd panic `mount[3] exited`. /sbin/mount: fn 0x100005f90 reads IODeviceTree:/chosen boot-manifest-hash (hex), bindfs-mounts /private/preboot/<HEX>/usr/standalone/firmware (ENOENT tolerated unless required). `tools/mkadt.py` now adds `boot-manifest-hash` = SHA-384("sweet boot manifest") (5CBE3601...5205). ADTs `shim/out/sweet-0036hi.adt`, `research/q0036-hi.adt` (QEMU probe OK, csops 0x26000001). Image `shim/out/shim-boot-0036mw.img` (0036 + new ADT + ufsrw=1 rootrw=1), booted 16:57:47 UTC (`research/boot0036mw.log`): FIRST WRITABLE BOOT of userdata (restore source: v2 image on SSD).
- **0036 CS_SIGNED (phone boot 0036hr pending photo).** Phone boot 0035hr 2026-10-16 15:57:02 UTC (`research/boot0035hr.log`, photo IMG_20261016_180249): highmem works on hardware; shared cache maps (trust-cache warnings only), Apple launchd runs (`Darwin Bootstrapper Version 7.0.0`, `entering ondemand mode`), starts boot task fsck, then userspace panic `boot task is not a platform binary (fsck, /sbin/fsck)`. launchd+0x3fea0: `csops(pid, CS_OPS_STATUS)` must have bit 0x04000000. Cause: nothing set CS_SIGNED (AMFI does it in vnode_check_signature), so csproc_get_blob() returns NULL for every process and csops never reports CS_PLATFORM_BINARY (also breaks per-process cdhash/entitlement queries). QEMU probe init (`csops` status printer, scratchpad csq/) on 0035: `0x02000001`; patch **0036** (`*cs_flags |= CS_SIGNED` in the SWEET AMFI hook), CI `38929635791` -> `xnu/out-0036`: `0x26000001`. Images `shim/out/shim-boot-0036hr.img` / `-0036hw.img` (same cmdlines as 0035). 0036hr booted 16:15:32 UTC (`research/boot0036hr.log`). Next launchd boot tasks (embedded __config plist): fsck -qL and mount -P 1/2 (RequireSuccess); no /etc/fstab on the image.
- **0035 ENTITLEMENTS + PLATFORM BINARIES (QEMU verified).** `xnu/patches/0035-sweet-amfi-entitlements-platform-binaries.patch`: new `iokit/Kernel/arm/SweetEntitlements.cpp` (OSObject subclass: OSDictionary from OSUnserializeXML of the signature's XML entitlements + original XML for CS_OPS_ENTITLEMENTS_BLOB); `bsd/kern/sweet_amfi.c` answers queryEntitlementBoolean/String(+WithProc, string also matches array members), copyEntitlementAsOSObject(+WithProc, retained), asdict (retained), get_xml (kalloc_data copy); built-in MAC policy "SWEET AMFI" (registered from bsd_init before vfs/exec) with mpo_vnode_check_signature: every signed binary on the MNT_ROOTFS mount gets CS_PLATFORM_BINARY (stand-in for AMFI's static trust cache: iOS system binaries are ad-hoc, cd_flags 0x2, platform byte 0), and attaches entitlements ONLY for the writable copy (cs_blob != csb_ro_addr; revalidation passes the RO blob). LESSON: first version attached in adjustContextWithoutMonitor -> QEMU `unable to adjust OSEntitlements context without monitor: 53` because ubc_cs_convert_to_multilevel_hash (4K-page signatures on 16K kernel) sets csb_entitlements_blob = NULL; ALL iOS 16 binaries (launchd, backboardd, SpringBoard) use 4K code pages, so this would have broken launchd on the phone. Boot-arg `sweet_amfi_debug=1` logs `SWEET AMFI: <ident>: N entitlements (test: ...)`. `tools/mkinit.py OBJ OUT [ENTS.plist]` adds an XML entitlements blob (special slot -5; default output byte-identical). QEMU `research/q0035-ent` (RAM disk `research/root-hfs-ent.img`, init with 3 test entitlements, highmem): `org.sweet.init: 3 entitlements (test: bool 1 string 1 array 1)` then init PID 1. MAC policies loaded: 0034 = 1, 0035 = 2 (QMP `mac_policy_list`). CI `38909807230` -> `xnu/out-0035`. Phone images: `shim/out/shim-boot-0035hr.img` (highmem, ro), `-0035hw.img` (highmem, +ufsrw=1 rootrw=1), `-0035r.img` (low mem fallback).
- **PHONE TEST ORDER (updated):** 0035hr -> if instant reset, 0035r -> then 0035hw.

- **HIGHMEM: XNU in the upper DDR bank, ~3.95 GiB (was 1.2 GiB).** Live FDT memory = <0x80000000 2G> + <0x1_00000000 0xfcc00000>; all fixed reserved-memory carve-outs are in the low bank (highest: ramdump_fb 0xaf000000, rmtfs ~0xfde01000), dynamic pools have alloc-ranges <= 0xffffffff, UFS node has no `iommus` (Linux DMAs anywhere). `tools/mkadt.py --highmem` sets /chosen dram-base 0x100000000 dram-size 0xfcc00000; `tools/mkpayload.py` now takes phys_base/mem_size from the ADT (default payloads byte-identical, verified); `tools/qemu-sweet.py` sizes -m from the payload (8G for highmem). Patch **0034** (`0034-sweet-ufs-dma-above-4g.patch`): UFS refuses DMA memory above 4G without UFSHCI CAP.64AS (bit 24), logs `DMA at 0x...`. CI `38905889883` success -> `xnu/out-0034`. **QEMU verified** (`research/q0034-hi`, ADT `research/q0034-hi.adt` --qemu --highmem, HFS RAM disk): phys_base 0x100000000, init PID 1 heartbeat, no panic; `max_mem` = `mem_size` = 0xfcc00000 read via QMP (`research/q0034-hi-mem`). Phone images: `shim/out/shim-boot-0034hr.img` (read-only) / `-0034hw.img` (+ufsrw=1 rootrw=1), ADT `shim/out/sweet-0034hi.adt` (asmb SIP + sweet-ufs + highmem). PHONE RISK: unknown runtime TZ/XPU protection in the upper bank would show as an instant reset; fall back to 0033r/w. Watchdog ruled out for the overnight reset: msm-watchdog bark is 20 s (qcom,bark-time 0x4e20) yet panic screens stay up for many minutes.

- **Offline research 2026-10-16 (user away, phone unavailable). Images rebuilt** `shim/out/shim-boot-0033r.img` / `-0033w.img` now also carry `wdt_test=no_user_checkin`. NEXT ON PHONE: boot 0033r (expect past in6_nigroup), then 0033w (first writes: rw root fixes HFS link-chain bits itself and gives /var for launchd sockets /var/run/syslog, /var/run/lockdown.sock).
- **launchd.plist** (`/System/Library/xpc/launchd.plist`, compiled; 532 daemons, 66 RunAtLoad/KeepAlive, list in scratchpad `early-daemons.txt`). `_PanicOnCrash` daemons: containermanagerd/usermanagerd (InternalOnly), lockdownd/remoted/trustd/remotepairingdeviced (AutomationOnly), **watchdogd unconditional** (KeepAlive SuccessfulExit=false). watchdogd needs IOKit `IOWatchdog` kext service; if absent it exits only when `kern.hv_vmm_present` (ADT `/defaults/vmm-present`, hvg_sysctl.c) or with boot-arg `wdt_test=no_user_checkin` ("detected testing boot-args to not run, exiting"; reads kern.bootargs). Using the boot-arg (vmm-present would change many daemons; keep as an option).
- **GUI path research (QuartzCore in the shared cache, `ipsw dyld str CACHE STR`, ~10 s/search):** CA::WindowServer has IOMFBServer/IOMFBDisplay (Apple DCP/IOMobileFramebuffer), AppleCLCDDisplay, AppleRGBOutDisplay, **VirtualServer/VirtualDisplay** and **MemorySurface**, EAGLServer. Renderers: CA::OGL::MetalContext, GLContext and a **CPU software rasterizer CA::OGL::SW** (samplers/blend modes; "image is too large for software renderer"). Env knobs: `CA_ENABLE_OGL`, `CA_DISPLAY_TYPE`, `CA_FORCE_LOCAL_SERVER` (249 CA_* vars). Hypothesis (unverified): backboardd's render server could run a VirtualServer/MemorySurface with the SW renderer and we copy the surface to the ABL framebuffer -> needs disassembly of CA::WindowServer server creation. Expected other GUI walls: IOSurface (closed-source kext; needs a reimplementation), IOMobileFramebuffer user client, IOHID touch events, AppleKeyStore/keybag (SEP) for lock state, MobileGestalt answers (AppleCLCD etc.).

- **0032r RESULT (boot 05:07:50 UTC, `research/boot0032r.log`, photo IMG_20261016_071200): SHARED CACHE MAPPED, LAUNCHD RUNS.** With SIP relaxed (ADT asmb) the `not in trust cache` lines are only warnings for every subcache (.31 ... .42.dyldlinkedit); no SIP rejection; libSystem loads; launchd configures networking (`skip attaching fsw to lo0 using legacy TX model`) -> kernel data abort far 0x28 in `SHA1Init` (symbolized as sha1_init) from `in6_nigroup` (IPv6 on lo0): g_crypto_funcs NULL. Kernel addresses are unslid: `~/swift/usr/bin/llvm-symbolizer --obj=KERNEL ADDR` works directly.
- **0032** BearSSL SHA-1 (`0032-sweet-bearssl-sha1.patch`), **0033** BearSSL SHA-384/512 (`0033-sweet-bearssl-sha384-sha512.patch`, BearSSL ctx stored in SHA512_CTX, static-asserted to fit; ubc_subr.c uses SHA-384 for code directories). `0020-stage-bearssl.sh` now also stages hash/sha1.c, hash/sha2big.c, codec/{dec,enc}{32,64}be.c. CI `38854909053` success (0032-only run `38854802073` superseded). Kernel `xnu/out-0033` (SHA1Init -> _br_sha1_init verified by disassembly; nm symbols have a leading underscore). Images (ADT sweet-0032): `shim/out/shim-boot-0033r.img` (read-only), `shim-boot-0033w.img` (+ufsrw=1 rootrw=1). Still NULL g_crypto_funcs users: des, chacha20poly1305, rsa, aesxts, rand, flow_divert.
- `research/check-patch-order.py` now skips patches touching CI-staged sweet_hfs sources (0031) instead of stopping.

- **0031r RESULT (boot 05:03:52 UTC 2026-10-16, `research/boot0031r.log`, photo IMG_20261016_070508): SHARED CACHE FOUND.** dyld now opens `dyld_shared_cache_arm64` (v2 image hard links), kernel refuses to map it: `shared_region: ... map(...'dyld_shared_cache_arm64'): not in trust cache` -> `vnode is not SIP-protected` (vm_unix.c: macOS arm64 path needs trust cache, else root-owned + SF_RESTRICTED unless CSR_ALLOW_UNRESTRICTED_FS) -> `dyld cache '(null)' not loaded: syscall to map cache into shared region failed` -> libSystem not loaded -> coredump to /cores fails error 30 (EROFS) -> panic initproc failed -> "MACH Reboot" (spins; screen kept). Lots of `hfs: set hardlink bit on vol=iOSRoot cnid=... linkid=...` spam (Linux-made hard links lack the link-chain bit; read-only mount cannot persist the fix). FIX: ADT `/chosen/asmb` with `lp-sip0`=0x6f (u64; incl. CSR_ALLOW_UNRESTRICTED_FS) and `lp-sip1`=1 (unauthenticated root), `tools/mkadt.py` -> `shim/out/sweet-0032.adt`. Images with kernel 0031: `shim/out/shim-boot-0032r.img` (read-only) and `shim-boot-0032w.img` (+ufsrw=1 rootrw=1).

- **2026-10-16 morning:** userdata now = **v2** image (`diff-v1-v2.simg` flashed 21:06:50 UTC 2026-10-15, OKAY, `research/flash-userdata-diff-v2.log`); future diffs use `ios16-root-20H392-v2.img` as OLD. Booted `shim-boot-0029k.img` (ignition_level=1) right after (`research/boot0029k-v2.log`); **no photo** (user asleep). Next morning the phone was in PixelOS recovery = some hardware reset (ABL then booted Android, which cannot use userdata). OBSERVATION: our kernel cannot reset the SoC itself (`PE_halt_restart` is never set; reboot/halt print "MACH Reboot"/"CPU halted" and spin), so the reset came from outside XNU: Qualcomm watchdog or a TZ/XPU violation. Unknown which; re-boot 0029k and watch/video until the reset. Do NOT tap factory reset/format data in recovery (would wipe the iOS image).
- **0030** (`xnu/patches/0030-sweet-ufs-writes.patch`, CI `38852655542`): UFS WRITE(10) + read-modify-write for partial 4 KiB blocks + SYNCHRONIZE CACHE (DKIOCSYNCHRONIZE), only with boot-arg `ufsrw=1`; `ufs_write_blocks` re-checks partition bounds before every write (only place data goes out).
- **0031** (`xnu/patches/0031-sweet-read-write-root.patch`, CI `38852837176`): boot-arg `rootrw=1` clears MNT_RDONLY before the root mount (no data volume on sweet: /private/var is on the root; image has no /etc/fstab); Apple HFS accepts a dirty non-journaled ROOT read-write on SWEET (logs "mounting dirty non-journaled root read-write"). Later: journaled HFS for crash safety. Kernel `xnu/out-0031` (CI `38852837176` success, 5m31s; 0030 run cancelled by the newer push). Boot images (phone ADT `sweet-0028.adt`, ramdisk byte-matched): `shim/out/shim-boot-0031r.img` = 0029k args (read-only, ignition_level=1) and `shim/out/shim-boot-0031w.img` = same + `ufsrw=1 rootrw=1`. PLAN: boot 0031r first and film until the reset (diagnose overnight reset), then 0031w (first ever writes to userdata; v2 image on the SSD is the restore source). `research/check-patch-order.py` cannot check 0031 (staged sweet_hfs files are not in its index); CI stage scripts run first, so CI is the check.

- **ignition_level=1 result** (boot 21:01:39 UTC, `research/boot0029k.log`, photo IMG_20261015_230308): preboot/cryptex stages skipped (need >= 2/3), `dylib_cache: finding shared cache on system volume: ignition level = 1, search root fd = 4, subpath = System/Library/Caches/com.apple.dyld/` -> not found -> `ignition boot failed: 19` -> no shared cache -> libSystem not loaded. FIX IN PROGRESS: image v2 = copy of the flashed image + `/System/Library/Caches/com.apple.dyld/` with HARD LINKS to the 44 cryptex cache files (no extra space; avoids symlink-following doubts), then `tools/sparsediff.py ios16-root-20H392.img ios16-root-20H392-v2.img diff.simg` and flash only the diff. Boot with `ignition_level=1` (shim-boot-0029k.img).
- **ignition_level=0 result** (boot 20:58:07 UTC, `research/boot0029j.log`, photo IMG_20261015_230037): all stages skipped as "ignition level insufficient" (hello/preboot/cryptex1 sniff >= 2, select os cryptex path/graft >= 3, **dyld_cache >= 1**), `ignition boot failed: 89`, "ignition partially disabled", then same `Library not loaded: /usr/lib/libSystem.B.dylib (no such file, no dyld cache)`. => dyld gets the shared cache directory from ignition's dyld_cache stage. Next: `ignition_level=1` (`shim/out/shim-boot-0029k.img`) to skip preboot/cryptex stages but run dyld_cache; its log "finding shared cache on %s ... subpath = %s" will show where it searches. If it searches rootfs /System/Library/Caches/com.apple.dyld, add a symlink there (image rebuild; consider a diff-only sparse flash tool to avoid rewriting 12 GB).
- **APPLE dyld/launchd RUNNING (libignition) with `unentitled_ios_sim_launch=1`** (boot 20:53:24 UTC, `research/boot0029i.log`, photo IMG_20261015_225617): kernel prints "Allowing spawn of iOS binary ... boot-arg set to true"; `shared_region: ... check_np ... vm_shared_region_start_address() failed` (no region yet, normal); dyld's built-in **libignition** (Darwin Ignition Sequence 1.0.0, libignition-51~1974; prints rd=ufsroot0, hardware target sweet, ignition level 0x5, platform 0x2, boot spec local, 7 stages): `hello from launchd.1` -> `preboot: mounting preboot` -> `failed to lookup preboot: 25` (ENOTTY: looks for a separate Preboot volume by role) -> ignition fails -> dyld `Library not loaded: /usr/lib/libSystem.B.dylib ... (no such file, no dyld cache)` -> launchd exit -> panic initproc failed. dyld boot-args found via strings: `ignition_level`, `ignition_force_dylib_root` (forced rootfs/livefs/cryptex fallback), `ignition_halt_after`, `ignition_live_app_graft`; dyld cache search paths include /System/Cryptexes/OS, /System/Volumes/Preboot/Cryptexes/OS/, /private/preboot/Cryptexes/OS/ (present in our image). Next try `ignition_level=0` (`shim/out/shim-boot-0029j.img`).
- **APPLE launchd EXECUTED FROM UFS (2026-10-15).** Flashed iOS image: `img2simg` -> `ios16-root-20H392.simg` (12.1 GB) then `fastboot -S 512M flash userdata ...simg` (24 chunks, 307 s, `research/flash-userdata-ios16.log`; a raw-image flash was killed by earlyoom at 2.6 GB RSS - always flash the sparse image). ABL fastboot hung on getvar after the flash; power+vol-down fixed it. Boot 0029u 20:49:04 UTC (`research/boot0029u-ios16.log`), photo IMG_20261015_225134: `hfs: mounted iOSRoot` -> load_init_program /sbin/launchd -> panic `unexpected SIGKILL of launchd (CS_KILLED) with reason -- namespace 9 code 0xe` = OS_REASON_EXEC / EXEC_EXIT_REASON_WRONG_PLATFORM: our kernel is XNU_TARGET_OS_OSX, iOS-platform binaries are "alien" and refused unless spawn attr platform set or DEVELOPMENT TUNABLE `unentitled_ios_sim_launch`. Next try: same kernel, cmdline + `unentitled_ios_sim_launch=1` (`shim/out/shim-boot-0029i.img`). LONGER TERM: macOS-config kernel marks iOS maps alien (vm_map_mark_alien) and differs from iOS in many policies; an iPhoneOS-config kernel build may eventually be needed.
- **iOS 16 ROOT IMAGE BUILT:** `/run/media/dipa/android/vmios-ipsw/ios16-root-20H392.img` (16 GiB case-sensitive HFS+, label iOSRoot, 12 GB used, fsck OK after `fsck.hfsplus -y` rewrote 32 non-ASCII localized WorkflowKit Shortcut names Linux decomposes differently). Built by `tools/mkiosroot.sh OS.dmg SYSTEMOS.dmg APPOS.dmg OUT.img [SIZE]` (needs sudo; apfs-fuse as root; OS dmg is UDIF -> link must end .dmg). Contents: iPhone X 20H392 OS root + SystemOS cryptex at /private/preboot/Cryptexes/OS (so /System/Cryptexes/OS -> cache, 44 files, dyld_v1 arm64) + AppOS at .../App. /sbin/launchd and /usr/lib/dyld root:wheel 0755. NEXT: (confirm) `fastboot flash userdata ios16-root-20H392.img` (auto-sparse), boot 0029u (rd=ufsroot0) -> Apple launchd attempt.
- **MILESTONE ON HARDWARE: BOOT FROM INTERNAL FLASH.** 0029 CI `38797924912` PASSED, `xnu/out-0029` SHA256 `a68bc847...2a37`. Image `shim/out/shim-boot-0029u.img` (payload-0029u = 0029 kernel + `shim/out/sweet-0028.adt` + `rd=ufsroot0`, NO RAM disk). Boots 20:01:34 and 20:12:37 UTC (`research/boot0029u*.log`), photo IMG_20261015_221403: `SWEET UFS: "userdata" on LUN 0: first block 0x2b8c00, 109643 MiB, read-only` -> `BSD root: ufsroot0, major 1, minor 0` -> `hfs: mounted SweetRoot on device b(1, 0)` -> `SWEET: root volume is not authenticated (error 25); continuing unsealed` -> `load_init_program ... /sbin/launchd` -> `*** SWEET userspace: init running as PID 1 ***` -> heartbeat (ran for minutes unattended). userdata currently holds the 8 MB `research/root-hfs.img`. NEXT: build a multi-GB HFS+ image with the iOS 16 (iPhone X 20H392) userland (OS rootfs + SystemOS cryptex contents incl. dyld shared cache at /System/Library/Caches/com.apple.dyld; preserve modes/owners/symlinks; decompress LZBITMAP via apfs-fuse), flash it to userdata (sparse, needs user OK), then try Apple's dyld/launchd. Driver is read-only (root mounts RDONLY), fine for first launchd attempts.
- **userdata FLASHED with the 8 MB HFS test volume** (user said "flash it", 2026-10-15 19:53:17 UTC, `research/flash-userdata-hfs-test.log`: `fastboot flash userdata research/root-hfs.img` OKAY; pre-checks: one sweet device, partition-size:userdata 0x1AC4BFB000, partition-type f2fs, image fsck OK, SHA256 3626ea69...). Android userdata is now destroyed (expected/approved). Boot 0028u at 19:53:20 (`research/boot0028u-hfs.log`), photo IMG_20261015_215541: `BSD root: ufsroot0` -> **`hfs: mounted SweetRoot on device b(1, 0)` from internal UFS** -> panic `rootvp not authenticated after mounting @bsd_init.c:931` (arm64 macOS-config requires FSIOC_KERNEL_ROOTAUTH sealed root for non-ramdisk roots). Patch **0029** (`dd1c284`): SWEET logs `SWEET: root volume is not authenticated (error N); continuing unsealed` instead of panicking (Apple configs keep the panic; pivot_root still requires auth). CI **`38797924912`** running. Next: download out-0029, phone image with sweet-0028.adt + rd=ufsroot0 (no RAM disk), boot -> expect init from UFS.
- **UFS ROOT DRIVER VERIFIED ON HARDWARE (read-only).** 0028 CI `38796139570` PASSED, `xnu/out-0028` SHA256 `8b981640...9da6`; QEMU HFS RAM-disk regression `research/q0028-hfs` still runs init. Phone boot 2026-10-15 19:50:24 UTC (`research/boot0028u.log`, image `shim/out/shim-boot-0028u.img`, phone ADT `shim/out/sweet-0028.adt` with /sweet-ufs, NO RAM disk, `rd=ufsroot0`), photos IMG_20261015_215151/215220: `SWEET UFS: "userdata" on LUN 0: first block 0x2b8c00, 109643 MiB, read-only` -> `BSD root: ufsroot0, major 1, minor 0` -> `hfs_ValidateHFSPlusVolumeHeader: unknown Volume Signature : f188` (Android-encrypted data, as expected) -> `cannot mount root, errno = 19`, kernel retries mountroot (no panic). Nothing written to flash. NEXT (destructive, needs user confirmation right before): `fastboot flash userdata research/root-hfs.img` (8 MB HFS with test init) then boot rd=ufsroot0 -> expect init from internal flash.
- **PATCH 0028 (`33aceac`): XNU read-only UFS root device**, CI **`38796139570`** running (next artifacts xnu/out-0028, research/bt29, run29.log). `bsd/dev/sweet_ufs.c`: reuses ABL's UFSHCI state (like the shim probe), takes over UTRL at a kmem_alloc_contig region (DMA layout: UTRL 0x0, UCD 0x1000, 1 MiB bounce 0x4000), verifies UTRLBA readback before any doorbell, IE=0 polled, one SCSI cmd at a time on LUN0 (TUR x3, READ(10) via bounce, PRDT 256 KiB chunks), flush_dcache64 by PA around each command (host not dma-coherent per DT), finds GPT partition by name (`ufsroot=` boot-arg, default `userdata`), exposes `/dev/ufsroot0`/`rufsroot0` (512-byte logical sectors, physical 4 KiB, DKIOC* ioctls), refuses writes (EROFS). IOKitBSDInit: `rd=ufsroot0` -> sweet_ufs_rootdev() (lazy init) else panic. ADT: `tools/mkadt.py` adds `/sweet-ufs` reg <0x1d84000 0x3000> for the PHONE only (not --qemu). Local compile OK, imports resolve. Sandbox research/bt28 (pre0028 originals). FIRST PHONE TEST PLAN (non-destructive): boot 0028 with phone ADT + `rd=ufsroot0` and NO RAM disk: expect `SWEET UFS: "userdata" on LUN 0: first block 0x2b8c00, 109643 MiB` + `BSD root: ufsroot0`, then root mount failure (userdata is still Android-encrypted) -> panic. That validates the driver before flashing an HFS image into userdata (needs explicit user confirmation at that time).
- **SUPERSEDES the 64 GiB iosroot GPT plan: user said "u can delete android" (2026-10-15).** Use the existing `userdata` partition (LUN0 sda34, 4K LBA 0x2B8C00, 0x1AC4B MiB ~107 GiB) directly as the iOS root: NO GPT changes. Keep bootloaders, recovery (OrangeFox), modem/persist/fsg/modemst untouched. Write the HFS image later with `fastboot flash userdata` (sparse, auto-split under the 768 MiB limit). Android will no longer boot normally (expected; reinstallable). Order: XNU UFS driver first, read-only against the current GPT; flash only once it can locate userdata. Nothing erased yet.
- **DECIDED (user, 2026-10-15): 64 GiB `iosroot` on LUN0 (sda), taken from userdata (wipes Android user data; Android/super kept).** Planned GPT (4K LBAs): userdata 0x2B8C00..0xD7D6FF (~43 GiB, keep type/unique GUIDs and attributes); iosroot 0xD7D700..0x1D7D6FF (0x1000000 blocks = 64 GiB, 1 MiB aligned); backup GPT area unchanged. Procedure: user backs up phone data -> boot OrangeFox recovery (adb) -> back up GPT (sgdisk --backup + raw dd of LBA 0-5 and last 6 blocks) to research/ -> sgdisk edit -> Format Data -> verify Android boots to setup. NOT EXECUTED YET.
- **INTERNAL UFS WORKS FROM THE SHIM (read-only), user authorized internal-UFS approach incl. flashing (2026-10-15, "i allow everything").** Shim probe `shim/ufs.c` (commit `12ed3ed` + filter): ufshc@1d84000 is UFSHCI 2.1 (ver 0x210, cap 0x1587031F, 32 slots), ABL leaves HCE=1, HCS=0x10F (device present, lists ready, UIC ready); probe takes over UTRL at its own buffer (verifies UTRLBA readback before any doorbell), TEST UNIT READY/READ CAPACITY/READ(10) all succeed. LUN0 = 0x1D7D800 x 4 KiB (~126.6 GB), valid GPT (64 entries at LBA 2). Photos IMG_20261015_212916/213325/213429. Big LUN0 partitions (start in 4K LBAs / MiB): super 0xCA00/0x2200 (8.5 GiB), logdump 0x22CA00/64, minidump 0x230A00/128, rawdump 0x238A00/128, recovery 0x240C00/128, cache 0x248C00/384 ext4, exaid 0x260C00/384, cust 0x278C00/1024 ext4, **userdata 0x2B8C00/0x1AC4B MiB (~107 GiB), fs unreadable = encrypted (metadata encryption)**. cache..cust contiguous = only 1.75 GiB (too small for iOS ~10+ GiB). Plan needing user consent: shrink userdata in GPT (wipes Android data) and add an `iosroot` partition at the end of LUN0. LUNs 1-5 not listed yet (sdb..sdf backed up in backup/lun).
- **fastboot limit measured (2026-10-15, read-only getvar):** `max-download-size: 805306368` (768 MiB); `max-fetch-size` unsupported; `is-userspace: no` (ABL fastboot). A `fastboot boot` image (shim+kernel+RAM disk) must be < 768 MiB, so the 2.5 GiB iOS shared cache cannot ride in the boot RAM disk even if XNU gets all RAM. Real userland needs storage access (UFS driver, or USB host) or a much smaller cache. Unlocking full RAM is still needed later (GUI).
- **iOS 16 USERLAND SOURCE (Claude, 2026-10-15).** Chose **iPhone X (iPhone10,3/10,6, D22/D221AP)** iOS **16.7.16 (20H392)** over iPhone 8: same A11 (no PAC -> plain arm64, runs on Kryo 470/ARMv8.2), last iOS for A11; X userland is home-button-less and tall-screen (1125x2436 vs sweet 1080x2400), better fit for later GUI. Note the X has its OWN SystemOS cryptex (different digest from iPhone 8's). IPSW URL in `research/ipsw-x/URL.txt` (+ BuildManifest). Images on the user's external SSD (NOT in git, do not format that disk: it holds the user's photos): `/run/media/dipa/android/vmios-ipsw/iPhone10,3_16.7.16_20H392/` — `087-86593-047.dmg` = Cryptex1,SystemOS (2,743,074,816 B), `087-86698-044.dmg` = OS rootfs (4,730,814,044 B), both zip CRC-32 verified, plus Firmware/*.root_hash/.trustcache/.mtree. AppOS cryptex is 087-86715-047.dmg (10 MB, same as iPhone 8).
  - Images are raw APFS; files use LZBITMAP (decmpfs type 14). 7z cannot decode. Tools: `ipsw` 3.1.738 (AUR ipsw-bin, user-approved) needs apfs-fuse on Linux; **apfs-fuse** built in user space (system cmake broken: cmake 4.4.4 wants libjsoncpp.so.27, jsoncpp 1.9.6 installed = partial upgrade, NOT fixed) with pip cmake + `-DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DCMAKE_CXX_FLAGS="-include cstdint"`, installed to `~/.local/bin/apfs-fuse` (+apfs-dump-quick). Mount via a comma-free symlink (apfs-fuse splits options on ',' in `iPhone10,3`; exFAT has no symlinks -> put link elsewhere): `apfs-fuse LINK/087-86698-044.dmg MNT` -> `MNT/root/...`; unmount `fusermount3 -u MNT`.
  - Verified from headers: `dyld_shared_cache_arm64` magic `dyld_v1   arm64`; `/sbin/launchd`, `/usr/lib/dyld` = cputype 0x100000c subtype 0 (plain arm64). libSystem exists only inside the cache.
  - **BLOCKER for real userland via RAM disk:** shared cache = 3.10 GiB in 44 files (~2.5 GiB without the 592 MB `.symbols`), but the kernel manages only 1.20 GiB (0xb0000000..0xfd000000). Options: (A) give XNU the phone's full ~6 GB (banks 0x80000000+2G and 0x100000000+0xfcc00000, carve-out holes need pmap support) AND check fastboot max-download-size for a multi-GB boot image; (B) storage driver (Qualcomm UFS) to read a root from flash (no flashing allowed: would need a file/partition strategy); (C) run against individual dylibs extracted from the cache (uncertain).
- **MILESTONE ON HARDWARE: HFS+ ROOT FILESYSTEM -> PID 1.** Boot 2026-10-15 18:22:12 UTC (`research/boot0027b.log`, image `shim/out/shim-boot-0027b.img`), photo `IMG_20261015_202334.jpg`: `BSD root: md0` -> `hfs: mounted SweetRoot on device b(1, 0)` -> `load_init_program: attempting to load /sbin/launchd` -> `*** SWEET userspace: init running as PID 1 ***` -> repeated `SWEET init: still alive`, no panic. Kernel 0027 (built-in Apple OSS HFS + BearSSL MD5), init with SP alignment fix. NEXT: real iOS 16 userland on the HFS image (dyld, libSystem/dyld shared cache, launchd). Known gaps: entitlements (none granted), SHA-1/SHA-384/512 providers, no storage driver (RAM disk only), root mounted read-only.
- **PHONE HFS ROOT (0027) + SIGBUS ROOT-CAUSED.** Phone boot 2026-10-15 17:49:06 UTC (`research/boot0027.log`, photo `IMG_20261015_200031.jpg`): `hfs: mounted SweetRoot on device b(1, 0)` (HFS works on hardware), init printed its first line, then `pid 1 exited -- exit reason namespace 2 subcode 0xa` = SIGNAL/SIGBUS -> `initproc failed to start` panic. Diagnostic boot 18:08:13 UTC (`research/boot0027d.log`, image `shim/out/shim-boot-0027d.img`, diag init `research/diag-init` from scratch diag-init.S with [a][b][c] markers, `cs_debug=1`; photo `IMG_20261015_201547.jpg`): output `PID [a][b]` then SIGBUS -> fault at first `strb w21,[sp]`; no code-signing messages. Cause: kernel enters a static binary with sp at argc, not necessarily 16-aligned (depends on arg/apple string lengths, differs mockfs vs HFS); EL0 SP alignment check -> EXC_ARM_SP_ALIGN -> SIGBUS (sleh handle_sp_align). QEMU does not enforce SP alignment. NOT a kernel bug: real binaries start in dyld which aligns. Fix `1a8fc15`: sweet-init aligns sp at entry. Rebuilt `research/root-hfs.img`, QEMU `research/q0027-hfs2` OK. Phone image `shim/out/shim-boot-0027b.img` SHA256 `098ba46c...c5c` (payload-0027b, ramdisk match check-0027b) ready, awaiting FASTBOOT. Lesson: Assembly `;` is a comment in Apple arm64 asm (use .macro, not ;-joined #define).
- **HFS ROOT WORKS (QEMU).** 0027 CI `38779441895` PASSED, `xnu/out-0027` SHA256 `a8643886...5f6a`. QEMU `research/q0027-hfs` (RAM disk = `research/root-hfs.img`, rd=md0): `BSD root: md0` -> `hfs: mounted SweetRoot on device b(1, 0)` -> `load_init_program: attempting to load /sbin/launchd` -> `*** SWEET userspace: init running as PID 1 ***` + heartbeat, no panic. Phone image `shim/out/shim-boot-0027.img` (payload-0027 = 0027 kernel + sweet-0021.adt + root-hfs.img + rd=md0, ramdisk byte-match check-0027) ready; awaiting FASTBOOT for phone test.
- **HFS ROOT WORK (Claude), patches 0026-0027.**
  - 0026 (`f0e990c` + link fix `64c96f4`): Apple OSS **hfs-627.100.6** (commit `31d5ec238dfab485e78a9a30b8b92d13e8914f03`, paired with xnu-8796.141.3 in macos-135 release.json) staged by `xnu/patches/0026-stage-hfs.sh` into `bsd/sweet_hfs` (core + hfs_encodings; AppleKeyStore include/key prototypes guarded by CONFIG_PROTECT; SDK TargetConditionals copied). New config option `sweet_hfs` (MASTER + MASTER.arm64.sweet); 40 `optional sweet_hfs` files; Makefile.template foreach adds `_CFLAGS_ADD = -include sweet_hfs_compat.h -I...` (MUST come after kernel -D flags; compat undefs BSD/XNU_KERNEL_PRIVATE and the CONFIG_* HFS tests so kext-config.h decides: macOS profile, no content protection). `sweet_hfs_iokit.c` replaces hfs_iokit.cpp/hfs_encodings_kext.cpp: `sweet_hfs_register()` called in bsd_init after vfsinit (encodings init, vfs_fsadd VFS_TBLCANMOUNTROOT, zones, sysctls); is_ejectable 0, iterate_media none, serial KERN_NOT_SUPPORTED, OSKextGetCurrentLoadTag -> kOSKextInvalidLoadTag (renamed via compat macro). hfs_encodings' own `hfs_allocated` renamed per object (separate kexts on Apple; first CI `38777325964` failed on that duplicate at link). mockfs now validates Mach-O magic (its TODO) so non-Mach-O roots fall through to HFS (new fs entries come AFTER mockfs in vfsconf). CI `38778133720` PASSED, `xnu/out-0026` SHA256 `0b49170c...701a`, prints `SWEET HFS: hfs-627.100.6 registered`.
  - HFS+ image: `research/root-hfs.img` (8 MB, mkfs.hfsplus from AUR hfsprogs installed with user approval; loop-mounted with sudo; /sbin/launchd = research/sweet-init, /dev; fsck.hfsplus OK). QEMU `research/q0026-hfs`: `BSD root: md0` then data abort in MD5Init from hfs_getvoluuid (mount computes volume UUID).
  - 0027 (`14bf2b7`): 0020 stager also copies BearSSL hash/md5.c + codec/dec32le.c/enc32le.c; `corecrypto_md5.c` SWEET branch converts MD5_CTX <-> br_md5_context around br_md5_* calls; wrappers sweet_md5.c/sweet_dec32le.c/sweet_enc32le.c. Host test 40/40 match md5sum. CI **`38779441895`** running.
  - Local tooling: `tools/xnu-cc.py` has `XNU_CC_POST` (flags after logged ones). Sandbox `research/bt28/xnu` = 0025 CI tree + 0026/0027 edits; originals `research/pre0026`, `research/pre0027`. HFS local objects `research/hfs-objs`. Checker entries updated to bt28.
  - SHA-1 / SHA-384/512 still have no provider.
- **MILESTONE ON HARDWARE: USERSPACE PID 1 RUNS ON THE PHONE.** Boot 2026-10-15 17:16:00 UTC (`research/boot0025.log`: send OKAY0.410s, boot OKAY0.135s), image `shim/out/shim-boot-0025.img` SHA256 `9dbfa0b1...89db0`. Photo `IMG_20261015_191733.jpg`: `BSD root: md0` -> `load_init_program: attempting to load /sbin/launchd` -> `*** SWEET userspace: init running as PID 1 ***` -> repeated `SWEET init: still alive` (5 s heartbeat), no panic. Kernel 0025 + mockfs RAM disk + built-in no-entitlements AMFI. No flashing performed.
- **NEXT (toward real iOS userland):** real root filesystem with real binaries. Options: (a) build Apple OSS `hfs` (macOS 13.5 tag `hfs-627.100.6`) into SWEET like libpthread, then an HFS RAM disk image; (b) iOS 16 dyld + libSystem/dyld shared cache from the IPSW (needs APFS or repacking onto HFS). Expected hurdles: entitlements (sweet_amfi grants none), SHA-1/MD5/SHA-384/512 providers (BearSSL), missing kexts/daemons. Current init is a static test program, not launchd.
- **MILESTONE: USERSPACE RUNS (QEMU).** 0025 CI `38774788048` PASSED, `xnu/out-0025` SHA256 `5496069b...4877`. QEMU `research/q0025-rd` (150 s, no panic): `BSD root: md0` -> `load_init_program: attempting to load /sbin/launchd` -> `*** SWEET userspace: init running as PID 1 ***` -> `SWEET init: still alive` every 5 s. Exec, ad-hoc SHA-256 code signature, syscalls, devfs /dev/console, select timeouts all work. Phone image prepared: `shim/out/shim-boot-0025.img` 16,515,072 bytes SHA256 `9dbfa0b15140c0bd733a16c4f727f6a7df44a8741f98d8e266d5f2fa4f689db0` (payload-0025 = 0025 kernel + sweet-0021.adt + research/sweet-init + rd=md0; ramdisk byte-match check-0025). Waiting for user to put phone in FASTBOOT.
- **0024 CI `38773277811` PASSED**, `xnu/out-0024` SHA256 `a0ba964b...4348`. QEMU `research/q0024-rd` and **PHONE (boot 2026-10-15 17:05:55 UTC, `research/boot0024.log`, image `shim/out/shim-boot-0024.img` SHA256 `cf3dac86...6964`, 16,510,976 bytes, payload `shim/out/payload-0024.bin` = 0024 kernel + `shim/out/sweet-0021.adt` + RAM disk `research/sweet-init` + rd=md0; ramdisk byte-match `check-0024`)** agree: `Added memory device md0`, `BSD root: md0`, `load_init_program: attempting to load /sbin/launchd`, then data abort in accelerate_entitlement_queries (PC 0x...77d2458, FAR 0x1a0) = NULL AMFI interface. Photo `IMG_20261015_190715.jpg`. RAM disk root is physically verified.
- **0025 (`2518c79`)**: new `bsd/kern/sweet_amfi.c` registers a built-in AMFI interface at EARLY_BOOT/MIDDLE: no entitlements (adjustContextWithoutMonitor succeeds without creating a context, queries KERN_DENIED, copies NULL/KERN_NOT_FOUND, get_xml/transmuted false); WithMonitor KERN_NOT_SUPPORTED; OSEntitlements_query and query_context_to_object panic explicitly (CoreEntitlements closed; no kernel caller); TrustCache version 0 (0015 keys on trust_cache_rt==NULL, img4 absent -> still unavailable); CoreEntitlements table zero (PMAP_CS only). Compiles locally; checker updated (bt27 entries). CI **`38774788048`** running. Next artifacts `xnu/out-0025`, `research/bt29`, `research/run29.log`. Real iOS binaries will need real entitlements later (no OSS CoreEntitlements exists).
- **0021-0024 RAM-disk-root iteration (Claude), QEMU only so far, no new phone boot since 0020.** Each kernel tested with `tools/mkpayload.py KERNEL research/q0021.adt OUT --ramdisk research/sweet-init --cmdline "debug=0xc serial=3 cpus=1 keepsyms=1 -enable_kprintf_spam -noprogress rd=md0"` then `tools/qemu-sweet.py OUT DIR --secs 150 --kernel KERNEL --fail-on-panic` (PATH needs ~/swift/usr/bin for llvm-nm). Fresh ADTs: `research/q0021.adt` (QEMU), `shim/out/sweet-0021.adt` (phone).
  - 0021 CI `38769532000` PASSED, `xnu/out-0021` SHA256 `2b7500a1...962e`, `research/bt25`/`run25.log`. QEMU `research/q0021-rd`: md0 root, then assert `iomediaClass` in IOService::publishHiddenMedia.
  - 0022 (`20ece9c`, publishHiddenMedia without IOMedia class) CI `38770666158` PASSED, `xnu/out-0022` SHA256 `a4d0e787...30c5`, `research/bt26`/`run26.log`. QEMU `research/q0022-rd`: data abort in SHA256_Init (NULL g_crypto_funcs) from vm_kernel_addrhash_internal.
  - 0023 (`c8089d1`, libkern SHA256_Init/Update/Final use built-in ccsha256_ltc_di + ccdigest_init/update on SWEET; also serves code-signing SHA-256; SHA-1/MD5/SHA-384/512 still have NO provider - BearSSL from 0020 could supply them later) CI `38771876423` PASSED, `xnu/out-0023` SHA256 `d763fed7...1003`, `research/bt27`/`run27.log`. QEMU `research/q0023-rd`: **mockfs mounted md0, `load_init_program: attempting to load /sbin/launchd`**, then panic `mockfs_fsnode_vnode failed to create fictitious pages ... rvalue = 5` (mockfs.c:351).
  - 0024 (`3293c80`): mockfs used memdev mi_base (4K page number of a VIRTUAL kernel address for IOKit RAMDisk, truncated to 32 bits) << PAGE_SHIFT as a physical address. Now zero-copy pager mapping only when mi_phys (with 4K units); virtual md uses pagein/blockmap/strategy -> memdev bcopy. memdev's own mdPhys path assumes 4K ppnums (unsafe on 16K arm64), so do NOT switch the RAMDisk to physical. CI **`38773277811`** running. Next artifacts `xnu/out-0024`, `research/bt28`, `research/run28.log`.
  - Sandboxes: bt25/bt26/bt27 contain the next patch's edited files; pristine copies in `research/pre0022`..`pre0024`.
- **PATCH 0021 (Claude): RAM disk root via mockfs -> first userspace program.** Commits `9c37771` (initial; CI `38768500280` FAILED: mockfs_fsnode.c kfree_type(mockfs_fsnode_t) typed-alloc static assert; local xnu-cc stubs `__builtin_xnu_types_compatible` so it can't catch this) and `193772f` (fix), CI **`38769532000`** running: https://github.com/dipa-studio/vmios/actions/runs/38769532000. Next artifacts: `xnu/out-0021`, `research/bt25`, `research/run25.log`.
  - Kernel: `config/MASTER.arm64.sweet` FILESYS_BASE += `mockfs` (XNU's built-in FS: root device is itself a Mach-O, served as /sbin/launchd, plus /dev for devfs). Upstream mockfs bit-rot fixed: kalloc_type/kfree_type used the POINTER typedef mockfs_fsnode_t (nodes were 8 bytes) -> `struct mockfs_fsnode`. `IOService::setRootMedia` asserted IOBlockStorageDriver class exists (IOStorageFamily absent): SWEET-only, a missing class means root=NULL (same as IOSetImageBoot); Apple path keeps assert. All 21 patches apply (`research/check-patch-order.py`); 5 TUs compile locally with -DMOCKFS (`research/mockfs-objs`), imports resolve vs 0020 kernel. Sandbox `research/bt24/xnu` now holds 0021 versions of those 3 files; pristine 0020 copies in `research/pre0021`.
  - Tools: `tools/mkpayload.py --ramdisk IMAGE` appends IMAGE as an extra payload segment right after the kernel, moves kernel_end past it (shim unchanged: ADT+boot_args follow it, image stays below topOfKernelData), and adds ADT `/chosen/memory-map` `RAMDisk`=<phys,size>. Boot with `rd=md0`. Without --ramdisk output is byte-identical to existing 0020 QEMU and phone payloads (verified). `tools/sweet-init.S` + `tools/mkinit.py`: PIC static init (open /dev/console, print PID, heartbeat every 5 s via select, never exits) wrapped into a static arm64 Mach-O (__PAGEZERO, __TEXT@0x100000000, LC_UNIXTHREAD, ad-hoc SHA-256 CodeDirectory v0x20400, 4K pages). Build: `~/swift/usr/bin/clang -target arm64-apple-ios16.0 -c tools/sweet-init.S -o X.o && tools/mkinit.py X.o research/sweet-init` (ld64.lld cannot link static iOS). Signature not verified by a real codesign; the kernel will tell.
  - QEMU with 0020 kernel + RAM disk (`research/q0020-rd.bin`, rd=md0, 150 s `research/q0020-rd150`): `Added memory device md0`, **`BSD root: md0, major 1, minor 0`** (plumbing works), then the setRootMedia assert (now fixed in 0021). NOTE: QEMU needs >60 s to reach IOFindBSDRoot (60 s run showed nothing after stf0; likely RTC/inittodr wait), so use --secs 150.
  - NEXT: download 0021, QEMU 150 s with ramdisk; expect mockfs mount then init exec -> `*** SWEET userspace: init running as PID 1 ***`. Then phone boot with same payload (phone ADT shim/out/sweet-0020.adt pattern + --ramdisk + rd=md0).
- **0020 PHONE RESULT (user transcription of screen, 2026-10-15): KERNEL INIT COMPLETE, WAITING FOR ROOT.** After Skywalk self-tests PASSED, kminit, ifnet_attach lo0/gif0/stf0, screen prints `BSD`, then `Waiting on <dict><key>IOProviderClass</key><string>IOMedia</string><key>Content</key><string>Apple_HFS</string></dict>` and `Failed to write boot-picker-bringup-reason to NVRAM.` No panic. This is IOFindBSDRoot waiting for a root device (none exists); NVRAM warning is expected (no NVRAM driver). QEMU `cpu_idle` snapshot is presumably the same wait (not GDB-confirmed; milestone GDB run was cancelled by user since phone answered it). Draft `research/check-milestones20.gdb` (hbreaks inittodr/vfs_mountroot/IOFindBSDRoot/bsd_utaskbootstrap) left uncommitted/ignored.
- **NEXT MILESTONE: root filesystem -> launchd.** Plan: (1) RAM disk: shim places an image in RAM, ADT /chosen/memory-map `RAMDisk` entry, boot-arg `rd=md0` (XNU md driver). (2) HFS is a separate kext on Apple; build Apple OSS `hfs` (tag paired with macOS 13.5 in distribution-macOS macos-135 release.json) into SWEET like libpthread 0019. APFS is closed. (3) Minimal HFS image with iOS 16 launchd (later: dyld/shared cache; AMFI/code-signing absent will be a later hurdle). User's end goal is full iOS GUI.
- **0020 (AES) VERIFIED + PHONE BOOTED (Claude took over after Codex usage limit).** Actions `38765422261` (`ab9e23f`) PASSED; kernel `xnu/out-0020/kernel.development.sweet` checksum OK; buildtree `research/bt24`, log `research/run24.log`. Actual-kernel AES checks PASS (`research/check-aes20.gdb` / `.log`, 12 extra CBC cases match OpenSSL). 45s QEMU `research/q0020`: no panic, zero unknown glyphs, past old TCP/AES panic -> Skywalk self-tests PASSED -> bsd_autoconf kminit -> ifnet_attach lo0/gif0/stf0; final snapshot PC in `cpu_idle` (idle or waiting; NOT yet diagnosed, could be root-device wait). Image `shim/out/shim-boot-0020.img` 16,461,824 bytes SHA256 `775200cb02d95fc750981516b79d91dcdc96184bbe67a38f9d57c59b4a391828`, ramdisk byte-matches `payload-0020.bin` (`check-0020`). **Phone temporarily booted 2026-10-15 16:10:00 UTC**: one FASTBOOT product sweet, send OKAY0.407s, boot OKAY0.134s, total0.549s, exit0 (`research/boot0020.log`). Awaiting user photo; do not reboot the phone before it. NEXT: read photo; diagnose what QEMU waits on after stf0 (GDB backtrace of threads / longer run). Codex's STOP request below is complete.
- User requests STOP after completing the current0020 AES iteration (Actions/QEMU/phone), then leave a precise committed handoff for another AI. User says FASTBOOT ready again after0019 photo. Do not start a new blocker fix after this iteration.
- Goal: iOS16-generation XNU on Redmi Note10Pro sweet/SM7150. Always commit, use gh/Actions for kernel builds, keep this handoff current. Temporary fastboot boot only; preserve Android/backups. No userland/root filesystem boot yet.
- **Patch0020 update:** initial `e71098d` / Actions `38765012466` superseded by scalar-only compile flags. Added -mgeneral-regs-only to all six provider/BearSSL TUs and corecrypto_aes.c; object disassembly now confirms no SIMD. Updated implementation `ab9e23f`, Actions `38765422261` queued/running: https://github.com/dipa-studio/vmios/actions/runs/38765422261. Do not launch another run. portable BearSSL AES CBC and legacy one-block ECB wired directly into SWEET corecrypto_aes.c. Genuine bitslice implementation, no CPU AES/SIMD requirement, heap or fake global crypto table. Source fetched by `0020-stage-bearssl.sh` from official BearSSL git at immutable `7bea48e5e850ab4cafbe68d3765cdaba13a86d6f`; MIT license retained, downloaded source stays out of git. Kernel limits include adapter only. All128/192/256-bit keys, CBC encrypt/decrypt, copied contexts, in-place/out-of-place; zero block count and size overflow handled, invalid keys clear context. Seven TUs compile to arm64 objects (`research/aes-objs`), imports resolve, all20 patches apply and sources match (`research/patch0020-check.log`). Sandbox `research/bt23/xnu`, originals `research/pre0020`. NEXT: Actions then actual-kernel NIST/random CBC/ECB checks and >=45s QEMU before another phone boot. Next artifacts out-0020 / bt24 / run24.log. 0020 updated CI pending. Local sources/checks match the scalar-only patch.
- **Latest built kernel0019**, implementation `256d3f0`, patches0001-0019. Actions `38763072907` PASSED (4m5s): https://github.com/dipa-studio/vmios/actions/runs/38763072907. Kernel `xnu/out-0019/kernel.development.sweet`, SHA256 `a27df7568f03fb541cf0e8024c0a594fa178a85054fcf9eba29158cbd4c5ecc0`; checksum verified. Log/source `research/run23.log` / `research/bt23` (no nested .git). Seven pthread source/build/header files and staged adaptations byte-match local compile inputs.
- **0019 hardware photo received** `IMG_20261015_175306.jpg`: pthread registration visible, passes mbinit and DLIL checksum/scheduling, same AES fault as QEMU: PC`0xfffffe00079174e0` (`aes_encrypt_key128`), LR`0xfffffe000767c3a4` (`tcp_init`), FAR0x78, x8=0. Disassembly proves NULL g_crypto_funcs->ccaes_cbc_encrypt. Photo processed; no more0019 observation pending. General crypto table remains absent, other hash/mode operations may still fault after0020. DO NOT bypass TCP or install fake crypto. XNU already contains SHA256/HMAC implementations; AES source there is a dispatch wrapper. Full future provider interface libkern/libkern/crypto/register_crypto.h. Apple/corecrypto default README describes evaluation-only licensing, so no external corecrypto was fetched or staged; BearSSL selected for this portable AES integration.
- **0019 pthread FIXED in QEMU and observed beyond its init on phone**: 45s QEMU `research/q0019`, zero unknown glyphs, then AES panic. Actual-kernel API checks PASS `research/check-pthread19.gdb` / `.log`, guest `research/q0019-api`: function/callback table identity, actual provider pthread_init returns, locks/global hash/threadcall/typed zones initialized, thread_selfid via syscall shim + buffer bounds, process hash init/delete via shims restores NULL. Monitor quit prints expected remote-disconnect after PASS. All fixture guests stopped.
- **0019 provider**: genuine Apple libpthread-514.100.2 commit `a6c70ca0e544347a0377babf748f831577ec24f9`, exact paired release with xnu8796.141.3 in distribution-macOS/macos-135/release.json (`research/macos-135-release.json`). 0019 shell stage runs before patches (workflow copies *.sh); three SWEET wrapper TUs use kext BSD header view, vm_fault_external, renamed provider-side pthread_kern/current_uthread; register real function table at EARLY_BOOT SECOND, real pthread_init later. Stager applies bounded address casts, zero user addresses, proper panic format. SWEET opaque ksyn storage enlarged48->56 for trailing kwe_uth, checked with provider static assertion. Local pre-CI TargetConditionals fixture was syntax-only; artifact bt23 carries actual SDK header and CI is authoritative.
- **Phone0019 temporarily booted** 2026-10-15 15:51:36 UTC: exactly one FASTBOOT/product sweet verified; send OKAY0.406s, boot OKAY0.134s, total0.546s, exit0 (`research/boot0019.log`). Image `shim/out/shim-boot-0019.img`, 16,457,728 bytes, SHA256 `19429a57e486b856880df9e27327ed488e0139345311fdb0350974e72103a9a1`. Phone ADT/payload `shim/out/sweet-0019.adt` / `payload-0019.bin` timer19, unpacked ramdisk byte-match (`check-0019`). EntryPA0xb146b488, kernelendPA0xb2000000, boot_argsPA0xb2004000/top0xb2008000. Last user FASTBOOT+USB reply preceded this boot; do not assume phone is still in FASTBOOT.
- **CPU0018 physically verified** by `IMG_20261015_173951 (2).jpg`: boot CPU0 registered, real SGI1 verified, initialization complete -> BSD/MAC/mbinit -> old pthread-table panic. SweetCPU uses legacy IOCPU, ml_processor_register/processor_start/initCPU, real SGI1 clears SIGPdisabled before max CPUs completion; no forced flags/skipped waits. CPU APIs and two-CPU rejection passed (`research/check-cpu18.gdb`, `q0018-api`, `q0018-smp`). Single core; SMP/suspend unsupported. CURRENT SWEET has NO USE_APPLEARMSMP.
- QEMU next run: generate fresh `tools/mkadt.py research/q0020.adt --qemu` (timer27), mkpayload with `debug=0xc serial=3 cpus=1 keepsyms=1 -enable_kprintf_spam -noprogress`, then `tools/qemu-sweet.py PAYLOAD OUT --secs 45 --kernel KERNEL --fail-on-panic`. 12s can miss later panics because IORTC waits30s. Runner snapshot only: panic exit2, blank/incomplete exit3; absence of panic does not mean complete boot. Qualcomm XPU/ABL/panel and phone SMC PSCI require hardware checks.
- Local checker `tools/xnu-cc.py research/run23.log research/bt23 FILTER --per-file`, XNU_CC_OBJDIR for objects. For new BearSSL TUs add XNU_CC_EXTRA with -I bt23/xnu/libkern/crypto/sweet_bearssl/{inc,src}. Patch checker `research/check-patch-order.py` uses temporary upstream index; source fixtures/artifacts ignored under research. GDB mask registers to unsigned64, use function-entry manual-call return traps, discard manipulated guests. No QEMU guest intentionally left running.

## Session log and earlier handoffs (superseded by the active summary above)

### Prior 0019 transition notes (superseded)

- Goal: iOS 16 generation XNU on sweet. Always commit completed work, use gh/Actions for kernel builds, keep this handoff current. Temporary fastboot boot only; preserve Android/backups.
- **0019 build PASSED** Actions `38763072907` (4m5s), implementation `256d3f0`. Kernel `xnu/out-0019/kernel.development.sweet`, SHA256 `a27df7568f03fb541cf0e8024c0a594fa178a85054fcf9eba29158cbd4c5ecc0`; checksum verified. Log/source `research/run23.log` / `research/bt23`; all seven patched files and staged provider adaptations match local compile inputs. Prefer bt23 as the next baseline.
- **0019 pthread FIXED in QEMU**: 45s run `research/q0019` registers provider, passes mbinit, DLIL SUM16 checks and DLIL thread scheduling. Actual-kernel GDB checks `research/check-pthread19.gdb` / `.log` PASS: function/callback table identity, real _pthread_init returns, locks/global hash/cleanup threadcall/typed zones non-NULL, thread_selfid via actual syscall shim with output bounds, process hash init/delete through actual shims restores NULL. Guest stopped after tests; no fixture left running. GDB monitor quit prints expected remote disconnect after PASS.
- **Current next blocker:** QEMU0019 panic data abort FAR0x78 at `aes_encrypt_key128` PC`0xfffffe00079174e0`, called by `tcp_init` LR`0xfffffe000767c3a4`. Disassembly confirms `g_crypto_funcs == NULL`, loading ccaes_cbc_encrypt at+0x78. General crypto registration is still absent; DO NOT bypass TCP or supply fake crypto. Next integrate a genuine compatible crypto implementation/provider (AES first needed here, other digest/mode APIs also used). XNU contains SHA256/HMAC but no AES implementation; its corecrypto_aes.c is a dispatch wrapper. Full crypto table is in libkern/libkern/crypto/register_crypto.h.
- **0019 phone image prepared and verified**, user reports FASTBOOT+USB again; exactly one device/product sweet verified. `shim/out/shim-boot-0019.img`, 16,457,728 bytes, SHA256 `19429a57e486b856880df9e27327ed488e0139345311fdb0350974e72103a9a1`; unpacked ramdisk matches phone payload (`shim/out/check-0019`, `payload-0019.bin`, `sweet-0019.adt`, timer19). EntryPA0xb146b488; kernelendPA0xb2000000; boot_argsPA0xb2004000/top0xb2008000. Usual debug cmdline cpus=1/-noprogress. **Temporarily booted 2026-10-15 15:51:36 UTC**: send OKAY0.406s, boot OKAY0.134s, total0.546s, exit0 (`research/boot0019.log`). User asked for photo after45s. Await the photo; DO NOT reboot again before observation. Bootloader acceptance only; no0019 physical progress observed yet.
- **Hardware photo confirms 0018 progress** (`IMG_20261015_173951 (2).jpg`): real phone prints `SWEET CPU: boot CPU 0 registered, SGI1 verified, initialization complete`, enters BSD/MAC, reaches `mbinit: done`, then the same missing-pthread-function-table panic as QEMU at pthread_shims.c:318. CPU completion/interrupt delivery is now physically observed. The photo was received; no further phone boot performed yet.
- **Patch0019 committed/pushed `256d3f0`; Actions `38763072907` queued/running:** https://github.com/dipa-studio/vmios/actions/runs/38763072907. Do not launch a duplicate. genuine Apple OSS libpthread-514.100.2 provider (immutable commit `a6c70ca0e544347a0377babf748f831577ec24f9`), paired with xnu-8796.141.3 by Apple's `distribution-macOS/macos-135/release.json` (`research/macos-135-release.json`). `0019-stage-libpthread.sh` fetches/stages it before patches; workflow now copies shell scripts too. SWEET-only wrappers compile all three real kernel sources, rename provider-side symbols, use kext header view and vm_fault_external, register the real function table at EARLY_BOOT SECOND. Existing pthread_init then runs the actual provider initialization. No pthread wait/syscall is bypassed. Source staging includes bounded explicit address casts/zero user addresses and panic-format fixes. SWEET kernel opaque ksyn storage enlarged from48 to56 bytes to contain this provider's trailing kwe_uth, with a provider size assertion. Local compile of three provider TUs plus pthread_shims/kern_fork passed; imports resolve and provider exports do not collide with existing kernel symbols. All19 patches apply and changed sources match (`research/patch0019-check.log`). Source sandbox `research/bt22/xnu`, originals `research/pre0019`, objects `research/pthread-objs`. Local TargetConditionals fixture only has target macros for syntax; CI stages the real macOS SDK header and is authoritative. Next Actions artifacts: out-0019 / bt23 / run23.log; run QEMU >=45 seconds. 0019 CI is pending; no 0019 QEMU run yet.
- **Latest kernel implementation `e7d9550`, patches0001-0018; CI `38760004398` PASSED (3m56s)**: https://github.com/dipa-studio/vmios/actions/runs/38760004398. No build is pending. Kernel `xnu/out-0018/kernel.development.sweet`, SHA256 `b3c8d59acc88f93a2c836eb2527a05ed4fbaac7c580a2ea8c3b795137f4aadf1`; checksum verified. Source/log `research/bt22` / `research/run22.log` (baseline for patch0019; no nested .git). New driver/config sources match CI exactly.
- **CPU wait FIXED in QEMU**: SweetCPU uses legacy IOCPU, validates single boot CPU, ml_processor_register -> processor_start -> initCPU real SGI1 -> scheduler/IOKit completion -> ml_set_max_cpus. It does NOT force a flag or skip a wait. CPU APIs passed: Running CPU0, processor_array[0] association, SGI signalling enabled, name, unsupported secondary-start error (`research/check-cpu18.gdb` / `.log`, `research/q0018-api`). Single-core only; SMP and suspend unsupported. Two-CPU topology fails explicitly (`research/q0018-smp`).
- **Next blocker reproduced in 45s QEMU** (`research/q0018-long`, zero unknown glyphs): BSD initialization reaches MAC framework, network mcache and `mbinit: done`, then **`pthread kernel extension not loaded (function table is NULL). @pthread_shims.c:318`**. Do not bypass pthread_init: find/integrate the matching open-source libpthread kernel implementation and register its real function table. A 12s run `research/q0018` looked panic-free before the 30s IORTC wait elapsed; use >=45s or GDB checkpoints for the next iteration. No userland/root filesystem boot yet.
- **Phone 0018 TEMPORARILY BOOTED** 2026-10-15 **15:31:15 UTC**: exactly one FASTBOOT device verified product sweet; send OKAY0.400s, boot OKAY0.134s, total0.539s, exit0. Local log `research/boot0018.log`. This confirms bootloader acceptance only. User was asked for a photo; await it, DO NOT reboot the phone again before their observation. No flashing performed.
- Current hardware image `shim/out/shim-boot-0018.img`, **16,437,248 bytes**, SHA256 **`b7a23595d143a76c72c9fe2cfcc5d77a8f16987b5af1a2703bbffdfa6922908c`**. Phone ADT/payload `shim/out/sweet-0018.adt` / `shim/out/payload-0018.bin` (timer19), unpacked ramdisk exactly matches payload (`shim/out/check-0018`). EntryPA0xb146b488; kernelendPA0xb1ffc000; boot_argsPA0xb2000000/top0xb2004000. Command line `debug=0xc serial=3 cpus=1 keepsyms=1 -enable_kprintf_spam -noprogress`.
- QEMU payload/ADT `research/q0018.bin` / `research/q0018.adt` (timer27). Run `python3 tools/qemu-sweet.py research/q0018.bin research/NEW-OUT --secs 45 --kernel xnu/out-0018/kernel.development.sweet --fail-on-panic`; fresh ADT seed for a new payload. Output fb.png/fb.txt/regs.txt/qemu.log/result.json. Visible panic exit2; blank/incomplete decode exit3; no_panic_observed is snapshot-only, not successful boot. -noprogress prevents the graphical indicator corrupting console text. Qualcomm XPU/bootloader/panel and SMC PSCI still need physical validation.
- Patches0014-0017 fixed PRNG registration/direct SHA256, explicit unavailable trust-cache service with rejected loads/no matches, built-in SweetPlatformExpert, and timer PPI from ADT (phone19/default19, QEMU27). All their checks/artifacts are preserved in the history below. CURRENT SWEET has NO USE_APPLEARMSMP; do not assume gCPUIC/gAIC/gPMGR AppleARMSMP globals exist.
- Local single-file checker: tools/xnu-cc.py research/run22.log research/bt22 FILTER --per-file, output via XNU_CC_OBJDIR. Patch checker `research/check-patch-order.py` applies all18 via temporary index, matches sandbox sources. Sandbox for0018 `research/bt21/xnu`, originals `research/pre0018`, objects `research/cpu-objs`. First compiler issues were missing machine/atomic.h and nonexistent getNameSymbol; fixed and both TUs compiled successfully before CI. Fixtures/artifacts under research are local-only/ignored.
- GDB: mask int(register)&((1<<64)-1) for unsigned kernel pointers; use function-entry manual-call return traps, discard manipulated guests. No QEMU fixture is intentionally left running.

### Earlier active handoff snapshot (superseded)


- **0018 milestone:** Actions `38760004398` PASSED (3m56s), checksums passed, new CPU/build files byte-match CI tree. Kernel `xnu/out-0018/kernel.development.sweet`, SHA256 `b3c8d59acc88f93a2c836eb2527a05ed4fbaac7c580a2ea8c3b795137f4aadf1`; log/tree `research/run22.log` / `research/bt22`. QEMU `research/q0018` 12s: boot CPU registered, SGI1 verified, CPU initialization complete, **BSD initialization entered** (copyright, MAC framework, buffer headers), no panic/zero unknown glyphs. Direct CPU API checks PASS (`research/check-cpu18.gdb`, `.log`, `research/q0018-api`): CPU0 Running, processor matches processor_array[0], real SGI enabled, CPU name correct, secondary-start returns KERN_NOT_SUPPORTED. Two-CPU ADT correctly panics before registration (`research/q0018-smp`). Longer 45s run `research/q0018-long` still running; next BSD wait/fault not yet identified.
- **Prepared 0018 phone image:** `shim/out/shim-boot-0018.img`, 16,437,248 bytes, SHA256 `b7a23595d143a76c72c9fe2cfcc5d77a8f16987b5af1a2703bbffdfa6922908c`. Phone ADT/payload `shim/out/sweet-0018.adt` / `shim/out/payload-0018.bin`, usual debug args with cpus=1 and -noprogress. Unpacked ramdisk byte-compared (`shim/out/check-0018`). Entry PA remains 0xb146b488; kernel end PA 0xb1ffc000, boot_args 0xb2000000/top0xb2004000. User reports FASTBOOT+USB ready; read-only check found exactly one product sweet. NEXT: temporary fastboot boot of this verified image, record send/boot results, then await hardware photo without rebooting again.
- Patch 0018 committed/pushed **`e7d9550`**; Actions **`38760004398`** queued/running: https://github.com/dipa-studio/vmios/actions/runs/38760004398. Do not launch a duplicate run.
- Active continuation: patch **0018** implemented in `iokit/Kernel/arm/SweetCPU.cpp` + arm64 source list + exact qcom,kryo470 personality. Keeps legacy IOCPU, accepts ONLY the single boot CPU, fills ml_processor_info from parsed topology with CPU object as cpu_id, calls ml_processor_register and processor_start. initCPU sends SGI1 via ICC_SGI1R_EL1 and waits (1-second deadline) for real cpu_signal_handler to clear SIGPdisabled. Only after successful startup calls ml_cpu_init_completed/cpusRunning and publishes completion/max CPUs. Secondary startup/suspend are explicitly unsupported. Local C++ compile passed for both TUs (`research/cpu-objs`), all imports resolve, object contains dsb ishst / ICC_SGI1R / isb; all18 patches apply in order and match sources. Sandbox `research/bt21/xnu`, originals `research/pre0018`; next CI artifacts should use `xnu/out-0018`, `research/bt22`, `research/run22.log`. User has the phone available; first run QEMU, then prepare/temporarily boot useful hardware progress.
- Goal: iOS 16 generation XNU on Redmi Note 10 Pro / sweet. User wants persistent progress, commits, kernel builds via `gh` Actions, and this handoff kept current across agent switches. Temporary `fastboot boot` only; preserve Android and backups.
- Latest kernel implementation: **`aa3f991`**, patches **0001-0017**. All four new Actions builds PASSED: 0014 `38748543058` (4m0s), 0015 `38749549779` (4m3s), 0016 `38750733996` (4m3s), 0017 **`38751507437` (4m7s)**. Latest: https://github.com/dipa-studio/vmios/actions/runs/38751507437. No build is pending.
- **Current blocker: CPU initialization has no SWEET CPU driver.** QEMU registers SweetPlatformExpert, then kernel_bootstrap_thread waits in **kperf_init_early -> ml_wait_max_cpus**. Confirmed via actual-kernel GDB call stack (`research/locate-cpu-wait2.log` / `.symbols`) and normal-run `max_cpus_initialized == 2` (MAX_CPUS_WAIT). Do not force the flag or remove the wait. Next implement real CPU registration and completion using XNU's CPU/processor interfaces. CURRENT SWEET uses legacy IOCPU (`USE_APPLEARMSMP` is absent); enabling AppleARMSMP is a separate architectural change requiring GIC/PMGR services. No userland/root filesystem boot yet.
- Fixed this session: PC=0 unregistered PRNG callback (0014, built-in HMAC-SHA256 provider + direct entropy/write_random hashing); absent Image4/AMFI trust-cache service (0015, unavailable runtime, loads rejected and queries no-match); missing platform driver (0016, SweetPlatformExpert exact personality); incorrect QEMU timer IRQ (0017, validated ADT PPI property, phone default19/QEMU27).
- **Latest kernel** `xnu/out-0017/kernel.development.sweet`, SHA256 `055a80190ab998b4df9203f1102072dcc78faad1779a537a514e522b682b582f`. Buildtree/log **`research/bt21` / `research/run21.log`**; all nine changed C/C++/header/config files byte-match local checked sources. Checksums passed. Entry PA `0xb146b488`, kernel end PA `0xb1ff4000`. Preferred baseline for patch 0018: `research/bt21/xnu` (no nested .git).
- **QEMU verified**: `research/q0017-noprogress` ran **30 seconds**, no visible panic, **zero unknown glyphs**, IRQ exceptions returned normally (4 IRQs, tickless idle). It still waits for CPU completion, so this is NOT a completed boot. Earlier 15s run `research/q0017` captured 122 IRQs, timer value27, GICR_ISENABLER0 `0x08000002`, and CPU WAIT; graphical progress overlay corrupted 13 glyphs. Add **`-noprogress`** to keep the console readable. New runner classifies incomplete/blank decoding explicitly (exit3 with --fail-on-panic), visible panic exits2. Snapshot-only; use regs/GDB to diagnose stalls.
- Current QEMU payload/ADT: **`research/q0017-noprogress.bin` / `research/q0017.adt`**. Run: `python3 tools/qemu-sweet.py research/q0017-noprogress.bin research/NEW-OUT --secs 30 --kernel xnu/out-0017/kernel.development.sweet --fail-on-panic`. Generate fresh seed with mkadt for a new payload. QEMU virt models generic ARM execution, not Qualcomm XPU/bootloader/panel or the phone's SMC PSCI conduit.
- **Prepared phone image**: **`shim/out/shim-boot-0017.img`**, 16,416,768 bytes, SHA256 `51ff7fe30b4a6668c3452ffe1da922c5ac30cb8de60625c2a652587ecbd0ec92`. Phone ADT/payload `shim/out/sweet-0017.adt` / `shim/out/payload-0017.bin` (timer19). Unpacked ramdisk exactly matches payload (`shim/out/check-0017`). Command line **`debug=0xc serial=3 cpus=1 keepsyms=1 -enable_kprintf_spam -noprogress`**. NOT sent to phone this session: known CPU-driver wait should be addressed in QEMU first. Last actual phone boot remains 0013; user's latest photo `IMG_20261015_160033.jpg` confirmed the old PRNG PC=0 panic.
- Direct QEMU/GDB API checks: PRNG 600-byte chunking, buffer bounds, changing output, zero-length reads/writes, user reseed, contended refresh, generator1 init/output PASS again on latest0017 (`research/check-prng17.gdb` / `.log`, guest `research/q0017-api`). Trust-cache unavailable-service/argument/output cases PASS on0015 (`research/check-trustcache.gdb` / `.log`). Platform registration + target/product normal/truncated/zero/null/bounds PASS on0016 (`research/check-platform.gdb`, `research/check-platform3.log`). Different platform ID correctly retains IOPanicPlatform fallback (`research/q0016-negative`). Timer PPI32 and size2 correctly panic (`research/q0017-badppi`, `research/q0017-badsize`); omitted property selects19 (`research/q0017-default`). These are API/bring-up checks, not crypto certification or SMP scheduling validation.
- Local checker **`research/check-patch-order.py`** verifies all17 patches and changed source equality using a temporary upstream git index. Fixtures/logs/artifacts under research are local-only and ignored. For GDB unsigned kernel pointers, mask `int(register_value) & ((1<<64)-1)`; x30/x29 may be rendered signed. Stop at a function entry for manual-call return traps, and discard each manipulated guest after API tests. All fixture QEMU guests have been stopped.


- User wants persistent progress toward iOS 16, commits for completed changes, builds through `gh` / GitHub Actions.
- Keep this file current at every milestone so another agent can resume immediately, including when usage limits interrupt a session.
- Patch 0017 committed/pushed `aa3f991`, Actions `38751507437` running: https://github.com/dipa-studio/vmios/actions/runs/38751507437. Next artifacts: xnu/out-0017, research/bt21, research/run21.log. Do not duplicate.
- Patch 0016 kernel downloaded/checksum verified: SHA256 `d06336c54baa06e0df6561a8bd7df98a9b9f7502c9381c62d1a44c045cd1ce46`, `xnu/out-0016/kernel.development.sweet`; buildtree/log `research/bt20` / `research/run20.log`. QEMU `research/q0016` (10s) prints platform expert registered, zero unknown glyphs, no panic observed BUT stalls (timer mapping still wrong until 0017). Direct actual-kernel GDB tests passed for registered instance and target/product names, including maxLength=1/0 and NULL, sentinels intact (`research/check-platform.gdb`, `research/check-platform3.log`, `research/q0016-api3`). First two fixture attempts used premature/wrong return breakpoints; discarded, corrected fixture uses start-return observation then a function-entry return trap. No phone boot yet.
- Patch 0016 CI `38750733996` PASSED (4m3s); artifacts not yet downloaded/booted. Patch 0017 prepared to fix QEMU timer fidelity BEFORE interpreting future no-panic/stall runs: actual `qemu-system-aarch64 -M virt,gic-version=3,dumpdtb=research/qemu-virt.dtb ...` timer property has virtual PPI 11 => INTID 27, while phone uses INTID 19. Kernel formerly hardcoded 19. New optional /arm-io/gic virtual-timer-intid property selects the PPI (validate exact u32 and 16..31); missing property retains phone default 19. One RO-late global drives GIC enable and sleh_irq dispatch. tools/mkadt.py emits phone19/QEMU27. Both C TUs compile (`research/timer-objs`), ADT serialize/parse checks confirm values/addresses, all 17 patches apply and match. Sandbox `research/bt19/xnu`, originals `research/pre0017`; initial local sleh compile failed due read-only exported header not updated, fixed export and BOTH recompiled successfully. CI exports normally.
- Architecture correction for next agent: CURRENT SWEET board_config does NOT define USE_APPLEARMSMP; it compiles the legacy IOCPU path, not cpu_boot_thread/IOPMGR AppleARMSMP. Existing roadmap mentions AppleARMSMP as a future approach. Do not look for gCPUIC/gAIC/gPMGR globals in the current kernel: they are absent. Determine the actual CPU-init wait after platform registration before choosing the next driver architecture.
- Patch 0016 committed/pushed as `0dcdf5c`; Actions `38750733996` running: https://github.com/dipa-studio/vmios/actions/runs/38750733996. Next artifacts: `xnu/out-0016`, `research/bt20`, `research/run20.log`.
- Patch 0016 implemented: new `iokit/Kernel/arm/SweetPlatformExpert.cpp`, arm64 source list, built-in personality in KernelConfigTables.cpp guarded by ARM64_BOARD_CONFIG_SWEET. Matches only xiaomi,sweet at score 10000, keeps IOPanicPlatform fallback for other hardware. Uses IODTPlatformExpert base initialization/power domain and createNubs CPU logical-ID annotation; overrides top-level publishing because base requires nonexistent Apple NVRAM /options. Publishes real CPU/top-level nodes, provides bounded target/product names, and registers the platform service. GIC/PMGR and arm-io child-bus drivers remain separate work. Both C++ TUs compile (`research/platform-objs`), all imports resolve against 0015/own objects, all 16 patches apply and sources match. Sandbox `research/bt19/xnu`; originals `research/pre0016`. NEXT: full Actions/QEMU; inspect CPU boot waits after the platform registers, do not equate absence of panic with successful boot.
- Patch 0015 CI `38749549779` PASSED (4m3s), checksum verified. Kernel `xnu/out-0015/kernel.development.sweet`, SHA256 `ca1b424a596c7058550ad1659080a333e7643270f019656401d80bf2b876645f`; buildtree/log `research/bt19` / `research/run19.log`. QEMU `research/q0015` (10s, zero unknown glyphs) passes trust-cache handling and machine lockdown, then panics `Unable to find driver for this platform: "xiaomi,sweet" @IOPlatformExpert.cpp:2319` (IOPanicPlatform fallback). Next concrete work: add a built-in SWEET IODTPlatformExpert personality/class; keep the fallback for mismatched platforms. No phone boot yet.
- Direct trust-cache API checks PASSED in the actual 0015 kernel under QEMU/GDB (`research/check-trustcache.gdb`, `research/check-trustcache.log`, `research/q0015-api`): runtime pointers NULL, hash/UUID queries return NOT_FOUND, typed/untyped/legacy loads return NOT_SUPPORTED, capabilities outputs zero and bounds preserved, invalid-argument cases still reject. Second PRNG check also verifies contended refresh returns immediately (`research/check-prng2.log`, `research/q0014-api2`).
- Patch 0015 committed/pushed `8f851d4`, Actions run `38749549779` running: https://github.com/dipa-studio/vmios/actions/runs/38749549779. Do not duplicate.
- Direct PRNG API checks passed in the REAL 0014 kernel under QEMU/GDB, stopped before trust-cache init (`research/check-prng.gdb`, log `research/check-prng.log`, guest `research/q0014-api`). Invoked read_random for 600 bytes (chunking and buffer sentinel intact), repeated output differed, zero-length read/write succeeded, write_random(64-byte input) succeeded, secondary generator 1 initialized and generated distinct output. QEMU log has no exceptions during these checks; guest was discarded after the tests. This tests API behavior, not a cryptographic certification or SMP scheduling.
- Patch 0015 implemented in `bsd/kern/kern_trustcache.c`: SWEET with missing Image4/AMFI marks both runtime pointers NULL and logs service unavailability. Existing static loader handles NULL. Public load APIs return KERN_NOT_SUPPORTED; hash/UUID queries return KERN_NOT_FOUND; capabilities outputs are zero with KERN_NOT_SUPPORTED. Invalid-input checks remain, and Apple paths/available-provider initialization retain existing behavior. No trust is granted. Local arm64 compile passed (`research/trustcache-objs`), all 15 patches apply and sources match. Sandbox `research/bt18/xnu`, baseline `research/pre0015`. Next: Actions/QEMU and direct unavailable-service API checks using GDB.
- Patch 0014 CI `38748543058` PASSED (4m0s), artifact checksum passed. Kernel `xnu/out-0014/kernel.development.sweet`, SHA256 `741de20c851755d333759d7e668346f3edb4f325efac4cc7c142d80d1f5ff75c`; buildtree/log `research/bt18` / `research/run18.log`. QEMU run `research/q0014` (10s, zero unknown glyphs) prints `SWEET PRNG: HMAC-SHA256 registered`, passes commpage initialization, loads vnguard policy, THEN panics `image4 interface not available @kern_trustcache.c:253`. PC=0 fault FIXED IN QEMU. No new phone boot performed.
- Next work: SWEET currently has neither AppleImage4 nor AMFI. `trust_cache_runtime_init` unconditionally requires both; unlike BCM2837, SWEET enters this startup path. Investigate an explicitly unavailable trust-cache runtime with rejected loads/no query matches while providers are absent; preserve all Apple-platform checks. Merely skipping the startup call would leave later AMFI/IMG4 dereferences unsafe. Existing load_static_trust_cache already handles trust_cache_rt == NULL.
- QEMU runner now supports `--kernel MATCHING_KERNEL --fail-on-panic`: runtime font extraction from the payload produces exact `fb.txt`, plus `result.json`; a visible panic returns 2. Baseline 0013 re-run `research/q0013-text` detects the same NULL callback panic with zero unknown glyphs. Synthetic glyph roundtrip (including literal `?`) and invalid-VA rejection passed. Screen rows remain circular, not a full log; `no_panic_observed` does not prove successful boot. README has the invocation.
- Patch 0014 committed/pushed as `be61f99`; Actions run `38748543058` is running: https://github.com/dipa-studio/vmios/actions/runs/38748543058. Do not start a duplicate build.
- 2026-10-15 active: hardware photo `IMG_20261015_160033.jpg` confirms the same PC=0 instruction-fetch abort as QEMU (LR `0xfffffe0007443fe4` = read_random). Independently reproduced with kernel 0013 in `research/q0013` (8-second run); prior allocator fix works. Latest tooling commit reviewed: `8d66d2d`.
- Patch 0014 implemented: registers a built-in HMAC-SHA256 DRBG provider at EARLY_BOOT/FIRST, before commpage creation. A shared mutex serializes output/reseed across CPUs (correctness first; no per-CPU scaling yet), initgen validates CPU identities, refresh uses try-lock and the existing entropy filter/health tests. SWEET entropy accumulation and write_random now use the built-in SHA256 directly; no incomplete g_crypto_funcs table is registered. The existing bootloader-seed requirement remains enforced.
- Local validation: both PRNG translation units compile to arm64 objects in `research/prng-objs`; no SHA256 wrapper imports remain. All 14 patches apply in CI order and resulting PRNG sources match local inputs. Sandbox `research/bt17/xnu`, originals `research/pre0014`, checker `research/check-patch-order.py`. NEXT: Actions kernel build, download to `xnu/out-0014`, run the QEMU payload before requesting another phone boot. Baseline QEMU ADT/payload are `research/q0013.adt` / `research/q0013.bin`.
- 2026-10-15 08:15 QEMU EMULATION WORKS (`tools/qemu-sweet.py`, see "QEMU emulation" below). Patch 0013 VERIFIED in QEMU: boot passes kmem_crypto_init and ulock_initialize. NEXT BLOCKER (reproduced in QEMU, expected on hardware too): `pmap_create_commpages -> random() -> RandomULong -> read_random -> prng_funcs.refresh == NULL` (instruction fetch abort at pc 0, lr read_random+0x34). Nobody calls `register_and_init_prng` (closed corecrypto kext does it on Apple). Fix = patch 0014: SWEET-registered cckprng_funcs provider (osfmk/prng/prng_random.c); note random_cpu_init also panics while !prng_ready. The 07:26 hardware boot of 0013 will most likely show this same panic.
- Previous hardware boot: patch 0013 (`a3a46e2`) CI `38686345689` PASSED (3m44s), image `shim/out/shim-boot-0013.img` was temporarily booted on 2026-10-15 at 05:26 UTC: send OKAY (0.407s), boot OKAY (0.134s), total 0.546s. Superseded by the hardware/QEMU PC=0 observation and patch 0014 work above.
- Latest kernel implementation commit: `8f851d4`. Latest successful kernel CI: `38749549779` (patch 0015), https://github.com/dipa-studio/vmios/actions/runs/38749549779.
- CURRENT image: `shim/out/shim-boot-0013.img`, 16,412,672 bytes, SHA256 `110d1c46aee4b60253db24b6535e9781c4cf0fd25ca2a70e9016cf81378cea25`. Kernel `xnu/out-0013/kernel.development.sweet`, SHA256 `f0b1d375995316c550ce7014ff234d8271e9b9ac2857795ceff41b76ba2cd740`, plain arm64. CI log confirms 0013 applied; checksums passed. Entry PA `0xb146b488`, kernel end PA `0xb1ff4000`.
- Current log/buildtree: `research/run17.log`, `research/bt17` (extracted, no nested .git; preferred baseline for patch 0014). Payload/ADT: `shim/out/payload-0013.bin`, `shim/out/sweet-0013.adt` (includes /defaults). Unpacked ramdisk byte-compared with payload in `shim/out/check-0013`.
- Patch-0012 original image: `shim/out/shim-boot-0012.img`, 16,412,672 bytes, SHA256 `cf4b8ec4a65a51888d71c17d09cd0831d6b761b90e2531fdb8e575c32f4fd24a`. Kernel `xnu/out-0012/kernel.development.sweet`, SHA256 `69b78f49f6459cc63a0af44e7cf73c1779ef72130ef72b12ae86c88183ffc742`; checksums passed and sweet_early_relocate symbol present. Entry PA remains `0xb146b488`, kernel end PA `0xb1ff4000`.
- Patch-0012 log/tree: `research/run16.log`, `research/bt16` (extracted, no nested .git; preferred baseline for next patch). CI log confirms 0012 applied. Payload `shim/out/payload-0012.bin`, ADT `shim/out/sweet-0012.adt`; packed ramdisk byte-compared with payload in `shim/out/check-0012`.
- Active payload command line: `debug=0xc serial=3 cpus=1 keepsyms=1 -enable_kprintf_spam`.
- Latest observed photo: `/home/dipa/Downloads/IMG_20261015_071346.jpg` (local only). Stages 9 (kernel framebuffer VA), 10 (TTBR0 off/TLB flush), 11 (physmap table pointers) and 12 (calling pmap_bootstrap) all visible. Persistent diagnostics are VERIFIED ON HARDWARE.
- pmap.c:1987 is the assert after SecureDTLookupEntry(NULL, "/defaults", &entry). The pmap-max-asids property itself is optional; an empty /defaults uses XNU's MAX_ASIDS. Do not bypass the assertion or guess an ASID limit.
- Previous payload-only fix image: `shim/out/shim-boot-0012-defaults.img`, SHA256 `3ff61a268853c6ea7cbf284833f1346a1d791980ca366b6e1a215a86e040512b` (16,412,672 bytes). Same kernel/CI as 0012; ADT 2516 bytes (`shim/out/sweet-0012-defaults.adt`), root /defaults present with no ASID override. Payload `shim/out/payload-0012-defaults.bin`; unpacked ramdisk exactly matches payload (`shim/out/check-0012-defaults`). This boot reached the allocator crypto NULL-pointer fault below.
- Latest hardware photo: `/home/dipa/Downloads/IMG_20261015_071608.jpg` (local only). Normal serial framebuffer console works. VM bootstrap/zone initialization, logging, scheduler, IPC, KDP and ulock_initialize print before the kmem_crypto_init data abort. gPanicBase warnings are expected because PLATFORM_PANIC_LOG_DISABLED is configured, and are not the faulting call.
- Faulting instruction: `ldr x0, [x8, #0x150]` in crypto_random_kmem_ctx_size; x8 = NULL g_crypto_funcs. Source: libkern/crypto/corecrypto_rand.c and osfmk/vm/vm_kern.c:2448. rand.h explicitly permits NON-cryptographic kmem RNGs, but requires no locking in generation and context size <=256. Do not substitute read_random here: the global PRNG provider is also unregistered and kmem generation must remain lock-free. early_random may seed contexts during single-CPU bootstrap; it uses the built-in HMAC-SHA256 DRBG with the host-generated ADT seed.
- Patch 0013 keeps the replacement entirely private to vm_kern.c: SplitMix64 state is 8 bytes per CPU/sizeclass, initialized using early_random. Uniform selection uses rejection sampling to avoid modulo bias. Other platforms retain the original corecrypto calls; SWEET's generic crypto APIs/registration remain untouched. Reference: https://prng.di.unimi.it/splitmix64.c (Sebastiano Vigna, public domain).
- Validation: vm_kern.c compiles to arm64 (`research/kmem-rng-objs`, using `research/run16.log` + `research/bt16`). Undefined symbols include early_random and NO crypto_random_* references. All 13 patches apply in CI order and match the checked source. Original saved as `research/vm_kern.pre0013.c`.
- RNG host checks: extracted actual new helper in `research/kmem-rng-check.c`; 16,384 outputs match the author's downloaded reference (`research/splitmix64-reference.c`), 147,456 bounded outputs satisfy their limits (including 1 and UINT64_MAX), and a forced rejection advances correctly. Full kernel crypto services and the registered kernel PRNG provider remain future work; this patch only supplies the allocator RNG contract.
- Patch-0011 artifacts: kernel `xnu/out-0011/kernel.development.sweet`, log `research/run15.log`, extracted buildtree `research/bt15` (no nested .git). CI log confirms patch 0011 applied; artifact checksums passed. Kernel is plain arm64, entry VA `0xfffffe000746b488` -> PA `0xb146b488`, kernel end PA still `0xb1ff4000`.
- Patch-0011 image: 16,412,672 bytes, SHA256 `29ad5cbfc752473de4af2c471a24a8b34f92da4bff5afec65c614b90cd3ad53a`. Kernel SHA256 `8ac3a956894b09f7bd0d890de8c5de38c65513287feb1e1bcd12db8ca772ee5c`. Payload/ADT in `shim/out/payload-0011.bin`, `shim/out/sweet-0011.adt`. Header unpacked/checked in `shim/out/check-0011`.
- First patch-0011 attempt timed out waiting for FASTBOOT; superseded by the successful send/boot recorded above. Do not repeat the boot before the user reports the current screen.
- Patch-0011 photo: `/home/dipa/Downloads/IMG_20261015_070218.jpg` (local only). Visible stages 1-8 and old red shim text; entry PA B146B488, boot args PA B1FF8000 / top B1FFC000. No evidence yet locating execution after stage 8.
- Patch-0012 sandbox: `research/bt15/xnu` (NO nested .git). Proposed permanent debug VA: VM_MIN_KERNEL_ADDRESS + ARM_TT_L2_SIZE, in the reserved gap below gVirtBase and above low globals; map the same PA framebuffer as Normal-NC in the final TTBR1 before arm_vm_physmap_init changes phystokv(). Keep the early panic sink until normal kprintf startup.
- Patch 0012 validation: all 4 changed C translation units compiled to arm64 objects in `research/post-ttbr0-objs`; internal header export added to osfmk/arm64/Makefile and recreated locally in EXPORT_HDRS for pe_serial.c. All 12 patches apply in CI order and match all 6 edited files. Baselines are saved under `research/pre0012/`.
- Actual mapping-helper host model (`research/early-map-check.c`, barrier stubbed only for host compilation) confirms: VA `0xfffffe0002000000`, L1 index 2016, L2 index 1; descriptor `0x006000009c000605` = framebuffer PA, Normal-NC, outer-shareable, EL1 RW, PXN+UXN. All other L2 entries preserved. The gap is excluded by ARM_LARGE_MEMORY's pmap_virtual_region(0).
- Next boot command line MUST add `-enable_kprintf_spam`: DEVELOPMENT disables kprintf_output by default even when DB_KPRT is set (`pexpert/arm/pe_kprintf.c`). Planned command line: `debug=0xc serial=3 cpus=1 keepsyms=1 -enable_kprintf_spam`.

### Patch 0012 screen legend (after original stages 1-8)
- 9: kernel framebuffer VA live; 10: TTBR0 off / TLB flushed; 11: physmap pointers rebound.
- 12: calling pmap_bootstrap; 13: pmap_bootstrap returned; 14: early I/O page tables ready; 15: arm_vm_init returned.
- 16: calling serial_init; 17: fbcon config read / mapping; 18: fbcon mapping returned; 19: serial_init returned; 20: kprintf startup complete.
- Normal serial initialization clears the screen, so earlier stages may disappear before 19. If serial exists, early console disables after 20; otherwise early panic output stays enabled.
- Local source sandbox: `research/bt13/xnu` (git baseline `623b060`, patches 0001-0008 already in baseline; uncommitted export edits correspond to patch 0009). Preserve those edits when producing patch 0010.
- Previous compile log/tree: `research/run13.log`, `research/bt13`; previous kernel: `xnu/out/kernel.development.sweet`. New successful log/tree: `research/run14.log`, `research/bt14`; new kernel: `xnu/out-0010/kernel.development.sweet`.
- Current device access: patch-0012 image was temporarily started from FASTBOOT; no adb connection is expected. Never flash partitions for bring-up; use `fastboot boot` with the shim image.
- Patch `0010` lives in `xnu/patches/0010-sweet-early-framebuffer-debug.patch`. Its exact compiled sources are under `research/bt13/xnu`; generated objects are in `research/early-objs`.
- Local checks passed: all 5 changed/new translation units compiled to arm64 Mach-O objects; new console only imports `_doprnt` and `iso_font` (both exist in the previous kernel). All 10 patches applied to a temporary upstream git index in CI order, and all 7 resulting changed source files matched the local compile inputs.
- Reproduce changed-file compilation: `XNU_CC_OBJDIR="$PWD/research/early-objs" python3 tools/xnu-cc.py research/run13.log research/bt13 arm_init.c arm_vm_init.c kern/debug.c arm64/start.s osfmk/arm64/sweet_early.c --per-file` (create the output directory first). The helper now accepts explicit new source paths absent from the old artifact's Makefiles and rejects empty selections.
- Device command result: `adb reboot bootloader`, then `timeout 30s fastboot boot shim/out/shim-boot-0010.img`: send OKAY (16028 KB), boot OKAY, total 0.541s. This confirms bootloader acceptance only, not XNU progress.
- The successful boot above was on 2026-10-14. On 2026-10-15, `timeout 45s fastboot boot ...` timed out waiting for a device; no image was sent. Boot image SHA256 rechecked and unchanged. No new build is needed to repeat the trial.
- Earlier retry: `timeout 90s fastboot boot shim/out/shim-boot-0010.img` timed out (exit 124). This is superseded by the successful 2026-10-15 repeat boot recorded above; do not repeat it until the user reports the screen.
- User observation confirms MMU-on C entry, platform expert, CPU topology/bootstrap, startup bootstrap and cpu_init all complete. Failure is within arm_vm_physmap_init (non-XNU_MONITOR branch), before stage 8 / TTBR0 teardown. Old red shim text remains behind the early console; this is expected because only written rows are cleared.
- New edit/compile sandbox is `research/bt14/xnu` (extracted artifact, NO nested .git; `git diff` there would act on the parent project). Use a saved baseline file / generated unified diff, or explicitly initialize a local baseline before editing. `research/bt13/xnu` does have its own baseline git repo.
- Exact user-reported panic: `arm_vm_init.c:1606 Assertion failed: (temp_ptov_table[ptov_index - 1].va + temp_ptov_table[ptov_index - 1].len) <= physmap_end`.
- Root cause: MacOSX build sets `ARM_LARGE_MEMORY=1`; `XNU_MONITOR` is off. Block alignment in arm_vm_physmap_slide can add gaps, but the non-PPL large-memory physmap_end omitted the padding already present in the small-memory branch. Patch 0011 reserves PTOV_TABLE_SIZE*ARM_TT_TWIG_SIZE (8*32MB) in both the aperture bound and its L1 allocation; monitor/PPL builds retain zero padding. The assertion is preserved.
- Validation: `arm_vm_init.c` compiled to an arm64 object using `research/run14.log` + `research/bt14` (object in `research/physmap-objs`). All 11 patches apply in CI order and produce exactly that source. Host harness `research/physmap-check.c` extracts the real XNU slide function with page-table-write stubs: all 65,536 page-aligned slides within 1GB checked against the current kernel memory layout; old bound fails 65,504 cases, padded bound fails zero; worst overrun 0x1ffc000 bytes. Baseline source saved as `research/arm_vm_init.pre0011.c`.
- CI: https://github.com/dipa-studio/vmios/actions/runs/38638702083 (success; artifacts and full log downloaded).
- New image: `shim/out/shim-boot-0010.img` (16,412,672 bytes, SHA256 `ed2c270e0081bad5ff517be415f9bfe8805463aea7866732203fa97ac737e64e`). Previous image preserved as `shim/out/shim-boot-pre0010.img`.
- New kernel SHA256: `3ee05270cc291c49589a101678f904b1b69cb2f2575e05398bce8a4e052f409a`. Artifact checksums passed; arm64 (not arm64e), early-console symbols present. Payload entry VA `0xfffffe000746a488` -> PA `0xb146a488`; kernel end PA `0xb1ff4000`. Command line remains `debug=0xc serial=3 cpus=1 keepsyms=1`.

### Patch 0010 screen legend
- Bottom-left white 64x32 tile: assembly entered `start_first_cpu`, before page tables/MMU.
- Text `SWEET EARLY 1`: entered `arm_init` with MMU on; 2: platform expert done; 3: CPU topology done; 4: CPU bootstrap done; 5: startup bootstrap done; 6: CPU init done; 7: entering `arm_vm_init`; 8: leaving bootstrap TTBR0.
- `SWEET EARLY PANIC:` prints a copy of panic arguments before normal panic handling needs per-CPU/thread state.
- In patches 0010/0011 the console disabled before TTBR0 invalidation; patch 0012 replaces that with a persistent kernel VA alias and diagnostics through normal serial/kprintf startup (see its legend above).
- Screen contents require a physical observation from the user: adb cannot capture a framebuffer after Android has been replaced by a bare-metal kernel.

## QEMU emulation (2026-10-15)
- `tools/mkadt.py OUT.adt --qemu` = same ADT with QEMU virt GICD 0x08000000 / GICR 0x080a0000 / CNTFRQ 62.5 MHz.
- `tools/qemu-sweet.py PAYLOAD OUTDIR [--secs N] [--hmp "x /8gx ADDR"] [--gdb]`: host-side copy of shim/loader.c
  (segments + ADT + boot_args at their PAs, 6-instruction stub sets x0 and jumps), `-M virt,gic-version=3 -cpu cortex-a76`
  (same ID_AA64MMFR0 as Kryo 470), 4G RAM so 0x9c000000 fb and 0xb0000000 kernel are plain RAM.
  Outputs `fb.png` (the screen), `regs.txt`, `qemu.log` (exceptions with ESR/FAR/ELR). `--gdb` halts with a stub on :1234
  (system `gdb` + `set architecture aarch64`, `hbreak *VA` works with the MMU on).
- Not emulated: Qualcomm XPUs, ABL, real panel, PSCI conduit (QEMU virt uses hvc). Hardware still decides those.
- Example: `python3 tools/mkadt.py /tmp/q.adt --qemu && python3 tools/mkpayload.py xnu/out-0013/kernel.development.sweet /tmp/q.adt /tmp/pq.bin --cmdline 'debug=0xc serial=3 cpus=1 keepsyms=1 -enable_kprintf_spam' && python3 tools/qemu-sweet.py /tmp/pq.bin /tmp/q`

## Layout
- `backup/`  partition dumps + full sdb..sdf LUNs, `SHA256SUMS` (all verified on-device == local)
- `dtb/`     live FDT (from OrangeFox), PixelOS boot.img dtb, dtbo, dts versions
- `shim/`    bare-metal boot shim (`./build.sh` -> `out/shim-boot.img`)
- `research/` mainline sm7150 dts, XNU pe_fiq.c etc, PocketDarwin patches
- `tools/unpack_bootv2.py`

## Device access
- No root in PixelOS 17 (user build, adb root disabled). Root = `fastboot boot recovery/recovery.img` (OrangeFox R12.0_2, temp boot, not flashed).
- `fastboot boot` works for stock boot.img, OrangeFox, and our shim.
- Shim resets itself via PSCI SYSTEM_RESET; IMEM restart_reason 0x77665500 is seen
  (bootreason=bootloader) but ABL still boots Android, so it does not stop in fastboot.

## Hardware facts (live DT + shim measurements)
- Framebuffer (ABL cont splash): 0x9c000000, 1080x2400, stride 4320, a8r8g8b8, panel is DSC *video* mode (no kick needed).
- RAM: 0x80000000+2G, 0x100000000+0xfcc00000. Live reserved-memory = PixelOS base dtb + sweet dtbo fixups.
- GICv3: GICD 0x17a00000, GICR 0x17a60000 (stride 0x20000, 8 PEs). GICD_TYPER 0x007B041D: SecurityExtn=1 (DS=0).
  ABL leaves GICD_CTLR = 0x10 (ARE_NS on, groups off). Writing 0x13 reads back 0x12: EnableGrp1A (bit1) is the one that matters.
- GIC Group 1 VERIFIED (shim 2c): vtimer INTID 19 = 30 IRQs/300ms, ptimer INTID 18 = 30, SGI 1 to self = 10/10.
  ICC_SRE=1 already, ICC_CTLR 0x8440, priority/enable writes stick. GICR_IGROUPR0 and GICD_IGROUPRn read 0 from NS
  even though Group 1 delivery works (RAZ in NS view) - do not use them as a health check.
  INTID 28 shows pending constantly (unknown PPI 12).
- Timer 19.2 MHz. Qualcomm PPI numbering: secure-phys/phys/virt/hyp = PPI 1/2/3/0 -> vtimer INTID 19, ptimer 18 (NOT 27/30).
- PSCI 1.1 via SMC, SMCCC 1.1. CPU_ON ok; SYSTEM_SUSPEND and SYSTEM_RESET2 unsupported.
- SMP: CPU_ON works for all 7 secondaries (MPIDR 0x81000n00).
- Entry EL1, MMU off, x0 = DTB (magic ok). ID_AA64MMFR0 = ...101122: 16K granule YES, 4K YES.
- No serial console: debug UART SE is in SPI mode on sweet. Screen is the only debug channel.

## XNU implications
- XNU GICv3 path (pexpert/arm/pe_fiq.c, VMAPPLE) puts the timer (PPI 27) in Group 0 = FIQ. With SecurityExtn=1,
  Group 0 is secure -> impossible from NS EL1. Need: Group 1 IRQ, ICC_IGRPEN1, INTID 19, and the timer handled in the IRQ path.
- XNU VMAPPLE PSCI uses `hvc`; sweet needs `smc`.
- PocketDarwin NonAppleGenericCpu.patch only swaps -mcpu=apple-h7 for -march=armv8-a.

## Milestone 3 (2026-10-14): 16K MMU verified
- ABL loads the Image at 0x80080000 (base 0x80000000 + 0x80000) regardless of text_offset=0.
- 16K granule, T0SZ=28 (L2 start, 32MB blocks), MAIR 0x44ff00, TCR 0x1409CB51C, PARange=2 (40-bit PA).
- Only own image pages WB (Qualcomm XPUs: never map carve-outs cacheable); fb Normal-NC; rest Device.
- AT S1E1R checks all as expected; unmapped -> translation fault L2.
- Fill fb: 110 ms (MMU off) -> 3.5 ms (NC). Memory loop 70 ms -> 0.7 ms. vtimer + SGI IRQs still fine with MMU on.

## XNU loader design notes (xnu-8796)
- Entry: `_start` -> `start_first_cpu`, x0 = boot_args (PA), MMU off, EL1. boot_args: Revision/Version 2,
  virtBase/physBase/memSize/topOfKernelData, Boot_Video (fb 0x9c000000, rowBytes 4320, 1080x2400, depth 32),
  deviceTreeP/Length (ADT), CommandLine[608], bootFlags, memSizeActual.
- start.s maps [kernel mach header .. physBase+memSize) with cacheable BLOCKS. On Qualcomm every XPU carve-out
  must therefore lie below the kernel: use physBase = 0xb0000000 (above ramdump_fb 0xaf000000+16M,
  cdsp_sec, qseecom), end before rmtfs 0xfde01000 -> memSize ~0x4d000000 for bring-up.
- Base ADT: iPhone 8 d20ap DeviceTree from iOS 16.7.16 IPSW (tools/remotezip.py + tools/adt.py; LZFSE payload).
  Template values are empty: the loader must fill chosen/*, memory-map, cpu*/reg etc. like iBoot.
- XNU build: GitHub Actions (dipa-studio/vmios, xnu.yml) via blacktop/darwin-xnu-build, MACOS_VERSION=13.5.
  New-clang fixes in xnu/patches; Xcode 16 iig is incompatible (IORPC.kernelContent) -> macos-14 runner, oldest Xcode.

## Kernel architecture plan (SWEET machine config)
- First stock build (VMAPPLE) is arm64e (PAC). Kryo 470 = ARMv8.2, no PAC -> SWEET must build plain arm64
  (HAS_APPLE_PAC is only defined for __arm64e__, so arm64 drops PAC automatically).
- Template: VMAPPLE (16K pages, GICv3 code in pe_fiq.c) minus APPLEVIRTUALPLATFORM hypercalls/paravirt PAC,
  plus BCM2837 (generic ARM: no APPLE_ARM64_ARCH_FAMILY Apple sysregs). Do not link the KDK lib<cfg>.os.*.a.
- Timer: XNU expects it on FIQ (sleh_fiq -> rtclock_intr). SWEET: GIC Group 1, so sleh_irq must ack ICC_IAR1,
  route INTID 19 to the same timer path, SGIs to cpu_signal_handler, EOI via ICC_EOIR1.
- SMP/interrupts: open-source AppleARMSMP (USE_APPLEARMSMP) needs an IOInterruptController (AIC role) and an
  IOPMGR (CPU power -> PSCI CPU_ON via SMC). Plan: built-in IOKit classes (SweetGIC, SweetPMGR, platform
  expert) compiled into the kernel and matched via iokit/KernelConfigTables.cpp -> no closed kexts needed.
- Debug: xnu patch 0003 sweet-fbcon = kprintf drawn on the framebuffer (ADT node "sweet-fbcon").
- ADT /arm-io ranges must not map to parent 0 (pe_arm_get_soc_base_phys()==0 disables serial): use parent 0x1000000.

## Status 2026-10-14 late: first XNU boot attempt
- SWEET kernel builds (CI run 38635343732, patches 0001-0009). Verified offline: arm64, no PAC, no >v8.2 code,
  70300 classic relocs all in range (slide 0 = no loader work), entry = __start.
- Boot: shim loader worked (initrd 0x846F0000-0x855FE3E0, BOOTARG 0xB1FF8000, JUMP 0xB146A488) but screen stayed
  red -> xnu died/hung before serial_init (fbcon). kprintf is a no-op before STARTUP_SUB_KPRINTF.
- Historical next-step plan (patch 0010, now implemented and built; see active handoff above): early fb debug channel
  1. start.s start_first_cpu (after mov x20,x0 / mov x21,#0): PA marker band (MMU off, direct store to 0x9c000000).
  2. start.s after both create_bootstrap_mapping calls: add ONE block entry to the existing V=P L2 table
     (x25 + 2*PGBYTES; do NOT call create_bootstrap_mapping again: fb and RAM share L1 entry 0, it would replace
     the L2 table). Entry = TYPE_BLOCK|VALID|SH(OUTER)|ATTRINDX(CACHE_ATTRINDX_WRITECOMB=1)|AF|PNX|NX|0x9c000000,
     index = (va & ARM_TT_L2_INDEX_MASK) >> ARM_TT_L2_SHIFT.
  3. new osfmk/arm64/sweet_early.c (+files.arm64 entry): sweet_early_mark(n) colored bands at screen bottom and
     sweet_early_putc using iso_font via VA=PA while the bootstrap TTBR0 is live; disable before
     arm_vm_init's set_mmu_ttb(invalid_ttep) (arm_vm_init.c:2148).
  4. markers in arm_init after PE_init_platform, ml_parse_cpu_topology, cpu_bootstrap, kernel_startup_bootstrap,
     cpu_init, before arm_vm_init.
  5. panic hook at top of panic_trap_to_debugger: va_copy + _doprnt(fmt, &copy, sweet_early_putc, 16).
  Verify with tools/xnu-cc.py (compile+symbols) and patch-order simulation before the single CI run.

### >>> TOUCH IS ALIVE, AND THE STUTTER IS NOT A GPU PROBLEM (2026-10-23, after midnight) <<<

Two kernel defects blocked every gesture, both now fixed in source and, because there is no Xcode here, also in the built kernel via `tools/kernel-patch.py` (byte-checked sites, undo sidecar):

1. `sweet_touch_init()` voted the L11C rail through RPMh; QEMU does not emulate that block (reads back `0xffffffff`), the vote returned ENODEV and the driver `goto out`, so the GT9896 was never probed. `artifacts/nocc-log2.txt` proves the same VM probed it fine before that vote existed. Fix: kernel 0085 (warn and keep going); binary preset `touch-skip-rail-vote` at `0x74E9AAC`.
2. The QEMU model only sets the report's "valid" bit while the state file says down, so a lift looked like "no new frame" and the driver kept `st.active` forever - the finger never came up. Fix: kernel 0086 (empty frame releases contacts) plus a model fix in `vm/qemu/sweet_touch.c` (emit one valid empty frame per lift); binary preset `touch-release-on-empty-frame` at `0x74EA06C`, which jumps to the existing `touch_report(0, x, y)` call site (w0 is still 0 from the successful `touch_read`).

Verified on the K70 Pro: `SWEET HID: touch 0 down/up` in pairs, and one swipe took iOS Setup from the Hello screen to the country picker.

**Performance, honestly.** There is no GPU to enable: the guest log has zero occurrences of `IOAccelerator`, `Metal` or `IOGPU`, so CoreAnimation runs its software renderer, and QEMU `-M virt` has no GPU to pass through anyway (iOS has no Adreno driver either). Per frame the guest rasterizes 1125x2436 and the kernel memcpys 10.4 MB into the 1080x2400 panel; measured 16.5 fps during animation. The three levers are resolution (ADT + kernel + app), MTTCG (engine), and dropping redundant presents (little to gain - presents are already change-driven).

`VmEngine` now takes `tcgmulti=1` from the command line and uses `-accel tcg,thread=multi`; `tools/bootargs.py vm-mttcg` is the profile. It boots, shows five threads in `/proc/<pid>/cmdline`, and does **not** trip the pset0 ticket lock - but it is not the fix for responsiveness, the software rasterizer is.

The APK can be built on Windows without Android Studio; the whole recipe (JDK 17, SDK 35, Gradle 8.9 from mirrors, `android.overridePathCheck=true` for the CJK path, and the signature mismatch that forces an uninstall + 16 GiB image re-push) is in `android/README.md`.
