#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
xcrun swift-format format --in-place --recursive Sources Tests Package.swift
xcrun swift-format format --in-place Scripts/ui-inspect.swift Scripts/icon.swift
node --input-type=module <<'JS'
import fs from 'node:fs';
import {transformSync} from './Tools/CompatibilityRuntime/node_modules/esbuild/lib/main.js';
const path = 'Sources/SelectionBarCore/Resources/compatibility.js';
const output = transformSync(fs.readFileSync(path, 'utf8'), {
  minify: false, target: 'esnext', charset: 'utf8'
}).code;
fs.writeFileSync(path,
  '/* Independently implemented host for documented PopClip extension APIs. */\n' + output);
JS
