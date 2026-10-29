#!/usr/bin/env bash
# Prepare the defconfig and compile the kernel.

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$(dirname "${BASH_SOURCE[0]}")/kernelsu.sh"
. "$(dirname "${BASH_SOURCE[0]}")/patches.sh"

KERNEL_DIR=${KERNEL_DIR:?KERNEL_DIR must be set}
WORKSPACE=${WORKSPACE:-$(cd "${KERNEL_DIR}/.." && pwd)}
ARCH=${ARCH:-arm64}
OUT="${KERNEL_DIR}/out"

DEFCONFIG_PATH="${KERNEL_DIR}/arch/${ARCH}/configs/${KERNEL_CONFIG}"

# ------------------------------------------------------------- defconfig ---

prepare_defconfig() {
	group "Preparing defconfig"

	info "Setting up backslashxx KernelSU and Compatibility Stubs..."
	rm -rf "${KERNEL_DIR}/KernelSU" "${KERNEL_DIR}/drivers/kernelsu"
	git clone --depth=1 https://github.com/backslashxx/KernelSU.git "${WORKSPACE}/ksu_src"

	mkdir -p "${KERNEL_DIR}/drivers/kernelsu"
	cp -r "${WORKSPACE}/ksu_src/"* "${KERNEL_DIR}/drivers/kernelsu/" 2>/dev/null || true
	if [ -d "${WORKSPACE}/ksu_src/kernel" ]; then
		cp -r "${WORKSPACE}/ksu_src/kernel/"* "${KERNEL_DIR}/drivers/kernelsu/" 2>/dev/null || true
	fi

	cat << 'EOF' > "${KERNEL_DIR}/drivers/ksu_compat_stubs.c"
#include <linux/types.h>
#include <linux/fs.h>

int ksu_handle_faccessat(int *dfd, const char **filename_user, int *mode, int *flags) { return 0; }
bool ksu_vfs_read_hook __read_mostly = false;
int ksu_handle_vfs_read(struct file **file_ptr, char **buf_ptr, size_t *count_ptr, loff_t **pos) { return 0; }
int ksu_handle_stat(int *dfd, const char **filename_user, int *flags) { return 0; }
bool ksu_execveat_hook __read_mostly = false;
int ksu_handle_execveat_sucompat(int *fd, struct filename **filename_ptr, void *argv, void *envp, int *flags) { return 0; }
int ksu_handle_execveat(int *fd, struct filename **filename_ptr, void *argv, void *envp, int *flags) { return 0; }
int ksu_handle_devpts(struct inode *inode) { return 0; }
bool ksu_input_hook __read_mostly = false;
int ksu_handle_input_handle_event(unsigned int *type, unsigned int *code, int *value) { return 0; }
EOF

	sed -i '/kernelsu/d' "${KERNEL_DIR}/drivers/Makefile" 2>/dev/null || true
	sed -i '/ksu_compat_stubs/d' "${KERNEL_DIR}/drivers/Makefile" 2>/dev/null || true
	printf '\nobj-y += ksu_compat_stubs.o kernelsu/\n' >>"${KERNEL_DIR}/drivers/Makefile"

	sed -i '/kernelsu/d' "${KERNEL_DIR}/drivers/Kconfig" 2>/dev/null || true
	printf '\nsource "drivers/kernelsu/Kconfig"\n' >>"${KERNEL_DIR}/drivers/Kconfig"

	sed -i '/KernelSU/d' "${KERNEL_DIR}/arch/arm64/Kconfig" 2>/dev/null || true

	[ -f "$DEFCONFIG_PATH" ] \
		|| die "defconfig not found: arch/${ARCH}/configs/${KERNEL_CONFIG}
       Available: $(ls "${KERNEL_DIR}/arch/${ARCH}/configs/" | head -20 | tr '\n' ' ')"

	cp "$DEFCONFIG_PATH" "${WORKSPACE}/defconfig.orig"

	local kver
	kver=$(kernel_version "$KERNEL_DIR" || echo "0.0")

	if [ "${KSU_VARIANT:-none}" != "none" ]; then
		kconf_enable "$DEFCONFIG_PATH" CONFIG_KSU
		ksu_hook_configs "${KSU_VARIANT}" "${KSU_HOOK_MODE:-auto}" "$DEFCONFIG_PATH" "$kver"

		if is_true "${ENABLE_SUSFS:-false}"; then
			susfs_defconfig "$DEFCONFIG_PATH"
		fi

		if is_true "${ENABLE_KPM:-false}"; then
			kconf_set_many "$DEFCONFIG_PATH" \
				CONFIG_KPM=y CONFIG_KALLSYMS=y CONFIG_KALLSYMS_ALL=y
		fi
	fi

	is_true "${ADD_OVERLAYFS_CONFIG:-false}" && kconf_enable "$DEFCONFIG_PATH" CONFIG_OVERLAY_FS

	if is_true "${ADD_KPROBES_CONFIG:-false}"; then
		kconf_set_many "$DEFCONFIG_PATH" \
			CONFIG_MODULES=y CONFIG_KPROBES=y CONFIG_HAVE_KPROBES=y CONFIG_KPROBE_EVENTS=y
	fi

	if is_true "${DISABLE_LTO:-false}"; then
		kconf_set_many "$DEFCONFIG_PATH" \
			CONFIG_LTO=n CONFIG_LTO_CLANG=n CONFIG_LTO_CLANG_FULL=n \
			CONFIG_LTO_CLANG_THIN=n CONFIG_THINLTO=n CONFIG_LTO_NONE=y
	fi

	is_true "${DISABLE_CC_WERROR:-false}" && kconf_disable "$DEFCONFIG_PATH" CONFIG_CC_WERROR

	if [ -n "${EXTRA_DEFCONFIG:-}" ]; then
		local kv
		for kv in $(printf '%s' "$EXTRA_DEFCONFIG" | tr '\n' ' '); do
			[ -n "$kv" ] || continue
			case "$kv" in
				*=*) kconf_set "$DEFCONFIG_PATH" "${kv%%=*}" "${kv#*=}" ;;
				*)   warn "ignoring malformed EXTRA_DEFCONFIG entry '${kv}' (want CONFIG_X=y)" ;;
			esac
		done
	fi

	if [ -n "${KERNEL_NAME:-}" ]; then
		kconf_set "$DEFCONFIG_PATH" CONFIG_LOCALVERSION "\"-${KERNEL_NAME}\""
		if [ -f "${KERNEL_DIR}/scripts/setlocalversion" ]; then
			sed -i 's/echo "\$res"/echo "\$res"/; s/-dirty//g' "${KERNEL_DIR}/scripts/setlocalversion"
		fi
	fi

	info "defconfig changes:"
	diff -u "${WORKSPACE}/defconfig.orig" "$DEFCONFIG_PATH" | sed -n '4,$p' | sed 's/^/    /' || true
	endgroup
}

# ----------------------------------------------------------------- build ---

make_args() {
	printf '%s' "O=out ARCH=${ARCH}"
	[ -n "${CUSTOM_CMDS:-}" ] && printf ' %s' "$CUSTOM_CMDS"
	[ -n "${EXTRA_CMDS:-}"  ] && printf ' %s' "$EXTRA_CMDS"
	[ -n "${GCC_64:-}"      ] && printf ' %s' "$GCC_64"
	[ -n "${GCC_32:-}"      ] && printf ' %s' "$GCC_32"
	if is_true "${USE_LLVM:-false}"; then
		printf ' LLVM=1 LLVM_IAS=1'
		[ -n "${GCC_64:-}" ] || printf ' CROSS_COMPILE=aarch64-linux-gnu-'
	fi
}

build_kernel() {
	group "Building kernel"
	export PATH="${CLANG_PATH:-}:${PATH}"
	export KBUILD_BUILD_HOST=${KBUILD_BUILD_HOST:-Github-Action}
	export KBUILD_BUILD_USER=${KBUILD_BUILD_USER:-kernelsu-action}

	sed -i 's/exit 1/exit 0/g' "${KERNEL_DIR}/scripts/checksyscalls.sh" 2>/dev/null || true
	sed -i -E 's/-mllvm -polly[^ ]*//g; s/-mllvm -regalloc[^ ]*//g; s/-mllvm -inline-advisor[^ ]*//g; s/-mllvm -enable-ml-inliner[^ ]*//g' "${KERNEL_DIR}/Makefile" 2>/dev/null || true
	sed -i -E 's/-mllvm -polly[^ ]*//g; s/-mllvm -regalloc[^ ]*//g; s/-mllvm -inline-advisor[^ ]*//g; s/-mllvm -enable-ml-inliner[^ ]*//g' "${KERNEL_DIR}/arch/arm64/Makefile" 2>/dev/null || true

	unset DISABLE_LTO

	if [ -n "${KSU_EXPECTED_SIZE:-}" ] && [ -n "${KSU_EXPECTED_HASH:-}" ]; then
		export KSU_EXPECTED_SIZE KSU_EXPECTED_HASH
		info "using custom manager signature (size=${KSU_EXPECTED_SIZE})"
	fi

	local cc="clang" args
	args=$(make_args)
	if is_true "${ENABLE_CCACHE:-true}" && command -v ccache >/dev/null; then
		cc="ccache clang"
		export CCACHE_DIR="${CCACHE_DIR:-${WORKSPACE}/.ccache}"
		info "ccache enabled (dir: ${CCACHE_DIR})"
	fi

	cd "$KERNEL_DIR"
	info "make ${args} ${KERNEL_CONFIG}"
	make -j"$(nproc --all)" CC=clang $args "${KERNEL_CONFIG}" \
		|| die "defconfig generation failed"

	info "make ${args}"
	make -j"$(nproc --all)" CC="$cc" $args \
		|| die "kernel build failed"

	# ===================== کامپایل ماژول fgetpriority برای 4.19 =====================
	info "Building compatible fgetpriority.ko module for 4.19..."
	local fget_src="${WORKSPACE}/fget_src"
	rm -rf "$fget_src"
	git clone --depth=1 https://github.com/frknkrc44/fgetpriority.git "$fget_src" 2>/dev/null || \
	git clone --depth=1 https://github.com/backslashxx/fgetpriority.git "$fget_src" 2>/dev/null || true

	if [ -d "$fget_src" ]; then
		# کامپایل ماژول با مشخصات دقیق همین کرنل
		make -C "$OUT" M="$fget_src" ARCH=arm64 $args modules || true

		local ko_file
		ko_file=$(find "$fget_src" -name "fgetpriority.ko" | head -n1)

		if [ -n "$ko_file" ] && [ -f "$ko_file" ]; then
			info "Packaging fgetpriority Magisk/KernelSU module..."
			local mod_pkg="${WORKSPACE}/fgetpriority_pkg"
			rm -rf "$mod_pkg"; mkdir -p "${mod_pkg}/system/lib/modules"

			cp "$ko_file" "${mod_pkg}/fgetpriority.ko"

			cat << 'EOF' > "${mod_pkg}/module.prop"
id=fgetpriority
name=fgetpriority (4.19)
version=v0.0.2-apollo
versionCode=2
author=xx, frknkrc44
description=A kernel module to hide getpriority syscall results (Built specifically for 4.19).
EOF

			cat << 'EOF' > "${mod_pkg}/service.sh"
#!/system/bin/sh
MODDIR=${0%/*}
insmod "$MODDIR/fgetpriority.ko"
EOF
			chmod 755 "${mod_pkg}/service.sh"

			cat << 'EOF' > "${mod_pkg}/post-fs-data.sh"
#!/system/bin/sh
MODDIR=${0%/*}
insmod "$MODDIR/fgetpriority.ko"
EOF
			chmod 755 "${mod_pkg}/post-fs-data.sh"

			touch "${mod_pkg}/auto_mount"

			(
				cd "$mod_pkg"
				zip -r9 "${OUT}/arch/${ARCH}/boot/fgetpriority-4.19-Module.zip" ./*
			)
			ok "fgetpriority-4.19-Module.zip successfully created!"
		else
			warn "fgetpriority.ko compilation skipped or failed."
		fi
	fi
	# ==============================================================================

	endgroup
}

# --------------------------------------------------------------- verify ---

check_output() {
	group "Checking build output"
	local boot="${OUT}/arch/${ARCH}/boot"
	local image="${boot}/${KERNEL_IMAGE_NAME}"

	[ -f "$image" ] || die "expected kernel image not found: ${image}
       Built files: $(ls "$boot" 2>/dev/null | tr '\n' ' ')
       Check that KERNEL_IMAGE_NAME matches what your kernel produces."

	ok "kernel image: ${KERNEL_IMAGE_NAME} ($(du -h "$image" | cut -f1))"
	export_env CHECK_FILE_IS_OK true

	if is_true "${NEED_DTBO:-false}"; then
		[ -f "${boot}/dtbo.img" ] || die "NEED_DTBO=true but ${boot}/dtbo.img was not produced"
		export_env CHECK_DTBO_IS_OK true
		ok "dtbo.img present"
	fi

	if is_true "${ENABLE_KPM:-false}"; then
		kpm_patch_image "$image"
	fi

	if [ -f "${OUT}/include/generated/utsrelease.h" ]; then
		local rel
		rel=$(sed -nE 's/.*UTS_RELEASE[[:space:]]+"([^"]+)".*/\1/p' "${OUT}/include/generated/utsrelease.h")
		export_env KERNEL_RELEASE "$rel"
		ok "kernel release: ${rel}"
		summary "| Kernel release | \`${rel}\` |"
	fi
	endgroup
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
	case "${1:-all}" in
		defconfig) prepare_defconfig ;;
		compile)   build_kernel ;;
		check)     check_output ;;
		all)       prepare_defconfig; build_kernel; check_output ;;
		*) die "unknown build step '$1'" ;;
	esac
fi
