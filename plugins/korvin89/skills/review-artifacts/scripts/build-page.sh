#!/usr/bin/env bash
#
# build-page.sh — assemble a self-contained HTML page from a manifest so it can
# be published as one Claude Code artifact. Images are inlined as data URIs;
# the model never touches the bytes.
#
# Usage: build-page.sh <dir>
#   <dir> holds manifest.json and every file it names. Writes <dir>/index.html
#   and prints its path and size.
#
# manifest.json:
#   {
#     "title": "Stacked bar, negative values",
#     "text": "One or more paragraphs; blank line = new paragraph.",
#     "base_label": "main",           (optional, default "main")
#     "head_label": "PR #123",        (optional, default "PR")
#     "pairs": [
#       { "label": "default theme", "base": "default-main.png", "head": "default-pr.png", "config": "default.json" }
#     ]
#   }
#   `config` is optional per pair. Page layout: title, text, a collapsed
#   "Screenshots" block with one base|head pair per row, a collapsed "Configs"
#   block with one code block per pair.
#
# Exit codes: 0 ok · 4 bad manifest or missing file · 6 jq missing · 7 page over the size limit

set -euo pipefail
LIMIT=$((12 * 1024 * 1024))   # artifacts fail above 16 MiB; keep a margin
err() { printf '%s\n' "$*" >&2; }
die() { local code="$1"; shift; err "$*"; exit "$code"; }

dir="${1:-}"
[ -n "$dir" ] && [ -d "$dir" ] || die 4 "Usage: build-page.sh <dir>  (a directory holding manifest.json)"
command -v jq >/dev/null 2>&1 || die 6 "jq is required to read the manifest. Install it: https://jqlang.github.io/jq/download/"
m="$dir/manifest.json"
[ -f "$m" ] || die 4 "No manifest.json in $dir"
jq -e '.title and (.pairs | type == "array" and length > 0)' "$m" >/dev/null 2>&1 \
  || die 4 "manifest.json needs a title and a non-empty pairs array"

mime() {
  case "${1##*.}" in
    png) echo image/png ;; jpg|jpeg) echo image/jpeg ;; webp) echo image/webp ;;
    gif) echo image/gif ;; svg) echo image/svg+xml ;; *) echo application/octet-stream ;;
  esac
}
need() { [ -f "$dir/$1" ] || die 4 "File named in manifest is missing: $1"; }
b64() { base64 < "$dir/$1" | tr -d '\n'; }
esc() { jq -Rsr '@html' ; }                                 # stdin → html-escaped

title="$(jq -r '.title' "$m" | esc)"
base_label="$(jq -r '.base_label // "main"' "$m" | esc)"
head_label="$(jq -r '.head_label // "PR"' "$m" | esc)"
text_html="$(jq -r '(.text // "") | split("\n\n") | map(select(length > 0) | @html "<p>\(.)</p>") | join("\n")' "$m")"
n="$(jq '.pairs | length' "$m")"

# Validate every referenced file before writing anything.
for i in $(seq 0 $((n - 1))); do
  need "$(jq -r ".pairs[$i].base" "$m")"
  need "$(jq -r ".pairs[$i].head" "$m")"
  c="$(jq -r ".pairs[$i].config // empty" "$m")"; [ -z "$c" ] || need "$c"
done

out="$dir/index.html"
{
cat <<HTML
<!doctype html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${title}</title>
<style>
  body { font: 15px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; color: #1a1a1a; max-width: 1400px; margin: 32px auto; padding: 0 24px; }
  h1 { font-size: 22px; margin: 0 0 12px; }
  p { margin: 0 0 10px; }
  details { border: 1px solid #ddd; border-radius: 8px; padding: 10px 14px; margin: 18px 0; }
  summary { cursor: pointer; font-weight: 600; }
  .pair { margin: 18px 0 6px; }
  .pair h3 { font-size: 15px; margin: 0 0 8px; }
  .grid { display: grid; grid-template-columns: 1fr 1fr; gap: 12px; }
  figure { margin: 0; }
  figcaption { font-size: 13px; color: #555; margin-bottom: 4px; }
  img { width: 100%; height: auto; border: 1px solid #e5e5e5; border-radius: 4px; background: #fff; }
  pre { background: #f6f8fa; border-radius: 6px; padding: 12px; overflow: auto; font-size: 13px; }
</style>
</head>
<body>
<h1>${title}</h1>
${text_html}
<details>
<summary>Screenshots: ${base_label} vs ${head_label}</summary>
HTML
for i in $(seq 0 $((n - 1))); do
  label="$(jq -r ".pairs[$i].label // \"pair $((i + 1))\"" "$m" | esc)"
  bf="$(jq -r ".pairs[$i].base" "$m")"; hf="$(jq -r ".pairs[$i].head" "$m")"
  printf '<section class="pair">\n<h3>%s</h3>\n<div class="grid">\n' "$label"
  printf '<figure><figcaption>%s</figcaption><img alt="%s: %s" src="data:%s;base64,%s"></figure>\n' \
    "$base_label" "$base_label" "$label" "$(mime "$bf")" "$(b64 "$bf")"
  printf '<figure><figcaption>%s</figcaption><img alt="%s: %s" src="data:%s;base64,%s"></figure>\n' \
    "$head_label" "$head_label" "$label" "$(mime "$hf")" "$(b64 "$hf")"
  printf '</div>\n</section>\n'
done
printf '</details>\n'
if [ "$(jq '[.pairs[] | select(.config)] | length' "$m")" -gt 0 ]; then
  printf '<details>\n<summary>Configs</summary>\n'
  for i in $(seq 0 $((n - 1))); do
    c="$(jq -r ".pairs[$i].config // empty" "$m")"; [ -n "$c" ] || continue
    label="$(jq -r ".pairs[$i].label // \"pair $((i + 1))\"" "$m" | esc)"
    printf '<section class="pair">\n<h3>%s</h3>\n<pre><code>' "$label"
    esc < "$dir/$c"
    printf '</code></pre>\n</section>\n'
  done
  printf '</details>\n'
fi
printf '</body>\n</html>\n'
} > "$out"

size="$(wc -c < "$out" | tr -d ' ')"
if [ "$size" -gt "$LIMIT" ]; then
  rm -f "$out"
  die 7 "Page would be $((size / 1024 / 1024)) MiB, over the $((LIMIT / 1024 / 1024)) MiB limit: fewer pairs, or render at deviceScaleFactor 1."
fi
printf '%s\n%s pairs · %s KiB\n' "$out" "$n" "$((size / 1024))"
