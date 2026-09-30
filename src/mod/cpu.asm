; =============================================================================
; cpu.asm — M1: Identificación del CPU
; -----------------------------------------------------------------------------
; Proyecto : LowMonitor
; Exporta  : mod_cpu_run   imprime la identificación del procesador
;            cpu_detect    consulta CPUID/XGETBV una sola vez y llena los datos
;            cpu_features  qword con los bits FEAT_* (ver cpu.inc) que usan
;                          otros módulos antes de ejecutar AVX, RDTSCP, etc.
;            cpu_familia, cpu_modelo, cpu_stepping (qwords, valores mostrados)
;
; Instrucciones clave:
;   CPUID  (EAX = hoja, ECX = subhoja) -> EAX, EBX, ECX, EDX con información del
;          procesador. Las hojas básicas van de 0 a CPUID(0).EAX; las
;          extendidas de 80000000h a CPUID(80000000h).EAX. Consultar una hoja
;          fuera de rango devuelve datos de otra hoja, por eso se verifica.
;   XGETBV (ECX = 0) -> EDX:EAX = XCR0: qué estados de registros extendidos
;          guarda el sistema operativo al cambiar de contexto. Que la CPU tenga
;          AVX no basta: si el SO no guarda YMM/ZMM, usarlos provoca #UD.
; Referencia: Intel SDM Vol. 2A "CPUID"; Vol. 1 cap. 13 "XSAVE"; AMD APM Vol. 3
;             "CPUID Specification".
; =============================================================================

default rel

%include "lib.inc"
%include "cpu.inc"

MASCARA_BYTES       equ 128           ; máscara de afinidad: hasta 1024 CPUs
FIN_TABLA           equ -1            ; marca de fin en las tablas de características

; -----------------------------------------------------------------------------
; SI_BIT registro32, bit, FEAT_x
; Si el bit `bit` del registro devuelto por CPUID está en 1, activa FEAT_x en
; r12 (acumulador de características durante cpu_detect).
; -----------------------------------------------------------------------------
%macro SI_BIT 3
    bt      %1, %2                      ; CF = bit consultado
    jnc     %%no
    bts     r12, %3                     ; marcar la característica
%%no:
%endmacro

; =============================================================================
section .data
; Constantes, strings, tablas de datos
; =============================================================================
; Etiquetas rellenadas a 18 columnas visibles (las tildes ocupan 2 bytes en
; UTF-8, por eso el relleno se hace en el texto y no contando bytes).
STR l_fabricante,  "Fabricante:       "
STR l_procesador,  "Procesador:       "
STR l_arquitectura,"Arquitectura:     "
STR l_familia,     "Familia:          "
STR l_modelo,      "Modelo:           "
STR l_stepping,    "Stepping:         "
STR l_hilos,       "Hilos lógicos:    "
STR l_hipervisor,  "Hipervisor:       "
STR l_caract,      "Características:  "
STR l_extensiones, "Extensiones:      "
STR l_avx_so,      "AVX (SO):         "
STR l_avx512_so,   "AVX-512 (SO):     "

STR t_x86_64,      "x86_64"
STR t_x86_32,      "x86 (sin modo de 64 bits)"
STR t_desconocido, "Desconocido"
STR t_ninguna,     "ninguna"
STR t_sep,         ", "
STR t_abre,        " ("
STR t_cierra_h,    "h)"
STR t_hab_ymm,     "Habilitado (XCR0 guarda YMM)"
STR t_hab_zmm,     "Habilitado (XCR0 guarda ZMM y k0-k7)"
STR t_no_so,       "No habilitado por el SO"
STR t_no_cpu,      "No soportado por la CPU"

; ---- Nombres de extensiones y características ---------------------------------
n_sse       db "SSE", 0
n_sse2      db "SSE2", 0
n_sse3      db "SSE3", 0
n_ssse3     db "SSSE3", 0
n_sse41     db "SSE4.1", 0
n_sse42     db "SSE4.2", 0
n_avx       db "AVX", 0
n_fma       db "FMA", 0
n_avx2      db "AVX2", 0
n_avx512f   db "AVX-512F", 0
n_avx512dq  db "AVX-512DQ", 0
n_avx512bw  db "AVX-512BW", 0
n_avx512vl  db "AVX-512VL", 0
n_rdtscp    db "RDTSCP", 0
n_invtsc    db "TSC invariante", 0
n_clflush   db "CLFLUSH", 0
n_popcnt    db "POPCNT", 0

; ---- Tablas (bit FEAT_*, nombre): se recorren en bucle para imprimir ----------
align 8
tabla_extensiones:
    dq FEAT_SSE,      n_sse
    dq FEAT_SSE2,     n_sse2
    dq FEAT_SSE3,     n_sse3
    dq FEAT_SSSE3,    n_ssse3
    dq FEAT_SSE41,    n_sse41
    dq FEAT_SSE42,    n_sse42
    dq FEAT_AVX,      n_avx
    dq FEAT_FMA,      n_fma
    dq FEAT_AVX2,     n_avx2
    dq FEAT_AVX512F,  n_avx512f
    dq FEAT_AVX512DQ, n_avx512dq
    dq FEAT_AVX512BW, n_avx512bw
    dq FEAT_AVX512VL, n_avx512vl
    dq FIN_TABLA

tabla_caracteristicas:
    dq FEAT_RDTSCP,   n_rdtscp
    dq FEAT_INVTSC,   n_invtsc
    dq FEAT_CLFLUSH,  n_clflush
    dq FEAT_POPCNT,   n_popcnt
    dq FIN_TABLA

; =============================================================================
section .bss align=8
; Variables reservadas (buffers, contadores)
; (primero los datos de 8 bytes y la máscara: quedan alineados sin relleno)
; =============================================================================
cpu_features    resq 1                  ; bits FEAT_* (ver cpu.inc)
cpu_familia     resq 1                  ; familia mostrada (con familia extendida)
cpu_modelo      resq 1                  ; modelo mostrado (con modelo extendido)
cpu_stepping    resq 1
mascara_cpus    resb MASCARA_BYTES      ; máscara de afinidad (sched_getaffinity)
cpu_firma       resd 1                  ; CPUID(1).EAX sin procesar
cpu_max_hoja    resd 1                  ; CPUID(0).EAX
cpu_max_ext     resd 1                  ; CPUID(80000000h).EAX
cpu_vendor      resb 16                 ; 12 caracteres + 0
cpu_marca       resb 52                 ; 48 caracteres + 0
cpu_hv          resb 16                 ; firma del hipervisor, 12 caracteres + 0
cpu_detectado   resb 1                  ; 1 = cpu_detect ya se ejecutó

; =============================================================================
section .text
; =============================================================================
global mod_cpu_run, cpu_detect
global cpu_features, cpu_familia, cpu_modelo, cpu_stepping

; -----------------------------------------------------------------------------
; cpu_detect — consulta CPUID y XGETBV y llena cpu_features y los datos crudos
; Salidas  : ninguna (resultados en las variables globales)
; Notas    : idempotente: la segunda llamada retorna de inmediato.
;            CPUID sobrescribe rbx (callee-saved): se guarda y restaura.
; Modifica : rax, rcx, rdx, rdi, r8-r11
; -----------------------------------------------------------------------------
cpu_detect:
    cmp     byte [cpu_detectado], 0
    jne     .ya_detectado
    push    rbx                         ; cpuid escribe ebx
    push    r12                         ; r12 = acumulador de características
    push    r13                         ; r13 = auxiliar (3 pushes: pila alineada)
    xor     r12, r12

    ; ---- Hoja 0: máxima hoja básica y fabricante ------------------------------
    ; CPUID trabaja con registros de 32 bits: escribir eax/ecx limpia la parte
    ; alta de rax/rcx, y los resultados llegan en eax, ebx, ecx, edx.
    xor     eax, eax                    ; hoja 0
    xor     ecx, ecx                    ; subhoja 0
    cpuid
    mov     [cpu_max_hoja], eax
    mov     [cpu_vendor], ebx           ; el fabricante está en EBX, EDX, ECX
    mov     [cpu_vendor + 4], edx       ; (en ese orden): "Genu" "ineI" "ntel"
    mov     [cpu_vendor + 8], ecx

    ; ---- Hoja 1: firma (familia/modelo) y características básicas -------------
    mov     eax, 1
    xor     ecx, ecx
    cpuid
    mov     [cpu_firma], eax
    SI_BIT  edx, 19, FEAT_CLFLUSH
    SI_BIT  edx, 25, FEAT_SSE
    SI_BIT  edx, 26, FEAT_SSE2
    SI_BIT  ecx, 0,  FEAT_SSE3
    SI_BIT  ecx, 9,  FEAT_SSSE3
    SI_BIT  ecx, 12, FEAT_FMA
    SI_BIT  ecx, 19, FEAT_SSE41
    SI_BIT  ecx, 20, FEAT_SSE42
    SI_BIT  ecx, 23, FEAT_POPCNT
    SI_BIT  ecx, 28, FEAT_AVX
    SI_BIT  ecx, 31, FEAT_HYPERVISOR    ; bit reservado a hipervisores

    ; ---- XCR0: ¿el SO guarda los registros extendidos? ------------------------
    bt      ecx, 27                     ; OSXSAVE: el SO habilitó XSAVE y XGETBV
    jnc     .sin_xsave                  ; sin OSXSAVE, xgetbv sería #UD
    xor     ecx, ecx                    ; XCR0
    xgetbv                              ; edx:eax = XCR0
    mov     r13, rax
    and     r13, 0x06                   ; bit 1 = estado SSE (XMM), bit 2 = AVX (YMM alto)
    cmp     r13, 0x06
    jne     .sin_xsave
    bt      r12, FEAT_AVX               ; también debe tenerlo la CPU
    jnc     .sin_xsave
    bts     r12, FEAT_OS_AVX
    mov     r13, rax
    and     r13, 0xE0                   ; bits 5-7 = opmask k0-k7, ZMM0-15 alto, ZMM16-31
    cmp     r13, 0xE0
    jne     .sin_xsave
    bts     r12, FEAT_OS_AVX512         ; se confirma con AVX-512F tras la hoja 7
.sin_xsave:

    ; ---- Hoja 7 subhoja 0: extensiones estructuradas (AVX2, AVX-512) ----------
    cmp     dword [cpu_max_hoja], 7
    jb      .sin_hoja7
    mov     eax, 7
    xor     ecx, ecx
    cpuid
    SI_BIT  ebx, 5,  FEAT_AVX2
    SI_BIT  ebx, 16, FEAT_AVX512F
    SI_BIT  ebx, 17, FEAT_AVX512DQ
    SI_BIT  ebx, 30, FEAT_AVX512BW
    SI_BIT  ebx, 31, FEAT_AVX512VL
.sin_hoja7:
    bt      r12, FEAT_AVX512F           ; AVX-512 usable = CPU con AVX-512F + SO
    jc      .avx512_ok
    btr     r12, FEAT_OS_AVX512
.avx512_ok:

    ; ---- Hojas extendidas ------------------------------------------------------
    mov     eax, 0x80000000
    xor     ecx, ecx
    cpuid
    mov     [cpu_max_ext], eax
    cmp     eax, 0x80000001
    jb      .sin_ext

    mov     eax, 0x80000001
    xor     ecx, ecx
    cpuid
    SI_BIT  edx, 27, FEAT_RDTSCP
    SI_BIT  edx, 29, FEAT_LM            ; Long Mode: la CPU es x86-64

    ; Nombre comercial: 3 hojas x 16 bytes (EAX, EBX, ECX, EDX) = 48 caracteres
    cmp     dword [cpu_max_ext], 0x80000004
    jb      .sin_marca
    lea     r13, [cpu_marca]            ; r13 = destino
    mov     edi, 0x80000002             ; edi = hoja actual (cpuid no toca rdi)
.marca:
    mov     eax, edi
    xor     ecx, ecx
    cpuid
    mov     [r13], eax
    mov     [r13 + 4], ebx
    mov     [r13 + 8], ecx
    mov     [r13 + 12], edx
    add     r13, 16
    inc     edi
    cmp     edi, 0x80000004             ; comparación de 32 bits: el inmediato no se extiende con signo
    jbe     .marca
.sin_marca:

    cmp     dword [cpu_max_ext], 0x80000007
    jb      .sin_ext
    mov     eax, 0x80000007             ; gestión de energía avanzada
    xor     ecx, ecx
    cpuid
    SI_BIT  edx, 8, FEAT_INVTSC         ; TSC a frecuencia constante en todos los estados
.sin_ext:

    ; ---- Hipervisor: firma en la hoja 40000000h --------------------------------
    bt      r12, FEAT_HYPERVISOR
    jnc     .sin_hv
    mov     eax, 0x40000000
    xor     ecx, ecx
    cpuid
    mov     [cpu_hv], ebx               ; p. ej. "Micr" "osof" "t Hv"
    mov     [cpu_hv + 4], ecx
    mov     [cpu_hv + 8], edx
.sin_hv:

    ; ---- Familia, modelo y stepping mostrados (a partir de CPUID(1).EAX) -------
    ;   bits 3:0 stepping | 7:4 modelo | 11:8 familia | 19:16 modelo ext. | 27:20 familia ext.
    mov     eax, [cpu_firma]            ; carga de 32 bits: limpia la parte alta de rax
    mov     rcx, rax
    and     rcx, 0x0F
    mov     [cpu_stepping], rcx
    mov     rdx, rax
    shr     rdx, 4
    and     rdx, 0x0F                   ; rdx = modelo base
    mov     r8, rax
    shr     r8, 8
    and     r8, 0x0F                    ; r8 = familia base
    mov     r9, rax
    shr     r9, 16
    and     r9, 0x0F                    ; r9 = modelo extendido
    mov     r10, rax
    shr     r10, 20
    and     r10, 0xFF                   ; r10 = familia extendida
    mov     r11, r8                     ; familia mostrada = base...
    cmp     r8, 0x0F
    jne     .familia_lista
    add     r11, r10                    ; ...+ extendida sólo si la base es 0Fh
.familia_lista:
    mov     [cpu_familia], r11
    cmp     r8, 0x06                    ; el modelo extendido aplica a familias 06h y 0Fh
    je      .modelo_ext
    cmp     r8, 0x0F
    jne     .modelo_listo
.modelo_ext:
    shl     r9, 4
    add     rdx, r9                     ; modelo = (modelo ext. << 4) + modelo
.modelo_listo:
    mov     [cpu_modelo], rdx

    mov     [cpu_features], r12
    mov     byte [cpu_detectado], 1
    pop     r13
    pop     r12
    pop     rbx
.ya_detectado:
    ret

; -----------------------------------------------------------------------------
; mod_cpu_run — imprime la identificación del procesador
; Salidas  : rax = 0
; -----------------------------------------------------------------------------
mod_cpu_run:
    push    rbx                         ; rbx = cpu_features durante la impresión
    call    cpu_detect
    mov     rbx, [cpu_features]

    PRINT   l_fabricante
    lea     rdi, [cpu_vendor]
    mov     rsi, 12
    call    out_recortado
    call    out_nl

    PRINT   l_procesador
    lea     rdi, [cpu_marca]
    mov     rsi, 48
    call    out_recortado
    call    out_nl

    PRINT   l_arquitectura
    bt      rbx, FEAT_LM
    jnc     .sin_lm
    PRINT   t_x86_64
    jmp     .arq_lista
.sin_lm:
    PRINT   t_x86_32
.arq_lista:
    call    out_nl

    PRINT   l_familia
    mov     rdi, [cpu_familia]
    call    out_dec_hex
    PRINT   l_modelo
    mov     rdi, [cpu_modelo]
    call    out_dec_hex
    PRINT   l_stepping
    mov     rdi, [cpu_stepping]
    call    out_u64
    call    out_nl

    PRINT   l_hilos
    call    contar_hilos                ; rax = hilos o 0 si no se pudo
    test    rax, rax
    jz      .hilos_desconocido
    mov     rdi, rax
    call    out_u64
    jmp     .hilos_listo
.hilos_desconocido:
    PRINT   t_desconocido
.hilos_listo:
    call    out_nl

    bt      rbx, FEAT_HYPERVISOR        ; la línea sólo aparece bajo un hipervisor
    jnc     .sin_hipervisor
    PRINT   l_hipervisor
    lea     rdi, [cpu_hv]
    mov     rsi, 12
    call    out_recortado
    call    out_nl
.sin_hipervisor:

    PRINT   l_caract
    lea     rdi, [tabla_caracteristicas]
    call    out_lista
    PRINT   l_extensiones
    lea     rdi, [tabla_extensiones]
    call    out_lista

    ; ---- Soporte del SO para AVX / AVX-512 -------------------------------------
    PRINT   l_avx_so
    bt      rbx, FEAT_AVX
    jnc     .avx_no_cpu
    bt      rbx, FEAT_OS_AVX
    jnc     .avx_no_so
    PRINT   t_hab_ymm
    jmp     .avx_listo
.avx_no_so:
    PRINT   t_no_so
    jmp     .avx_listo
.avx_no_cpu:
    PRINT   t_no_cpu
.avx_listo:
    call    out_nl

    PRINT   l_avx512_so
    bt      rbx, FEAT_AVX512F
    jnc     .z_no_cpu
    bt      rbx, FEAT_OS_AVX512
    jnc     .z_no_so
    PRINT   t_hab_zmm
    jmp     .z_listo
.z_no_so:
    PRINT   t_no_so
    jmp     .z_listo
.z_no_cpu:
    PRINT   t_no_cpu
.z_listo:
    call    out_nl

    xor     rax, rax
    pop     rbx
    ret

; -----------------------------------------------------------------------------
; out_lista — imprime, separadas por comas, las características presentes
; Entradas : rdi = tabla de pares (bit FEAT_*, cadena C) terminada en FIN_TABLA
; Notas    : si ninguna está presente imprime "ninguna". Termina con salto de línea.
; -----------------------------------------------------------------------------
out_lista:
    push    rbx                         ; rbx = entrada actual de la tabla
    push    r12                         ; r12 = cantidad impresa
    push    r13                         ; r13 = copia de cpu_features
    mov     rbx, rdi
    xor     r12, r12
    mov     r13, [cpu_features]
.siguiente:
    mov     rax, [rbx]
    cmp     rax, FIN_TABLA
    je      .fin
    bt      r13, rax                    ; ¿está presente esta característica?
    jnc     .avanzar
    test    r12, r12
    jz      .primera                    ; la primera no lleva separador
    PRINT   t_sep
.primera:
    mov     rdi, [rbx + 8]
    call    out_cstr
    inc     r12
.avanzar:
    add     rbx, 16                     ; siguiente par (2 qwords)
    jmp     .siguiente
.fin:
    test    r12, r12
    jnz     .con_datos
    PRINT   t_ninguna
.con_datos:
    call    out_nl
    pop     r13
    pop     r12
    pop     rbx
    ret

; -----------------------------------------------------------------------------
; out_recortado — imprime un texto de CPUID sin espacios ni ceros a los lados
; Entradas : rdi = dirección, rsi = longitud máxima
; Notas    : los fabricantes rellenan el nombre comercial con espacios al
;            inicio o con ceros al final. Si queda vacío imprime "Desconocido".
; -----------------------------------------------------------------------------
out_recortado:
    lea     rdx, [rdi + rsi]            ; rdx = límite
    mov     rsi, rdi                    ; rsi buscará el final (0 o límite)
.buscar_fin:
    cmp     rsi, rdx
    jae     .quitar_final
    cmp     byte [rsi], 0
    je      .quitar_final
    inc     rsi
    jmp     .buscar_fin
.quitar_final:
    cmp     rsi, rdi                    ; retroceder sobre espacios finales
    jbe     .quitar_inicio
    cmp     byte [rsi - 1], ' '
    jne     .quitar_inicio
    dec     rsi
    jmp     .quitar_final
.quitar_inicio:
    cmp     rdi, rsi                    ; avanzar sobre espacios iniciales
    jae     .vacio
    cmp     byte [rdi], ' '
    jne     .imprimir
    inc     rdi
    jmp     .quitar_inicio
.imprimir:
    sub     rsi, rdi                    ; longitud del tramo útil
    jmp     out_str
.vacio:
    lea     rdi, [t_desconocido]
    mov     rsi, t_desconocido_len
    jmp     out_str

; -----------------------------------------------------------------------------
; out_dec_hex — imprime "N (XXh)" y salto de línea
; Entradas : rdi = valor
; -----------------------------------------------------------------------------
out_dec_hex:
    push    rbx                         ; rbx = valor (y alinea la pila)
    mov     rbx, rdi
    call    out_u64
    PRINT   t_abre
    mov     rdi, rbx
    mov     rsi, 2
    call    out_hex
    PRINT   t_cierra_h
    call    out_nl
    pop     rbx
    ret

; -----------------------------------------------------------------------------
; contar_hilos — cantidad de CPUs lógicas donde el proceso puede ejecutarse
; Salidas  : rax = cantidad, o 0 si sched_getaffinity falló
; Método   : sched_getaffinity(0, tamaño, máscara) devuelve un bit por CPU;
;            se cuentan los bits en 1 con x &= x - 1 (borra el 1 más bajo en
;            cada vuelta), que no requiere la instrucción POPCNT.
; -----------------------------------------------------------------------------
contar_hilos:
    mov     rax, SYS_SCHED_GETAFFINITY
    xor     rdi, rdi                    ; pid 0 = este proceso
    mov     rsi, MASCARA_BYTES
    lea     rdx, [mascara_cpus]
    syscall                             ; rax = bytes escritos en la máscara
    CHECK_SYSCALL .error
    mov     rcx, rax
    shr     rcx, 3                      ; qwords escritos (el kernel escribe múltiplos de 8)
    lea     rsi, [mascara_cpus]
    xor     rax, rax                    ; rax = total de bits
.qword:
    test    rcx, rcx
    jz      .fin
    mov     rdx, [rsi]
.bit:
    test    rdx, rdx
    jz      .siguiente
    lea     r8, [rdx - 1]
    and     rdx, r8                     ; borrar el bit 1 más bajo
    inc     rax
    jmp     .bit
.siguiente:
    add     rsi, 8
    dec     rcx
    jmp     .qword
.error:
    xor     rax, rax
.fin:
    ret
