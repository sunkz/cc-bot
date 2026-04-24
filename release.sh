#!/usr/bin/env bash
set -euo pipefail

# ─── 配置 ────────────────────────────────────────────────
PROJECT_FILE="project.yml"
TAG_PREFIX="v"

# ─── 帮助信息 ────────────────────────────────────────────
usage() {
  cat <<EOF
用法: $0 <patch|minor|major|版本号>

示例:
  $0 patch          # 1.0.2 → 1.0.3
  $0 minor          # 1.0.2 → 1.1.0
  $0 major          # 1.0.2 → 2.0.0
  $0 1.2.3          # 直接指定版本号

流程: 更新 project.yml 版本号 → 提交 → 打 tag → 推送到远端
EOF
  exit 1
}

# ─── 参数校验 ─────────────────────────────────────────────
BUMP="${1:-patch}"

# ─── 前置检查 ─────────────────────────────────────────────
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "错误: 工作区有未提交的修改，请先提交或暂存" >&2
  exit 1
fi

# ─── 读取当前版本 ─────────────────────────────────────────
CURRENT_VERSION=$(grep 'CFBundleShortVersionString:' "$PROJECT_FILE" | sed -E 's/.*"([0-9]+\.[0-9]+\.[0-9]+)".*/\1/')
if [[ -z "$CURRENT_VERSION" ]]; then
  echo "错误: 无法从 $PROJECT_FILE 中读取当前版本号" >&2
  exit 1
fi

IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT_VERSION"

# ─── 计算新版本 ─────────────────────────────────────────
case "$BUMP" in
  patch) NEW_VERSION="$MAJOR.$MINOR.$((PATCH + 1))" ;;
  minor) NEW_VERSION="$MAJOR.$((MINOR + 1)).0" ;;
  major) NEW_VERSION="$((MAJOR + 1)).0.0" ;;
  *)
    if [[ "$BUMP" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      NEW_VERSION="$BUMP"
    else
      echo "错误: 无效的版本号格式 '$BUMP'，需要 X.Y.Z 格式" >&2
      usage
    fi
    ;;
esac

TAG_NAME="${TAG_PREFIX}${NEW_VERSION}"

# ─── 检查 tag 是否已存在 ──────────────────────────────────
if git rev-parse "$TAG_NAME" >/dev/null 2>&1; then
  echo "错误: tag $TAG_NAME 已存在" >&2
  exit 1
fi

# ─── 确认 ────────────────────────────────────────────────
echo "版本变更: $CURRENT_VERSION → $NEW_VERSION"
echo "Git tag:  $TAG_NAME"
echo ""
read -r -p "确认发布？(y/N) " CONFIRM
if [[ "$CONFIRM" != [yY] ]]; then
  echo "已取消"
  exit 0
fi

# ─── 更新版本号 ───────────────────────────────────────────
PLIST_FILE="CCBot/Info.plist"

# 更新 project.yml
sed -i '' -E "s/(CFBundleShortVersionString: \")([0-9]+\.[0-9]+\.[0-9]+)(\")/\1${NEW_VERSION}\3/" "$PROJECT_FILE"

# 递增 build number
CURRENT_BUILD=$(grep 'CFBundleVersion:' "$PROJECT_FILE" | sed -E 's/.*"([0-9]+)".*/\1/')
NEW_BUILD=$((CURRENT_BUILD + 1))
sed -i '' -E "s/(CFBundleVersion: \")([0-9]+)(\")/\1${NEW_BUILD}\3/" "$PROJECT_FILE"

# 同步更新 Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $NEW_VERSION" "$PLIST_FILE"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEW_BUILD" "$PLIST_FILE"

echo "已更新版本号:"
echo "  CFBundleShortVersionString: $CURRENT_VERSION → $NEW_VERSION"
echo "  CFBundleVersion: $CURRENT_BUILD → $NEW_BUILD"

# ─── 提交、打 tag、推送 ──────────────────────────────────
git add "$PROJECT_FILE" "$PLIST_FILE"
git commit -m "🔖 release: ${TAG_NAME}"
git tag -a "$TAG_NAME" -m "Release ${TAG_NAME}"
git push origin HEAD
git push origin "$TAG_NAME"

echo ""
echo "发布完成！"
echo "  提交已推送到远端"
echo "  tag $TAG_NAME 已推送，CI 将自动触发构建"
