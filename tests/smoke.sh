#!/usr/bin/env bash
# =============================================================================
# smoke.sh — Pruebas automáticas de LowMonitor
# -----------------------------------------------------------------------------
# Uso: bash tests/smoke.sh [ruta-al-binario]      (lo invoca `make test`)
# Cada módulo agrega su sección con las verificaciones automáticas. Sale con 0 si todo pasa.
# =============================================================================
set -u

BIN="${1:-bin/lowmonitor}"
PASS=0
FAIL=0

ok()   { PASS=$((PASS + 1)); printf '  [PASA]  %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  [FALLA] %s\n' "$1"; [ -n "${2:-}" ] && printf '          %s\n' "$2"; }
# check "descripción" comando args...  -> PASA si el comando retorna 0
check() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else fail "$d"; fi; }

if [ "$(uname -m)" != "x86_64" ]; then
    echo "Estas pruebas requieren una máquina x86-64 (actual: $(uname -m))."
    exit 2
fi

# -----------------------------------------------------------------------------
echo "== Binario =="
check "el binario existe y es ejecutable" test -x "$BIN"
check "formato ELF64"                    bash -c "readelf -h '$BIN' | grep -q 'Class:.*ELF64'"
check "máquina x86-64"                   bash -c "readelf -h '$BIN' | grep -q 'Machine:.*X86-64'"
check "estático, sin intérprete"    bash -c "! readelf -l '$BIN' | grep -q INTERP"
check "ningún 'int 0x80' en src/"             bash -c "! grep -rniE 'int[[:space:]]+(0x80|80h)' src/"
check "_start sólo en src/main.asm"           bash -c "[ \"\$(grep -rlE '^[[:space:]]*_start:' src/)\" = 'src/main.asm' ]"

out="$("$BIN" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then ok "código de salida 0"; else fail "código de salida 0" "obtenido: $rc"; fi
if grep -q "LowMonitor" <<<"$out"; then ok "imprime la identificación"; else fail "imprime la identificación" "salida: $out"; fi

# -----------------------------------------------------------------------------
# (los módulos M1..M6 agregan aquí sus secciones)

echo
echo "Resultado: $PASS pasan, $FAIL fallan"
[ "$FAIL" -eq 0 ]
