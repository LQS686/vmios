# vmios 命名与符号规范

本规范对新代码具有约束力。存量代码除下列“冻结的遗留命名空间”外均遵循本
规范；遗留命名只在“内核 + payload”整体迁移时统一修改，禁止零散改名。

## 1. 命名空间划分

vmios 分三层标识符，改动时先确认属于哪一层：

| 层 | 命名空间 | 示例 |
| --- | --- | --- |
| 项目、仓库、网站、发布产物 | `vmios` | `vmios`、`vmios-device-test.py`、`dev.vmios.*` |
| 宿主侧：Android 应用、PC 工具、QEMU 设备、文档 | `vmios` | `dev.vmios.sweetvm`、`VmEngine` |
| 客户机平台 ABI：内核驱动、启动参数、payload 格式 | `sweet`（冻结） | `sweetfb_*`、`sweet_ufs`、`SWEETXNU`、`sweetmetal=1` |

**为什么冻结 `sweet`：** 客户机 ABI 已编译进 XNU 补丁、ADT、设备树属性与全部
历史 payload。改名会让已保存的 payload 与设备镜像失效，因此必须作为一次带版本
号的整体迁移完成，不能在同一子系统里混用 `vmios` 与 `sweet`。新增的客户机
ABI 标识符继续使用 `sweet` 前缀，直到整体迁移。

## 2. 通用标识符规则

- **C / 内核**：函数与变量 `snake_case`；宏与枚举常量 `UPPER_SNAKE_CASE`；
  类型 `PascalCase`（如 `SweetSurface`）。
- **Objective-C++ / C++ 类**：`PascalCase`。宿主侧新类使用 `Vmios` 前缀
  （如 `VmiosMetalDevice`）；客户机 ABI 保留 `Sweet` 前缀（如
  `SweetGPUUserClient`）。方法与成员变量与所在文件既有风格保持一致。
- **Java / Kotlin**：包名全小写（`dev.vmios.sweetvm`）；类 `PascalCase`；
  方法与字段 `lowerCamelCase`；常量 `UPPER_SNAKE_CASE`；文件名与公开类同名。
- **Python / Shell 工具**：文件名 `kebab-case`（如 `mk-payload.py`、
  `sweet-log-pull.sh`）；函数与变量 `snake_case`；常量 `UPPER_SNAKE_CASE`。
- **文档**：`docs/` 下新文档用 `kebab-case.md`；`README.md`、`AGENTS.md`、
  `CREDITS.md`、`NOTES.md` 等既有大写文件名保留（工具与习惯依赖）。
- **内核补丁**：`NNNN-sweet-<主题>.patch`。序号全局递增、不复用；主题小写
  kebab-case；一个补丁只做一件事，跨子系统必须拆分。
- **启动参数**：客户机使用 `sweet<区域>_<开关>=<值>`（如 `sweetfb_hz`、
  `sweetmetal`、`gpu_wire`）；宿主脚本参数使用 `--vmios-*`，QEMU 属性使用
  `vmios.*`。

## 3. 符号与线上格式

- **线上（wire）结构**一律使用定宽类型（`uint32_t` 等）并写明字段顺序；禁止
  在 wire 上使用 `long`、`size_t` 或依赖编译器布局。打包结构必须标注
  `__attribute__((packed))`，并用 `sizeof` 校验。
- **魔数**优先使用 8 字节 ASCII（`SWEETXNU`、`SWEETLOG`）或带注释的 32 位
  十六进制常量；已有通道不得另造新魔数。
- **导出符号**（内核源文件或 dylib）必须有头文件声明；文件内部符号一律
  `static`。
- **日志前缀**固定：`SWEET GPU:`、`SWEET FB:`、`SWEETMETAL:`、`vmios:`；
  Android 宿主日志 tag 使用 `vmios-<组件>`。
- **错误处理**返回明确状态（`IOReturn`、`kern_return_t`、Java 异常），同类
  错误只记录一次；禁止静默吞掉错误。

## 4. 文件与目录

- `vm/` 放虚拟硬件，一个设备一个文件（`sweet_ufs.c`、`sweet_touch.c`）；
  宿主 GPU 代码位于 `vm/metal/` 与 `android/.../GpuWireServer.java`。
- `tools/` 放独立脚本：必须有 `--help`，不依赖隐藏状态。
- 生成物（`research/`、`artifacts/`、`.tools/`、`*/build/`、`xnu/out-*/`）
  一律不入库。

## 5. 版本与 payload 标识

- payload 魔数保持 `SWEETXNU` 与版本字段；不兼容的布局变更必须同时提升版本，
  并同步修改 `tools/mkpayload.py` 与 shim 读取端。
- 启动参数属于 ABI：只增不改，旧名字保留到 `sweet` -> `vmios` 整体迁移。
