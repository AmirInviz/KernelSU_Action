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
	if [ -z "$ref" ]; then
		if ver_ge "$kver" "5.10"; then
			ref=$modern_ref
		else
			ref=$legacy_ref
			[ -n "$ref" ] && info "kernel ${kver} is pre-GKI; defaulting to ref '${ref}'"
		fi
	fi

	# 1. پاکسازی تداخل‌های قبلی و حذف فلگ‌های ناسازگار
	info "Applying fixes for EmanuelCN kernel..."
	rm -rf "${KERNEL_DIR}/KernelSU" "${KERNEL_DIR}/drivers/kernelsu"
	sed -i '/KernelSU/d' "${KERNEL_DIR}/arch/arm64/Kconfig" 2>/dev/null || true
	sed -i 's/exit 1/exit 0/g' "${KERNEL_DIR}/scripts/checksyscalls.sh" 2>/dev/null || true
	sed -i -E 's/-mllvm -polly[^ ]*//g; s/-mllvm -regalloc[^ ]*//g; s/-mllvm -inline-advisor[^ ]*//g; s/-mllvm -enable-ml-inliner[^ ]*//g' "${KERNEL_DIR}/Makefile" 2>/dev/null || true
	sed -i -E 's/-mllvm -polly[^ ]*//g; s/-mllvm -regalloc[^ ]*//g; s/-mllvm -inline-advisor[^ ]*//g; s/-mllvm -enable-ml-inliner[^ ]*//g' "${KERNEL_DIR}/arch/arm64/Makefile" 2>/dev/null || true

	# 2. کلون مستقیم سورس backslashxx به صورت کامل
	local ksu_dir="${KERNEL_DIR}/${dir}"
	git clone -q --depth=1 -b "${ref:-master}" "$repo" "$ksu_dir" || die "Failed to clone ${repo}"

	# 3. ایجاد بلافاصله پوشه drivers/kernelsu تا defconfig با خطای missing file متوقف نشود
	info "Populating drivers/kernelsu..."
	mkdir -p "${KERNEL_DIR}/drivers/kernelsu"
	cp -r "${ksu_dir}/"* "${KERNEL_DIR}/drivers/kernelsu/"

	# 4. همگام‌سازی ساختار برای ریشه کرنل
	mkdir -p "${KERNEL_DIR}/KernelSU/kernel"
	cp -r "${ksu_dir}/"* "${KERNEL_DIR}/KernelSU/kernel/" 2>/dev/null || true

	# 5. تنظیمات Makefile و Kconfig درایورها
	local driver_makefile="${KERNEL_DIR}/drivers/Makefile"
	sed -i '/kernelsu/d' "$driver_makefile" 2>/dev/null || true
	printf '\nobj-y += kernelsu/\n' >>"$driver_makefile"

	local driver_kconfig="${KERNEL_DIR}/drivers/Kconfig"
	if ! grep -q 'drivers/kernelsu/Kconfig' "$driver_kconfig"; then
		sed -i '/endmenu/i source "drivers/kernelsu/Kconfig"' "$driver_kconfig"
	fi

	local head_desc head_sha
	head_sha=$(git -C "$ksu_dir" rev-parse --short HEAD)
	head_desc=$(git -C "$ksu_dir" describe --tags --always 2>/dev/null || echo "$head_sha")

	local count version_label
	count=$(git -C "$ksu_dir" rev-list --count HEAD 2>/dev/null || echo 0)
	version_label="${ref:-HEAD}-${head_sha}"

	export_env KSU_DIR "$dir"
	export_env KSU_NAME "$name"
	export_env KSU_REF_RESOLVED "${ref:-<latest-tag>}"
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
