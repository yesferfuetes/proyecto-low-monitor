; =============================================================================
; memtest.asm — M3: Diagnóstico de memoria
; -----------------------------------------------------------------------------
; Proyecto : LowMonitor
; Exporta  : mod_mem_run          prueba de integridad de RAM
;            memtest_inject_run   (oculto) igual, pero voltea 3 bits a propósito
;                                 para demostrar que el detector funciona
;            mem_fill_const, mem_fill_incr, mem_verify_const, mem_verify_incr
;
; Método:
;   1. sysinfo(2) da la memoria total y libre del sistema.
;   2. mmap(2) reserva un bloque anónimo con MAP_POPULATE: el kernel asigna
;      páginas físicas reales antes de devolverlo (sin fallos de página
;      durante la medición). Un proceso de usuario no puede probar toda la RAM
;      física; prueba el bloque que el kernel le entrega.
;   3. Por cada patrón: escribir todo el bloque, luego leerlo y comparar.
;      Bits corruptos = POPCNT(leído XOR esperado), acumulado por qword.
;
; Optimizaciones:
;   - Escritura con non-temporal stores (MOVNTI): los datos van directo a RAM
;     a través de los write-combining buffers sin ocupar la caché, así la
;     verificación lee de memoria y no de una copia en caché. SFENCE ordena
;     y vacía esos buffers antes de verificar.
;   - Lectura con PREFETCHT0 a 512 bytes por delante del puntero: oculta la
;     latencia de RAM pidiendo las líneas antes de necesitarlas.
;   - Bucles desenrollados (4 escrituras / 8 lecturas por vuelta).
;
; Referencias: Intel SDM Vol. 2B (MOVNTI, PREFETCHh, POPCNT), Vol. 3A
;              §11.3 (write combining); man 2 sysinfo, mmap.
; =============================================================================

default rel

%include "lib.inc"
%include "cpu.inc"

extern cpu_detect, cpu_features

MIB                 equ 1024 * 1024
BLOQUE_DEFECTO      equ 64 * MIB      ; tamaño de prueba por defecto
BLOQUE_MINIMO       equ 4 * MIB
DIST_PREFETCH       equ 512           ; bytes por delante (8 líneas de caché)
PATRON_AA           equ 0xAAAAAAAAAAAAAAAA  ; 1010...: bits alternos
PATRON_55           equ 0x5555555555555555  ; 0101...: complemento del anterior
TIPO_CONSTANTE      equ 0
TIPO_INCREMENTAL    equ 1

; struct sysinfo (x86-64): offsets usados
SI_TOTALRAM         equ 32
SI_FREERAM          equ 40
SI_MEM_UNIT         equ 104           ; dword
SI_TAM              equ 128           ; espacio reservado (la estructura ocupa 112)

; =============================================================================
section .data
; Constantes, strings, tablas de datos
; =============================================================================
STR l_total,     "Memoria total:      "
STR l_libre,     "Memoria libre:      "
STR l_bloque,    "Bloque probado:     "
STR l_aa,        "Patrón 0xAA:        "
STR l_55,        "Patrón 0x55:        "
STR l_incr,      "Patrón incremental: "
STR l_escritura, "Escritura (NT):     "
STR l_lectura,   "Verificación:       "

STR t_detectada, " detectada"
STR t_mmap,      " (mmap + MAP_POPULATE)"
STR t_pasada,    "PASADA (0 errores)"
STR t_fallida,   "FALLIDA ("
STR t_bits,      " bits corruptos, primer error en +"
STR t_h_cierra,  "h)"
STR t_mbs,       " MB/s"
STR t_err_si,    "[ERROR] sysinfo falló", 10
STR t_err_mmap,  "[ERROR] no se pudo reservar memoria con mmap (errno "
STR t_err_unmap, "[ERROR] munmap no liberó el bloque (errno "
STR t_cierra_nl, ")", 10

; =============================================================================
section .bss align=8
; Variables reservadas (buffers, contadores)
; =============================================================================
info_sistema    resb SI_TAM             ; struct sysinfo
bloque_base     resq 1                  ; dirección del bloque (mmap)
bloque_bytes    resq 1
bloque_qwords   resq 1
ns_escritura    resq 1                  ; tiempo acumulado escribiendo
ns_lectura      resq 1                  ; tiempo acumulado verificando
usar_popcnt     resb 1                  ; 1 si la CPU tiene POPCNT
mem_inyectar    resb 1                  ; 1 = voltear 3 bits en el patrón 0xAA

; =============================================================================
section .text
; =============================================================================
global mod_mem_run, memtest_inject_run
global mem_fill_const, mem_fill_incr, mem_verify_const, mem_verify_incr

; -----------------------------------------------------------------------------
; mem_fill_const — llena un bloque con un patrón constante (non-temporal)
; Entradas : rdi = base (alineada a 8), rsi = qwords (múltiplo de 4), rdx = patrón
; Modifica : rcx
; -----------------------------------------------------------------------------
mem_fill_const:
    xor     rcx, rcx                    ; rcx = índice de qword
.bucle:
    movnti  [rdi + rcx*8], rdx          ; escritura que no pasa por la caché
    movnti  [rdi + rcx*8 + 8], rdx
    movnti  [rdi + rcx*8 + 16], rdx
    movnti  [rdi + rcx*8 + 24], rdx
    add     rcx, 4                      ; 32 bytes por vuelta
    cmp     rcx, rsi
    jb      .bucle
    sfence                              ; vaciar los buffers de write combining
    ret

; -----------------------------------------------------------------------------
; mem_fill_incr — llena un bloque con la secuencia incremental: qword i = i
; Entradas : rdi = base, rsi = qwords (múltiplo de 4)
; Notas    : cada qword guarda su propio índice: si dos direcciones se
;            "solapan" (línea de dirección defectuosa) la verificación lo nota.
; Modifica : rax, rcx
; -----------------------------------------------------------------------------
mem_fill_incr:
    xor     rcx, rcx
.bucle:
    movnti  [rdi + rcx*8], rcx          ; el valor es el propio índice
    lea     rax, [rcx + 1]
    movnti  [rdi + rcx*8 + 8], rax
    lea     rax, [rcx + 2]
    movnti  [rdi + rcx*8 + 16], rax
    lea     rax, [rcx + 3]
    movnti  [rdi + rcx*8 + 24], rax
    add     rcx, 4
    cmp     rcx, rsi
    jb      .bucle
    sfence
    ret

; -----------------------------------------------------------------------------
; VERIFICAR nombre, esperado — genera una función de verificación
; Entradas : rdi = base, rsi = qwords (múltiplo de 8), rdx = patrón (constante)
; Salidas  : rax = bits corruptos, rdx = desplazamiento en bytes del primer
;            qword con error (-1 si no hubo)
; Método   : por cada línea de caché (8 qwords) se hace un prefetch adelante;
;            cada qword se compara con XOR contra el valor esperado. El camino
;            rápido (sin error) es un XOR y un salto no tomado; sólo al
;            encontrar diferencias se cuentan los bits con POPCNT.
; Modifica : rcx, r8-r11
; -----------------------------------------------------------------------------
%macro VERIFICAR 2                      ; nombre, registro con el valor esperado
%1:
    mov     r10, rdx                    ; r10 = patrón (para la versión constante)
    xor     r8, r8                      ; r8 = bits corruptos acumulados
    mov     r9, -1                      ; r9 = primer error (ninguno aún)
    xor     rcx, rcx                    ; rcx = índice de qword
%%linea:
    prefetcht0 [rdi + rcx*8 + DIST_PREFETCH]  ; pedir la línea que se usará después
    mov     r11, 8                      ; 8 qwords = 64 bytes = una línea
%%qword:
    mov     rax, [rdi + rcx*8]          ; leer
    xor     rax, %2                     ; diferencias con lo esperado (0 = correcto)
    jnz     %%error                     ; raro: sólo si hay bits corruptos
%%siguiente:
    inc     rcx
    dec     r11
    jnz     %%qword
    cmp     rcx, rsi
    jb      %%linea
    mov     rax, r8
    mov     rdx, r9
    ret
%%error:
    cmp     r9, -1
    jne     %%contar
    lea     r9, [rcx*8]                 ; recordar el desplazamiento del primero
%%contar:
    cmp     byte [usar_popcnt], 0
    je      %%software
    popcnt  rax, rax                    ; cantidad de bits en 1 = bits distintos
    add     r8, rax
    jmp     %%siguiente
%%software:                             ; sin POPCNT: x &= x - 1 borra un bit por vuelta
    test    rax, rax
    jz      %%siguiente
    lea     rdx, [rax - 1]
    and     rax, rdx
    inc     r8
    jmp     %%software
%endmacro

VERIFICAR mem_verify_const, r10         ; esperado = patrón
VERIFICAR mem_verify_incr,  rcx         ; esperado = índice del qword

; -----------------------------------------------------------------------------
; inyectar_errores — voltea 3 bits conocidos del bloque (sólo para la demo)
; qword 10 bit 0 (desplazamiento +50h), qword 1000 bit 63, último qword bit 5
; -----------------------------------------------------------------------------
inyectar_errores:
    mov     rdi, [bloque_base]
    xor     qword [rdi + 10*8], 1
    mov     rax, 1
    shl     rax, 63
    xor     [rdi + 1000*8], rax
    mov     rcx, [bloque_qwords]
    xor     qword [rdi + rcx*8 - 8], 1 << 5
    mov     byte [mem_inyectar], 0      ; una sola vez
    ret

; -----------------------------------------------------------------------------
; probar_patron — escribe, verifica e informa un patrón
; Entradas : rdi = etiqueta, rsi = longitud de la etiqueta,
;            rdx = TIPO_CONSTANTE | TIPO_INCREMENTAL, rcx = patrón
; Salidas  : rax = bits corruptos
; -----------------------------------------------------------------------------
probar_patron:
    push    rbx                         ; rbx = bits corruptos
    push    r12                         ; r12 = tipo
    push    r13                         ; r13 = patrón
    push    r14                         ; r14 = instante inicial
    push    r15                         ; r15 = primer error (5 pushes: pila alineada)
    mov     r12, rdx
    mov     r13, rcx
    call    out_str                     ; etiqueta

    ; ---- escritura -------------------------------------------------------------
    call    mono_ns
    mov     r14, rax
    mov     rdi, [bloque_base]
    mov     rsi, [bloque_qwords]
    cmp     r12, TIPO_INCREMENTAL
    je      .llenar_incr
    mov     rdx, r13
    call    mem_fill_const
    jmp     .escrito
.llenar_incr:
    call    mem_fill_incr
.escrito:
    call    mono_ns
    sub     rax, r14
    add     [ns_escritura], rax

    ; ---- inyección opcional (demo del detector) ---------------------------------
    cmp     byte [mem_inyectar], 0
    je      .verificar
    cmp     r12, TIPO_CONSTANTE
    jne     .verificar
    call    inyectar_errores

    ; ---- verificación -----------------------------------------------------------
.verificar:
    mfence                              ; todas las escrituras previas visibles
    call    mono_ns
    mov     r14, rax
    mov     rdi, [bloque_base]
    mov     rsi, [bloque_qwords]
    cmp     r12, TIPO_INCREMENTAL
    je      .verificar_incr
    mov     rdx, r13
    call    mem_verify_const
    jmp     .verificado
.verificar_incr:
    call    mem_verify_incr
.verificado:
    mov     rbx, rax
    mov     r15, rdx
    call    mono_ns
    sub     rax, r14
    add     [ns_lectura], rax

    ; ---- resultado --------------------------------------------------------------
    test    rbx, rbx
    jnz     .fallida
    PRINT   t_pasada
    jmp     .fin
.fallida:
    PRINT   t_fallida
    mov     rdi, rbx
    call    out_u64
    PRINT   t_bits
    mov     rdi, r15
    mov     rsi, 1
    call    out_hex
    PRINT   t_h_cierra
.fin:
    call    out_nl
    mov     rax, rbx
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; -----------------------------------------------------------------------------
; out_mbs — imprime un ancho de banda: bytes * 1000 / ns  "N MB/s"
; Entradas : rdi = bytes, rsi = nanosegundos
; -----------------------------------------------------------------------------
out_mbs:
    sub     rsp, 8
    mov     rdx, rsi                    ; c = ns
    mov     rsi, 1000                   ; b
    call    mul_div                     ; (bytes / ns) * 1000 = MB/s (10^6 B/s)
    mov     rdi, rax
    call    out_u64
    PRINT   t_mbs
    call    out_nl
    add     rsp, 8
    ret

; -----------------------------------------------------------------------------
; mod_mem_run — punto de entrada del módulo M3
; Salidas  : rax = 0 si la prueba se ejecutó (aunque encuentre errores),
;            1 si falló sysinfo, mmap o munmap
; -----------------------------------------------------------------------------
mod_mem_run:
    push    rbx                         ; rbx = tamaño del bloque
    push    r12                         ; r12 = memoria total
    push    r13                         ; r13 = memoria libre
    call    cpu_detect
    bt      qword [cpu_features], FEAT_POPCNT
    setc    byte [usar_popcnt]          ; elegir conteo por hardware o software
    mov     qword [ns_escritura], 0
    mov     qword [ns_lectura], 0

    ; ---- sysinfo: memoria total y libre ---------------------------------------
    mov     rax, SYS_SYSINFO
    lea     rdi, [info_sistema]
    syscall
    CHECK_SYSCALL .error_sysinfo
    mov     eax, [info_sistema + SI_MEM_UNIT]   ; mem_unit (32 bits, limpia la parte alta)
    mov     r12, [info_sistema + SI_TOTALRAM]
    imul    r12, rax                    ; total en bytes
    mov     r13, [info_sistema + SI_FREERAM]
    imul    r13, rax                    ; libre en bytes

    PRINT   l_total
    mov     rdi, r12
    call    out_size
    PRINT   t_detectada
    call    out_nl
    PRINT   l_libre
    mov     rdi, r13
    call    out_size
    call    out_nl

    ; ---- tamaño del bloque: 64 MiB, o libre/4 si hay poca memoria -------------
    mov     rbx, BLOQUE_DEFECTO
    mov     rax, r13
    shr     rax, 2                      ; libre / 4
    cmp     rax, rbx
    jae     .tam_listo
    mov     rbx, rax
    and     rbx, -MIB                   ; múltiplo de 1 MiB (qwords múltiplo de 8)
    cmp     rbx, BLOQUE_MINIMO
    jae     .tam_listo
    mov     rbx, BLOQUE_MINIMO
.tam_listo:
    mov     [bloque_bytes], rbx
    mov     rax, rbx
    shr     rax, 3
    mov     [bloque_qwords], rax

    ; ---- mmap(NULL, tam, RW, PRIVATE|ANONYMOUS|POPULATE, -1, 0) ------------------
    mov     rax, SYS_MMAP
    xor     rdi, rdi                    ; el kernel elige la dirección
    mov     rsi, rbx
    mov     rdx, PROT_READ | PROT_WRITE
    mov     r10, MAP_PRIVATE | MAP_ANONYMOUS | MAP_POPULATE
    mov     r8, -1                      ; sin archivo
    xor     r9, r9
    syscall
    CHECK_SYSCALL .error_mmap
    mov     [bloque_base], rax

    PRINT   l_bloque
    mov     rdi, rbx
    call    out_size
    PRINT   t_mmap
    call    out_nl

    ; ---- patrones ---------------------------------------------------------------
    lea     rdi, [l_aa]
    mov     rsi, l_aa_len
    mov     rdx, TIPO_CONSTANTE
    mov     rcx, PATRON_AA
    call    probar_patron
    lea     rdi, [l_55]
    mov     rsi, l_55_len
    mov     rdx, TIPO_CONSTANTE
    mov     rcx, PATRON_55
    call    probar_patron
    lea     rdi, [l_incr]
    mov     rsi, l_incr_len
    mov     rdx, TIPO_INCREMENTAL
    xor     rcx, rcx
    call    probar_patron

    ; ---- ancho de banda (3 pasadas de escritura y 3 de lectura) ----------------
    PRINT   l_escritura
    mov     rdi, rbx
    imul    rdi, rdi, 3
    mov     rsi, [ns_escritura]
    call    out_mbs
    PRINT   l_lectura
    mov     rdi, rbx
    imul    rdi, rdi, 3
    mov     rsi, [ns_lectura]
    call    out_mbs

    ; ---- liberar ----------------------------------------------------------------
    mov     rax, SYS_MUNMAP
    mov     rdi, [bloque_base]
    mov     rsi, rbx
    syscall
    CHECK_SYSCALL .error_munmap
    xor     rax, rax
    jmp     .fin

.error_sysinfo:
    PRINT   t_err_si
    mov     rax, 1
    jmp     .fin
.error_mmap:
    lea     rdi, [t_err_mmap]
    mov     rsi, t_err_mmap_len
    jmp     .error_errno
.error_munmap:
    lea     rdi, [t_err_unmap]
    mov     rsi, t_err_unmap_len
.error_errno:
    neg     rax
    mov     r12, rax                    ; errno positivo
    call    out_str
    mov     rdi, r12
    call    out_u64
    PRINT   t_cierra_nl
    mov     rax, 1
.fin:
    pop     r13
    pop     r12
    pop     rbx
    ret

; -----------------------------------------------------------------------------
; memtest_inject_run — (comando oculto) M3 con 3 bits volteados en el patrón 0xAA
; -----------------------------------------------------------------------------
memtest_inject_run:
    mov     byte [mem_inyectar], 1
    jmp     mod_mem_run
