; =============================================================================
; perf.asm — M4: Monitor de rendimiento del CPU
; -----------------------------------------------------------------------------
; Proyecto : LowMonitor
; Exporta  : mod_perf_run   frecuencia, ciclos, CPI, IPC y GFLOPS
;            perf_calibrar  calibra tsc_hz (idempotente)
;            tsc_hz         frecuencia del TSC en Hz (qword, 0 hasta calibrar)
;
; Métricas:
;   ciclos  = diferencia del Time Stamp Counter, medida con serialización
;             (tsc_begin/tsc_end), mínimo de 5 repeticiones, menos el costo
;             de la propia medición.
;   CPI     = ciclos / instrucciones      IPC = instrucciones / ciclos
;   Las instrucciones se conocen por construcción: cada carga es un bucle
;   con un número fijo de instrucciones por vuelta.
;
; Advertencia (se explica en el reporte): el TSC avanza a la frecuencia
; NOMINAL constante, no a la del núcleo. Con turbo el núcleo ejecuta más
; ciclos reales que los que cuenta el TSC, y el CPI "TSC" sale menor que el
; real. Por eso los valores se marcan "(estimado con TSC)" y, si el kernel lo
; permite, se contrastan con los contadores de hardware (PMU) que cuentan
; ciclos reales e instrucciones retiradas (perf_event_open).
;
; Cargas:
;   dependiente   8 x `add rax, 1` encadenados: cada suma espera a la
;                 anterior (latencia 1) -> IPC cercano a 1.
;   independiente 8 sumas sobre 8 registros distintos: el núcleo fuera de
;                 orden las reparte entre sus ALUs -> IPC > 1 (ILP).
;   FP (SSE2)     4 mulsd + 4 addsd sobre 8 acumuladores: 8 FLOP por vuelta.
;
; Referencias: Intel SDM Vol. 2B (RDTSC, RDTSCP, LFENCE); man 2
;              perf_event_open, sched_setaffinity; Intel, "How to Benchmark
;              Code Execution Times..." (2010).
; =============================================================================

default rel

%include "lib.inc"

ITER                equ 10000000      ; vueltas de cada carga
INSTR_POR_VUELTA    equ 10            ; 8 operaciones + dec + jnz
FLOP_POR_VUELTA     equ 8             ; 4 mulsd + 4 addsd
REPETICIONES        equ 5             ; se toma la medición mínima
MUESTRAS_OVERHEAD   equ 1000
CALIBRACIONES       equ 3             ; se toma la mediana
CALIBRACION_MS      equ 100
NS_POR_SEG          equ 1000000000
MASCARA_BYTES       equ 128           ; hasta 1024 CPUs

; =============================================================================
section .data
; Constantes, strings, tablas de datos
; =============================================================================
STR l_frecuencia, "Frecuencia (TSC):     "
STR l_cpu,        "CPU fijada:           "
STR l_overhead,   "Costo de medición:    "
STR l_dep,        "Carga dependiente:    "
STR l_ind,        "Carga independiente:  "
STR l_fp,         "Carga FP (SSE2):      "
STR l_cpi,        "CPI promedio:         "
STR l_ipc,        "IPC:                  "
STR l_throughput, "Throughput:           "
STR l_pmu,        "Contadores PMU:       "
STR l_total,      "Ciclos totales:       "

STR t_ghz,        " GHz"
STR t_sched,      " (sched_setaffinity)"
STR t_no_fijada,  "no (sched_setaffinity falló)"
STR t_ciclos,     " ciclos"
STR t_instr,      " instr, "
STR t_ciclos_c,   " ciclos, CPI "
STR t_ipc_c,      ", IPC "
STR t_flop_c,     ", "
STR t_flop,       " FLOP"
STR t_estimado,   " (estimado con TSC)"
STR t_gflops,     " GFLOPS (SSE2 escalar)"
STR t_pmu_cpi,    "CPI "
STR t_pmu_reales, " (ciclos reales del núcleo)"
STR t_no_disp,    "no disponibles ("
STR t_cierra,     ")"
STR t_cero,       "contadores en 0"

align 8
uno_d           dq 1.0                  ; multiplicador neutro: el valor no crece
medio_d         dq 0.5                  ; sumando: crece despacio, sin desbordes

; =============================================================================
section .bss align=8
; Variables reservadas (buffers, contadores)
; =============================================================================
tsc_hz          resq 1                  ; frecuencia del TSC (Hz)
overhead        resq 1                  ; ciclos que cuesta medir "nada"
muestras_hz     resq CALIBRACIONES
ciclos_dep      resq 1
ciclos_ind      resq 1
ciclos_fp       resq 1
pmu_fd_ciclos   resq 1
pmu_fd_instr    resq 1
pmu_ciclos      resq 1
pmu_instr       resq 1
afinidad_bytes  resq 1                  ; 0 = no se pudo leer la máscara original
mascara_orig    resb MASCARA_BYTES
mascara_una     resb MASCARA_BYTES
attr            resb PERF_ATTR_TAM      ; struct perf_event_attr

; =============================================================================
section .text
; =============================================================================
global mod_perf_run, perf_calibrar, tsc_hz

; -----------------------------------------------------------------------------
; Cargas de trabajo. Sólo usan registros caller-saved (no necesitan guardar
; nada). Alineadas a 64 bytes para que el bucle no cruce líneas de caché de
; instrucciones de forma distinta entre ejecuciones.
; -----------------------------------------------------------------------------
align 64
carga_dependiente:
    mov     rcx, ITER
    xor     rax, rax
.vuelta:
    add     rax, 1                      ; cada add depende del resultado anterior:
    add     rax, 1                      ; la cadena se ejecuta en serie
    add     rax, 1
    add     rax, 1
    add     rax, 1
    add     rax, 1
    add     rax, 1
    add     rax, 1
    dec     rcx
    jnz     .vuelta
    ret

align 64
carga_independiente:
    mov     rcx, ITER
.vuelta:
    add     rax, 1                      ; 8 registros distintos: no hay dependencias
    add     rdx, 1                      ; entre estas sumas, el planificador puede
    add     rsi, 1                      ; emitir varias por ciclo en paralelo
    add     rdi, 1
    add     r8, 1
    add     r9, 1
    add     r10, 1
    add     r11, 1
    dec     rcx
    jnz     .vuelta
    ret

align 64
carga_fp:
    movsd   xmm8, [uno_d]               ; xmm8 = 1.0 (multiplicador)
    movsd   xmm9, [medio_d]             ; xmm9 = 0.5 (sumando)
    movapd  xmm0, xmm8                  ; acumuladores de producto = 1.0
    movapd  xmm1, xmm8
    movapd  xmm2, xmm8
    movapd  xmm3, xmm8
    xorpd   xmm4, xmm4                  ; acumuladores de suma = 0.0
    xorpd   xmm5, xmm5
    xorpd   xmm6, xmm6
    xorpd   xmm7, xmm7
    mov     rcx, ITER
.vuelta:
    mulsd   xmm0, xmm8                  ; 8 cadenas independientes de punto
    mulsd   xmm1, xmm8                  ; flotante doble precisión: el límite
    mulsd   xmm2, xmm8                  ; es la latencia de cada cadena, no
    mulsd   xmm3, xmm8                  ; una única dependencia
    addsd   xmm4, xmm9
    addsd   xmm5, xmm9
    addsd   xmm6, xmm9
    addsd   xmm7, xmm9
    dec     rcx
    jnz     .vuelta
    ret

; -----------------------------------------------------------------------------
; medir_overhead — ciclos que cuesta tsc_begin + tsc_end sin trabajo en medio
; Salidas  : [overhead] = mínimo de MUESTRAS_OVERHEAD mediciones
; -----------------------------------------------------------------------------
medir_overhead:
    push    rbx
    push    r12
    push    r13
    mov     r12, -1                     ; mínimo
    mov     r13, MUESTRAS_OVERHEAD
.muestra:
    call    tsc_begin
    mov     rbx, rax
    call    tsc_end
    sub     rax, rbx
    cmp     rax, r12
    cmovb   r12, rax                    ; quedarse con el menor
    dec     r13
    jnz     .muestra
    mov     [overhead], r12
    pop     r13
    pop     r12
    pop     rbx
    ret

; -----------------------------------------------------------------------------
; medir — ciclos TSC de una carga
; Entradas : rdi = dirección de la función de carga
; Salidas  : rax = mínimo de REPETICIONES mediciones menos el overhead
; Notas    : el mínimo descarta interrupciones y cambios de contexto del SO.
; -----------------------------------------------------------------------------
medir:
    push    rbx                         ; rbx = TSC inicial
    push    r12                         ; r12 = función
    push    r13                         ; r13 = mínimo
    push    r14                         ; r14 = repeticiones restantes
    push    r15                         ; (alineación: 5 pushes)
    mov     r12, rdi
    mov     r13, -1
    mov     r14, REPETICIONES
.repetir:
    call    tsc_begin
    mov     rbx, rax
    call    r12                         ; ejecutar la carga
    call    tsc_end
    sub     rax, rbx
    cmp     rax, r13
    cmovb   r13, rax
    dec     r14
    jnz     .repetir
    mov     rax, r13
    sub     rax, [overhead]
    jae     .fin
    xor     rax, rax                    ; no puede ser negativo
.fin:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; -----------------------------------------------------------------------------
; perf_calibrar — mide la frecuencia del TSC contra el reloj del sistema
; Salidas  : [tsc_hz]. Si ya estaba calibrado retorna de inmediato.
; Método   : ciclos TSC durante una espera de 100 ms, divididos por los
;            nanosegundos reales transcurridos (CLOCK_MONOTONIC):
;            Hz = ciclos * 10^9 / ns. Mediana de 3 calibraciones.
; -----------------------------------------------------------------------------
perf_calibrar:
    cmp     qword [tsc_hz], 0
    jne     .ya
    push    rbx                         ; rbx = índice de muestra
    push    r12                         ; r12 = ns inicial
    push    r13                         ; r13 = TSC inicial
    push    r14
    push    r15
    xor     rbx, rbx
.muestra:
    call    mono_ns
    mov     r12, rax
    call    tsc_begin
    mov     r13, rax
    mov     rdi, CALIBRACION_MS
    call    sleep_ms
    call    tsc_end
    mov     r14, rax
    call    mono_ns
    sub     rax, r12                    ; ns transcurridos
    mov     rdx, rax                    ; c = ns
    mov     rdi, r14
    sub     rdi, r13                    ; a = ciclos
    mov     rsi, NS_POR_SEG             ; b = 10^9
    call    mul_div                     ; Hz
    lea     rcx, [muestras_hz]
    mov     [rcx + rbx*8], rax
    inc     rbx
    cmp     rbx, CALIBRACIONES
    jb      .muestra
    ; mediana de 3: max(min(a,b), min(max(a,b), c))
    mov     rax, [muestras_hz]
    mov     rdx, [muestras_hz + 8]
    mov     rcx, rax
    cmp     rcx, rdx
    cmova   rcx, rdx                    ; rcx = min(a,b)
    cmp     rax, rdx
    cmovb   rax, rdx                    ; rax = max(a,b)
    mov     rdx, [muestras_hz + 16]
    cmp     rax, rdx
    cmova   rax, rdx                    ; rax = min(max(a,b), c)
    cmp     rax, rcx
    cmovb   rax, rcx                    ; rax = max(rcx, rax)
    mov     [tsc_hz], rax
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
.ya:
    ret

; -----------------------------------------------------------------------------
; fijar_cpu — fija el proceso a la primera CPU permitida
; Salidas  : rax = número de CPU, o -1 si no se pudo
; Notas    : guarda la máscara original para restaurar_cpu.
; -----------------------------------------------------------------------------
fijar_cpu:
    mov     qword [afinidad_bytes], 0
    mov     rax, SYS_SCHED_GETAFFINITY
    xor     rdi, rdi
    mov     rsi, MASCARA_BYTES
    lea     rdx, [mascara_orig]
    syscall
    CHECK_SYSCALL .error
    mov     [afinidad_bytes], rax       ; bytes válidos de la máscara
    lea     rsi, [mascara_orig]
    xor     rcx, rcx                    ; rcx = desplazamiento en bytes
.buscar:
    cmp     rcx, rax
    jae     .error
    mov     rdx, [rsi + rcx]
    test    rdx, rdx
    jnz     .encontrada
    add     rcx, 8
    jmp     .buscar
.encontrada:
    bsf     rdx, rdx                    ; índice del primer bit en 1
    shl     rcx, 3                      ; bytes -> bits
    add     rcx, rdx                    ; número de CPU
    mov     rdi, rcx
    push    rdi                         ; guardar el número (alinea la pila)
    lea     rax, [mascara_una]
    bts     qword [rax], rdi            ; máscara con un único bit (cadena de bits)
    mov     rax, SYS_SCHED_SETAFFINITY
    xor     rdi, rdi
    mov     rsi, MASCARA_BYTES
    lea     rdx, [mascara_una]
    syscall
    pop     rdi
    lea     rdx, [mascara_una]
    btr     qword [rdx], rdi            ; dejar la máscara limpia
    CHECK_SYSCALL .error
    mov     rax, rdi
    ret
.error:
    mov     rax, -1
    ret

; -----------------------------------------------------------------------------
; restaurar_cpu — vuelve a la máscara de afinidad original
; -----------------------------------------------------------------------------
restaurar_cpu:
    mov     rsi, [afinidad_bytes]
    test    rsi, rsi
    jz      .fin
    mov     rax, SYS_SCHED_SETAFFINITY
    xor     rdi, rdi
    lea     rdx, [mascara_orig]
    syscall
.fin:
    ret

; -----------------------------------------------------------------------------
; pmu_abrir — abre un contador de hardware para este proceso (modo usuario)
; Entradas : rdi = PERF_COUNT_HW_* (qué contar)
; Salidas  : rax = descriptor, o -errno
; -----------------------------------------------------------------------------
pmu_abrir:
    mov     r8, rdi                     ; guardar el evento (rep stosb usa rdi)
    lea     rdi, [attr]
    xor     rax, rax
    mov     rcx, PERF_ATTR_TAM
    rep     stosb                       ; struct perf_event_attr en ceros
    mov     dword [attr], PERF_TYPE_HARDWARE        ; type
    mov     dword [attr + 4], PERF_ATTR_TAM         ; size
    mov     [attr + 8], r8                          ; config
    mov     qword [attr + PERF_ATTR_FLAGS], PERF_FLAG_DISABLED | PERF_FLAG_EXCL_KERNEL | PERF_FLAG_EXCL_HV
    mov     rax, SYS_PERF_EVENT_OPEN
    lea     rdi, [attr]
    xor     rsi, rsi                    ; pid 0 = este proceso
    mov     rdx, -1                     ; en cualquier CPU
    mov     r10, -1                     ; sin grupo
    xor     r8, r8                      ; sin flags
    syscall
    ret

; -----------------------------------------------------------------------------
; pmu_ioctl — rdi = descriptor, rsi = petición PERF_EVENT_IOC_*
; -----------------------------------------------------------------------------
pmu_ioctl:
    mov     rax, SYS_IOCTL
    xor     rdx, rdx
    syscall
    ret

; -----------------------------------------------------------------------------
; pmu_leer — rdi = descriptor, rsi = destino (qword). rax = bytes leídos
; -----------------------------------------------------------------------------
pmu_leer:
    mov     rax, SYS_READ
    mov     rdx, 8
    syscall
    ret

; -----------------------------------------------------------------------------
; cerrar — rdi = descriptor
; -----------------------------------------------------------------------------
cerrar:
    mov     rax, SYS_CLOSE
    syscall
    ret

; -----------------------------------------------------------------------------
; medir_pmu — ejecuta las tres cargas contando ciclos e instrucciones reales
; Salidas  : rax = 0 si se obtuvieron contadores (en pmu_ciclos/pmu_instr),
;            -errno si no se pudo abrir, 1 si los contadores quedaron en 0
; -----------------------------------------------------------------------------
medir_pmu:
    push    rbx                         ; rbx = resultado
    mov     rdi, PERF_COUNT_HW_CPU_CYCLES
    call    pmu_abrir
    mov     rbx, rax
    CHECK_SYSCALL .fin
    mov     [pmu_fd_ciclos], rax
    mov     rdi, PERF_COUNT_HW_INSTRUCTIONS
    call    pmu_abrir
    mov     rbx, rax
    CHECK_SYSCALL .cerrar_ciclos
    mov     [pmu_fd_instr], rax

    mov     rdi, [pmu_fd_ciclos]
    mov     rsi, PERF_EVENT_IOC_RESET
    call    pmu_ioctl
    mov     rdi, [pmu_fd_instr]
    mov     rsi, PERF_EVENT_IOC_RESET
    call    pmu_ioctl
    mov     rdi, [pmu_fd_ciclos]
    mov     rsi, PERF_EVENT_IOC_ENABLE
    call    pmu_ioctl
    mov     rdi, [pmu_fd_instr]
    mov     rsi, PERF_EVENT_IOC_ENABLE
    call    pmu_ioctl
    call    carga_dependiente
    call    carga_independiente
    call    carga_fp
    mov     rdi, [pmu_fd_ciclos]
    mov     rsi, PERF_EVENT_IOC_DISABLE
    call    pmu_ioctl
    mov     rdi, [pmu_fd_instr]
    mov     rsi, PERF_EVENT_IOC_DISABLE
    call    pmu_ioctl

    mov     qword [pmu_ciclos], 0
    mov     qword [pmu_instr], 0
    mov     rdi, [pmu_fd_ciclos]
    lea     rsi, [pmu_ciclos]
    call    pmu_leer
    mov     rdi, [pmu_fd_instr]
    lea     rsi, [pmu_instr]
    call    pmu_leer
    xor     rbx, rbx                    ; éxito...
    cmp     qword [pmu_ciclos], 0
    je      .en_cero
    cmp     qword [pmu_instr], 0
    jne     .cerrar_instr
.en_cero:
    mov     rbx, 1                      ; ...salvo contadores sin datos
.cerrar_instr:
    mov     rdi, [pmu_fd_instr]
    call    cerrar
.cerrar_ciclos:
    mov     rdi, [pmu_fd_ciclos]
    call    cerrar
.fin:
    mov     rax, rbx
    pop     rbx
    ret

; -----------------------------------------------------------------------------
; out_cpi_ipc — imprime "CPI x.xx, IPC y.yy"-style a partir de ciclos/instr
; Entradas : rdi = ciclos, rsi = instrucciones, rdx = 1 si se imprime "CPI "
;            antes (formato PMU) o 0 (formato carga: el prefijo ya está)
; -----------------------------------------------------------------------------
out_cpi_ipc:
    push    rbx                         ; rbx = ciclos
    push    r12                         ; r12 = instrucciones
    sub     rsp, 8
    mov     rbx, rdi
    mov     r12, rsi
    test    rdx, rdx
    jz      .cpi
    PRINT   t_pmu_cpi
.cpi:
    mov     rdi, rbx
    mov     rsi, 100
    mov     rdx, r12
    call    mul_div                     ; CPI x 100
    mov     rdi, rax
    mov     rsi, 2
    call    out_fixed
    PRINT   t_ipc_c
    mov     rdi, r12
    mov     rsi, 100
    mov     rdx, rbx
    call    mul_div                     ; IPC x 100
    mov     rdi, rax
    mov     rsi, 2
    call    out_fixed
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

; -----------------------------------------------------------------------------
; out_carga — "N instr, M ciclos, CPI x.xx, IPC y.yy"
; Entradas : rdi = ciclos
; -----------------------------------------------------------------------------
out_carga:
    push    rbx
    mov     rbx, rdi
    mov     rdi, ITER * INSTR_POR_VUELTA
    call    out_u64
    PRINT   t_instr
    mov     rdi, rbx
    call    out_u64
    PRINT   t_ciclos_c
    mov     rdi, rbx
    mov     rsi, ITER * INSTR_POR_VUELTA
    xor     rdx, rdx
    call    out_cpi_ipc
    pop     rbx
    ret

; -----------------------------------------------------------------------------
; mod_perf_run — punto de entrada del módulo M4
; Salidas  : rax = 0
; -----------------------------------------------------------------------------
mod_perf_run:
    push    rbx
    push    r12
    push    r13

    ; ---- preparación: CPU fija, frecuencia, costo de medir ---------------------
    call    fijar_cpu
    mov     rbx, rax
    PRINT   l_cpu
    cmp     rbx, -1
    je      .sin_cpu
    mov     rdi, rbx
    call    out_u64
    PRINT   t_sched
    jmp     .cpu_lista
.sin_cpu:
    PRINT   t_no_fijada
.cpu_lista:
    call    out_nl

    call    perf_calibrar
    PRINT   l_frecuencia
    mov     rdi, [tsc_hz]
    mov     rsi, 1
    mov     rdx, 10000000               ; Hz / 10^7 = GHz x 100
    call    mul_div
    mov     rdi, rax
    mov     rsi, 2
    call    out_fixed
    PRINT   t_ghz
    call    out_nl

    call    medir_overhead
    PRINT   l_overhead
    mov     rdi, [overhead]
    call    out_u64
    PRINT   t_ciclos
    call    out_nl

    ; ---- cargas -------------------------------------------------------------------
    lea     rdi, [carga_dependiente]
    call    medir
    mov     [ciclos_dep], rax
    lea     rdi, [carga_independiente]
    call    medir
    mov     [ciclos_ind], rax
    lea     rdi, [carga_fp]
    call    medir
    mov     [ciclos_fp], rax

    PRINT   l_dep
    mov     rdi, [ciclos_dep]
    call    out_carga
    call    out_nl
    PRINT   l_ind
    mov     rdi, [ciclos_ind]
    call    out_carga
    call    out_nl
    PRINT   l_fp
    mov     rdi, [ciclos_fp]
    call    out_carga
    PRINT   t_flop_c
    mov     rdi, ITER * FLOP_POR_VUELTA
    call    out_u64
    PRINT   t_flop
    call    out_nl

    ; ---- métricas globales ----------------------------------------------------------
    mov     r12, [ciclos_dep]
    add     r12, [ciclos_ind]
    add     r12, [ciclos_fp]            ; r12 = Σ ciclos
    mov     r13, 3 * ITER * INSTR_POR_VUELTA    ; r13 = Σ instrucciones

    PRINT   l_cpi
    mov     rdi, r12
    mov     rsi, 100
    mov     rdx, r13
    call    mul_div
    mov     rdi, rax
    mov     rsi, 2
    call    out_fixed
    PRINT   t_estimado
    call    out_nl

    PRINT   l_ipc
    mov     rdi, r13
    mov     rsi, 100
    mov     rdx, r12
    call    mul_div
    mov     rdi, rax
    mov     rsi, 2
    call    out_fixed
    PRINT   t_estimado
    call    out_nl

    ; GFLOPS x 100 = FLOP * tsc_hz / ciclos / 10^7
    PRINT   l_throughput
    mov     rdi, ITER * FLOP_POR_VUELTA
    mov     rsi, [tsc_hz]
    mov     rdx, [ciclos_fp]
    call    mul_div                     ; FLOP por segundo
    xor     rdx, rdx
    mov     rcx, 10000000
    div     rcx
    mov     rdi, rax
    mov     rsi, 2
    call    out_fixed
    PRINT   t_gflops
    call    out_nl

    ; ---- contadores de hardware (si el kernel lo permite) ----------------------
    PRINT   l_pmu
    call    medir_pmu
    test    rax, rax
    jz      .pmu_ok
    mov     rbx, rax
    PRINT   t_no_disp
    cmp     rbx, 1
    je      .pmu_cero
    mov     rdi, rbx
    call    out_errno
    jmp     .pmu_cierre
.pmu_cero:
    PRINT   t_cero
.pmu_cierre:
    PRINT   t_cierra
    jmp     .pmu_fin
.pmu_ok:
    mov     rdi, [pmu_ciclos]
    mov     rsi, [pmu_instr]
    mov     rdx, 1
    call    out_cpi_ipc
    PRINT   t_pmu_reales
.pmu_fin:
    call    out_nl

    PRINT   l_total
    mov     rdi, r12
    call    out_u64
    call    out_nl

    call    restaurar_cpu
    xor     rax, rax
    pop     r13
    pop     r12
    pop     rbx
    ret
