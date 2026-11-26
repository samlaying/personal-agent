#!/bin/zsh
# 打包 + 签名 + 公证 + 发布。按环境自动降级：
#
#   ./scripts/release.sh              # 有 Xcode/证书就正式发布，否则 ad-hoc 打包
#   ./scripts/release.sh --adhoc      # 强制 ad-hoc（本机自用）
#   ./scripts/release.sh --publish    # 打包后创建 GitHub Release
#   ./scripts/release.sh --doctor     # 只检查环境
#
# 正式发布需要：
#   1. Xcode（xcodebuild / notarytool / stapler）
#   2. Developer ID Application 证书
#   3. 一次性写入公证凭据：
#      xcrun notarytool store-credentials pa-notary \
#        --apple-id <你的 Apple ID> --team-id <TEAMID> --password <App 专用密码>
set -euo pipefail
cd "$(dirname "$0")/.."

PROJECT_NAME="PersonalAgent"
SCHEME="PersonalAgent"
KEYCHAIN_PROFILE="${KEYCHAIN_PROFILE:-pa-notary}"
EXPORT_DIR="build/export"
ARCHIVE="build/PersonalAgent.xcarchive"

MODE="auto"
PUBLISH=0
for arg in "$@"; do
  case "$arg" in
    --adhoc) MODE="adhoc" ;;
    --publish) PUBLISH=1 ;;
    --doctor) MODE="doctor" ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    *) echo "未知参数：$arg"; exit 1 ;;
  esac
done

# 版本号只有一个来源：project.yml
VERSION=$(awk -F'"' '/MARKETING_VERSION:/ {print $2; exit}' project.yml)
BUILD=$(awk -F'"' '/CURRENT_PROJECT_VERSION:/ {print $2; exit}' project.yml)
VERSION=${VERSION:-0.0.0}
BUILD=${BUILD:-0}

have_xcode() { command -v xcodebuild >/dev/null 2>&1 && xcode-select -p 2>/dev/null | grep -q "Xcode.app"; }
have_identity() { security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application"; }
have_notary() { xcrun notarytool history --keychain-profile "$KEYCHAIN_PROFILE" >/dev/null 2>&1; }

report() {
  printf '%-28s %s\n' "$1" "$2"
}

doctor() {
  echo "== 环境检查 =="
  if have_xcode; then report "Xcode" "$(xcodebuild -version | head -1)"; else report "Xcode" "缺失（只有 Command Line Tools）"; fi
  if command -v xcodegen >/dev/null; then report "xcodegen" "$(xcodegen --version)"; else report "xcodegen" "缺失（brew install xcodegen）"; fi
  if have_identity; then report "签名证书" "$(security find-identity -v -p codesigning | grep 'Developer ID Application' | head -1 | sed 's/^ *//')"; else report "签名证书" "无 Developer ID（只能 ad-hoc）"; fi
  if have_notary; then report "公证凭据" "$KEYCHAIN_PROFILE"; else report "公证凭据" "未配置（notarytool store-credentials）"; fi
  command -v gh >/dev/null && report "gh" "$(gh --version | head -1)" || report "gh" "未安装（--publish 不可用）"
  report "版本" "$VERSION ($BUILD)"
}

build_with_xcode() {
  command -v xcodegen >/dev/null || { echo "需要 xcodegen：brew install xcodegen"; exit 1; }
  echo "==> xcodegen generate"
  xcodegen generate --quiet

  local signing_args=()
  local export_team=""
  if have_identity; then
    local team
    team=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed -n 's/.*(\([A-Z0-9]*\)).*/\1/p')
    signing_args=(CODE_SIGN_IDENTITY="Developer ID Application" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="$team")
    export_team="$team"
    echo "==> 用 Developer ID 签名（team $team）"
  else
    echo "==> 没有 Developer ID，退到 ad-hoc 签名"
    signing_args=(CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual)
  fi

  rm -rf "$ARCHIVE" "$EXPORT_DIR"
  echo "==> xcodebuild archive"
  xcodebuild -project "$PROJECT_NAME.xcodeproj" -scheme "$SCHEME" -configuration Release \
    -archivePath "$ARCHIVE" "${signing_args[@]}" archive | tail -5

  cat > build/ExportOptions.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>developer-id</string>
    <key>signingStyle</key><string>manual</string>
    <key>destination</key><string>export</string>
    <key>teamID</key><string>${export_team:-}</string>
</dict>
</plist>
PLIST

  echo "==> xcodebuild -exportArchive"
  xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist build/ExportOptions.plist \
    -exportPath "$EXPORT_DIR" | tail -5
  echo "$EXPORT_DIR/$PROJECT_NAME.app"
}

build_adhoc() {
  echo "==> ad-hoc 打包（scripts/build-app.sh）"
  scripts/build-app.sh >/dev/null
  echo ".build/app/$PROJECT_NAME.app"
}

notarize() {
  local app="$1" zip="$2"
  if ! have_identity || ! have_notary; then
    echo "==> 跳过公证（缺 Developer ID 或 notarytool 凭据），见 --doctor"
    return 1
  fi
  echo "==> 公证"
  xcrun notarytool submit "$zip" --keychain-profile "$KEYCHAIN_PROFILE" --wait
  xcrun stapler staple "$app"
  xcrun stapler validate "$app"
  return 0
}

if [[ "$MODE" == "doctor" ]]; then doctor; exit 0; fi

echo "== PersonalAgent $VERSION ($BUILD) =="

APP=""
if [[ "$MODE" == "auto" ]] && have_xcode; then
  APP=$(build_with_xcode | tail -1)
else
  [[ "$MODE" == "auto" ]] && echo "==> 没有完整 Xcode，改用 ad-hoc 打包"
  APP=$(build_adhoc | tail -1)
fi
[[ -d "$APP" ]] || { echo "构建产物不存在：$APP"; exit 1; }

ZIP="build/PersonalAgent-$VERSION.zip"
mkdir -p build && rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "==> 产物 $ZIP ($(du -h "$ZIP" | cut -f1))"

notarize "$APP" "$ZIP" || true

if [[ $PUBLISH -eq 1 ]]; then
  echo "==> 发布 v$VERSION"
  gh release create "v$VERSION" "$ZIP" \
    --title "v$VERSION" \
    --notes "PersonalAgent $VERSION ($BUILD)"
else
  echo "完成。要发布：./scripts/release.sh --publish（或手动 gh release create v$VERSION \"$ZIP\"）"
fi
