; =============================================================================
; selftest.asm — Autoverificación de la librería (comando oculto "_selftest")
; -----------------------------------------------------------------------------
; Proyecto : LowMonitor
; Exporta  : selftest_run
; Propósito: imprime casos fijos "clave=valor" que las pruebas automáticas
;            (tests/smoke.sh) comparan con los resultados esperados. Cubre el
;            formato de números, cadenas, aritmética de 128 bits, TSC, reloj,
;            y el vaciado del buffer con más de 4 KiB de salida.
; =============================================================================

default rel

%include "lib.inc"

extern cpu_detect, cpu_features

GRANDE_BYTES        equ 10000         ; supera el buffer de 4 KiB más de 2 veces

; =============================================================================
section .data
; Constantes, strings, tablas de datos
; =============================================================================
STR k_u64_0,      "u64_0="
STR k_u64_max,    "u64_max="
STR k_i64,        "i64="
STR k_hex,        "hex="
STR k_hex_big,    "hex_big="
STR k_fixed,      "fixed="
STR k_fixed2,     "fixed2="
STR k_fixed0,     "fixed0="
STR k_size,       "size="
STR k_size_l2,    "size_l2="
STR k_size_b,     "size_b="
STR k_size_round, "size_round="
STR k_bool,       "bool="
STR k_muldiv,     "muldiv="
STR k_streq,      "streq="
STR k_tsc,        "tsc="
STR k_sleep,      "sleep="
STR k_cpudetect,  "cpudetect="
STR v_ok,         "ok"
STR v_falla,      "FALLA"

s_a             db "cpu", 0
s_b             db "cpv", 0

; =============================================================================
section .bss
; Variables reservadas (buffers, contadores) — no se necesitan
; =============================================================================

; =============================================================================
section .text
; =============================================================================
global selftest_run

; Imprime "ok" o "FALLA" según la condición del último cmp (sin signo, >=).
%macro OK_SI_AE 0
    jae     %%ok
    PRINT   v_falla
    jmp     %%fin
%%ok:
    PRINT   v_ok
%%fin:
    call    out_nl
%endmacro

; -----------------------------------------------------------------------------
; selftest_run — ejecuta los casos de autoverificación
; Salidas  : rax = 0
; -----------------------------------------------------------------------------
selftest_run:
    push    rbx
    push    r12
    push    r13                         ; 3 registros: pila alineada a 16

    ; ---- enteros -------------------------------------------------------------
    PRINT   k_u64_0
    xor     rdi, rdi
    call    out_u64                     ; "0": al menos un dígito
    call    out_nl

    PRINT   k_u64_max
    mov     rdi, -1                     ; 2^64 - 1
    call    out_u64
    call    out_nl

    PRINT   k_i64
    mov     rdi, -42
    call    out_i64
    call    out_nl

    ; ---- hexadecimal ------------------------------------------------------------
    PRINT   k_hex
    mov     rdi, 0x3F8
    mov     rsi, 4                      ; rellenar a 4 dígitos -> 03F8
    call    out_hex
    call    out_nl

    PRINT   k_hex_big
    mov     rdi, 0xDEADBEEF
    mov     rsi, 2                      ; mínimo 2, pero el valor necesita 8
    call    out_hex
    call    out_nl

    ; ---- punto fijo -------------------------------------------------------------
    PRINT   k_fixed
    mov     rdi, 1800
    mov     rsi, 3
    call    out_fixed                   ; 1.800
    call    out_nl

    PRINT   k_fixed2
    mov     rdi, 5
    mov     rsi, 2
    call    out_fixed                   ; 0.05
    call    out_nl

    PRINT   k_fixed0
    mov     rdi, 7
    xor     rsi, rsi
    call    out_fixed                   ; 7
    call    out_nl

    ; ---- tamaños ----------------------------------------------------------------
    PRINT   k_size
    mov     rdi, 34359738368            ; 32 GiB
    call    out_size
    call    out_nl

    PRINT   k_size_l2
    mov     rdi, 1310720                ; 1.25 MiB -> 1280 KB
    call    out_size
    call    out_nl

    PRINT   k_size_b
    mov     rdi, 512
    call    out_size
    call    out_nl

    PRINT   k_size_round
    mov     rdi, 16662888448            ; ~15.5 GiB -> 16 GB
    call    out_size
    call    out_nl

    ; ---- booleanos --------------------------------------------------------------
    PRINT   k_bool
    mov     rdi, 1
    call    out_bool
    mov     rdi, ','
    call    out_char
    xor     rdi, rdi
    call    out_bool
    call    out_nl

    ; ---- aritmética de 128 bits: 10^12 * 10^12 / 10^6 = 10^18 --------------------
    PRINT   k_muldiv
    mov     rdi, 1000000000000
    mov     rsi, 1000000000000          ; el producto (10^24) no cabe en 64 bits
    mov     rdx, 1000000
    call    mul_div
    mov     rdi, rax
    call    out_u64
    call    out_nl

    ; ---- comparación de cadenas ---------------------------------------------------
    PRINT   k_streq
    lea     rdi, [s_a]
    lea     rsi, [s_a]
    call    str_eq
    mov     rdi, rax
    call    out_u64
    mov     rdi, ','
    call    out_char
    lea     rdi, [s_a]
    lea     rsi, [s_b]
    call    str_eq
    mov     rdi, rax
    call    out_u64
    call    out_nl

    ; ---- TSC: el contador avanza -------------------------------------------------
    PRINT   k_tsc
    call    tsc_begin
    mov     rbx, rax
    call    tsc_end
    cmp     rax, rbx                    ; fin > inicio
    seta    r12b                        ; r12b = 1 si avanzó
    movzx   r12, r12b
    cmp     r12, 1
    OK_SI_AE

    ; ---- reloj monotónico + nanosleep: dormir 20 ms mide >= 20 ms ----------------
    PRINT   k_sleep
    call    mono_ns
    mov     rbx, rax
    mov     rdi, 20
    call    sleep_ms
    call    mono_ns
    sub     rax, rbx                    ; ns transcurridos
    cmp     rax, 20000000
    OK_SI_AE

    ; ---- cpu_detect es idempotente: dos llamadas, mismas características -------
    PRINT   k_cpudetect
    call    cpu_detect
    mov     rbx, [cpu_features]
    call    cpu_detect
    mov     rax, [cpu_features]
    xor     rax, rbx                    ; 0 si no cambió
    cmp     rax, 1                      ; sin signo: 0 < 1 -> "FALLA" si no es 0
    setb    r12b
    movzx   r12, r12b
    cmp     r12, 1
    OK_SI_AE

    ; ---- salida grande: 10 000 '#' para probar el vaciado del buffer ------------
    mov     r13, GRANDE_BYTES
.grande:
    mov     rdi, '#'
    call    out_char
    dec     r13
    jnz     .grande
    call    out_nl

    xor     rax, rax
    pop     r13
    pop     r12
    pop     rbx
    ret
