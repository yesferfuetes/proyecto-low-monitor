; =============================================================================
; ports.asm — M2: Monitor de puertos de E/S
; -----------------------------------------------------------------------------
; Proyecto : LowMonitor
; Exporta  : mod_ports_run        ejecuta las pruebas de puertos
;            ports_senales_run    (oculto) verifica que se restauran los handlers
;            port_in8/16/32, port_out8/16/32   primitivas de acceso a puertos
;
; Espacio de E/S x86: 65536 puertos de 8 bits (0000h-FFFFh), separado de la
; memoria, accesible con IN/OUT. El puerto va en DX (o como inmediato de 8 bits)
; y el dato en AL/AX/EAX según el ancho (8/16/32 bits).
;
; Protección: en modo protegido un proceso en ring 3 sólo puede ejecutar IN/OUT
; si CPL <= IOPL (campo de RFLAGS) o si el bitmap de permisos de E/S de su TSS
; lo autoriza para ese puerto. Linux concede el bitmap con ioperm() (puertos
; 0-3FFh) y todo el espacio con iopl(3); ambas exigen CAP_SYS_RAWIO (root).
; Sin permiso, IN/OUT generan #GP y el kernel envía SIGSEGV al proceso.
;
; Este módulo instala un manejador de señales propio: si un IN/OUT falla, el
; manejador cambia el RIP guardado en el contexto de la señal para continuar
; en un punto de recuperación, y la prueba se informa como [PROTEGIDO].
; Así el programa funciona como usuario regular y con sudo hace el acceso real.
;
; Referencias: Intel SDM Vol. 1 cap. 19 "Input/Output" (protección de E/S y
; bitmap del TSS); man 2 ioperm, iopl, rt_sigaction; arch/x86/include/uapi/
; asm/sigcontext.h (diseño de ucontext en x86-64).
; =============================================================================

default rel

%include "lib.inc"

; ---- Puertos -----------------------------------------------------------------
P_KBD_DATOS         equ 0x60          ; controlador 8042: datos del teclado
P_KBD_ESTADO        equ 0x64          ; controlador 8042: registro de estado
P_PANEL             equ 0x61          ; System Control Port B (altavoz, NMI, refresco)
P_COM1              equ 0x3F8         ; UART 16550 COM1: base (RBR/THR)
P_COM1_SCRATCH      equ 0x3FF         ; COM1 + 7: registro scratch (libre, sin efectos)
P_PCI_DIR           equ 0xCF8         ; mecanismo PCI #1: dirección de configuración
P_PCI_DATOS         equ 0xCFC         ; mecanismo PCI #1: dato de configuración
PCI_BUS0_DEV0       equ 0x80000000    ; bit 31 = habilitar; bus 0, disp. 0, func. 0, reg. 0

RANGO_IOPERM        equ 8             ; cantidad de puertos por llamada a ioperm
BUS_FLOTANTE8       equ 0xFF          ; lectura sin dispositivo: líneas de datos en alto
MASCARA_61_ESTABLE  equ 0x0F          ; bits 0-3 de 61h: control (4-7 son de estado)

; ---- struct kernel_sigaction (x86-64), 32 bytes ------------------------------
SA_HANDLER          equ 0
SA_FLAGS            equ 8
SA_RESTORER_PTR     equ 16
SA_MASK             equ 24
SA_TAM              equ 32

; =============================================================================
section .data
; Constantes, strings, tablas de datos
; =============================================================================
STR l_ioperm,   "Permiso ioperm:        "
STR l_iopl,     "Permiso iopl(3):       "
STR l_rflags,   "IOPL (RFLAGS[13:12]):  "
STR l_p64,      "Puerto 64h (estado):   "
STR l_p60,      "Puerto 60h (teclado):  "
STR l_p61,      "Puerto 61h (panel):    "
STR l_com1,     "Puerto 3F8h (COM1):    "
STR l_pci,      "Puerto CFCh (PCI 32b): "

STR t_concedido,    "CONCEDIDO"
STR t_denegado,     "DENEGADO ("
STR t_sugerencia,   ") - ejecute con sudo para acceso real"
STR t_sin_soporte,  ") - el kernel no implementa esta llamada (¿emulación?)"
STR t_cierra,       ")"
STR t_flecha,       " -> "
STR t_emulado,      " (Linux emula iopl con el bitmap de E/S del TSS)"
STR t_ok8,          "[OK]  8b  valor="
STR t_ok61,         "h  escritura/lectura consistente"
STR t_ok_com1,      "[OK]  8b  scratch 55h/AAh verificado"
STR t_np_com1,      "[NO PRESENTE] scratch no responde (sin UART)"
STR t_com1_16,      "   16b valor="
STR t_ok_pci,       "[OK]  32b vendor:device="
STR t_np_pci,       "[NO PRESENTE] sin espacio PCI por CF8h/CFCh"
STR t_np,           "[NO PRESENTE] lee FFh (bus flotante)"
STR t_error61,      "[ERROR] 8b  escrito "
STR t_leido,        "h, leído "
STR t_h,            "h"
STR t_dos_puntos,   ":"
STR t_prot,         "[PROTEGIDO] "
STR t_prot_segv,    "#GP capturado (SIGSEGV)"
STR t_prot_bus,     "excepción capturada (SIGBUS)"
STR t_prot_ill,     "instrucción no disponible (SIGILL)"
STR t_prot_otra,    "excepción capturada (señal "
STR k_manejadores,  "manejadores="
STR t_si_ok,        "ok"
STR t_falla,        "FALLA"
msg_sigaction   db "no se pudo instalar el manejador de señales (rt_sigaction)", 0

; Acción "por defecto" usada por el manejador ante una falla no esperada
align 8
sa_defecto:
    dq SIG_DFL, 0, 0, 0

; Señales que se capturan durante las pruebas
senales:
    dq SIGSEGV, SIGBUS, SIGILL
NUM_SENALES         equ 3

; =============================================================================
section .bss align=8
; Variables reservadas (buffers, contadores)
; =============================================================================
port_reanudar   resq 1                  ; dirección de recuperación (0 = ninguna operación en curso)
port_falla      resq 1                  ; 1 si la última operación generó una señal
port_senal      resq 1                  ; número de la señal capturada
perm_ioperm     resq 1                  ; 0 = concedido, si no -errno
perm_iopl       resq 1                  ; 0 = concedido, si no -errno
sa_nueva        resb SA_TAM             ; acción que se instala
sa_viejas       resb SA_TAM * NUM_SENALES   ; acciones anteriores, para restaurarlas
sa_consulta     resb SA_TAM             ; usada por ports_senales_run

; =============================================================================
section .text
; =============================================================================
global mod_ports_run, ports_senales_run
global port_in8, port_in16, port_in32, port_out8, port_out16, port_out32

; -----------------------------------------------------------------------------
; Primitivas de puerto con recuperación
; port_inN  : rdi = puerto (0-FFFFh)              -> rax = dato, rdx = 0 ok / 1 excepción
; port_outN : rdi = puerto, rsi = dato             -> rdx = 0 ok / 1 excepción
; Mecanismo : antes de la instrucción se publica en port_reanudar la etiqueta
;             de recuperación. Si IN/OUT provoca una señal, el manejador escribe
;             esa dirección en el RIP del contexto interrumpido y el kernel
;             (rt_sigreturn) reanuda allí, con port_falla = 1.
; -----------------------------------------------------------------------------
%macro PUERTO_IN 2                      ; nombre, registro destino (al | ax | eax)
%1:
    lea     rax, [%%recuperar]
    mov     [port_reanudar], rax        ; armar el punto de recuperación
    mov     qword [port_falla], 0
    mov     rdx, rdi                    ; IN toma el número de puerto de DX
    xor     rax, rax                    ; limpiar: los anchos 8/16 no tocan la parte alta
    in      %2, dx                      ; lectura del espacio de E/S
%%recuperar:
    mov     qword [port_reanudar], 0    ; desarmar
    mov     rdx, [port_falla]           ; estado de la operación
    ret
%endmacro

%macro PUERTO_OUT 2                     ; nombre, registro fuente (al | ax | eax)
%1:
    lea     rax, [%%recuperar]
    mov     [port_reanudar], rax
    mov     qword [port_falla], 0
    mov     rdx, rdi                    ; puerto en DX
    mov     rax, rsi                    ; dato en AL/AX/EAX
    out     dx, %2                      ; escritura al espacio de E/S
%%recuperar:
    mov     qword [port_reanudar], 0
    mov     rdx, [port_falla]
    ret
%endmacro

PUERTO_IN  port_in8,  al                ; 8 bits
PUERTO_IN  port_in16, ax                ; 16 bits
PUERTO_IN  port_in32, eax               ; 32 bits
PUERTO_OUT port_out8,  al
PUERTO_OUT port_out16, ax
PUERTO_OUT port_out32, eax

; -----------------------------------------------------------------------------
; manejador — handler de SIGSEGV / SIGBUS / SIGILL (convención del kernel)
; Entradas : rdi = número de señal, rsi = siginfo_t*, rdx = ucontext_t*
; Efecto   : si hay una operación de puerto en curso, redirige la ejecución
;            a su punto de recuperación modificando uc_mcontext.rip (offset
;            UC_RIP = 0xA8) y marca la falla.
;            Si no la hay (falla real del programa), restaura la acción por
;            defecto y retorna: la instrucción se reejecuta y el proceso
;            termina con la señal, como sin manejador.
; Notas    : sólo usa operaciones seguras dentro de un handler (memoria y una
;            syscall); no llama a las rutinas de salida con buffer.
; -----------------------------------------------------------------------------
manejador:
    mov     rax, [port_reanudar]
    test    rax, rax
    jz      .no_esperada
    mov     [rdx + UC_RIP], rax         ; continuar en la etiqueta de recuperación
    mov     qword [port_falla], 1
    mov     [port_senal], rdi
    ret                                 ; -> restaurador -> rt_sigreturn
.no_esperada:
    mov     rax, SYS_RT_SIGACTION       ; rdi ya contiene el número de señal
    lea     rsi, [sa_defecto]
    xor     rdx, rdx                    ; no interesa la acción anterior
    mov     r10, SIGSET_SIZE            ; 4.º argumento de syscall va en r10
    syscall
    ret

; -----------------------------------------------------------------------------
; restaurador — trampolín SA_RESTORER: al retornar el handler se llega aquí,
; y rt_sigreturn restaura todos los registros desde el ucontext (con el RIP
; que haya dejado el handler). Nunca retorna.
; -----------------------------------------------------------------------------
restaurador:
    mov     rax, SYS_RT_SIGRETURN
    syscall

; -----------------------------------------------------------------------------
; instalar_manejadores — instala `manejador` para SIGSEGV, SIGBUS y SIGILL,
; guardando las acciones anteriores en sa_viejas
; -----------------------------------------------------------------------------
instalar_manejadores:
    push    rbx                         ; rbx = índice de señal (y alinea la pila)
    lea     rax, [manejador]
    mov     [sa_nueva + SA_HANDLER], rax
    mov     qword [sa_nueva + SA_FLAGS], SA_SIGINFO | SA_RESTORER
    lea     rax, [restaurador]
    mov     [sa_nueva + SA_RESTORER_PTR], rax
    mov     qword [sa_nueva + SA_MASK], 0   ; no bloquear otras señales
    xor     rbx, rbx
.siguiente:
    lea     rax, [senales]
    mov     rdi, [rax + rbx*8]          ; número de señal
    lea     rsi, [sa_nueva]
    mov     rdx, rbx
    shl     rdx, 5                      ; índice * 32 bytes
    lea     rax, [sa_viejas]
    add     rdx, rax                    ; destino de la acción anterior
    mov     r10, SIGSET_SIZE
    mov     rax, SYS_RT_SIGACTION
    syscall
    CHECK_SYSCALL .error
    inc     rbx
    cmp     rbx, NUM_SENALES
    jb      .siguiente
    pop     rbx
    ret
.error:
    lea     rdi, [msg_sigaction]
    mov     rsi, EXIT_SISTEMA
    call    fatal

; -----------------------------------------------------------------------------
; restaurar_manejadores — reinstala las acciones guardadas en sa_viejas
; -----------------------------------------------------------------------------
restaurar_manejadores:
    push    rbx
    xor     rbx, rbx
.siguiente:
    lea     rax, [senales]
    mov     rdi, [rax + rbx*8]
    mov     rsi, rbx
    shl     rsi, 5
    lea     rax, [sa_viejas]
    add     rsi, rax                    ; acción anterior de esta señal
    xor     rdx, rdx
    mov     r10, SIGSET_SIZE
    mov     rax, SYS_RT_SIGACTION
    syscall
    inc     rbx
    cmp     rbx, NUM_SENALES
    jb      .siguiente
    pop     rbx
    ret

; -----------------------------------------------------------------------------
; leer_iopl — devuelve el campo IOPL de RFLAGS (bits 13:12)
; Salidas  : rax = 0..3
; -----------------------------------------------------------------------------
leer_iopl:
    pushfq                              ; RFLAGS a la pila
    pop     rax
    shr     rax, 12
    and     rax, 3
    ret

; -----------------------------------------------------------------------------
; ioperm(rdi=desde, rsi=cantidad, rdx=activar) -> rax = 0 o -errno
; -----------------------------------------------------------------------------
sys_ioperm:
    mov     rax, SYS_IOPERM
    syscall
    ret

; -----------------------------------------------------------------------------
; out_protegido — imprime "[PROTEGIDO] <motivo según la señal>" y salto de línea
; -----------------------------------------------------------------------------
out_protegido:
    sub     rsp, 8                      ; alinear la pila
    PRINT   t_prot
    mov     rax, [port_senal]
    cmp     rax, SIGSEGV
    je      .segv
    cmp     rax, SIGBUS
    je      .bus
    cmp     rax, SIGILL
    je      .ill
    PRINT   t_prot_otra
    mov     rdi, [port_senal]
    call    out_u64
    PRINT   t_cierra
    jmp     .fin
.segv:
    PRINT   t_prot_segv
    jmp     .fin
.bus:
    PRINT   t_prot_bus
    jmp     .fin
.ill:
    PRINT   t_prot_ill
.fin:
    call    out_nl
    add     rsp, 8
    ret

; -----------------------------------------------------------------------------
; out_hex_h — imprime un valor en hexadecimal seguido de "h"
; Entradas : rdi = valor, rsi = dígitos mínimos
; -----------------------------------------------------------------------------
out_hex_h:
    sub     rsp, 8
    call    out_hex
    PRINT   t_h
    add     rsp, 8
    ret

; -----------------------------------------------------------------------------
; prueba_lectura8 — lee un puerto de 8 bits e informa el resultado
; Entradas : rdi = puerto
; Resultado: [OK] con el valor | [NO PRESENTE] si lee FFh | [PROTEGIDO]
; -----------------------------------------------------------------------------
prueba_lectura8:
    push    rbx
    call    port_in8
    test    rdx, rdx
    jnz     .protegido
    mov     rbx, rax
    cmp     rbx, BUS_FLOTANTE8
    je      .no_presente
    PRINT   t_ok8
    mov     rdi, rbx
    mov     rsi, 2
    call    out_hex_h
    call    out_nl
    jmp     .fin
.no_presente:
    PRINT   t_np
    call    out_nl
    jmp     .fin
.protegido:
    call    out_protegido
.fin:
    pop     rbx
    ret

; -----------------------------------------------------------------------------
; prueba_panel — 61h: lectura, escritura del MISMO valor y relectura
; Seguridad: nunca se escribe un valor distinto al leído (los bits 0-1
;            controlan el altavoz). Se comparan sólo los bits de control 0-3.
; -----------------------------------------------------------------------------
prueba_panel:
    push    rbx                         ; rbx = valor original
    push    r12                         ; r12 = relectura
    sub     rsp, 8
    mov     rdi, P_PANEL
    call    port_in8
    test    rdx, rdx
    jnz     .protegido
    mov     rbx, rax
    cmp     rbx, BUS_FLOTANTE8
    je      .no_presente                ; sin dispositivo: no se escribe nada
    mov     rdi, P_PANEL
    mov     rsi, rbx
    call    port_out8                   ; escribir el mismo valor
    test    rdx, rdx
    jnz     .protegido
    mov     rdi, P_PANEL
    call    port_in8
    test    rdx, rdx
    jnz     .protegido
    mov     r12, rax
    mov     rax, rbx
    xor     rax, r12                    ; bits que cambiaron
    test    rax, MASCARA_61_ESTABLE     ; ¿cambió algún bit de control?
    jnz     .inconsistente
    PRINT   t_ok8
    mov     rdi, rbx
    mov     rsi, 2
    call    out_hex
    PRINT   t_ok61
    call    out_nl
    jmp     .fin
.inconsistente:
    PRINT   t_error61
    mov     rdi, rbx
    mov     rsi, 2
    call    out_hex
    PRINT   t_leido
    mov     rdi, r12
    mov     rsi, 2
    call    out_hex_h
    call    out_nl
    jmp     .fin
.no_presente:
    PRINT   t_np
    call    out_nl
    jmp     .fin
.protegido:
    call    out_protegido
.fin:
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

; -----------------------------------------------------------------------------
; prueba_com1 — detecta el UART de COM1 con su registro scratch (3FFh) y hace
; una lectura de 16 bits en 3F8h (RBR + IER)
; Método   : escribir 55h y AAh (patrones complementarios) en scratch y
;            releerlos; si coinciden hay un UART. Se restaura el valor original.
; -----------------------------------------------------------------------------
prueba_com1:
    push    rbx                         ; rbx = valor original del scratch
    push    r12                         ; r12 = 1 si el UART respondió
    push    r13
    mov     rdi, P_COM1_SCRATCH
    call    port_in8
    test    rdx, rdx
    jnz     .protegido
    mov     rbx, rax
    xor     r12, r12
    ; patrón 55h
    mov     rdi, P_COM1_SCRATCH
    mov     rsi, 0x55
    call    port_out8
    test    rdx, rdx
    jnz     .protegido
    mov     rdi, P_COM1_SCRATCH
    call    port_in8
    cmp     rax, 0x55
    jne     .restaurar
    ; patrón AAh
    mov     rdi, P_COM1_SCRATCH
    mov     rsi, 0xAA
    call    port_out8
    mov     rdi, P_COM1_SCRATCH
    call    port_in8
    cmp     rax, 0xAA
    jne     .restaurar
    mov     r12, 1                      ; ambos patrones verificados
.restaurar:
    mov     rdi, P_COM1_SCRATCH
    mov     rsi, rbx
    call    port_out8                   ; dejar el scratch como estaba
    test    r12, r12
    jz      .sin_uart
    PRINT   t_ok_com1
    jmp     .ancho16
.sin_uart:
    PRINT   t_np_com1
.ancho16:
    mov     rdi, P_COM1
    call    port_in16                   ; lectura de 16 bits: RBR (bajo) + IER (alto)
    test    rdx, rdx
    jnz     .fin_linea
    mov     r13, rax
    PRINT   t_com1_16
    mov     rdi, r13
    mov     rsi, 4
    call    out_hex_h
.fin_linea:
    call    out_nl
    jmp     .fin
.protegido:
    call    out_protegido
.fin:
    pop     r13
    pop     r12
    pop     rbx
    ret

; -----------------------------------------------------------------------------
; prueba_pci — acceso de 32 bits: lee vendor/device del dispositivo 0 del
; bus 0 con el mecanismo de configuración PCI #1 (CF8h dirección, CFCh dato)
; Requiere iopl(3): los puertos están por encima de 3FFh.
; -----------------------------------------------------------------------------
prueba_pci:
    push    rbx                         ; rbx = valor original de CF8h
    push    r12                         ; r12 = identificador leído
    sub     rsp, 8
    mov     rdi, P_PCI_DIR
    call    port_in32
    test    rdx, rdx
    jnz     .protegido
    mov     rbx, rax
    mov     rdi, P_PCI_DIR
    mov     rsi, PCI_BUS0_DEV0
    call    port_out32                  ; seleccionar bus 0, disp. 0, registro 0
    test    rdx, rdx
    jnz     .protegido
    mov     rdi, P_PCI_DATOS
    call    port_in32                   ; [15:0] vendor ID, [31:16] device ID
    mov     r12, rax
    mov     rdi, P_PCI_DIR
    mov     rsi, rbx
    call    port_out32                  ; restaurar la dirección de configuración
    mov     rax, r12
    and     rax, 0xFFFF
    cmp     rax, 0xFFFF                 ; vendor FFFFh = no hay dispositivo
    je      .no_presente
    PRINT   t_ok_pci
    mov     rdi, r12
    and     rdi, 0xFFFF
    mov     rsi, 4
    call    out_hex                     ; vendor
    PRINT   t_dos_puntos
    mov     rdi, r12
    shr     rdi, 16
    mov     rsi, 4
    call    out_hex                     ; device
    call    out_nl
    jmp     .fin
.no_presente:
    PRINT   t_np_pci
    call    out_nl
    jmp     .fin
.protegido:
    call    out_protegido
.fin:
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

; -----------------------------------------------------------------------------
; mod_ports_run — punto de entrada del módulo M2
; Salidas  : rax = 0 (la falta de permisos no es un error del módulo)
; -----------------------------------------------------------------------------
mod_ports_run:
    push    rbx                         ; rbx = IOPL antes de iopl(3)
    push    r12
    push    r13
    call    instalar_manejadores

    ; ---- Permisos: ioperm para 60h-67h y 3F8h-3FFh ----------------------------
    mov     rdi, P_KBD_DATOS
    mov     rsi, RANGO_IOPERM
    mov     rdx, 1
    call    sys_ioperm
    test    rax, rax
    jnz     .ioperm_listo
    mov     rdi, P_COM1
    mov     rsi, RANGO_IOPERM
    mov     rdx, 1
    call    sys_ioperm
.ioperm_listo:
    mov     [perm_ioperm], rax
    PRINT   l_ioperm
    mov     rax, [perm_ioperm]
    test    rax, rax
    jnz     .ioperm_denegado
    PRINT   t_concedido
    jmp     .ioperm_fin
.ioperm_denegado:
    PRINT   t_denegado
    mov     rdi, [perm_ioperm]
    call    out_errno
    cmp     qword [perm_ioperm], -ENOSYS
    je      .ioperm_enosys
    PRINT   t_sugerencia                ; EPERM: falta CAP_SYS_RAWIO -> sudo
    jmp     .ioperm_fin
.ioperm_enosys:
    PRINT   t_sin_soporte               ; ENOSYS: sudo no ayudaría
.ioperm_fin:
    call    out_nl

    ; ---- Permisos: iopl(3) para todo el espacio --------------------------------
    call    leer_iopl
    mov     rbx, rax                    ; IOPL antes
    mov     rax, SYS_IOPL
    mov     rdi, 3
    syscall
    mov     [perm_iopl], rax
    PRINT   l_iopl
    mov     rax, [perm_iopl]
    test    rax, rax
    jnz     .iopl_denegado
    PRINT   t_concedido
    jmp     .iopl_fin
.iopl_denegado:
    PRINT   t_denegado
    mov     rdi, [perm_iopl]
    call    out_errno
    PRINT   t_cierra
.iopl_fin:
    call    out_nl

    ; ---- Flags: campo IOPL de RFLAGS antes y después ---------------------------
    PRINT   l_rflags
    mov     rdi, rbx
    call    out_u64
    cmp     qword [perm_iopl], 0
    jne     .rflags_fin                 ; iopl falló: sólo el valor actual
    PRINT   t_flecha
    call    leer_iopl
    mov     r12, rax
    mov     rdi, r12
    call    out_u64
    cmp     r12, 3
    je      .rflags_fin
    PRINT   t_emulado                   ; concedido pero IOPL sigue en 0
.rflags_fin:
    call    out_nl

    ; ---- Pruebas ----------------------------------------------------------------
    PRINT   l_p64
    mov     rdi, P_KBD_ESTADO
    call    prueba_lectura8
    PRINT   l_p60
    mov     rdi, P_KBD_DATOS
    call    prueba_lectura8
    PRINT   l_p61
    call    prueba_panel
    PRINT   l_com1
    call    prueba_com1
    PRINT   l_pci
    call    prueba_pci

    ; ---- Limpieza: devolver permisos y manejadores ------------------------------
    cmp     qword [perm_ioperm], 0
    jne     .sin_ioperm
    mov     rdi, P_KBD_DATOS
    mov     rsi, RANGO_IOPERM
    xor     rdx, rdx                    ; 0 = revocar
    call    sys_ioperm
    mov     rdi, P_COM1
    mov     rsi, RANGO_IOPERM
    xor     rdx, rdx
    call    sys_ioperm
.sin_ioperm:
    cmp     qword [perm_iopl], 0
    jne     .sin_iopl
    mov     rax, SYS_IOPL
    xor     rdi, rdi                    ; volver a IOPL 0
    syscall
.sin_iopl:
    call    restaurar_manejadores
    xor     rax, rax
    pop     r13
    pop     r12
    pop     rbx
    ret

; -----------------------------------------------------------------------------
; ports_senales_run — (comando oculto) ejecuta el módulo y comprueba que los
; manejadores de SIGSEGV/SIGBUS/SIGILL quedaron como estaban (SIG_DFL)
; Salidas  : rax = 0; imprime "manejadores=ok" o "manejadores=FALLA"
; -----------------------------------------------------------------------------
ports_senales_run:
    push    rbx                         ; rbx = índice de señal
    push    r12                         ; r12 = 1 si alguna no está restaurada
    push    r13
    call    mod_ports_run
    xor     rbx, rbx
    xor     r12, r12
.siguiente:
    lea     rax, [senales]
    mov     rdi, [rax + rbx*8]
    xor     rsi, rsi                    ; sin acción nueva: sólo consultar
    lea     rdx, [sa_consulta]
    mov     r10, SIGSET_SIZE
    mov     rax, SYS_RT_SIGACTION
    syscall
    cmp     qword [sa_consulta + SA_HANDLER], SIG_DFL
    je      .ok
    mov     r12, 1
.ok:
    inc     rbx
    cmp     rbx, NUM_SENALES
    jb      .siguiente
    PRINT   k_manejadores
    test    r12, r12
    jnz     .falla
    PRINT   t_si_ok
    jmp     .fin
.falla:
    PRINT   t_falla
.fin:
    call    out_nl
    xor     rax, rax
    pop     r13
    pop     r12
    pop     rbx
    ret
