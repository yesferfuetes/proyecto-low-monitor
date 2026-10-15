#!/usr/bin/env bash
# =============================================================================
# evidencia.sh — Guarda evidencia de funcionamiento para el reporte
# -----------------------------------------------------------------------------
# Uso: bash scripts/evidencia.sh [binario]        (lo invoca `make evidencia`)
# Crea evidencia/<fecha>_<host>/ con:
#   sistema.txt        uname, lscpu, cpuinfo, meminfo, cachés, versiones
#   salida-usuario.txt salida de `lowmonitor todo` como usuario regular
#   salida-sudo.txt    salida con sudo (si se autoriza)
# =============================================================================
set -u
BIN="${1:-bin/lowmonitor}"

# La evidencia sólo vale en Linux x86-64 (nativo o WSL2): en otro sistema el
# binario no se ejecuta y sólo se guardarían errores.
if [ "$(uname -s)" != "Linux" ] || [ "$(uname -m)" != "x86_64" ]; then
    echo "evidencia: hay que ejecutarlo en Linux x86-64 (WSL2 o nativo); este sistema es $(uname -s) $(uname -m)." >&2
    exit 1
fi
if ! "$BIN" ayuda >/dev/null 2>&1; then
    echo "evidencia: $BIN no se pudo ejecutar; compile primero con 'make'." >&2
    exit 1
fi
DIR="evidencia/$(date +%Y-%m-%d_%H%M)_$(hostname -s)"
mkdir -p "$DIR"

{
    echo "# Fecha: $(date -Iseconds)"
    echo "# Commit: $(git rev-parse --short HEAD 2>/dev/null || echo desconocido)"
    echo; echo "## uname -a";          uname -a
    echo; echo "## /proc/version";     cat /proc/version
    if grep -qi microsoft /proc/version; then echo "(Entorno: WSL2)"; fi
    echo; echo "## lscpu";             lscpu 2>/dev/null
    echo; echo "## /proc/cpuinfo (cpu0)"; awk '/^$/{exit} {print}' /proc/cpuinfo
    echo; echo "## /proc/meminfo";     head -n 5 /proc/meminfo
    echo; echo "## Cachés (sysfs)"
    for d in /sys/devices/system/cpu/cpu0/cache/index*; do
        [ -d "$d" ] && echo "L$(cat "$d/level") $(cat "$d/type"): $(cat "$d/size")"
    done
    echo; echo "## perf_event_paranoid"; cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null
    echo; echo "## Herramientas";      nasm -v; ld -v
} > "$DIR/sistema.txt" 2>&1

echo "\$ $BIN todo" > "$DIR/salida-usuario.txt"
"$BIN" todo >> "$DIR/salida-usuario.txt" 2>&1
echo "[código de salida: $?]" >> "$DIR/salida-usuario.txt"

read -r -p "¿Ejecutar también con sudo (acceso real a puertos E/S)? [s/N] " r
if [[ "$r" =~ ^[sS]$ ]]; then
    echo "\$ sudo $BIN todo" > "$DIR/salida-sudo.txt"
    sudo "$BIN" todo >> "$DIR/salida-sudo.txt" 2>&1
    echo "[código de salida: $?]" >> "$DIR/salida-sudo.txt"
fi

echo "Evidencia guardada en $DIR"
cat "$DIR/salida-usuario.txt"
