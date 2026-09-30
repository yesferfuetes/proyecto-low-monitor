; =============================================================================
; main.asm — Punto de entrada de LowMonitor
; -----------------------------------------------------------------------------
; Proyecto : LowMonitor — Diagnóstico y monitorización de hardware x86-64
; Estado   : esqueleto inicial (la CLI completa se agrega después)
; Plataforma: Linux x86-64, NASM (-f elf64), GNU ld, sin libc
;
; Exporta  : _start
; Flujo    : imprime la línea de identificación con write(2) y termina con
;            exit(0). Si write falla, termina con código 1.
; =============================================================================

default rel                             ; direccionamiento relativo a RIP

%include "syscalls.inc"

; =============================================================================
section .data
; Constantes, strings, tablas de datos
; =============================================================================
banner      db "LowMonitor v0.0.0 - Diagnóstico y monitorización de hardware x86-64", 10
banner_len  equ $ - banner              ; longitud en bytes (UTF-8), calculada por NASM

; =============================================================================
section .bss
; Variables reservadas (buffers, contadores) — vacío por ahora
; =============================================================================

; =============================================================================
section .text
; =============================================================================
global _start

; -----------------------------------------------------------------------------
; _start — punto de entrada principal (el kernel salta aquí tras execve)
; Al entrar: [rsp] = argc, [rsp+8] = argv[0] ... (aún no se usan)
; -----------------------------------------------------------------------------
_start:
    ; write(STDOUT, banner, banner_len)
    mov     rax, SYS_WRITE              ; rax = número de syscall
    mov     rdi, STDOUT                 ; arg1: descriptor de salida estándar
    lea     rsi, [banner]               ; arg2: dirección del texto (relativa a RIP)
    mov     rdx, banner_len             ; arg3: cantidad de bytes
    syscall                             ; entra al kernel; destruye rcx y r11

    ; Verificación de error: rax en [-4095, -1] => -errno
    cmp     rax, -MAX_ERRNO             ; comparación sin signo: errores son >= -4095
    jae     .error_write

    xor     rdi, rdi                    ; código de salida 0
    jmp     salir

.error_write:
    mov     rdi, 1                      ; código de salida 1: no se pudo escribir

; -----------------------------------------------------------------------------
; salir — termina el proceso
; Entrada: rdi = código de salida. No retorna.
; -----------------------------------------------------------------------------
salir:
    mov     rax, SYS_EXIT_GROUP         ; exit_group: termina todos los hilos
    syscall
