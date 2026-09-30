; =============================================================================
; macros.inc — Macros y constantes comunes de LowMonitor
; -----------------------------------------------------------------------------
; Contenido: sólo macros y constantes; no genera código por sí mismo.
; Incluye  : syscalls.inc (las macros usan sus constantes)
;
; Macros:
;   STR   nombre, "texto"[, bytes...]  cadena en .data + nombre_len
;   PRINT nombre                       envía una cadena STR al buffer de salida
;   CHECK_SYSCALL etiqueta             salta si rax contiene -errno
; =============================================================================

%ifndef MACROS_INC
%define MACROS_INC

%include "syscalls.inc"

; ---- Códigos de salida del programa ------------------------------------------
EXIT_OK             equ 0             ; todo terminó bien
EXIT_USO            equ 1             ; argumentos incorrectos
EXIT_MODULO         equ 2             ; algún módulo de diagnóstico devolvió error
EXIT_SISTEMA        equ 3             ; error de E/S o de una syscall imprescindible

; -----------------------------------------------------------------------------
; STR nombre, "texto"[, bytes...]
; Define la etiqueta `nombre` con los bytes indicados y la constante
; `nombre_len` con su longitud en bytes (no en caracteres: UTF-8 ocupa más).
; Debe usarse dentro de section .data.
;   STR msg_hola, "Hola", 10     ->  msg_hola db "Hola",10 / msg_hola_len equ 5
; -----------------------------------------------------------------------------
%macro STR 2+
%1:         db %2
%{1}_len    equ $ - %1
%endmacro

; -----------------------------------------------------------------------------
; PRINT nombre
; Copia al buffer de salida una cadena definida con STR.
; Destruye los registros caller-saved (llama a out_str).
; -----------------------------------------------------------------------------
%macro PRINT 1
    lea     rdi, [%1]                   ; arg1: dirección de la cadena
    mov     rsi, %{1}_len               ; arg2: longitud en bytes
    call    out_str
%endmacro

; -----------------------------------------------------------------------------
; CHECK_SYSCALL etiqueta
; Tras un `syscall`, el kernel devuelve -errno en rax si falló. Los errores
; son los valores [-4095, -1], que vistos sin signo son los más grandes:
; basta una comparación sin signo contra -4095.
; -----------------------------------------------------------------------------
%macro CHECK_SYSCALL 1
    cmp     rax, -MAX_ERRNO             ; ¿rax >= 0xFFFFFFFFFFFFF001 (sin signo)?
    jae     %1                          ; sí: es -errno -> manejar error
%endmacro

%endif ; MACROS_INC
