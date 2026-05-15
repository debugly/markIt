
cd "$(dirname "$0")"

# 0. 更新 CURRENT_PROJECT_VERSION 为当前日期 (MMdd)
VERSION=$(date +%m%d)
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

# 3. 导出 .app (或者直接从 Archive 里提取)
# 最简单的方法是直接去 Archive 路径拷贝
echo "Copying .app from archive to /Applications..."
rsync -a --delete ./build/Markit.xcarchive/Products/Applications/Markit.app/ /Applications/Markit.app/

open /Applications/Markit.app