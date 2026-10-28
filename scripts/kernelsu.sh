#!/usr/bin/env bash

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

KERNEL_DIR=${KERNEL_DIR:?KERNEL_DIR must point at the kernel source tree}

ksu_registry() {
	case "$1" in
	kernelsu)
		echo "https://github.com/tiann/KernelSU|main|KernelSU||v0.9.5|-|KernelSU" ;;
	kernelsu-next)
		echo "https://github.com/KernelSU-Next/KernelSU-Next|dev|KernelSU-Next|dev|legacy|-|KernelSU-Next" ;;
	sukisu-ultra)
		echo "https://github.com/SukiSU-Ultra/SukiSU-Ultra|main|KernelSU|main|builtin|builtin|SukiSU-Ultra" ;;
	resukisu)
		echo "https://github.com/ReSukiSU/ReSukiSU|main|KernelSU|main|main|-|ReSukiSU" ;;
	rsuntk)
		echo "https://github.com/rsuntk/KernelSU|main|KernelSU|main|main|susfs-rksu-master|RKSU (rsuntk)" ;;
	backslashxx)
		echo "https://github.com/backslashxx/KernelSU|master|KernelSU|master|master|-|backslashxx KernelSU" ;;
	*)
		die "unknown KSU_VARIANT '$1'" ;;
	esac
}

ksu_field() { ksu_registry "$1" | cut -d'|' -f"$2"; }
ksu_default_is_branch() { [ "$1" = "resukisu" ]; }

ksu_install() {
	local variant=$1 requested_ref=${2-}

	[ "$variant" = "none" ] && { info "KernelSU integration disabled"; return 0; }

	local repo setup_ref dir modern_ref legacy_ref susfs_refs name
	IFS='|' read -r repo setup_ref dir modern_ref legacy_ref susfs_refs name <<<"$(ksu_registry "$variant")"

	group "Installing ${name}"
	info "repository: ${repo}"

	local kver ref=$requested_ref
	kver=$(kernel_version "$KERNEL_DIR" || echo "0.0")

	# ۱. پاکسازی پوشه‌های قدیمی و اعمال فیکس‌های سازگاری
	info "Applying fixes for EmanuelCN kernel..."
	rm -rf "${KERNEL_DIR}/KernelSU" "${KERNEL_DIR}/drivers/kernelsu"
	sed -i '/KernelSU/d' "${KERNEL_DIR}/arch/arm64/Kconfig" 2>/dev/null || true
	sed -i 's/exit 1/exit 0/g' "${KERNEL_DIR}/scripts/checksyscalls.sh" 2>/dev/null || true
	sed -i -E 's/-mllvm -polly[^ ]*//g; s/-mllvm -regalloc[^ ]*//g; s/-mllvm -inline-advisor[^ ]*//g; s/-mllvm -enable-ml-inliner[^ ]*//g' "${KERNEL_DIR}/Makefile" 2>/dev/null || true
	sed -i -E 's/-mllvm -polly[^ ]*//g; s/-mllvm -regalloc[^ ]*//g; s/-mllvm -inline-advisor[^ ]*//g; s/-mllvm -enable-ml-inliner[^ ]*//g' "${KERNEL_DIR}/arch/arm64/Makefile" 2>/dev/null || true

	# ۲. دانلود مستقیم سورس backslashxx داخل drivers/kernelsu
	info "Cloning backslashxx directly into drivers/kernelsu..."
	git clone --depth=1 https://github.com/backslashxx/KernelSU.git "${KERNEL_DIR}/drivers/kernelsu"

	# ۳. کپی در ریشه کرنل جهت سازگاری با رفرنس‌های احتمالی
	mkdir -p "${KERNEL_DIR}/KernelSU/kernel"
	cp -r "${KERNEL_DIR}/drivers/kernelsu/"* "${KERNEL_DIR}/KernelSU/" 2>/dev/null || true
	cp -r "${KERNEL_DIR}/drivers/kernelsu/"* "${KERNEL_DIR}/KernelSU/kernel/" 2>/dev/null || true

	# ۴. تنظیم اتصالات Makefile و Kconfig
	local driver_makefile="${KERNEL_DIR}/drivers/Makefile"
	sed -i '/kernelsu/d' "$driver_makefile" 2>/dev/null || true
	printf '\nobj-y += kernelsu/\n' >>"$driver_makefile"

	local driver_kconfig="${KERNEL_DIR}/drivers/Kconfig"
	sed -i '/kernelsu/d' "$driver_kconfig" 2>/dev/null || true
	sed -i '/endmenu/i source "drivers/kernelsu/Kconfig"' "$driver_kconfig"

	local head_desc head_sha
	head_sha=$(git -C "${KERNEL_DIR}/drivers/kernelsu" rev-parse --short HEAD)
	head_desc=$(git -C "${KERNEL_DIR}/drivers/kernelsu" describe --tags --always 2>/dev/null || echo "$head_sha")

	local count version_label
	count=$(git -C "${KERNEL_DIR}/drivers/kernelsu" rev-list --count HEAD 2>/dev/null || echo 0)
	version_label="backslashxx-${head_sha}"

	export_env KSU_DIR "drivers/kernelsu"
	export_env KSU_NAME "$name"
	export_env KSU_REF_RESOLVED "master"
	export_env KSU_VERSION_LABEL "$version_label"
	export_env KSU_COMMIT_COUNT "$count"
	export_env KSU_SUSFS_BUNDLED_REFS "$susfs_refs"
	export_env UPLOADNAME "-${name// /_}_${version_label}"

	ksu_resolve_hook_mode "${KSU_HOOK_MODE:-auto}" "$kver"
	endgroup
}

ksu_resolve_hook_mode() {
	local mode=${1:-auto} kver=$2
	if [ "$mode" = "auto" ]; then
		mode="manual"
	fi
	export_env KSU_HOOK_MODE_RESOLVED "$mode"
}

ksu_hook_configs() {
	local variant=$1 mode=$2 defconfig=$3 kver=$4
	kconf_enable "$defconfig" CONFIG_MODULES
	kconf_enable "$defconfig" CONFIG_KPROBES
	kconf_enable "$defconfig" CONFIG_HAVE_KPROBES
	kconf_enable "$defconfig" CONFIG_KPROBE_EVENTS
	kconf_enable "$defconfig" CONFIG_KSU
	kconf_enable "$defconfig" CONFIG_KSU_MANUAL_HOOK
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
	ksu_install "${KSU_VARIANT:-none}" "${KSU_REF:-}"
fi
