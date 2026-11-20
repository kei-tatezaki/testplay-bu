#!/bin/bash
# src/model-kit.js を three.js ごと1つにまとめて assets/vendor/model-kit.js に書き出す（版は固定）
set -e
cd "$(dirname "$0")/.."
W=/tmp/tpb-model-kit; mkdir -p $W; cd $W
[ -f package.json ] || npm init -y >/dev/null
npm i --silent three@0.187.0 esbuild@0.25 >/dev/null
cd - >/dev/null
NODE_PATH=$W/node_modules $W/node_modules/.bin/esbuild src/model-kit.js --bundle --minify --format=iife --target=es2020 \
  --legal-comments=eof --outfile=assets/vendor/model-kit.js --log-level=warning
ls -la assets/vendor/model-kit.js
