; =============================================================================
; util.asm — Utilidades comunes: cadenas, errores, salida, tiempo y aritmética
; -----------------------------------------------------------------------------
; Proyecto : LowMonitor
; Exporta  : util_init, str_eq, err_write, err_cstr, fatal, sys_exit,
;            tsc_begin, tsc_end, mono_ns, sleep_ms, mul_div
;
; Medición de tiempo con el Time Stamp Counter (TSC):
;   rdtsc no es una instrucción serializante: el procesador fuera de orden
;   puede ejecutarla antes de que terminen instrucciones previas o dejar que
;   instrucciones posteriores empiecen antes. Para medir un bloque de código:
;     inicio: lfence ; rdtsc ; lfence   -> nada del bloque empieza antes de leer
;     fin   : rdtscp ; lfence           -> rdtscp espera a que el bloque termine
;   (Intel SDM Vol. 2B, RDTSC/RDTSCP; Intel, "How to Benchmark Code Execution
;   Times on Intel IA-32 and IA-64 Instruction Set Architectures", 2010).
; =============================================================================

default rel

%define UTIL_IMPL                       ; este archivo implementa las utilidades
%include "lib.inc"

NS_POR_SEG          equ 1000000000
NS_POR_MS           equ 1000000

; =============================================================================
section .data
; Constantes, strings, tablas de datos
; =============================================================================
STR msg_prefijo, "lowmonitor: "
STR msg_nl, 10
msg_reloj       db "no se pudo leer CLOCK_MONOTONIC (clock_gettime)", 0

; =============================================================================
section .bss
; Variables reservadas (buffers, contadores)
; =============================================================================
tiene_rdtscp    resb 1                  ; 1 si la CPU implementa RDTSCP (lo fija util_init)

; =============================================================================
section .text
; =============================================================================
global util_init, str_eq, err_write, err_cstr, fatal, sys_exit
global tsc_begin, tsc_end, mono_ns, sleep_ms, mul_div

; -----------------------------------------------------------------------------
; util_init — inicializa las utilidades; llamar una vez al inicio del programa
; Detecta RDTSCP: CPUID.80000001h:EDX[27]. Primero se comprueba con
; CPUID.80000000h que la hoja extendida 80000001h exista.
; Modifica : rax, rcx, rdx (rbx se preserva: cpuid lo sobrescribe)
; -----------------------------------------------------------------------------
util_init:
    push    rbx                         ; cpuid escribe ebx: preservarlo (callee-saved)
    mov     eax, 0x80000000             ; cpuid lee eax (32 bits); escribirlo limpia rax
    xor     ecx, ecx                    ; subhoja 0 (cpuid también lee ecx)
    cpuid                               ; eax = máxima hoja extendida
    cmp     eax, 0x80000001
    jb      .fin                        ; no existe la hoja: sin RDTSCP
    mov     eax, 0x80000001
    xor     ecx, ecx
    cpuid
    bt      edx, 27                     ; CF = bit RDTSCP
    jnc     .fin
    mov     byte [tiene_rdtscp], 1
.fin:
    pop     rbx
    ret

; -----------------------------------------------------------------------------
; str_eq — compara dos cadenas terminadas en 0
; Entradas : rdi, rsi = direcciones de las cadenas
; Salidas  : rax = 1 si son iguales, 0 si no
; -----------------------------------------------------------------------------
str_eq:
.bucle:
    mov     al, [rdi]                   ; comparación byte a byte (8 bits)
    cmp     al, [rsi]
    jne     .distintas
    test    al, al                      ; ambos llegaron al 0 a la vez
    jz      .iguales
    inc     rdi
    inc     rsi
    jmp     .bucle
.iguales:
    mov     rax, 1
    ret
.distintas:
    xor     rax, rax
    ret

; -----------------------------------------------------------------------------
; err_write — escribe bytes directamente en stderr (sin pasar por el buffer)
; Entradas : rdi = dirección, rsi = longitud
; Notas    : reintenta escrituras parciales / EINTR; otros errores se ignoran
;            (si stderr tampoco funciona no hay a dónde informar).
; -----------------------------------------------------------------------------
err_write:
    mov     r8, rdi                     ; r8 = puntero pendiente
    mov     r9, rsi                     ; r9 = bytes pendientes (syscall no toca r8/r9)
.escribir:
    test    r9, r9
    jz      .fin
    mov     rax, SYS_WRITE
    mov     rdi, STDERR
    mov     rsi, r8
    mov     rdx, r9
    syscall
    cmp     rax, -EINTR
    je      .escribir
    CHECK_SYSCALL .fin                  ; error: abandonar en silencio
    test    rax, rax
    jz      .fin
    add     r8, rax
    sub     r9, rax
    jmp     .escribir
.fin:
    ret

; -----------------------------------------------------------------------------
; err_cstr — escribe una cadena terminada en 0 en stderr
; Entradas : rdi = dirección de la cadena
; -----------------------------------------------------------------------------
err_cstr:
    mov     rsi, rdi
.buscar:
    cmp     byte [rsi], 0
    je      .medida
    inc     rsi
    jmp     .buscar
.medida:
    sub     rsi, rdi                    ; longitud
    jmp     err_write

; -----------------------------------------------------------------------------
; fatal — manejador de errores irrecuperables. No retorna.
; Entradas : rdi = mensaje (cadena C), rsi = código de salida
; Efecto   : vacía la salida pendiente, escribe "lowmonitor: <mensaje>\n" en
;            stderr y termina el proceso con el código indicado.
; -----------------------------------------------------------------------------
fatal:
    mov     r12, rdi                    ; no hace falta preservar nada: no retorna
    mov     r13, rsi
    and     rsp, -16                    ; alinear la pila a 16 sin importar el origen
    call    out_flush                   ; lo ya impreso llega antes que el error
    lea     rdi, [msg_prefijo]
    mov     rsi, msg_prefijo_len
    call    err_write
    mov     rdi, r12
    call    err_cstr
    lea     rdi, [msg_nl]
    mov     rsi, msg_nl_len
    call    err_write
    mov     rdi, r13
    mov     rax, SYS_EXIT_GROUP
    syscall

; -----------------------------------------------------------------------------
; sys_exit — termina el programa ordenadamente. No retorna.
; Entradas : rdi = código de salida
; -----------------------------------------------------------------------------
sys_exit:
    push    rdi                         ; guardar el código (y alinear la pila)
    call    out_flush                   ; no perder salida pendiente
    pop     rdi
    mov     rax, SYS_EXIT_GROUP         ; termina todos los hilos del proceso
    syscall

; -----------------------------------------------------------------------------
; tsc_begin — lee el TSC al INICIO de una medición
; Salidas  : rax = TSC de 64 bits
; Secuencia: lfence (espera a que terminen las instrucciones previas)
;            rdtsc  (edx:eax = contador)
;            lfence (impide que el código medido empiece antes de la lectura)
; Modifica : rax, rdx
; -----------------------------------------------------------------------------
tsc_begin:
    lfence
    rdtsc                               ; rdtsc entrega el contador partido en edx:eax
    lfence
    shl     rdx, 32                     ; parte alta a los bits 63..32
    or      rax, rdx                    ; rax = TSC completo de 64 bits
    ret

; -----------------------------------------------------------------------------
; tsc_end — lee el TSC al FINAL de una medición
; Salidas  : rax = TSC de 64 bits
; Secuencia: rdtscp espera a que todas las instrucciones previas se ejecuten
;            antes de leer; el lfence posterior evita que código siguiente se
;            adelante. Sin RDTSCP se usa lfence; rdtsc; lfence.
; Modifica : rax, rcx (rdtscp deja IA32_TSC_AUX en ecx), rdx
; -----------------------------------------------------------------------------
tsc_end:
    cmp     byte [tiene_rdtscp], 0
    je      .sin_rdtscp
    rdtscp                              ; edx:eax = TSC, ecx = TSC_AUX (id de CPU)
    lfence
    shl     rdx, 32
    or      rax, rdx
    ret
.sin_rdtscp:
    lfence
    rdtsc
    lfence
    shl     rdx, 32
    or      rax, rdx
    ret

; -----------------------------------------------------------------------------
; mono_ns — tiempo del reloj monotónico en nanosegundos
; Salidas  : rax = segundos * 10^9 + nanosegundos
; Errores  : si clock_gettime falla -> fatal(EXIT_SISTEMA)
; Notas    : struct timespec { int64 tv_sec; int64 tv_nsec; } en la pila.
; -----------------------------------------------------------------------------
mono_ns:
    sub     rsp, 24                     ; 16 bytes de timespec + 8 de alineación
    mov     rax, SYS_CLOCK_GETTIME
    mov     rdi, CLOCK_MONOTONIC
    mov     rsi, rsp                    ; el kernel escribe el timespec aquí
    syscall
    CHECK_SYSCALL .error
    mov     rax, [rsp]                  ; tv_sec
    imul    rax, rax, NS_POR_SEG        ; a nanosegundos
    add     rax, [rsp + 8]              ; + tv_nsec
    add     rsp, 24
    ret
.error:
    lea     rdi, [msg_reloj]
    mov     rsi, EXIT_SISTEMA
    call    fatal

; -----------------------------------------------------------------------------
; sleep_ms — suspende el proceso
; Entradas : rdi = milisegundos
; Notas    : nanosleep(req, rem) con req y rem en la misma estructura: si una
;            señal lo interrumpe (EINTR), el kernel deja allí lo que falta y
;            se reintenta con ese resto.
; -----------------------------------------------------------------------------
sleep_ms:
    sub     rsp, 24                     ; timespec + alineación
    mov     rax, rdi
    xor     rdx, rdx
    mov     rcx, 1000
    div     rcx                         ; rax = segundos, rdx = milisegundos restantes
    mov     [rsp], rax                  ; tv_sec
    imul    rdx, rdx, NS_POR_MS
    mov     [rsp + 8], rdx              ; tv_nsec
.dormir:
    mov     rax, SYS_NANOSLEEP
    mov     rdi, rsp
    mov     rsi, rsp
    syscall
    cmp     rax, -EINTR
    je      .dormir
    add     rsp, 24
    ret

; -----------------------------------------------------------------------------
; mul_div — calcula floor(a * b / c) sin desbordar
; Entradas : rdi = a, rsi = b, rdx = c
; Salidas  : rax = resultado. c = 0 -> 0; resultado > 2^64-1 -> 2^64-1
; Método   : mul produce el producto completo de 128 bits en rdx:rax y div
;            divide ese valor de 128 bits entre 64 bits. div provoca #DE si el
;            cociente no cabe en 64 bits, lo que ocurre si la parte alta del
;            producto es >= c; se comprueba antes y se satura.
; Uso      : convertir ciclos <-> tiempo y calcular métricas en punto fijo.
; -----------------------------------------------------------------------------
mul_div:
    mov     rcx, rdx                    ; rcx = c (mul va a sobrescribir rdx)
    test    rcx, rcx
    jz      .cero
    mov     rax, rdi
    mul     rsi                         ; rdx:rax = a * b (128 bits sin signo)
    cmp     rdx, rcx
    jae     .saturar                    ; el cociente no cabría en 64 bits
    div     rcx                         ; rax = (rdx:rax) / c
    ret
.saturar:
    mov     rax, -1                     ; 0xFFFFFFFFFFFFFFFF
    ret
.cero:
    xor     rax, rax
    ret
