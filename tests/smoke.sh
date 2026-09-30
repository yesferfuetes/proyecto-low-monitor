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
sleep=ok
cpudetect=ok'
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
echo "== M1: identificación del CPU =="
out="$("$BIN" cpu)"; rc=$?
# campo "Etiqueta" -> valor de la línea "Etiqueta:   valor" de la salida
campo() { awk -v k="$1:" 'index($0, k) == 1 { s = substr($0, length(k) + 1); sub(/^ +/, "", s); print s; exit }' <<<"$out"; }
# info "clave" -> valor de /proc/cpuinfo (primer procesador)
info() { awk -F': ' -v k="$1" '$1 ~ "^"k"[ \t]*$" { print $2; exit }' /proc/cpuinfo; }

if [ "$rc" -eq 0 ]; then ok "código de salida 0"; else fail "código de salida 0" "rc=$rc"; fi
faltan=""
for et in "Fabricante" "Procesador" "Arquitectura" "Familia" "Modelo" "Stepping" "Hilos lógicos" \
          "Características" "Extensiones" "AVX (SO)" "AVX-512 (SO)"; do
    [ -n "$(campo "$et")" ] || faltan="$faltan [$et]"
done
if [ -z "$faltan" ]; then ok "todas las líneas presentes"; else fail "todas las líneas presentes" "faltan:$faltan"; fi
if [ "$(campo Arquitectura)" = "x86_64" ]; then ok "arquitectura x86_64 (modo largo)"; else fail "arquitectura x86_64 (modo largo)" "$(campo Arquitectura)"; fi
if [ "$(campo 'Hilos lógicos')" = "$(nproc)" ]; then ok "hilos lógicos = nproc ($(nproc))"; else fail "hilos lógicos = nproc" "$(campo 'Hilos lógicos') vs $(nproc)"; fi

if ! grep -q '^vendor_id' /proc/cpuinfo; then
    echo "  [OMITE] comparación con /proc/cpuinfo: el kernel no es x86 (¿emulación?)"
elif [ "$(info vendor_id)" = "VirtualApple" ]; then
    echo "  [OMITE] comparación con /proc/cpuinfo: emulación Rosetta (su /proc/cpuinfo no refleja CPUID)"
else
    v="$(info vendor_id)"
    if [ "$(campo Fabricante)" = "$v" ]; then ok "fabricante = /proc/cpuinfo ($v)"; else fail "fabricante = /proc/cpuinfo" "$(campo Fabricante) vs $v"; fi
    v="$(info 'model name')"
    if [ "$(campo Procesador)" = "$v" ]; then ok "nombre comercial = /proc/cpuinfo"; else fail "nombre comercial = /proc/cpuinfo" "'$(campo Procesador)' vs '$v'"; fi
    v="$(info 'cpu family')"
    if [ "$(campo Familia | cut -d' ' -f1)" = "$v" ]; then ok "familia = /proc/cpuinfo ($v)"; else fail "familia = /proc/cpuinfo" "$(campo Familia) vs $v"; fi
    v="$(info model)"
    if [ "$(campo Modelo | cut -d' ' -f1)" = "$v" ]; then ok "modelo = /proc/cpuinfo ($v)"; else fail "modelo = /proc/cpuinfo" "$(campo Modelo) vs $v"; fi

    flags=" $(info flags) "
    ext=", $(campo Extensiones), "
    difs=""
    for par in sse:SSE sse2:SSE2 pni:SSE3 ssse3:SSSE3 sse4_1:SSE4.1 sse4_2:SSE4.2 avx:AVX fma:FMA \
               avx2:AVX2 avx512f:AVX-512F avx512dq:AVX-512DQ avx512bw:AVX-512BW avx512vl:AVX-512VL; do
        f="${par%%:*}"; n="${par#*:}"
        en_kernel=0; [[ "$flags" == *" $f "* ]] && en_kernel=1
        en_salida=0; [[ "$ext" == *", $n, "* ]] && en_salida=1
        [ "$en_kernel" -eq "$en_salida" ] || difs="$difs $n(kernel=$en_kernel,lowmonitor=$en_salida)"
    done
    if [ -z "$difs" ]; then ok "extensiones = flags de /proc/cpuinfo"; else fail "extensiones = flags de /proc/cpuinfo" "$difs"; fi

    if [[ "$flags" == *" hypervisor "* ]]; then
        if [ -n "$(campo Hipervisor)" ]; then ok "hipervisor detectado ($(campo Hipervisor))"; else fail "hipervisor detectado" "falta la línea"; fi
    fi
fi

# -----------------------------------------------------------------------------
# (los módulos M2..M6 agregan aquí sus secciones)

echo
echo "Resultado: $PASS pasan, $FAIL fallan"
[ "$FAIL" -eq 0 ]
