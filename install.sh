#!/bin/sh
# Kindle-only HTTPS GitHub Pages variant.
# Invocation at EOF prevents a partial function body from being executed.
bootstrap() {
    set -eu
    PATH=/usr/sbin:/usr/bin:/sbin:/bin
    export PATH
    offline=
    if [ "${1:-}" = --offline ]; then
        [ "$#" = 2 ] || { echo 'Usage: install --offline BUNDLE_DIRECTORY' >&2; return 1; }
        offline=$2
        shift 2
    fi
    base=${1:-https://katadelos.github.io/eink-opkg-beta}
    base=${base%/}
    case "$base" in http://*|https://*) ;; *) echo 'Expected an HTTP(S) feed URL' >&2; return 1;; esac
    [ "$(id -u)" = 0 ] || { echo 'Run as root.' >&2; return 1; }
    umask 022
    # Identify the mounted vendor userstore before interpreting its firmware ABI.
    vendor=$(awk '$2 == "/mnt/us" {kindle=1} $2 == "/mnt/onboard" {kobo=1}
        END {if (kindle && !kobo) print "kindle"; else if (kobo && !kindle) print "kobo"}' /proc/mounts)
    case "$vendor" in
        kindle) userstore=/mnt/us ;;
        kobo) echo 'This installer supports Kindle only (kindle5, kindlepw2, kindlehf).' >&2; return 1 ;;
        *) echo 'A unique Kindle userstore must be mounted.' >&2; return 1 ;;
    esac
    store=$userstore/.eink-sdk
    control=$store/control
    machine=$(hexdump -s 18 -n 1 -e '1/1 "%u"' /bin/sh)
    flags=$(hexdump -s 37 -n 1 -e '1/1 "%u"' /bin/sh)
    [ "$machine" = 40 ] || { echo 'Unsupported native ABI: an ARM32 userspace is required.' >&2; return 1; }
    kernel=$(uname -r)
    case "$vendor" in
        kindle)
            [ -z "$offline" ] || { echo 'Offline installation requires a Kobo bundle.' >&2; return 1; }
            if [ "$((flags & 4))" != 0 ]; then
                platform=kindlehf
            else
                case "$kernel" in 2.6.*) platform=kindle5;; *) platform=kindlepw2;; esac
            fi
            ;;
        kobo)
            [ "$(uname -m)" = armv7l ] || { echo 'Kobo requires ARMv7.' >&2; return 1; }
            grep -q 'neon' /proc/cpuinfo || { echo 'Kobo requires NEON.' >&2; return 1; }
            [ "$((flags & 4))" != 0 ] || { echo 'Kobo requires ARM hard-float firmware.' >&2; return 1; }
            glibc=$(/lib/libc.so.6 | sed -n 's/.*release version 2.\([0-9][0-9]*\),.*/\1/p')
            case "$glibc" in ''|*[!0-9]*) echo 'Cannot identify firmware glibc.' >&2; return 1;; esac
            major=${kernel%%.*}; rest=${kernel#*.}
            minor=${rest%%.*}; patch=${rest#*.}; patch=${patch%%[!0-9]*}
            kernel_version=$((major * 10000 + minor * 100 + patch))
            platform=kobo
            if [ "$glibc" -ge 19 ] && [ "$kernel_version" -ge 40100 ]; then platform=kobov4; fi
            case "$platform" in
                kobo) min_glibc=15; min_kernel=20633 ;;
                kobov4) min_glibc=19; min_kernel=40100 ;;
            esac
            [ "$glibc" -ge "$min_glibc" ] || {
                echo "$platform requires glibc 2.$min_glibc or newer." >&2; return 1;
            }
            [ "$kernel_version" -ge "$min_kernel" ] || {
                echo "Kernel $kernel is too old for $platform." >&2; return 1;
            }
            ;;
    esac
    mkdir /tmp/eink-opkg-bootstrap.lock 2>/dev/null || { echo 'Another bootstrap is running.' >&2; return 1; }
    work=
    stage=
    cleanup() {
        result=$?
        trap - 0
        [ -z "$work" ] || rm -rf "$work"
        [ -z "$stage" ] || rm -rf "$stage"
        rmdir /tmp/eink-opkg-bootstrap.lock
        exit "$result"
    }
    trap cleanup 0
    trap 'exit 1' 1 2 15
    work=$(mktemp -d /tmp/eink-opkg.XXXXXX)
    # Stock Kindle /var (including /tmp) is only 64 MiB. Keep the archive
    # and regular IPKs on userstore; executable seed files and their symlinks
    # must stay on tmpfs because userstore may be noexec and FAT.
    stage=$(mktemp -d "$userstore/.eink-opkg.XXXXXX")
    TMPDIR=$work
    export TMPDIR
    if [ -n "$offline" ]; then
        bundle=$offline/bundle.tar.gz
    else
        bundle=$stage/bundle.tar.gz
        echo "Downloading $platform package manager..."
        case "$vendor" in
            kindle) /usr/bin/curl -fL --connect-timeout 20 --max-time 180 "$base/bootstrap/$platform.tar.gz" -o "$bundle" ;;
            kobo) wget -O "$bundle" "$base/bootstrap/$platform.tar.gz" ;;
        esac
    fi
    control_scripts="activate run env ssh modprobe depmod"
    extra_files=
    if [ "$vendor" = kobo ]; then
        control_scripts="$control_scripts qt usbnet"
        extra_files=Packages
    fi
    tar -xzf "$bundle" -C "$stage" packages
    tar -xzf "$bundle" -C "$work" seed packages.list platform eink-sdk-links $control_scripts $extra_files
    [ -n "$offline" ] || rm -f "$bundle"
    bundled_platform=$(cat "$work/platform")
    [ "$bundled_platform" = "$platform" ] || {
        echo "This bundle is for $bundled_platform; this device requires $platform." >&2; return 1;
    }
    mkdir -p "$control" "$store/opkg/info" "$store/opkg/lists" "$store/opkg/cache"
    cat > "$work/opkg.conf" <<CONF
src/gz $platform $base/$platform
dest root /
option overlay_root $userstore
arch all 1
arch $platform 10
option info_dir $store/opkg/info
option status_file $store/opkg/status
option lists_dir $store/opkg/lists
option cache_dir $store/opkg/cache
option cache_local_files 1
option ssl_ca_file $store/etc/ssl/certs/ca-certificates.crt
option lock_file /tmp/eink-opkg.lock
CONF
    if [ -f "$store/opkg/opkg.conf" ]; then
        awk '($1 == "src/gz" && $2 == "sdk-kernel") || ($1 == "arch" && $2 ~ /^kernel_/)' \
            "$store/opkg/opkg.conf" >> "$work/opkg.conf"
    fi
    # Bootstrap hooks need the static helper before any runtime links exist.
    mkdir -p "$store/usr/libexec"
    cp "$work/eink-sdk-links" "$store/usr/libexec/eink-sdk-links.new"
    chmod 755 "$store/usr/libexec/eink-sdk-links.new"
    mv "$store/usr/libexec/eink-sdk-links.new" "$store/usr/libexec/eink-sdk-links"
    for script in $control_scripts; do
        cp "$work/$script" "$control/$script.new"
        chmod 755 "$control/$script.new"
        mv "$control/$script.new" "$control/$script"
    done
    /bin/sh "$control/activate"
    seed_opkg() {
        LD_LIBRARY_PATH="$work/seed/usr/lib:$work/seed/lib" \
            "$work/seed/usr/bin/opkg" -f "$work/opkg.conf" "$@"
    }
    tab=$(printf '\t')
    seed_opkg list-installed > "$work/installed"
    while IFS="$tab" read -r name filename version; do
        installed=$(awk -v name="$name" '$1 == name && $2 == "-" { print $3 }' "$work/installed")
        if [ -n "$installed" ] && seed_opkg compare-versions "$installed" '>=' "$version"; then
            echo "$name $installed is already installed."
        else
            seed_opkg --force-reinstall install "$stage/packages/$filename"
        fi
    done < "$work/packages.list"
    cp "$work/opkg.conf" "$store/opkg/opkg.conf.new"
    mv "$store/opkg/opkg.conf.new" "$store/opkg/opkg.conf"
    . "$control/env"
    # Seed the feed index so an offline install can list available packages.
    [ "$vendor" != kobo ] || cp "$work/Packages" "$store/opkg/lists/$platform"
    if [ -n "$offline" ]; then
        if [ -f "$offline/kernel-feed" ]; then
            sh "$offline/kernel-feed" "$base" "$offline"
        fi
        while IFS="$tab" read -r name filename version; do
            installed=$(awk -v name="$name" '$1 == name && $2 == "-" { print $3 }' "$work/installed")
            if [ -n "$installed" ] && opkg compare-versions "$installed" '>=' "$version"; then
                echo "$name $installed is already installed."
            else
                opkg install "$offline/$filename"
            fi
        done < "$offline/extra-packages.list"
    else
        opkg update
    fi
    opkg --version
    echo "Ready. Load the environment: . $control/env"
    echo "After boot: sh $control/activate (after userstore mounts)."
}
bootstrap "$@"
