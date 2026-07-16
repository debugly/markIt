import os
import sys
import re

# Get file path from argument or default to relative path
if len(sys.argv) > 1:
    file_path = sys.argv[1]
else:
    file_path = "Resources/JS/tiptap-bundle.js"

# Resolve absolute path to be extremely safe
file_path = os.path.abspath(file_path)

if not os.path.exists(file_path):
    print(f"Error: {file_path} does not exist.")
    exit(1)

with open(file_path, "r", encoding="utf-8") as f:
    content = f.read()

print(f"Original bundle size: {len(content)} characters")

modified_content = content

# 1. Clean named classes with uninitialized public fields
# e.g., class BE{tokens;options;state;inlineQueue;tokenizer;constructor
named_uninit_pattern = r'class\s+([A-Za-z0-9_$]+)\s*\{\s*(?:[a-zA-Z0-9_$]+;\s*)+\s*constructor'
def repl_named(m):
    print(f"Sanitizing named class: {m.group(1)}")
    return f"class {m.group(1)}{{constructor"

modified_content = re.sub(named_uninit_pattern, repl_named, modified_content)

# 2. Clean anonymous classes with uninitialized public fields
# e.g., class{options;rules;lexer;constructor
anon_uninit_pattern = r'class\s*\{\s*(?:[a-zA-Z0-9_$]+;\s*)+\s*constructor'
def repl_anon(m):
    print("Sanitizing anonymous class with fields")
    return "class{constructor"

modified_content = re.sub(anon_uninit_pattern, repl_anon, modified_content)

# 3. Clean classes with initializers
# e.g., class{defaults=jE();options=this.setOptions;parse=this.parseMarkdown(!0)...
init_pattern = r'class\s*\{\s*defaults=([^;]+);options=([^;]+);parse=([^;]+);parseInline=([^;]+);Parser=([^;]+);Renderer=([^;]+);TextRenderer=([^;]+);Lexer=([^;]+);Tokenizer=([^;]+);Hooks=([^;]+);constructor\(\.\.\.([a-zA-Z0-9_$]+)\)\{this\.use\(\.\.\.([a-zA-Z0-9_$]+)\)\}'
def repl_init(m):
    print("Sanitizing class with initializers (markdown parser)")
    return f"class{{constructor(...{m.group(11)}){{this.defaults={m.group(1)};this.options={m.group(2)};this.parse={m.group(3)};this.parseInline={m.group(4)};this.Parser={m.group(5)};this.Renderer={m.group(6)};this.TextRenderer={m.group(7)};this.Lexer={m.group(8)};this.Tokenizer={m.group(9)};this.Hooks={m.group(10)};this.use(...{m.group(11)})}}"

modified_content = re.sub(init_pattern, repl_init, modified_content)

with open(file_path, "w", encoding="utf-8") as f:
    f.write(modified_content)

print(f"JS Bundle cleanup complete! Sanitized: {file_path}")

