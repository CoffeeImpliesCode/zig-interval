# Sourced by cross-test. Published platforms, not an architecture/OS product.
# Tier table: https://ziglang.org/download/0.16.0/release-notes.html#Support-Table

cross_tz_find_exec() {
  local path
  path=$(command -v -- "$1" 2>/dev/null) || return 1
  [[ $path == */* && -f $path && -x $path ]] || return 1
  printf '%s\n' "$path"
}

cross_tz_normalize_host_arch() {
  case ${1,,} in
    amd64|x64|x86_64) printf 'x86_64\n' ;;
    arm64|aarch64) printf 'aarch64\n' ;;
    armv6l|armv7l|armv8l) printf 'arm\n' ;;
    i386|i486|i586|i686) printf 'x86\n' ;;
    ppc64le) printf 'powerpc64le\n' ;;
    ppc64) printf 'powerpc64\n' ;;
    ppc) printf 'powerpc\n' ;;
    *) printf '%s\n' "${1,,}" ;;
  esac
}

cross_tz_normalize_host_os() {
  case ${1,,} in
    linux*) printf 'linux\n' ;;
    darwin*|macos*) printf 'macos\n' ;;
    freebsd*) printf 'freebsd\n' ;;
    netbsd*) printf 'netbsd\n' ;;
    openbsd*) printf 'openbsd\n' ;;
    mingw*|msys*|cygwin*|windows_nt*) printf 'windows\n' ;;
    *) printf '%s\n' "${1,,}" ;;
  esac
}

cross_default_matrix() {
  CROSS_MATRIX=(); CROSS_MATRIX_SOURCE=; CROSS_MATRIX_VERSION=
  if [[ ${1:-} != 0.16.0 ]]; then
    printf 'cross-test: no verified tier table for Zig %s (supported: 0.16.0)\n' "${1:-unknown}" >&2
    return 2
  fi
  local targets=(
    x86_64-linux
    aarch64-freebsd aarch64-linux aarch64_be-linux aarch64-maccatalyst
    aarch64-macos aarch64-netbsd aarch64_be-netbsd aarch64-openbsd aarch64-windows
    arm-freebsd arm-linux armeb-linux arm-netbsd armeb-netbsd arm-openbsd
    hexagon-linux loongarch64-linux
    mips-linux mipsel-linux mips-netbsd mipsel-netbsd
    mips64-linux mips64el-linux mips64-openbsd mips64el-openbsd
    powerpc-linux powerpc-netbsd powerpc-openbsd
    powerpc64-freebsd powerpc64le-freebsd powerpc64-linux powerpc64le-linux powerpc64-openbsd
    riscv32-linux riscv64-freebsd riscv64-linux riscv64-openbsd s390x-linux
    thumb-linux thumbeb-linux thumb-windows wasm32-wasi
    x86-linux x86-netbsd x86-openbsd x86-windows
    x86_64-freebsd x86_64-maccatalyst x86_64-macos x86_64-netbsd x86_64-openbsd x86_64-windows
  )
  local native target
  native=$(cross_tz_normalize_host_arch "${CROSS_HOST_ARCH:-}")-$(cross_tz_normalize_host_os "${CROSS_HOST_OS:-}")
  for target in "${targets[@]}"; do
    [[ $target != "$native" ]] || CROSS_MATRIX+=("$target|auto")
  done
  for target in "${targets[@]}"; do
    [[ $target == "$native" ]] || CROSS_MATRIX+=("$target|auto")
  done
  CROSS_MATRIX_SOURCE='https://ziglang.org/download/0.16.0/release-notes.html#Support-Table'
  CROSS_MATRIX_VERSION=0.16.0
}

cross_detect_runner() {
  local target=${1:-} arch os rest host_arch host_os name path
  CROSS_RUNNER_KIND=unavailable; CROSS_RUNNER=(); CROSS_RUNNER_REASON=malformed_target
  [[ $target =~ ^[a-z0-9_]+-[a-z0-9_.]+(-[a-z0-9_.]+)*$ ]] || return 2
  arch=${target%%-*}; rest=${target#*-}; os=${rest%%-*}; os=${os%%.*}
  host_arch=$(cross_tz_normalize_host_arch "${CROSS_HOST_ARCH:-}")
  host_os=$(cross_tz_normalize_host_os "${CROSS_HOST_OS:-}")
  [[ -n $host_arch && -n $host_os ]] || { CROSS_RUNNER_REASON=host_context_missing; return 2; }
  if [[ $arch == "$host_arch" && $os == "$host_os" ]]; then
    CROSS_RUNNER_KIND=native; CROSS_RUNNER_REASON=native; return 0
  fi
  CROSS_RUNNER_REASON=no_local_runner_$os
  case $os in
    linux)
      [[ $host_os == linux ]] || return 0
      case $arch in
        powerpc) name=ppc ;;
        powerpc64) name=ppc64 ;;
        powerpc64le) name=ppc64le ;;
        x86) name=i386 ;;
        thumb) name=arm ;;
        thumbeb) name=armeb ;;
        sh) name=sh4 ;;
        sheb) name=sh4eb ;;
        aarch64|aarch64_be|arm|armeb|hexagon|loongarch64|mips|mipsel|mips64|mips64el|riscv32|riscv64|s390x|x86_64|alpha|hppa|m68k|microblaze|microblazeel|or1k|sparc|sparc64|xtensa|xtensaeb) name=$arch ;;
        *) CROSS_RUNNER_REASON=no_qemu_user_arch; return 0 ;;
      esac
      if path=$(cross_tz_find_exec "qemu-$name"); then
        CROSS_RUNNER_REASON=qemu_user
      elif path=$(cross_tz_find_exec "qemu-$name-static"); then
        CROSS_RUNNER_REASON=qemu_user_static
      else CROSS_RUNNER_REASON=missing_qemu_$name; return 0; fi
      CROSS_RUNNER=("$path")
      ;;
    wasi)
      [[ $arch == wasm32 ]] || return 0
      if path=$(cross_tz_find_exec wasmtime); then
        CROSS_RUNNER=("$path" run); CROSS_RUNNER_REASON=wasmtime
      else CROSS_RUNNER_REASON=missing_wasmtime; return 0; fi
      ;;
    windows)
      [[ $host_os == linux ]] || return 0
      case $arch in
        x86) name=wine ;;
        x86_64) name=wine64 ;;
        *) CROSS_RUNNER_REASON=unsupported_windows_arch; return 0 ;;
      esac
      if path=$(cross_tz_find_exec "$name"); then CROSS_RUNNER_REASON=$name
      elif [[ $arch == x86_64 ]] && path=$(cross_tz_find_exec wine); then CROSS_RUNNER_REASON=wine_wow64
      else CROSS_RUNNER_REASON=missing_$name; return 0; fi
      CROSS_RUNNER=("$path")
      ;;
    *) return 0 ;;
  esac
  CROSS_RUNNER_KIND=exec
}
