# Registro de decisiones técnicas (ADR)

Cada decisión que afecta la arquitectura o se aparta de lo literal del enunciado se registra
aquí. Este registro alimenta la sección "decisiones técnicas" del reporte (objetivo 5 del proyecto).

---

## ADR-001 — Proyecto multiarchivo enlazado con `ld`

- **Fecha:** 29/09/2026 · **Estado:** Aceptada
- **Contexto:** El enunciado pide "archivo .asm" y una estructura `.data/.bss/.text`. Seis módulos
  más la librería de salida en un solo archivo superarían las 3000 líneas.
- **Decisión:** Un `.asm` por módulo (`src/mod/`) y por librería (`src/lib/`), cada uno con la
  estructura exigida, ensamblados por separado y enlazados con GNU `ld`. Los símbolos compartidos
  se declaran con `global`/`extern`.
- **Consecuencias:** Compilación incremental, trabajo por módulo aislado, demuestra enlace de objetos.
  Si se exige un único archivo, `main.asm` puede `%include` los demás (cambio mecánico).

## ADR-002 — Sin libc: sólo syscalls

- **Fecha:** 29/09/2026 · **Estado:** Aceptada
- **Contexto:** El criterio "Uso de x86-64 nativo" premia `SYSCALL` y registros de 64 bits.
- **Decisión:** No se enlaza libc. Salida, memoria, señales y tiempo se hacen con `syscall`.
  Se escribe una librería propia de formato (`src/lib/io.asm`).
- **Consecuencias:** Binario estático pequeño, sin intérprete dinámico. Más código propio (formato
  de números en punto fijo en vez de `printf`).

## ADR-003 — Convención System V AMD64 para funciones internas

- **Fecha:** 29/09/2026 · **Estado:** Aceptada
- **Decisión:** Argumentos en `rdi, rsi, rdx, rcx, r8, r9`; retorno en `rax`; preservar `rbx, rbp, r12–r15`.
- **Consecuencias:** Convención conocida y documentable; compatible con gdb. `cpuid` obliga a
  guardar `rbx` en cada función que lo usa.

## ADR-004 — Puertos E/S sin privilegios: intentar, capturar `#GP`, informar

- **Fecha:** 29/09/2026 · **Estado:** Aceptada
- **Contexto:** El enunciado exige correr como usuario regular y a la vez ejecutar `IN/OUT`.
  En Linux, `IN/OUT` en ring 3 requieren `ioperm/iopl`, que necesitan `CAP_SYS_RAWIO`.
- **Decisión:** M2 intenta `ioperm`; si se niega, instala un handler de `SIGSEGV` (vía
  `rt_sigaction` con restorer propio), ejecuta el `IN` igualmente, captura la excepción,
  redirige `RIP` en el `ucontext` y reporta `[PROTEGIDO]`. Con `sudo` se hacen las pruebas reales.
- **Consecuencias:** Cumple "usuario regular" y demuestra el mecanismo de protección de E/S del
  modo protegido (IOPL + bitmap de permisos del TSS). Se explica en el reporte.

## ADR-005 — Validación: CI en Ubuntu x86-64 + Windows/WSL2

- **Fecha:** 29/09/2026 · **Estado:** Aceptada
- **Contexto:** El desarrollo se hace en macOS arm64, que no puede ejecutar ELF x86-64.
- **Decisión:** GitHub Actions (`ubuntu-24.04`, x86-64) compila y ejecuta `make test` en cada
  push. Las mediciones reales para el reporte se toman en la máquina Windows con WSL2
  (`make evidencia`).
- **Consecuencias:** Ubuntu 26.04 no existe como runner: CI usa 24.04. Los tests de rendimiento
  son tolerantes (runner compartido y virtualizado).

## ADR-006 — Métricas en punto fijo entero

- **Fecha:** 29/09/2026 · **Estado:** Aceptada
- **Decisión:** CPI, IPC, GHz, GFLOPS se calculan como enteros escalados (×100 / ×1000) con
  `mul`/`div` de 128 bits (`mul_div`) y se imprimen con `out_fixed`. No se implementa impresión
  de coma flotante.
- **Consecuencias:** Formato exacto y determinista; se evita convertir IEEE-754 a texto.
