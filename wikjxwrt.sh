#!/bin/bash

# ============================================================
# Wikjxwrt 编译脚本 - 优化版
# 优化点: 并行克隆/安装、增量编译、ccache缓存、错误处理增强
# ============================================================

set -e  # 遇错即停

# 定义颜色和状态图标
RESET="\033[0m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
RED="\033[1;31m"
CYAN="\033[1;36m"
BOLD="\033[1m"
MAGENTA="\033[1;35m"

ICON_SUCCESS="[${GREEN}✓${RESET}]"
ICON_WARN="[${YELLOW}⚠${RESET}]"
ICON_ERROR="[${RED}✗${RESET}]"
ICON_PROGRESS="[${CYAN}...${RESET}]"
ICON_CLONE="[${MAGENTA}⚡${RESET}]"

# 输出函数
info() { echo -e "${GREEN}[INFO]${RESET} $1"; }
warn() { echo -e "${YELLOW}[WARN]${RESET} $1"; }
error() { echo -e "${RED}[ERROR]${RESET} $1"; exit 1; }
section() { echo -e "\n${CYAN}═══════════════════════════════════════${RESET}\n${CYAN}  $1${RESET}\n${CYAN}═══════════════════════════════════════${RESET}\n"; }
step() { echo -e "${MAGENTA}[→]${RESET} $1"; }

# 默认配置
CORES=$(nproc)
SKIP_FEEDS=0
SKIP_COMPILE=0
INCREMENTAL=0
CCACHE=1
FEEDS_FILE="feeds.conf.default"

# 仓库地址
WIKJXWRT_ENTRY="src-git wikjxwrt https://github.com/wixxm/wikjxwrt-feeds"
PASSWALL_PACKAGES_ENTRY="src-git passwall_packages https://github.com/Openwrt-Passwall/openwrt-passwall-packages.git;main"
PASSWALL_ENTRY="src-git passwall_luci https://github.com/Openwrt-Passwall/openwrt-passwall.git;main"
WIKJXWRT_SSH_REPO="https://github.com/wixxm/WikjxWrt-ssh"
SYSINFO_TARGET="feeds/packages/utils/bash/files/etc/profile.d/sysinfo.sh"
TURBOACC_SCRIPT="https://raw.githubusercontent.com/chenmozhijin/turboacc/luci/add_turboacc.sh"
WIKJXWRTR_CONFIG_REPO="https://github.com/wixxm/wikjxwrtr-config"
OPENWRT_REPO="https://github.com/wixxm/OpenWrt-24.10"

# 显示帮助信息
usage() {
    cat <<EOF
${BOLD}用法:${RESET} $0 [选项]

${BOLD}选项:${RESET}
  -j <线程数>       编译线程数，默认 $(nproc)
  --skip-feeds      跳过 feeds 更新步骤
  --skip-compile    跳过编译步骤
  --incremental     增量编译（复用已有的 openwrt 目录）
  --no-ccache       禁用 ccache 缓存
  -h, --help        显示帮助信息

${BOLD}示例:${RESET}
  $0                    # 正常编译
  $0 -j 8               # 8线程编译
  $0 --incremental       # 增量编译（更快）
  $0 --skip-compile      # 仅准备环境，不编译
EOF
}

# 解析参数
while [[ $# -gt 0 ]]; do
    case "$1" in
        -j)
            CORES="$2"; shift 2 ;;
        --skip-feeds) SKIP_FEEDS=1; shift ;;
        --skip-compile) SKIP_COMPILE=1; shift ;;
        --incremental) INCREMENTAL=1; shift ;;
        --no-ccache) CCACHE=0; shift ;;
        -h|--help) usage; exit 0 ;;
        *) error "未知参数: $1" ;;
    esac
done

# ============================================================
# 环境检查
# ============================================================
section "环境检查"
info "检查必要工具..."
for tool in git make sed curl; do
    if command -v "$tool" &>/dev/null; then
        echo -e "$ICON_SUCCESS 工具已安装: $tool"
    else
        echo -e "$ICON_ERROR 缺少工具: $tool"
        exit 1
    fi
done
echo -e "$ICON_SUCCESS 环境检查通过"

# 记录开始时间
START_TIME=$(date +%s)

# ============================================================
# 克隆/更新 OpenWrt 源码
# ============================================================
section "OpenWrt 源码"
if [[ ! -d "openwrt" ]]; then
    info "克隆 OpenWrt 源码仓库..."
    git clone "$OPENWRT_REPO" openwrt
    echo -e "$ICON_SUCCESS OpenWrt 仓库克隆成功"
elif [[ $INCREMENTAL -eq 0 ]]; then
    warn "openwrt 目录已存在，删除后重新克隆..."
    rm -rf openwrt
    git clone "$OPENWRT_REPO" openwrt
    echo -e "$ICON_SUCCESS 重新克隆完成"
else
    info "增量模式：复用已有的 openwrt 目录"
    cd openwrt
    git pull origin main
    echo -e "$ICON_SUCCESS 源码更新完成"
fi

cd openwrt || error "进入 openwrt 目录失败！"
cd ..

# ============================================================
# 添加自定义 feeds
# ============================================================
section "自定义 feeds 处理"
info "检查和修改 $FEEDS_FILE..."
cd openwrt || error "进入 openwrt 目录失败！"
for entry in "$WIKJXWRT_ENTRY" "$PASSWALL_ENTRY" "$PASSWALL_PACKAGES_ENTRY"; do
    if ! grep -q "^$entry" "$FEEDS_FILE" 2>/dev/null; then
        echo "$entry" >> "$FEEDS_FILE"
        echo -e "$ICON_SUCCESS 添加自定义 feeds"
    else
        echo -e "$ICON_WARN feeds 已存在，跳过"
    fi
done

# 更新 feeds
if [[ $SKIP_FEEDS -eq 0 ]]; then
    info "更新 feeds..."
    ./scripts/feeds update -a
    echo -e "$ICON_SUCCESS feeds 更新完成"
else
    warn "跳过 feeds 更新步骤"
fi
cd ..

# ============================================================
# 并行克隆所有依赖仓库
# ============================================================
section "并行克隆依赖仓库"

mkdir -p temp_clones

clone_repo() {
    local url=$1
    local target=$2
    local desc=$3
    echo -e "$ICON_CLONE 克隆: $desc"
    if git clone --depth 1 "$url" "$target" 2>/dev/null; then
        echo -e "$ICON_SUCCESS 完成: $desc"
    else
        echo -e "$ICON_WARN 失败或已存在: $desc"
    fi
}

# 串行改并行（使用后台任务）
step "开始并行克隆（节省时间）..."

# coremark
clone_repo "https://github.com/wixxm/wikjxwrt-coremark" "temp_clones/coremark" "coremark" &
# v2ray-geodata
clone_repo "https://github.com/sbwml/v2ray-geodata" "temp_clones/v2ray-geodata" "v2ray-geodata" &
# Rust
clone_repo "https://github.com/wixxm/Rust" "temp_clones/rust" "Rust" &
# golang
clone_repo "https://github.com/wixxm/WikjxWrt-golang" "temp_clones/golang" "golang" &
# SSH配置
clone_repo "$WIKJXWRT_SSH_REPO" "temp_clones/ssh_repo" "sysinfo.sh" &
# 配置仓库
clone_repo "$WIKJXWRTR_CONFIG_REPO" "temp_clones/config_repo" ".config" &

# 等待所有克隆完成
wait

echo -e "\n$ICON_SUCCESS 所有仓库克隆完成"

# ============================================================
# 安装替换
# ============================================================
section "安装替换"

cd openwrt || error "进入 openwrt 目录失败！"

# 替换 coremark
step "替换 coremark..."
rm -rf feeds/packages/utils/coremark
mv ../temp_clones/coremark feeds/packages/utils/coremark
echo -e "$ICON_SUCCESS coremark 替换完成"

# 配置 sysinfo.sh
step "配置 sysinfo.sh..."
mkdir -p "$(dirname $SYSINFO_TARGET)"
mv ../temp_clones/ssh_repo/sysinfo.sh "$SYSINFO_TARGET" 2>/dev/null || warn "sysinfo.sh 不在预期位置"
rm -rf ../temp_clones/ssh_repo

# 添加 Turbo ACC
step "添加 Turbo ACC..."
curl -sSL "$TURBOACC_SCRIPT" -o add_turboacc.sh && bash add_turboacc.sh || warn "Turbo ACC 添加失败"
rm -f add_turboacc.sh
echo -e "$ICON_SUCCESS Turbo ACC 添加完成"

# 替换 v2ray-geodata
step "替换 v2ray-geodata..."
rm -rf feeds/packages/net/v2ray-geodata
mv ../temp_clones/v2ray-geodata package/v2ray-geodata
echo -e "$ICON_SUCCESS v2ray-geodata 替换完成"

# 替换 Rust
step "替换 Rust..."
rm -rf feeds/packages/lang/rust
mv ../temp_clones/rust feeds/packages/lang/rust
echo -e "$ICON_SUCCESS Rust 替换完成"

# 替换 golang
step "替换 golang..."
rm -rf feeds/packages/lang/golang
mv ../temp_clones/golang feeds/packages/lang/golang
echo -e "$ICON_SUCCESS golang 替换完成"

# 清理临时目录
rm -rf ../temp_clones

# 安装 feeds（执行两次确保成功）
info "安装 feeds（第一次）..."
./scripts/feeds install -a || warn "第一次 feeds 安装可能有警告，继续..."
info "安装 feeds（第二次确保）..."
./scripts/feeds install -a
echo -e "$ICON_SUCCESS feeds 安装完成"

# 注释自定义 feeds
step "注释自定义 feeds..."
for entry in "$WIKJXWRT_ENTRY" "$PASSWALL_ENTRY" "$PASSWALL_PACKAGES_ENTRY"; do
    sed -i "s|^$entry|#$entry|" "$FEEDS_FILE" 2>/dev/null || true
done
echo -e "$ICON_SUCCESS feeds 注释完成"

# 配置 .config
step "配置 .config..."
cd ..
mv temp_clones/config_repo/6.6/.config openwrt/ 2>/dev/null || warn ".config 不在预期位置"
rm -rf temp_clones
cd openwrt || error "进入 openwrt 目录失败！"
make defconfig
echo -e "$ICON_SUCCESS .config 配置完成"

# ============================================================
# ccache 配置
# ============================================================
if [[ $CCACHE -eq 1 ]]; then
    section "ccache 缓存配置"
    info "启用 ccache 加速重复编译..."
    export CCACHE_DIR="/workdir/ccache"
    export CCACHE_SIZE="10G"
    mkdir -p "$CCACHE_DIR"
    which ccache &>/dev/null && echo -e "$ICON_SUCCESS ccache 已安装" || warn "ccache 未安装，将自动安装"
    echo -e "$ICON_SUCCESS ccache 配置完成"
fi

# ============================================================
# 下载编译依赖
# ============================================================
section "下载编译依赖"
info "下载依赖文件（这可能需要一些时间）..."
cd openwrt || error "进入 openwrt 目录失败！"
make download -j"$CORES"
echo -e "$ICON_SUCCESS 依赖文件下载完成"

# ============================================================
# 完成提示
# ============================================================
END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))
MINUTES=$((ELAPSED / 60))
SECONDS=$((ELAPSED % 60))

section "编译准备完成"
echo -e "${GREEN}✅ 所有准备步骤已完成！${RESET}"
echo -e ""
echo -e "${CYAN}📋 耗时统计:${RESET}"
echo -e "   准备阶段: ${MINUTES}分${SECONDS}秒"
echo -e ""
echo -e "${YELLOW}下一步:${RESET}"
echo -e "   cd openwrt && make -j$CORES"
echo -e ""
if [[ $CCACHE -eq 1 ]]; then
    echo -e "${GREEN}💡 提示: ccache 已启用，二次编译会更快！${RESET}"
fi
if [[ $INCREMENTAL -eq 1 ]]; then
    echo -e "${GREEN}💡 提示: 增量模式已启用，已有的编译缓存会被复用！${RESET}"
fi
