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
echo "== Núcleo: línea de comandos =="
out="$("$BIN")"; rc=$?
n=$(grep -c '^== \[M[1-6]\]' <<<"$out")
if [ "$rc" -eq 0 ] && [ "$n" -eq 6 ]; then ok "sin argumentos ejecuta los 6 módulos"; else fail "sin argumentos ejecuta los 6 módulos" "rc=$rc encabezados=$n"; fi

i=1
for cmd in cpu puertos memoria rendimiento jerarquia simd; do
    out="$("$BIN" "$cmd")"; rc=$?
    n=$(grep -c '^== \[M' <<<"$out")
    if [ "$rc" -eq 0 ] && [ "$n" -eq 1 ] && grep -q "^== \[M$i\]" <<<"$out"; then
        ok "'$cmd' ejecuta sólo M$i"
    else
        fail "'$cmd' ejecuta sólo M$i" "rc=$rc encabezados=$n"
    fi
    i=$((i + 1))
done

out="$("$BIN" ayuda)"; rc=$?
if [ "$rc" -eq 0 ] && grep -q '^Uso: lowmonitor' <<<"$out"; then ok "'ayuda' muestra el uso"; else fail "'ayuda' muestra el uso" "rc=$rc"; fi

out="$("$BIN" noexiste 2>/tmp/lm_err)"; rc=$?
if [ "$rc" -eq 1 ] && grep -q 'Uso:' /tmp/lm_err && ! grep -q 'Uso:' <<<"$out"; then
    ok "comando desconocido: uso por stderr y código 1"
else
    fail "comando desconocido: uso por stderr y código 1" "rc=$rc"
fi

"$BIN" cpu memoria >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 1 ]; then ok "más de un argumento: código 1"; else fail "más de un argumento: código 1" "rc=$rc"; fi

if [ -w /dev/full ]; then
    "$BIN" todo >/dev/full 2>/tmp/lm_err; rc=$?
    if [ "$rc" -eq 3 ] && [ -s /tmp/lm_err ]; then ok "stdout sin espacio (/dev/full): código 3 y aviso"; else fail "stdout sin espacio (/dev/full): código 3 y aviso" "rc=$rc"; fi
fi
rm -f /tmp/lm_err

# -----------------------------------------------------------------------------
echo "== Núcleo: librería de salida y utilidades =="
esperado='u64_0=0
u64_max=18446744073709551615
i64=-42
hex=03F8
hex_big=DEADBEEF
fixed=1.800
fixed2=0.05
fixed0=7
size=32 GB
size_l2=1280 KB
size_b=512 B
size_round=16 GB
bool=Sí,No
muldiv=1000000000000000000
streq=1,0
tsc=ok
sleep=ok'
out="$("$BIN" _selftest)"; rc=$?
obtenido="$(grep '=' <<<"$out")"
if [ "$rc" -eq 0 ] && [ "$obtenido" = "$esperado" ]; then
    ok "autotest de formato (_selftest)"
else
    fail "autotest de formato (_selftest)" "diferencias:"
    diff <(echo "$esperado") <(echo "$obtenido") | sed 's/^/          /'
fi
n=$(tr -cd '#' <<<"$out" | wc -c | tr -d ' ')
if [ "$n" -eq 10000 ]; then ok "salida mayor a 4 KiB completa (10000 bytes)"; else fail "salida mayor a 4 KiB completa (10000 bytes)" "obtenidos: $n"; fi

# -----------------------------------------------------------------------------
# (los módulos M1..M6 agregan aquí sus secciones)

echo
echo "Resultado: $PASS pasan, $FAIL fallan"
[ "$FAIL" -eq 0 ]
