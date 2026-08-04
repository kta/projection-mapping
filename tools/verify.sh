#!/usr/bin/env bash
#
# CornerCast 検証スクリプト(macOS + Xcode が必要)
#
# 「ビルドが通るか」「テストが通るか」だけでなく、
# 静的なコードリーディングでは断定できない次の点を実測で確かめる:
#
#   1. xcodegen が生成した .xcodeproj で、サンプル動画が Copy Bundle Resources に入るか
#   2. ビルド成果物の .app の中に、サンプル動画が実際に存在するか
#      (ここが入っていないと SampleVideo.url が nil になり、
#       コンテンツ選択からサンプル欄ごと消える = サンプルが「動かない」)
#   3. Info.plist が誤ってリソースとして二重にコピーされていないか
#   4. 同梱動画そのものの健全性(解像度/fps/尺/全フレームのデコード可否)
#
# 使い方:
#   ./tools/verify.sh              # 全部
#   ./tools/verify.sh bundle       # 生成〜バンドル同梱の確認まで(テストは走らせない)
#   ./tools/verify.sh test         # ビルド+テストのみ
#   ./tools/verify.sh assets       # 動画アセットの検査のみ(macOS 以外でも動く)
#
set -uo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
MODE="${1:-all}"

RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; DIM=$'\033[2m'; RST=$'\033[0m'
FAILED=0
pass() { printf '%s  PASS%s %s\n' "$GRN" "$RST" "$1"; }
fail() { printf '%s  FAIL%s %s\n' "$RED" "$RST" "$1"; FAILED=1; }
warn() { printf '%s  WARN%s %s\n' "$YLW" "$RST" "$1"; }
info() { printf '%s       %s%s\n' "$DIM" "$1" "$RST"; }
head_() { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }

need_macos() {
  if [ "$(uname -s)" != "Darwin" ]; then
    fail "$1 には macOS + Xcode が必要です(現在: $(uname -s))"
    return 1
  fi
  if ! command -v xcodebuild >/dev/null 2>&1; then
    fail "xcodebuild が見つかりません。Xcode をインストールしてください"
    return 1
  fi
  return 0
}

SAMPLE_DIR="CornerCast/Resources/SampleVideos"
SAMPLES=(warp-drive gentle-ocean firefly-forest)

# ---------------------------------------------------------------- 1. 生成

generate_project() {
  head_ "Xcode プロジェクト生成"
  if ! command -v xcodegen >/dev/null 2>&1; then
    fail "xcodegen が見つかりません → brew install xcodegen"
    return 1
  fi
  if xcodegen generate >/tmp/cc-xcodegen.log 2>&1; then
    pass "xcodegen generate 成功"
  else
    fail "xcodegen generate 失敗"
    sed 's/^/       /' /tmp/cc-xcodegen.log | tail -20
    return 1
  fi
}

# ------------------------------------------- 2. pbxproj のリソース登録を確認

check_pbxproj() {
  head_ "Copy Bundle Resources への登録(pbxproj)"
  local pbx="CornerCast.xcodeproj/project.pbxproj"
  [ -f "$pbx" ] || { fail "$pbx が無い(先に生成が必要)"; return 1; }

  for s in "${SAMPLES[@]}"; do
    if grep -q "$s.mp4" "$pbx"; then
      pass "$s.mp4 が pbxproj に登録されている"
    else
      fail "$s.mp4 が pbxproj に無い → バンドルに入らずサンプルが表示されない"
    fi
  done

  # Info.plist は INFOPLIST_FILE で指定済み。リソースにも入っていると二重になる。
  if awk '/Begin PBXResourcesBuildPhase/,/End PBXResourcesBuildPhase/' "$pbx" \
       | grep -q "Info.plist"; then
    warn "Info.plist が Copy Bundle Resources にも入っている(二重コピー)"
  else
    pass "Info.plist はリソースに二重登録されていない"
  fi
}

# ------------------------------------- 3. 実ビルドして .app の中身を確認

check_app_bundle() {
  head_ "ビルド成果物 .app の中身"
  need_macos "バンドル確認" || return 1

  local udid
  udid=$(xcrun simctl list devices available \
         | grep -E 'iPad' \
         | grep -oE '[0-9A-F]{8}-([0-9A-F]{4}-){3}[0-9A-F]{12}' | head -n 1)
  if [ -z "$udid" ]; then
    fail "利用可能な iPad シミュレータが無い"
    return 1
  fi
  info "シミュレータ: $udid"

  local dd="$ROOT/.build-verify"
  info "ビルド中… (ログ: /tmp/cc-build.log)"
  if xcodebuild build \
        -project CornerCast.xcodeproj \
        -scheme CornerCast \
        -destination "id=$udid" \
        -derivedDataPath "$dd" \
        CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" \
        >/tmp/cc-build.log 2>&1; then
    pass "ビルド成功"
  else
    fail "ビルド失敗"
    grep -E 'error:' /tmp/cc-build.log | head -20 | sed 's/^/       /'
    return 1
  fi

  local app
  app=$(find "$dd/Build/Products" -maxdepth 3 -name 'CornerCast.app' -type d | head -n 1)
  if [ -z "$app" ]; then
    fail "CornerCast.app が見つからない"
    return 1
  fi
  info "app: ${app#$ROOT/}"

  # ここが本題。Bundle.main.url(forResource:withExtension:) が
  # 見に行くのはバンドル直下なので、直下にあるかを厳密に見る。
  for s in "${SAMPLES[@]}"; do
    if [ -f "$app/$s.mp4" ]; then
      local sz
      sz=$(stat -f%z "$app/$s.mp4" 2>/dev/null || stat -c%s "$app/$s.mp4")
      pass "$s.mp4 がバンドル直下にある (${sz} bytes)"
    elif find "$app" -name "$s.mp4" | grep -q .; then
      local where
      where=$(find "$app" -name "$s.mp4" | head -1)
      fail "$s.mp4 はバンドル内にあるが直下ではない: ${where#$app/}
       → Bundle.main.url(forResource:) は nil を返し、サンプルが表示されない"
    else
      fail "$s.mp4 がバンドルに入っていない → サンプル欄が丸ごと消える"
    fi
  done
}

# ---------------------------------------------------------------- 4. テスト

run_tests() {
  head_ "ユニットテスト"
  need_macos "テスト実行" || return 1

  local udid
  udid=$(xcrun simctl list devices available | grep -E 'iPad' \
         | grep -oE '[0-9A-F]{8}-([0-9A-F]{4}-){3}[0-9A-F]{12}' | head -n 1)
  [ -n "$udid" ] || { fail "利用可能な iPad シミュレータが無い"; return 1; }

  info "テスト実行中… (ログ: /tmp/cc-test.log)"
  if xcodebuild test \
        -project CornerCast.xcodeproj \
        -scheme CornerCast \
        -destination "id=$udid" \
        CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" \
        >/tmp/cc-test.log 2>&1; then
    local n
    n=$(grep -cE "^Test Case .* passed" /tmp/cc-test.log || true)
    pass "全テスト成功 (${n} ケース)"
  else
    fail "テスト失敗"
    grep -E "error:|failed" /tmp/cc-test.log | head -20 | sed 's/^/       /'
  fi
}

# ------------------------------------------------------------ 5. アセット検査

check_assets() {
  head_ "同梱サンプル動画の健全性"
  if ! command -v python3 >/dev/null 2>&1; then
    warn "python3 が無いのでアセット検査をスキップ"
    return 0
  fi
  if ! python3 -c "import numpy, imageio_ffmpeg" 2>/dev/null; then
    warn "検査には numpy と imageio-ffmpeg が必要 → pip install numpy imageio-ffmpeg"
    return 0
  fi
  python3 tools/verify_samples.py || FAILED=1
}

# ---------------------------------------------------------------- 実行

case "$MODE" in
  all)    generate_project && check_pbxproj; check_app_bundle; run_tests; check_assets ;;
  bundle) generate_project && check_pbxproj && check_app_bundle ;;
  test)   generate_project && run_tests ;;
  assets) check_assets ;;
  *)      echo "使い方: $0 [all|bundle|test|assets]"; exit 2 ;;
esac

head_ "結果"
if [ "$FAILED" -eq 0 ]; then
  printf '%s すべて通過%s\n\n' "$GRN" "$RST"
else
  printf '%s 失敗あり(上の FAIL を参照)%s\n\n' "$RED" "$RST"
fi
exit "$FAILED"
