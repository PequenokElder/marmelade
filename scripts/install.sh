#!/bin/zsh
# Builds Marmalade and installs it into /Applications (replacing any previous copy).
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build_app.sh
osascript -e 'tell application "Marmalade" to quit' 2>/dev/null || true
rm -rf /Applications/Marmalade.app
cp -R build/Marmalade.app /Applications/Marmalade.app
echo "Installed /Applications/Marmalade.app"
