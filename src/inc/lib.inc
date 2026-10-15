; =============================================================================
; lib.inc — Declaraciones externas de la librería de LowMonitor
; -----------------------------------------------------------------------------
; Cualquier archivo que use las rutinas de salida o utilidades incluye este
; archivo. Los archivos que las implementan definen IO_IMPL / UTIL_IMPL antes
; de incluirlo para no declarar como externos sus propios símbolos.
;
; Convención de llamada: System V AMD64 (argumentos rdi, rsi, rdx, rcx, r8,
; r9; retorno en rax; se preservan rbx, rbp, r12-r15).
; =============================================================================

%ifndef LIB_INC
%define LIB_INC

%include "macros.inc"

%ifndef IO_IMPL
    ; ---- src/lib/io.asm: salida con buffer -----------------------------------
    extern out_str                      ; (rdi=ptr, rsi=len)
    extern out_cstr                     ; (rdi=ptr a cadena terminada en 0)
    extern out_char                     ; (dil=byte)
    extern out_nl                       ; ()
    extern out_spaces                   ; (rdi=n)
    extern out_u64                      ; (rdi=valor sin signo)
    extern out_i64                      ; (rdi=valor con signo)
    extern out_hex                      ; (rdi=valor, rsi=dígitos mínimos)
    extern out_fixed                    ; (rdi=valor escalado, rsi=decimales)
    extern out_size                     ; (rdi=bytes)
    extern out_bool                     ; (rdi=0 -> "No", otro -> "Sí")
    extern out_flush                    ; () vacía el buffer en stdout
    extern out_errno                    ; (rdi=-errno) nombre del error
    extern out_contador                 ; () -> rax = bytes emitidos
    extern out_pad_hasta                ; (rdi=inicio, rsi=ancho) rellena
%endif

%ifndef UTIL_IMPL
    ; ---- src/lib/util.asm: utilidades ------------------------------------------
    extern util_init                    ; () detecta RDTSCP; llamar al inicio
    extern str_eq                       ; (rdi, rsi) -> rax=1 si iguales
    extern err_write                    ; (rdi=ptr, rsi=len) directo a stderr
    extern err_cstr                     ; (rdi=cadena C) directo a stderr
    extern fatal                        ; (rdi=cadena C, rsi=código) no retorna
    extern sys_exit                     ; (rdi=código) vacía buffer y termina
    extern tsc_begin                    ; () -> rax=TSC (serializado antes)
    extern tsc_end                      ; () -> rax=TSC (serializado después)
    extern mono_ns                      ; () -> rax=ns de CLOCK_MONOTONIC
    extern sleep_ms                     ; (rdi=milisegundos)
    extern mul_div                      ; (rdi=a, rsi=b, rdx=c) -> rax=a*b/c
%endif

%endif ; LIB_INC
