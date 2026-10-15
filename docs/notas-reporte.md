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

- Frecuencia del TSC calibrada contra `CLOCK_MONOTONIC` (ciclos durante 100 ms / ns reales, mediana de 3).
- Medición serializada: `lfence; rdtsc; lfence` al inicio y `rdtscp; lfence` al final; mínimo de 5
  repeticiones menos el costo de medir "nada". Proceso fijado a una CPU con `sched_setaffinity`.
- Instrucciones conocidas por construcción (10 por vuelta, 10⁷ vueltas). Cadena dependiente de `add`
  → IPC ≈ 1 (latencia); 8 sumas independientes → IPC > 1 (paralelismo a nivel de instrucción, varias ALUs).
- El TSC cuenta ciclos de referencia (frecuencia nominal), no del núcleo: con turbo el CPI "TSC" sale
  menor que el real. Bajo Rosetta el TSC emulado va a ~1 GHz y el IPC aparente se infla (~5).
- Observado en CI (runner con turbo): TSC 2.59 GHz mientras `cpu MHz` marcaba 4.2 GHz; el IPC de la cadena
  dependiente dio 2.04 ≈ 1.25 × (4.2 / 2.59): el TSC subestima los ciclos reales en la proporción del turbo.
- *Immediate folding*: en un Xeon 8573C (Emerald Rapids) la cadena `add rax, 1` × 8 dio IPC 7.6, igual que la
  carga independiente: desde Golden Cove Intel pliega las sumas de inmediatos encadenadas al renombrar, sin
  pasar por la ALU. Con `add rax, rdx` (registro-registro) la dependencia vuelve a ser real (latencia 1).
  En AMD Zen 3/5 no se observó el efecto.
- Contadores PMU (`perf_event_open`, ciclos e instrucciones reales) se usan si el kernel lo permite; en
  Ubuntu `perf_event_paranoid=4` los niega a usuarios (`EACCES`) y en VMs suelen no existir.
- _(completar con la salida real de WSL2: frecuencia, IPC de cada carga y GFLOPS)_

## M5 — Jerarquía de memoria

- Tamaños de caché con CPUID (Intel hoja 4; AMD hoja 8000001Dh o 80000005h/6h).
- Lista enlazada cíclica aleatoria (Sattolo + xorshift64) de nodos de 64 B: cada `mov rax, [rax]` depende
  del anterior y el orden aleatorio anula el prefetcher → el tiempo por carga es la latencia del nivel.
- Conjunto de trabajo de cada nivel entre su tamaño y el del anterior; buffers alineados a 2 MiB con
  `MADV_HUGEPAGE` para que los fallos de TLB no inflen L3/RAM.
- Dos mediciones: TSC alrededor de cada acceso (lo pedido; el costo de rdtsc/rdtscp es mayor que la latencia
  de L1, por eso es ruidosa) y TSC alrededor de 10⁶ cargas (más precisa).
- La L3 es compartida por todos los núcleos (y, en la nube, por otras VMs): en CI (Xeon 8370C, L3 48 MB,
  VM de 2 vCPU) un conjunto de 25 MB midió ~260 ciclos, igual que RAM. Con 5 MB (4 × L2) la latencia de L3
  se separa claramente de RAM. El conjunto de L3 se limita a 4 × L2.
- Demostración de prefetch en RAM: recorrido aleatorio vs secuencial vs secuencial + `prefetcht0`.
- Los "ciclos" son del TSC (frecuencia nominal); con turbo el núcleo hace más ciclos reales por ciclo TSC.
- CI (AMD EPYC 7763, cadena): L1 3.1, L2 11.0, L3 34.4, RAM 212.3 ciclos TSC; RAM/L1 = 68x.
- `prefetcht0` no mejora el recorrido secuencial (5.2 vs 4.8 ciclos/línea): el prefetcher de hardware ya
  detecta el patrón secuencial y la instrucción extra sólo agrega costo. El prefetch por software rinde en
  patrones que el hardware no puede predecir.
- _(completar con la tabla real de WSL2 y una gráfica latencia vs nivel)_

## M6 — SIMD

## Optimizaciones (antes / después)

| Técnica | Dónde | Sin | Con | Mejora |
|---------|-------|-----|-----|--------|

## Referencias (APA)

- Intel Corporation. (2025). *Intel® 64 and IA-32 architectures software developer's manual* (Vols. 1–4). https://www.intel.com/sdm
- NASM Development Team. (2024). *NASM — The Netwide Assembler documentation*. https://nasm.us/docs.php
- Brey, B. B. (2006). *Los microprocesadores Intel* (7.ª ed.). Pearson Prentice Hall.
- Tanenbaum, A. S. (2000). *Organización de computadoras: Un enfoque estructurado* (4.ª ed.). Prentice Hall.
