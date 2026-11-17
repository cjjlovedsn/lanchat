#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
app="${1:-$repo_dir/build/macos/Build/Products/Release/lanchat.app}"
output="${2:-$repo_dir/dist}"
stage="$(mktemp -d "${TMPDIR:-/tmp}/lanchat-package.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
ditto "$app" "$stage/lanchat.app"
codesign --verify --deep --strict "$stage/lanchat.app"
if [[ -f "$repo_dir/LICENSE" ]]; then cp "$repo_dir/LICENSE" "$stage/LICENSE"; fi
cat > "$stage/README.txt" <<'INFO'
LanChat macOS 安装说明

推荐使用 DMG：打开后，将 lanchat.app 拖到旁边的 Applications 快捷方式。
随后推出磁盘映像，从“应用程序”启动 LanChat。
使用 ZIP 时，也建议把解压后的 lanchat.app 拖入“应用程序”，再启动应用。
首次从下载目录或 DMG 启动时，会显示一次安装提示，可打开访达中的安装位置。

更新前先退出旧版，替换“应用程序”中的应用文件；聊天数据保存在应用支持目录。
下载更新：https://github.com/cjjlovedsn/lanchat/releases/latest
INFO
version="$(python3 "$repo_dir/scripts/release-version.py")"
app_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$stage/lanchat.app/Contents/Info.plist")"
if [[ "$app_version" != "$version" ]]; then
    echo 'Built Mac application version does not match pubspec.yaml; rebuild before packaging.' >&2
    exit 1
fi
"$repo_dir/scripts/package-macos.sh" "$stage" "$output" "lanchat-macos-$version" "LanChat $version"
mv "$output/SHA256SUMS.txt" "$output/SHA256SUMS-$version.txt"
