# Notas para el reporte técnico

Borrador vivo: al terminar cada módulo se agregan aquí las mediciones reales, observaciones y
decisiones. Al final se condensa en el PDF de máx. 5 páginas.

## Entorno de pruebas

- Máquina: _(completar con `evidencia/*/sistema.txt`)_
- CPU:
- RAM (host / visible en WSL2):
- SO: Windows + WSL2 Ubuntu __ · kernel __
- NASM __ · GNU ld __

## M1 — Identificación del CPU

## M2 — Puertos E/S

- Sin privilegios, `ioperm` devuelve `EPERM` (falta `CAP_SYS_RAWIO`) y cada `IN`/`OUT` produce #GP,
  que el kernel entrega como `SIGSEGV`. El manejador propio redirige el RIP del `ucontext` a un punto
  de recuperación: demuestra la protección de E/S del modo protegido sin abortar el programa.
- Desde Linux 5.5 `iopl(3)` se emula con el bitmap de E/S del TSS: la llamada tiene éxito pero el campo
  IOPL de RFLAGS sigue en 0 (se observa en la salida con `sudo`).
- Bajo emulación Rosetta (Docker en Apple Silicon) `ioperm`/`iopl` devuelven `ENOSYS`.
- En VMs (WSL2/Hyper-V, runners de CI) varios dispositivos legados no están emulados: `[NO PRESENTE]`.
- _(completar con la salida real de WSL2 con y sin sudo)_

## M3 — Diagnóstico de memoria

- Un proceso de usuario no ve la RAM física: se prueba un bloque de 64 MiB que el kernel asigna con
  `mmap` + `MAP_POPULATE` (páginas físicas reales, sin fallos de página durante la medición).
- Patrones: 0xAA (1010…), 0x55 (su complemento: cada bit pasa por 0 y por 1) e incremental (qword i = i,
  detecta alias de direcciones). Bits corruptos = POPCNT(leído XOR esperado).
- Escritura con `MOVNTI` + `SFENCE` (non-temporal: no contamina la caché y obliga a verificar desde RAM);
  lectura con `PREFETCHT0` a 512 B.
- Autoverificación: `_memtest_inject` voltea 3 bits conocidos y el detector informa exactamente 3,
  primer error en +50h.
- En WSL2 la "memoria total" es la de la VM (por defecto ~50 % del host, configurable en `.wslconfig`).
- _(completar con la salida real de WSL2 y el ancho de banda medido)_

## M4 — Rendimiento del CPU

## M5 — Jerarquía de memoria

## M6 — SIMD

## Optimizaciones (antes / después)

| Técnica | Dónde | Sin | Con | Mejora |
|---------|-------|-----|-----|--------|

## Referencias (APA)

- Intel Corporation. (2025). *Intel® 64 and IA-32 architectures software developer's manual* (Vols. 1–4). https://www.intel.com/sdm
- NASM Development Team. (2024). *NASM — The Netwide Assembler documentation*. https://nasm.us/docs.php
- Brey, B. B. (2006). *Los microprocesadores Intel* (7.ª ed.). Pearson Prentice Hall.
- Tanenbaum, A. S. (2000). *Organización de computadoras: Un enfoque estructurado* (4.ª ed.). Prentice Hall.
