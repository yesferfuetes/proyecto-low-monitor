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
echo "== M2: puertos de E/S =="
# verificar_puertos "contexto" salida rc
verificar_puertos() {
    local ctx="$1" out="$2" rc="$3"
    local prot ok_np
    prot=$(grep -c '\[PROTEGIDO\]' <<<"$out")
    ok_np=$(grep -cE '\[(OK|NO PRESENTE)\]' <<<"$out")
    if [ "$rc" -eq 0 ]; then ok "$ctx: código de salida 0 (sin abortar)"; else fail "$ctx: código de salida 0 (sin abortar)" "rc=$rc"; fi
    if grep -q '^Permiso ioperm: *DENEGADO' <<<"$out"; then
        if [ "$prot" -eq 5 ]; then ok "$ctx: sin permiso, las 5 pruebas quedan [PROTEGIDO]"; else fail "$ctx: sin permiso, las 5 pruebas quedan [PROTEGIDO]" "protegidas=$prot"; fi
    elif grep -q '^Permiso ioperm: *CONCEDIDO' <<<"$out"; then
        # con ioperm, 64h/60h/61h/COM1 deben accederse; CFCh depende de iopl
        if [ "$ok_np" -ge 4 ] && ! grep -qE '^Puerto (6[014]h|3F8h).*PROTEGIDO' <<<"$out"; then
            ok "$ctx: con permiso, acceso real a 60h/61h/64h/3F8h"
        else
            fail "$ctx: con permiso, acceso real a 60h/61h/64h/3F8h" "$(grep '^Puerto' <<<"$out" | tr '\n' '|')"
        fi
        if ! grep -q '\[ERROR\]' <<<"$out"; then ok "$ctx: 61h escritura/lectura consistente"; else fail "$ctx: 61h escritura/lectura consistente"; fi
    else
        fail "$ctx: línea de permiso ioperm"
    fi
}
out="$("$BIN" puertos 2>&1)"; rc=$?
verificar_puertos "usuario" "$out" "$rc"

anchos=0
for inst in "PUERTO_IN +port_in8, +al" "PUERTO_IN +port_in16, +ax" "PUERTO_IN +port_in32, +eax" \
            "PUERTO_OUT +port_out8, +al" "PUERTO_OUT +port_out16, +ax" "PUERTO_OUT +port_out32, +eax"; do
    grep -qE "^$inst" src/mod/ports.asm && anchos=$((anchos + 1))
done
if [ "$anchos" -eq 6 ]; then ok "IN/OUT de 8, 16 y 32 bits en el código"; else fail "IN/OUT de 8, 16 y 32 bits en el código" "instancias=$anchos/6"; fi

out="$("$BIN" _puertos_senales 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && grep -q '^manejadores=ok' <<<"$out"; then ok "handlers de señales restaurados al terminar"; else fail "handlers de señales restaurados al terminar" "rc=$rc $(grep manejadores <<<"$out")"; fi

if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    out="$(sudo -n "$BIN" puertos 2>&1)"; rc=$?
    verificar_puertos "sudo" "$out" "$rc"
else
    echo "  [OMITE] prueba con sudo (no disponible sin contraseña)"
fi

# -----------------------------------------------------------------------------
echo "== M3: diagnóstico de memoria =="
out="$("$BIN" memoria 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then ok "código de salida 0"; else fail "código de salida 0" "rc=$rc $(grep ERROR <<<"$out")"; fi
n=$(grep -cE '^Patrón (0xAA|0x55|incremental): +PASADA \(0 errores\)' <<<"$out")
if [ "$n" -eq 3 ]; then ok "patrones 0xAA, 0x55 e incremental: PASADA"; else fail "patrones 0xAA, 0x55 e incremental: PASADA" "$(grep '^Patrón' <<<"$out" | tr '\n' '|')"; fi

# memoria total: "N UNIDAD" vs MemTotal de /proc/meminfo, tolerancia de 1 unidad
total="$(grep '^Memoria total:' <<<"$out" | sed -E 's/^Memoria total: +//; s/ detectada$//')"
kb=$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo)
if awk -v t="$total" -v kb="$kb" 'BEGIN {
        split(t, p, " "); u = 1
        if (p[2] == "KB") u = 1024; else if (p[2] == "MB") u = 1048576
        else if (p[2] == "GB") u = 1073741824; else if (p[2] == "TB") u = 1099511627776
        d = p[1] * u - kb * 1024; if (d < 0) d = -d
        exit !(d <= u) }'; then
    ok "memoria total = MemTotal de /proc/meminfo ($total)"
else
    fail "memoria total = MemTotal de /proc/meminfo" "$total vs ${kb} kB"
fi
if grep -qE '^Escritura \(NT\): +[1-9][0-9]* MB/s' <<<"$out" && grep -qE '^Verificación: +[1-9][0-9]* MB/s' <<<"$out"; then
    ok "ancho de banda medido (escritura y verificación)"
else
    fail "ancho de banda medido (escritura y verificación)"
fi

out="$("$BIN" _memtest_inject 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && grep -qE '^Patrón 0xAA: +FALLIDA \(3 bits corruptos, primer error en \+50h\)' <<<"$out" \
   && [ "$(grep -cE 'PASADA \(0 errores\)' <<<"$out")" -eq 2 ]; then
    ok "inyección: detecta exactamente 3 bits corruptos en +50h"
else
    fail "inyección: detecta exactamente 3 bits corruptos en +50h" "$(grep '^Patrón' <<<"$out" | tr '\n' '|')"
fi

usos=0
for inst in movnti sfence prefetcht0 popcnt; do grep -qE "^[[:space:]]+$inst[[:space:]]" src/mod/memtest.asm && usos=$((usos + 1)); done
if [ "$usos" -eq 4 ]; then ok "usa MOVNTI, SFENCE, PREFETCHT0 y POPCNT"; else fail "usa MOVNTI, SFENCE, PREFETCHT0 y POPCNT" "$usos/4"; fi

# -----------------------------------------------------------------------------
echo "== M4: rendimiento del CPU =="
out="$("$BIN" rendimiento 2>&1)"; rc=$?
campo() { awk -v k="$1:" 'index($0, k) == 1 { s = substr($0, length(k) + 1); sub(/^ +/, "", s); print s; exit }' <<<"$out"; }
if [ "$rc" -eq 0 ]; then ok "código de salida 0"; else fail "código de salida 0" "rc=$rc"; fi

ghz="$(campo 'Frecuencia (TSC)' | cut -d' ' -f1)"
if awk -v g="$ghz" 'BEGIN { exit !(g >= 0.5 && g <= 10) }'; then ok "frecuencia TSC razonable ($ghz GHz)"; else fail "frecuencia TSC razonable" "'$ghz'"; fi
# Referencia: en x86 Linux calibra el TSC al arrancar y BogoMIPS = 2 x frecuencia del TSC.
# ("cpu MHz" NO sirve: es la frecuencia actual del núcleo, con turbo.)
bogo="$(awk -F': ' '/^bogomips/ { print $2; exit }' /proc/cpuinfo)"
if [ -n "$bogo" ] && [ "$(awk -F': ' '/^vendor_id/ { print $2; exit }' /proc/cpuinfo)" != "VirtualApple" ]; then
    if awk -v g="$ghz" -v b="$bogo" 'BEGIN { m = b / 2; d = g * 1000 - m; if (d < 0) d = -d; exit !(d <= m * 0.10) }'; then
        ok "frecuencia TSC dentro de ±10% de BogoMIPS/2 ($bogo)"
    else
        fail "frecuencia TSC dentro de ±10% de BogoMIPS/2" "$ghz GHz vs BogoMIPS $bogo"
    fi
else
    echo "  [OMITE] comparación con BogoMIPS (no disponible o emulación)"
fi

ipc_dep="$(campo 'Carga dependiente' | sed -E 's/.*IPC ([0-9.]+).*/\1/')"
ipc_ind="$(campo 'Carga independiente' | sed -E 's/.*IPC ([0-9.]+).*/\1/')"
if [ "$(awk -F': ' '/^vendor_id/ { print $2; exit }' /proc/cpuinfo)" = "VirtualApple" ]; then
    echo "  [OMITE] cota de IPC dependiente: bajo Rosetta el TSC no corresponde a los ciclos del núcleo"
elif awk -v d="$ipc_dep" 'BEGIN { exit !(d >= 0.3 && d <= 2.5) }'; then ok "IPC dependiente plausible ($ipc_dep)"
else fail "IPC dependiente plausible (0.3-2.5)" "$ipc_dep"; fi
if awk -v d="$ipc_dep" -v i="$ipc_ind" 'BEGIN { exit !(i > d) }'; then ok "IPC independiente ($ipc_ind) > dependiente ($ipc_dep)"; else fail "IPC independiente > dependiente" "$ipc_ind vs $ipc_dep"; fi

gf="$(campo 'Throughput' | cut -d' ' -f1)"
if awk -v g="$gf" 'BEGIN { exit !(g > 0) }'; then ok "GFLOPS > 0 ($gf)"; else fail "GFLOPS > 0" "'$gf'"; fi
if grep -qE '^CPI promedio: +[0-9]+\.[0-9]{2} \(estimado con TSC\)$' <<<"$out" && grep -qE '^IPC: +[0-9]+\.[0-9]{2} ' <<<"$out"; then
    ok "CPI promedio e IPC con formato numérico"
else
    fail "CPI promedio e IPC con formato numérico"
fi
if grep -qE '^Contadores PMU: +(CPI [0-9]|no disponibles \()' <<<"$out"; then ok "línea de contadores PMU ($(campo 'Contadores PMU'))"; else fail "línea de contadores PMU"; fi
if grep -qE '^Ciclos totales: +[1-9][0-9]*$' <<<"$out"; then ok "ciclos totales > 0"; else fail "ciclos totales > 0"; fi

# -----------------------------------------------------------------------------
echo "== M5: jerarquía de memoria =="
# fila "Nivel" columna n (1=tamaño ... ) desde la tabla; las etiquetas tienen 13 columnas visibles
fila() { grep -m1 -E "^$1 +[-0-9]" <<<"$out" | sed -E "s/^$1 +//"; }
# a_kb "48 KB" -> 48 ; "2 MB" -> 2048
a_kb() { awk '{ u = 1; if ($2 == "MB") u = 1024; else if ($2 == "GB") u = 1048576; else if ($2 == "B") u = 1 / 1024; print $1 * u }' <<<"$1"; }
emulado=0; [ "$(awk -F': ' '/^vendor_id/ { print $2; exit }' /proc/cpuinfo)" = "VirtualApple" ] && emulado=1

intentos=0; monotono=0
while [ "$intentos" -lt 3 ]; do
    out="$("$BIN" jerarquia 2>&1)"; rc=$?
    intentos=$((intentos + 1))
    # columna "Cadena": último número de cada fila
    cad() { fila "$1" | awk '{ print $NF }'; }
    r=$(cad "Registros"); c1=$(cad "L1 caché"); c2=$(cad "L2 caché"); c3=$(cad "L3 caché"); cr=$(cad "RAM")
    if awk -v a="$r" -v b="$c1" -v c="$c2" -v d="$c3" -v e="$cr" 'BEGIN { exit !(a < b && b < c && c < d && d < e) }'; then monotono=1; break; fi
done
if [ "$rc" -eq 0 ]; then ok "código de salida 0"; else fail "código de salida 0" "rc=$rc $(grep ERROR <<<"$out")"; fi
if [ "$(grep -cE '^(Registros|L1 caché|L2 caché|L3 caché|RAM) +[-0-9]' <<<"$out")" -eq 5 ]; then ok "tabla con los 5 niveles"; else fail "tabla con los 5 niveles"; fi

if [ "$emulado" -eq 1 ]; then
    echo "  [OMITE] orden de latencias y tamaños: bajo Rosetta CPUID y la jerarquía real no coinciden"
else
    if [ "$monotono" -eq 1 ]; then ok "latencias crecientes Reg < L1 < L2 < L3 < RAM ($r < $c1 < $c2 < $c3 < $cr, intento $intentos)"
    else fail "latencias crecientes Reg < L1 < L2 < L3 < RAM" "$r $c1 $c2 $c3 $cr"; fi
    if awk -v a="$r" -v c="$c2" -v e="$cr" 'BEGIN { exit !(a <= 2 && e >= 3 * c) }'; then ok "registros <= 2 ciclos y RAM >= 3 x L2"
    else fail "registros <= 2 ciclos y RAM >= 3 x L2" "reg=$r L2=$c2 RAM=$cr"; fi

    # tamaños contra sysfs (index con level/type)
    difs=""
    for d in /sys/devices/system/cpu/cpu0/cache/index*; do
        [ -d "$d" ] || continue
        lvl=$(cat "$d/level"); typ=$(cat "$d/type")
        [ "$typ" = "Instruction" ] && continue
        kb_sys=$(sed 's/K$//' "$d/size")
        tam="$(fila "L$lvl caché" | sed -E 's/^([0-9]+ [KMG]?B).*/\1/')"
        kb_lm=$(a_kb "$tam")
        [ "$kb_sys" = "$kb_lm" ] || difs="$difs L$lvl(sysfs=${kb_sys}K,lowmonitor=$tam)"
    done
    if [ -z "$difs" ]; then ok "tamaños L1d/L2/L3 = /sys/devices/system/cpu/cpu0/cache"; else fail "tamaños L1d/L2/L3 = sysfs" "$difs"; fi
fi

al=$(grep '^  Aleatorio' <<<"$out" | awk '{ print $NF }'); se=$(grep '^  Secuencial: ' <<<"$out" | awk '{ print $NF }')
if awk -v a="$al" -v s="$se" 'BEGIN { exit !(a > s) }'; then ok "prefetch: aleatorio ($al) > secuencial ($se)"; else fail "prefetch: aleatorio > secuencial" "$al vs $se"; fi
if grep -qE '^[[:space:]]+call[[:space:]]+tsc_begin' src/mod/cache.asm && grep -qE '^[[:space:]]+prefetcht0' src/mod/cache.asm; then
    ok "TSC alrededor de cada acceso y PREFETCHT0 en el código"
else
    fail "TSC alrededor de cada acceso y PREFETCHT0 en el código"
fi

# -----------------------------------------------------------------------------
echo "== M6: operaciones SIMD =="
out="$("$BIN" simd 2>&1)"; rc=$?
cpu_out="$("$BIN" cpu 2>&1)"
linea() { grep -m1 -F "$1" <<<"$out"; }
emulado=0; [ "$(awk -F': ' '/^vendor_id/ { print $2; exit }' /proc/cpuinfo)" = "VirtualApple" ] && emulado=1
if [ "$rc" -eq 0 ]; then ok "código de salida 0 (sin SIGILL)"; else fail "código de salida 0 (sin SIGILL)" "rc=$rc"; fi
if ! grep -q '\[ERROR\]' <<<"$out" && [ "$(grep -c 'suma \[OK\]  mult \[OK\]  comp \[OK\]' <<<"$out")" -ge 1 ]; then
    ok "ISAs disponibles: suma, mult y comp idénticas al escalar ($(grep -c 'comp \[OK\]' <<<"$out") ISAs)"
else
    fail "ISAs disponibles: suma, mult y comp idénticas al escalar" "$(grep -E 'lanes' <<<"$out" | tr '\n' '|')"
fi

# coherencia con M1: AVX2 disponible <=> extensión AVX2 + AVX (SO) habilitado; ídem AVX-512
ext="$(grep '^Extensiones:' <<<"$cpu_out")"
esp2=0; [[ "$ext" == *"AVX2"* ]] && grep -q '^AVX (SO): *Habilitado' <<<"$cpu_out" && esp2=1
esp5=0; grep -q '^AVX-512 (SO): *Habilitado' <<<"$cpu_out" && esp5=1
hay2=0; linea "AVX2 (256b" | grep -q 'Sí' && hay2=1
hay5=0; linea "AVX-512 (512b" | grep -q 'Sí' && hay5=1
if [ "$esp2" -eq "$hay2" ] && [ "$esp5" -eq "$hay5" ]; then ok "disponibilidad coherente con M1 (AVX2=$hay2, AVX-512=$hay5)"
else fail "disponibilidad coherente con M1" "M1: AVX2=$esp2 AVX-512=$esp5 / M6: AVX2=$hay2 AVX-512=$hay5"; fi

sp() { linea "$1" | sed -nE 's/.*x([0-9]+\.[0-9]+)$/\1/p'; }
s_sse=$(sp "SSE2 (128b"); s_avx=$(sp "AVX2 (256b")
if awk -v a="$s_sse" 'BEGIN { exit !(a > 1) }'; then ok "speedup SSE2 > 1 (x$s_sse)"; else fail "speedup SSE2 > 1" "x$s_sse"; fi
if [ "$hay2" -eq 1 ]; then
    if [ "$emulado" -eq 1 ]; then
        echo "  [OMITE] AVX2 > SSE2: bajo Rosetta AVX se traduce a NEON de 128 bits"
    elif awk -v a="$s_avx" -v b="$s_sse" 'BEGIN { exit !(a > b) }'; then ok "speedup AVX2 (x$s_avx) > SSE2 (x$s_sse)"
    else fail "speedup AVX2 > SSE2" "x$s_avx vs x$s_sse"; fi
fi
if grep -qE '^Throughput: +(4|8|16) operaciones paralelas' <<<"$out" && grep -qE '^Benchmark: +[0-9]+\.[0-9]{2} GFLOPS' <<<"$out"; then
    ok "resumen: throughput y benchmark"
else
    fail "resumen: throughput y benchmark"
fi
if grep -qE '^Escritura normal 64 MB: +[1-9][0-9]* MB/s' <<<"$out" && grep -qE '^Escritura NT 64 MB: +[1-9][0-9]* MB/s' <<<"$out"; then
    ok "escritura normal vs non-temporal medida"
else
    fail "escritura normal vs non-temporal medida"
fi


echo
echo "Resultado: $PASS pasan, $FAIL fallan"
[ "$FAIL" -eq 0 ]
