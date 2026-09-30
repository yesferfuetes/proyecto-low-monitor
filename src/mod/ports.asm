; =============================================================================
; ports.asm — M2: Monitor de puertos E/S
; -----------------------------------------------------------------------------
; Proyecto : LowMonitor
; Exporta  : mod_ports_run
; Estado   : provisional — imprime "[pendiente]" hasta que se implemente el
;            módulo, para que "lowmonitor todo" funcione desde ya.
; =============================================================================

default rel

%include "lib.inc"

; =============================================================================
section .data
; Constantes, strings, tablas de datos
; =============================================================================
STR msg_pendiente, "  [pendiente]", 10

; =============================================================================
section .bss
; Variables reservadas (buffers, contadores)
; =============================================================================

; =============================================================================
section .text
; =============================================================================
global mod_ports_run

; -----------------------------------------------------------------------------
; mod_ports_run — ejecuta el módulo M2
; Salidas  : rax = 0 (ok)
; -----------------------------------------------------------------------------
mod_ports_run:
    sub     rsp, 8                      ; alinear la pila a 16 antes de llamar
    PRINT   msg_pendiente
    add     rsp, 8
    xor     rax, rax                    ; sin error
    ret
