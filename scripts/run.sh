#!/bin/zsh
# 一条命令启动项目：需要时重新编译，然后打开 app。
#
#   ./scripts/run.sh           # 增量编译 + 启动
#   ./scripts/run.sh --clean   # 先清掉编译产物再启动
#
# 本项目定位是本机自用，不分发：没有签名/公证环节，ad-hoc 够用。
set -e
cd "$(dirname "$0")/.."

if [[ "${1:-}" == "--clean" ]]; then
  echo "==> 清理编译产物"
  rm -rf .build/app .build/release
fi

scripts/build-app.sh
open .build/app/PersonalAgent.app
echo "==> 已启动：菜单栏 ✨（拼音输入法图标右边），⌥Space 唤出面板"
