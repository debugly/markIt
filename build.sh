
cd "$(dirname "$0")"
# 1. 确保项目是最新的
xcodegen generate

# 2. 编译并归档 (Archive)
xcodebuild archive \
  -project Markit.xcodeproj \
  -scheme Markit \
  -archivePath ./build/Markit.xcarchive

# 3. 导出 .app (或者直接从 Archive 里提取)
# 最简单的方法是直接去 Archive 路径拷贝
cp -R ./build/Markit.xcarchive/Products/Applications/Markit.app ./Markit.app