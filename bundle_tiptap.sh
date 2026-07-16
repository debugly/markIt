#!/bin/bash
set -e

# Define directories
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMP_DIR="${SCRIPT_DIR}/.build-tiptap-temp"
OUT_DIR="${SCRIPT_DIR}/Resources/JS"

echo "=== MarkIt Tiptap Bundler ==="
echo "Creating output directory..."
mkdir -p "${OUT_DIR}"

echo "Creating temporary workspace..."
mkdir -p "${TEMP_DIR}"
cd "${TEMP_DIR}"

# Write package.json
cat << 'EOF' > package.json
{
  "name": "tiptap-bundler",
  "version": "1.0.0",
  "private": true
}
EOF

echo "Installing Tiptap and Esbuild..."
npm install --legacy-peer-deps @tiptap/core @tiptap/starter-kit @tiptap/markdown @tiptap/extension-heading @tiptap/extension-table core-js
npm install --legacy-peer-deps -D esbuild

echo "Writing entry file..."
cat << 'EOF' > entry.js
import 'core-js/stable';
import { Editor, mergeAttributes } from '@tiptap/core';
import StarterKit from '@tiptap/starter-kit';
import { Markdown } from '@tiptap/markdown';
import Heading from '@tiptap/extension-heading';
import { TableKit } from '@tiptap/extension-table';

window.Tiptap = {
    Editor,
    mergeAttributes,
    StarterKit,
    Markdown,
    Heading,
    TableKit
};
EOF

echo "Bundling and minifying with esbuild..."
npx esbuild entry.js --bundle --minify --format=iife --target=safari14 --supported:destructuring=true --outfile="${OUT_DIR}/tiptap-bundle.js"

echo "Sanitizing bundle for Safari 14 / macOS 11 compatibility..."
python3 "${SCRIPT_DIR}/clean_bundle.py" "${OUT_DIR}/tiptap-bundle.js"

echo "Verifying JavaScript bundle syntax..."
node -c "${OUT_DIR}/tiptap-bundle.js"

echo "Cleaning up temporary files..."
cd "${SCRIPT_DIR}"
rm -rf "${TEMP_DIR}"

echo "=== Bundling Complete ==="
echo "Local Tiptap bundle created at: Resources/JS/tiptap-bundle.js"
