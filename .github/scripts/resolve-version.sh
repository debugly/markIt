#!/usr/bin/env bash
#
# 算出这次发布的版本号和 tag。
#
# markIt 两端共用一个裸版本号（0.4.0 这样的），和 macOS 版历史一致：mac 用
# MARKETING_VERSION，Android 用 versionName，两个文件里本来就要填同一个值。
# 但那两处都是手写的，迟早会漂，所以真正作为真相来源的是 release 的 tag，
# 产物里的版本号在编译之后按 tag 打进去。
#
# 用法：
#   resolve-version.sh [tag] [是-beta:1|0]
#
# 不传 tag 就用 dispatch 时所在的分支名。beta 模式下不会自己造 -betaN 后缀，
# 而是要求 tag 里已经带了 —— tag 是要给人看的，「beta.3」比「1.1-beta.4」清楚。
set -euo pipefail

TAG="${1:-${GITHUB_REF_NAME:-}}"
IS_BETA="${2:-0}"

if [[ -z "$TAG" ]]; then
  echo "::error::no tag given and GITHUB_REF_NAME is empty" >&2
  exit 1
fi

if [[ "$TAG" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  # 纯数字版本：去掉可能的前导 v，两端都用裸版本号。
  VERSION="${TAG#v}"
elif [[ "$TAG" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+- ]]; then
  # 预发布：原样用 tag 作为版本号的一部分。
  VERSION="${TAG#v}"
else
  echo "::error::tag '$TAG' is neither a version (1.2.3) nor a prerelease (1.2.3-beta.1)" >&2
  exit 1
fi

if [[ "$IS_BETA" == "1" && "$VERSION" != *-* ]]; then
  echo "::error::beta release requested but tag '$TAG' has no prerelease suffix" >&2
  echo "::error::use a tag like 0.5.0-beta.1 so the release reads as a beta" >&2
  exit 1
fi

TAG="$VERSION"

cat > release-constants.env <<EOF
VERSION=$VERSION
TAG=$TAG
IS_BETA=$IS_BETA
EOF

echo "version=$VERSION tag=$TAG beta=$IS_BETA"
