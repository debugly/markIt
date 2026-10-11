
cd "$(dirname "$0")"

# 可用环境变量：
#   MARKIT_DEST     构建完成后把 .app 放哪。默认 /Applications（本地开发习惯）。
#                   传一个目录就 rsync 到那里，传空字符串就完全不拷贝。
#   MARKIT_OPEN     1 = 构建完自动打开（本地默认）。其他值 = 不打开。
#   MARKIT_KEEP_DSYM 1 = 同时把 dSYM 拷到 MARKIT_DEST 的同级目录。
#   MARKIT_BUILD    CURRENT_PROJECT_VERSION（build 号）的值。默认取当天日期 MMdd。
#                   刻意和 MARKETING_VERSION 分开：后者是 0.4.0 这样的对外版本号，
#                   前者是每次构建都要变大的编号，拿版本号去填会让两次构建的
#                   build 号相同。
#
# GitHub Actions 用这套开关把产物留在工作目录里，不碰 runner 的 /Applications，
# 也不会试图 open 一个没有用户会话的 GUI。

DEST="${MARKIT_DEST-/Applications}"
OPEN="${MARKIT_OPEN-1}"
KEEP_DSYM="${MARKIT_KEEP_DSYM-0}"

# 0. 更新 CURRENT_PROJECT_VERSION 为当前日期 (MMdd)，或 CI 传入的 build 号
VERSION="${MARKIT_BUILD:-$(date +%m%d)}"
sed -i '' "s/CURRENT_PROJECT_VERSION: \".*\"/CURRENT_PROJECT_VERSION: \"$VERSION\"/" project.yml

# 1. 确保项目是最新的
xcodegen generate

rm -rf build
mkdir build

# 2. 编译并归档 (Archive)
xcodebuild archive \
  -project Markit.xcodeproj \
  -scheme Markit \
  -archivePath ./build/Markit.xcarchive

APP="./build/Markit.xcarchive/Products/Applications/Markit.app"

# 3. 拷到目标位置
#
# rsync 的目标必须是 $DEST/Markit.app 而不是 $DEST：--delete 作用在目标目录上，
# 直接 sync 到 $DEST 会把刚放进来的 dSYM 和别的东西一起删掉。
if [[ -n "$DEST" ]]; then
  echo "Copying .app to $DEST..."
  mkdir -p "$DEST"
  rsync -a --delete "$APP/" "$DEST/Markit.app/"
fi

# 4. dSYM 必须和 .app 一起留着：崩溃栈只有在有 dSYM 时才能还原成源码行号，
#    事后没法从二进制里补出来，所以在这里就导出，而不是等出事再去想办法。
#    放在 Markit.app.dSYM 而不是嵌进 app 里：用户解压 zip 之后不该看到一堆
#    给开发者看的东西。
DSYM_SRC="$(find ./build/Markit.xcarchive/dSYMs -maxdepth 1 -name '*.dSYM' | head -1)"
if [[ "$KEEP_DSYM" == "1" ]]; then
  if [[ -z "$DSYM_SRC" ]]; then
    echo "::error::no dSYM found in the archive" >&2
    exit 1
  fi
  # 无论如何都留一份在 build/ 里给 CI 打包用
  cp -pPR "$DSYM_SRC" ./build/
  echo "dSYM at ./build/$(basename "$DSYM_SRC")"
  if [[ -n "$DEST" ]]; then
    cp -pPR "$DSYM_SRC" "$DEST/"
    echo "copied dSYM to $DEST"
  fi
fi

if [[ "$OPEN" == "1" ]]; then
  open "${DEST:+/Applications}/Markit.app"
fi
