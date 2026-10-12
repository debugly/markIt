#!/usr/bin/env bash
#
# 生成 release 说明。
#
# Changelog 段落按上一个正式版 tag 到本次之间的 commit 生成；没有正式版
# （第一次发）时列出全部 commit。上一个 tag 从 git log 里找，找不到就当首次发布。
set -euo pipefail

CONSTANTS="$1"
OUT="$2"

set -a; source "$CONSTANTS"; set +a

REPO="${GITHUB_REPOSITORY:-unknown/markIt}"
CHANGELOG="$(mktemp)"
trap 'rm -f "$CHANGELOG"' EXIT

# 上一个正式版：版本号不带预发布后缀的 tag。beta 之间互相不算「上一个」，
# 否则每次 beta 的说明都只包含上一个 beta 的那几条 commit。
PREVIOUS="$(git tag --list --sort=-v:refname \
  | grep -E '^v?[0-9]+\.[0-9]+\.[0-9]+$' \
  | head -1 || true)"

# 首次发布时仓库里还没有 tag，而本次的 tag 要等 release create 才存在，
# 所以用 HEAD 到 HEAD 这个空区间去查是查不到东西的。改用整个历史：首次发布的
# 「更新内容」本来就应该是全部提交。
FIRST_RELEASE=0
if [[ -z "$PREVIOUS" ]]; then
  FIRST_RELEASE=1
  RANGE="HEAD"
else
  RANGE="$PREVIOUS..HEAD"
fi

{
  echo "## 更新内容"
  echo
  # 判空用 git log 自己的退出码，不要先 rev-parse --verify：--verify 只接受单个
  # revision，给它一个区间（a..b）会报 "Needed a single revision" 并返回非零，
  # 于是每次都掉进「没有新的提交」这个分支，哪怕区间里明明有几百条提交。
  if LOG="$(git log --pretty='- %s (%h)' "$RANGE" 2>/dev/null)" && [[ -n "$LOG" ]]; then
    printf '%s\n' "$LOG"
  else
    echo "_这个版本没有新的提交。_"
  fi

  if [[ "$FIRST_RELEASE" == "1" ]]; then
    echo
    echo "_首次发布，以上是全部提交。_"
  fi

  if [[ -n "$PREVIOUS" ]]; then
    echo
    echo "[对比 ${PREVIOUS}...${TAG}](https://github.com/${REPO}/compare/${PREVIOUS}...${TAG})"
  fi
} > "$CHANGELOG"

# Changelog 里的相对链接在 release 页面里指向不到文件，要补成仓库绝对地址。
MARKDOWN="$(mktemp)"
trap 'rm -f "$CHANGELOG" "$MARKDOWN"' EXIT
sed -e "s#](\./#](https://github.com/${REPO}/blob/${TAG}/#g" \
    -e "s#](docs/#](https://github.com/${REPO}/blob/${TAG}/docs/#g" \
    "$CHANGELOG" > "$MARKDOWN"

{
  echo "# MarkIt ${VERSION}"
  echo
  if [[ "$IS_BETA" == "1" ]]; then
    echo "> 预发布版本。功能可能还会变，重要文件建议先备份。"
    echo
  fi
  echo "MarkIt 是一个本地优先的 Markdown 编辑器：笔记存在你自己的设备上，"
  echo "可选地通过 WebDAV 镜像到自己的服务器。两个平台功能一致。"
  echo
  echo "## 下载"
  echo
  echo "| 平台 | 文件 | 说明 |"
  echo "| --- | --- | --- |"
  echo "| macOS | \`MarkIt-${VERSION}.zip\` | 解压后把 MarkIt.app 拖进「应用程序」|"
  echo "| Android | \`MarkIt-${VERSION}.apk\` | 安装需要允许「未知来源」|"
  echo
  # Three files ship, but only two are for using the app. Saying so here saves
  # the person reading this from wondering what the third one is for.
  echo "普通用户只需要上面两个。同一 release 里还有 \`MarkIt-${VERSION}-dSYM.zip\`，"
  echo "那是崩溃符号表，只在排查崩溃时用得上：崩溃日志里只有 UUID 和加载地址，"
  echo "要还原成源码行号必须配对「那个构建」的符号表。"
  echo
  echo "### macOS"
  echo
  echo "这个版本没有开发者证书签名（没有 Apple Developer 账号的自动签名）。"
  echo "第一次打开会提示「无法验证开发者」，请右键点 app，选「打开」，再确认一次。"
  echo "之后就正常了。"
  echo
  cat "$MARKDOWN"
} > "$OUT"

echo "wrote $OUT"
