#!/usr/bin/env bash
# Smoke-test the package exactly as an external project consumes it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TLUA="${TLUA:-tlua}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

APP="$TMP/app"
mkdir -p "$APP"
cat > "$APP/tlua.toml" <<EOF
[package]
name = "package-smoke"
version = "v0.1.0"

[dependencies]
"github.com/types-lua/typelua-httpd" = { path = "$ROOT" }
EOF

cat > "$APP/tlua.json" <<'EOF'
{
  "compilerOptions": {
    "target": "5.4",
    "strict": true,
    "strictNilChecks": true,
    "noImplicitAny": true,
    "rootDir": ".",
    "outDir": "dist",
    "typeRoots": [
      "types",
      "tlua_modules/github.com/types-lua/typelua-httpd/types"
    ]
  },
  "include": ["**/*.tl"],
  "exclude": ["dist"]
}
EOF

cat > "$APP/main.tl" <<'TL'
import http from "github.com/types-lua/typelua-httpd"

local router = http.HttpRouter.new()
router:get("/", function(ctx: HttpContextApi): void
  ctx:text("package smoke\n")
end)
print("root_ok=" .. tostring(router:count() == 1))
TL

cat > "$APP/core.tl" <<'TL'
import core from "github.com/types-lua/typelua-httpd/core"

local router = core.HttpRouter.new()
router:get("/", function(ctx: HttpContextApi): void ctx:text("core\n") end)
print("core_ok=" .. tostring(router:count() == 1))
print("socket_loaded=" .. tostring(package.loaded["socket"] ~= nil))
print("ssl_loaded=" .. tostring(package.loaded["ssl"] ~= nil))
print("ffi_loaded=" .. tostring(package.loaded["ffi"] ~= nil))
TL

(cd "$APP" && "$TLUA" mod get >/dev/null && "$TLUA" mod vendor >/dev/null)
# A local path dependency can contain a developer's ignored dist/ tree; remove
# it so this mirrors a clean Git checkout fetched by `tlua mod get`.
rm -rf "$APP/tlua_modules/github.com/types-lua/typelua-httpd/dist"

(cd "$APP" && "$TLUA" check && "$TLUA" build >/dev/null)
(cd "$APP/dist" && lua5.4 main.lua)
(cd "$APP/dist" && lua5.4 core.lua)

if command -v luajit >/dev/null 2>&1; then
  cat > "$APP/ffi.tl" <<'TL'
import core from "github.com/types-lua/typelua-httpd/core"
import ffiTransport from "github.com/types-lua/typelua-httpd/adapters/ffi"

local transport = ffiTransport.FfiSocketTransport.new()
local router = core.HttpRouter.new()
router:get("/", function(ctx: HttpContextApi): void ctx:text("ffi\n") end)
local server = core.HttpServer.new(router, transport, {})
server:listen("127.0.0.1", 0)
print("ffi_ok=" .. tostring(server:address().port > 0))
server:close()
print("socket_loaded=" .. tostring(package.loaded["socket"] ~= nil))
print("ssl_loaded=" .. tostring(package.loaded["ssl"] ~= nil))
TL
  (cd "$APP" && "$TLUA" build --target 5.1 >/dev/null)
  (cd "$APP/dist" && luajit ffi.lua)
fi

echo "package smoke test passed"
