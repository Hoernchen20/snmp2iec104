#!/bin/sh
# Regenerate src/api/schema.d.ts from the gateway's OpenAPI document
# (s2i_web_openapi:spec/0). Needs a compiled build: `rebar3 compile` in the
# repository root.
set -e
cd "$(dirname "$0")/.."
erl -noshell -pa ../_build/default/lib/*/ebin -eval '
    ok = file:write_file("openapi.json", s2i_web_json:encode(s2i_web_openapi:spec())),
    halt().'
npx openapi-typescript openapi.json -o src/api/schema.d.ts
rm openapi.json
