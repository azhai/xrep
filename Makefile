# =============================================================================
# xrep — 交叉编译 Makefile
# -----------------------------------------------------------------------------
# 为什么需要 zig：
#   Odin 的原生链接器（默认 / -linker:lld）在本机只能链接「本机平台」和
#   `darwin_amd64`（走 macOS SDK）；对 linux_* / windows_* 会直接报
#   "Linking for cross compilation for this platform is not yet supported"。
#   因此本 Makefile 的策略是分两条路：
#
#     A. darwin_*   → odin 原生链接（-linker:lld），不需要 zig。
#     B. 其余平台   → odin 只负责编译（-build-mode:obj），再用 `zig cc` 链接。
#                     zig 自带各平台的 libc / 导入库，无需 sysroot 或 Windows SDK。
#
#   两条路的产物都是完整可执行文件，不是"能编译"而已。
#
# 前置要求：
#   - odin（dev-2026-10 或更新）
#   - zig（仅非 darwin 目标需要；已验证 0.17.0）
#
# 常用命令：
#   make              构建全部主流平台（默认 = all）
#   make host         只构建当前机器平台
#   make main         五大主流：darwin x2 / linux amd64+arm64 / windows amd64
#   make extra        扩展：linux 386/arm/riscv64、freebsd amd64+arm64
#   make musl         Linux 静态链接变体（musl，无 glibc 依赖）
#   make universal    macOS universal2（arm64 + amd64 用 lipo 合并）
#   make check        用 file(1) 核对每个产物的真实格式
#   make list         列出平台表
#   make clean        清掉 dist/ 与 .build/
# =============================================================================

SHELL := /bin/sh

# ---- 工具与可配置项 --------------------------------------------------------

ODIN  ?= odin
ZIG   ?= zig
# odin 优化级别：none|minimal|size|speed
# 注意：这些赋值不要写行内注释——GNU make 会把 `#` 前的空格一并算进变量值。
OPT   ?= size
DIST  ?= dist
BUILD ?= .build
# darwin 原生链接使用的链接器
LINKER ?= lld

# zig cc 的编译选项。-O2 是链接期优化等级，与 odin 的 -o:$(OPT) 无关。
ZIG_CFLAGS ?= -O2

# 本机 PATH 里的 clang 可能被 Android NDK 抢占，导致链接报 unknown file type。
# 与 build.sh 保持一致：显式指向系统 Apple clang。
ODIN_CC ?= $(shell test -x /usr/bin/clang && echo /usr/bin/clang)
export ODIN_CC

# Windows 目标：Odin 要求给出 -windows-sdk-root，但走 zig cc 链接时并不真的
# 需要 SDK 内容，给一个空目录即可通过该检查（zig 自带 mingw 导入库）。
WINSDK ?= $(BUILD)/winsdk

VERSION := $(shell grep -m1 'XREP_VERSION ::' common.odin | cut -d'"' -f2)
ZIG_PATH := $(shell command -v $(ZIG) 2>/dev/null)

# ---- 平台表生成 ------------------------------------------------------------
#
# $(call DEFINE_TARGET, 短名, odin-target, zig-triple, 扩展名,
#                       额外链接参数, native|cross, 需要 _fltused)
#
# 第 7 参说明：Windows 的 COFF 目标文件会引用两个 mingw 没有的符号：
#   BCryptGenRandom  —— Odin runtime 的随机源，由 bcrypt 导入库提供（-lbcrypt）
#   _fltused         —— MSVC 的浮点使用标记，mingw 未定义；这里自行提供一个
#                       空符号垫片（见下方 fltused 规则）
define DEFINE_TARGET
TARGETS += $(1)
.PHONY: $(1)
ifeq ($(7),yes)
$(1): $(BUILD)/fltused-$(1).o
$(BUILD)/fltused-$(1).o:
	@mkdir -p $(BUILD)
	@printf 'int _fltused = 0x9875;\n' > $(BUILD)/fltused-$(1).c
	$(ZIG) cc -target $(3) -c $(BUILD)/fltused-$(1).c -o $$@
endif
$(1):
	@mkdir -p $(DIST) $(BUILD) $(WINSDK)
ifeq ($(6),native)
	@echo "==> $(1)	[odin 原生链接]"
	$(ODIN) build . -target:$(2) -o:$(OPT) -linker:$(LINKER) -out:$(DIST)/xrep-$(1)$(4)
else
	@echo "==> $(1)	[obj -> $(ZIG) cc -target:$(3)]"
	@if [ -z "$(ZIG_PATH)" ]; then \
		echo "错误：构建 $(1) 需要 $(ZIG)，但未在 PATH 中找到。" >&2; \
		echo "      安装：brew install zig   （或改用 'make host' 只构建本机平台）" >&2; \
		exit 1; \
	fi
	$(ODIN) build . -target:$(2) -build-mode:obj -o:$(OPT) -out:$(BUILD)/$(1).o \
		$(if $(findstring windows,$(2)),-windows-sdk-root:$(WINSDK),)
	$(ZIG) cc -target $(3) $(ZIG_CFLAGS) $(BUILD)/$(1).o $(5) -o $(DIST)/xrep-$(1)$(4)
	@rm -f $(DIST)/xrep-$(1).pdb   # lld-link 顺手生成的调试库，分发不需要
endif
endef

# --- 主流（Tier 1）---
$(eval $(call DEFINE_TARGET,darwin-arm64,darwin_arm64,,,,native,))
$(eval $(call DEFINE_TARGET,darwin-amd64,darwin_amd64,,,,native,))
$(eval $(call DEFINE_TARGET,linux-amd64,linux_amd64,x86_64-linux-gnu,,,cross,))
$(eval $(call DEFINE_TARGET,linux-arm64,linux_arm64,aarch64-linux-gnu,,,cross,))
$(eval $(call DEFINE_TARGET,windows-amd64,windows_amd64,x86_64-windows-gnu,.exe,$(BUILD)/fltused-windows-amd64.o -lbcrypt,cross,yes))

# --- 扩展（Tier 2）---
$(eval $(call DEFINE_TARGET,linux-386,linux_i386,x86-linux-gnu,,,cross,))
$(eval $(call DEFINE_TARGET,linux-arm,linux_arm32,arm-linux-gnueabihf,,,cross,))
$(eval $(call DEFINE_TARGET,linux-riscv64,linux_riscv64,riscv64-linux-gnu,,,cross,))
$(eval $(call DEFINE_TARGET,freebsd-amd64,freebsd_amd64,x86_64-freebsd-none,,,cross,))
$(eval $(call DEFINE_TARGET,freebsd-arm64,freebsd_arm64,aarch64-freebsd-none,,,cross,))

# --- Linux 静态变体（musl，不依赖目标机 glibc 版本）---
# 注意：zig 0.17 起 i386 的架构名是 x86，不是 i386。
$(eval $(call DEFINE_TARGET,linux-amd64-musl,linux_amd64,x86_64-linux-musl,,-static,cross,))
$(eval $(call DEFINE_TARGET,linux-arm64-musl,linux_arm64,aarch64-linux-musl,,-static,cross,))

MAIN_TARGETS  := darwin-arm64 darwin-amd64 linux-amd64 linux-arm64 windows-amd64
EXTRA_TARGETS := linux-386 linux-arm linux-riscv64 freebsd-amd64 freebsd-arm64
MUSL_TARGETS  := linux-amd64-musl linux-arm64-musl

# ---- 聚合目标 --------------------------------------------------------------

HOST_OS   := $(shell uname -s | tr '[:upper:]' '[:lower:]')
HOST_ARCH := $(patsubst x86_64,amd64,$(shell uname -m))
HOST_TARGET := $(HOST_OS)-$(HOST_ARCH)

.PHONY: all main extra musl host universal check list clean distclean test checksums

.DEFAULT_GOAL := all

all: $(MAIN_TARGETS) $(EXTRA_TARGETS)

main: $(MAIN_TARGETS)

extra: $(EXTRA_TARGETS)

musl: $(MUSL_TARGETS)

# 只构建当前机器平台。若本机平台不在表中（如 linux-x86_64 之外的冷门组合），
# 回退到一次普通的 odin build。
host:
	@mkdir -p $(DIST)
	@if echo " $(TARGETS) " | grep -q " $(HOST_TARGET) "; then \
		$(MAKE) $(HOST_TARGET); \
	else \
		echo "==> host [$(HOST_TARGET) 不在平台表中，直接 odin build]"; \
		$(ODIN) build . -o:$(OPT) -linker:$(LINKER) -out:$(DIST)/xrep-$(HOST_TARGET); \
	fi

# macOS universal2：把 arm64 与 amd64 两个 Mach-O 合并为一个胖二进制。
universal: darwin-arm64 darwin-amd64
	@mkdir -p $(DIST)
	lipo -create -output $(DIST)/xrep-darwin-universal \
		$(DIST)/xrep-darwin-arm64 $(DIST)/xrep-darwin-amd64
	@echo "==> darwin-universal	[lipo 合并]"

check:
	@if [ ! -d $(DIST) ] || [ -z "$$(ls -A $(DIST) 2>/dev/null)" ]; then \
		echo "dist/ 为空，先运行 make" >&2; exit 1; \
	fi
	@for f in $(DIST)/*; do printf '%-40s ' "$$(basename $$f)"; file -b "$$f"; done

list:
	@echo "平台短名              odin target        zig triple"
	@echo "--------------------  -----------------  -------------------------"
	@printf '%s\n' \
		"darwin-arm64          darwin_arm64       (odin 原生链接)" \
		"darwin-amd64          darwin_amd64       (odin 原生链接)" \
		"linux-amd64           linux_amd64        x86_64-linux-gnu" \
		"linux-arm64           linux_arm64        aarch64-linux-gnu" \
		"windows-amd64         windows_amd64      x86_64-windows-gnu" \
		"linux-386             linux_i386         x86-linux-gnu" \
		"linux-arm             linux_arm32        arm-linux-gnueabihf" \
		"linux-riscv64         linux_riscv64      riscv64-linux-gnu" \
		"freebsd-amd64         freebsd_amd64      x86_64-freebsd-none" \
		"freebsd-arm64         freebsd_arm64      aarch64-freebsd-none" \
		"linux-amd64-musl      linux_amd64        x86_64-linux-musl (静态)" \
		"linux-arm64-musl      linux_arm64        aarch64-linux-musl (静态)"

# 分发校验和（文件名带版本，避免与旧产物混淆）
checksums:
	@cd $(DIST) && shasum -a 256 xrep-* > SHA256SUMS-$(VERSION).txt
	@echo "已生成 $(DIST)/SHA256SUMS-$(VERSION).txt"

test:
	./test.sh

clean:
	rm -rf $(DIST) $(BUILD)

distclean: clean
	rm -f xrep
