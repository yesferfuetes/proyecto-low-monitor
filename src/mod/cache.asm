; =============================================================================
; cache.asm — M5: Gestión jerárquica de memoria
; -----------------------------------------------------------------------------
; Proyecto : LowMonitor
; Exporta  : mod_cache_run   latencia de registros, L1, L2, L3 y RAM
;            cache_detect    tamaños de caché con CPUID
;            cache_l1d, cache_l2, cache_l3 (qwords, bytes)
;
; Idea: el tiempo de una carga depende de dónde está el dato. Para medir un
; nivel se recorre una lista enlazada que cabe en ese nivel y no en el
; anterior. Cada nodo ocupa una línea de caché (64 B) y apunta al siguiente:
;     mov rax, [rax]
; Cada carga depende de la anterior (la dirección es el dato leído), así que
; no pueden solaparse: el tiempo por carga ES la latencia del nivel. El orden
; de los nodos es aleatorio para que el prefetcher de hardware no adivine
; la próxima línea.
;
; Dos mediciones por nivel:
;   por acceso : TSC antes y después de CADA carga (lo pide el enunciado),
;                promedio menos el costo de medir. Útil pero ruidosa: el costo
;                de rdtsc/rdtscp es mayor que la latencia de L1.
;   cadena     : TSC antes y después de 10^6 cargas encadenadas; el costo de
;                medir se reparte entre un millón: es la cifra más precisa.
;
; Referencias: Intel SDM Vol. 2A "CPUID leaf 04h"; AMD APM Vol. 3 "CPUID
;              Fn8000_001D, Fn8000_0005/6"; Drepper, U. (2007). What every
;              programmer should know about memory; Sattolo, S. (1986).
; =============================================================================

default rel

%include "lib.inc"

KIB                 equ 1024
MIB                 equ 1024 * 1024
ALINEACION_HUGE     equ 2 * MIB       ; tamaño de una página grande
LINEA               equ 64            ; bytes por nodo = línea de caché
RAM_MIN             equ 64 * MIB
RAM_MAX             equ 256 * MIB
CARGAS_CADENA       equ 1000000       ; múltiplo de 8 (bucle desenrollado x8)
MUESTRAS_ACCESO     equ 10000
MUESTRAS_OVERHEAD   equ 1000
CALENTAR_MAX        equ 1 << 20       ; nodos recorridos antes de medir
ATIPICO             equ 100000        ; muestra descartada (interrupción, cambio de contexto)
SEMILLA             equ 0x9E3779B97F4A7C15
SUPUESTO_L1         equ 1
SUPUESTO_L2         equ 2
SUPUESTO_L3         equ 4
NIVELES             equ 5             ; registros, L1, L2, L3, RAM
SI_TOTALRAM         equ 32
SI_MEM_UNIT         equ 104

; =============================================================================
section .data
; Constantes, strings, tablas de datos
; =============================================================================
STR t_encabezado, "Nivel        Tamaño      Por acceso   Cadena   (ciclos TSC)", 10
STR n_reg,        "Registros    "
STR n_l1,         "L1 caché     "
STR n_l2,         "L2 caché     "
STR n_l3,         "L3 caché     "
STR n_ram,        "RAM          "
STR t_guion,      "-"
STR t_supuesto,   "*"
STR l_razon,      "RAM / L1:    "
STR t_x,          "x"
STR l_trabajo,    "Conjuntos de trabajo: "
STR t_coma,       ", "
STR t_sp,         " "
STR l_pref,       "Prefetch sobre RAM (ciclos por línea de 64 B):", 10
STR l_aleatorio,  "  Aleatorio (cadena):       "
STR l_secuencial, "  Secuencial:               "
STR l_seq_pf,     "  Secuencial + prefetcht0:  "
STR t_nota_sup,   "(* tamaño supuesto: CPUID no lo informó)", 10
STR t_error,      "[ERROR] no se pudo reservar memoria para la medición", 10
n_trab_l1       db "L1", 0
n_trab_l2       db "L2", 0
n_trab_l3       db "L3", 0
n_trab_ram      db "RAM", 0

align 8
; Tablas por nivel (índices 0=registros .. 4=RAM)
nombres_nivel:  dq n_reg, n_l1, n_l2, n_l3, n_ram
largos_nivel:   dq n_reg_len, n_l1_len, n_l2_len, n_l3_len, n_ram_len
nombres_trab:   dq 0, n_trab_l1, n_trab_l2, n_trab_l3, n_trab_ram

; =============================================================================
section .bss align=8
; Variables reservadas (buffers, contadores)
; =============================================================================
cache_l1d       resq 1                  ; bytes
cache_l2        resq 1
cache_l3        resq 1
supuestos       resq 1                  ; bits SUPUESTO_* de tamaños no detectados
ram_total       resq 1
max_ext         resq 1
overhead        resq 1                  ; ciclos de medir sin trabajo
rng             resq 1                  ; estado del xorshift64
raw_base        resq 1                  ; mmap original (para munmap)
raw_tam         resq 1
trabajo         resq NIVELES            ; bytes del conjunto de trabajo por nivel
lat_acceso      resq NIVELES            ; ciclos x 10 (un decimal)
lat_cadena      resq NIVELES
pf_aleatorio    resq 1
pf_secuencial   resq 1
pf_prefetch     resq 1
info_sistema    resb 128

; =============================================================================
section .text
; =============================================================================
global mod_cache_run, cache_detect, cache_l1d, cache_l2, cache_l3

; -----------------------------------------------------------------------------
; recorrer_hoja — lee los descriptores de caché de CPUID 4 (Intel) o
; 8000001Dh (AMD), que comparten formato. Una subhoja por caché, hasta tipo 0.
;   EAX[4:0] tipo (1 datos, 2 instrucciones, 3 unificada)   EAX[7:5] nivel
;   EBX[31:22] vías-1   EBX[21:12] particiones-1   EBX[11:0] línea-1   ECX sets-1
;   tamaño = vías * particiones * línea * sets
; Entradas : rdi = hoja
; -----------------------------------------------------------------------------
recorrer_hoja:
    push    rbx                         ; cpuid escribe ebx
    push    r12                         ; r12 = hoja
    push    r13                         ; r13 = subhoja
    mov     r12, rdi
    xor     r13, r13
.subhoja:
    mov     eax, r12d                   ; cpuid usa los registros de 32 bits
    mov     ecx, r13d
    cpuid
    mov     r8d, eax
    and     r8d, 0x1F                   ; tipo
    jz      .fin                        ; tipo 0: no hay más cachés
    cmp     r8d, 2
    je      .siguiente                  ; caché de instrucciones: no interesa
    mov     r9d, eax
    shr     r9d, 5
    and     r9d, 7                      ; nivel
    mov     r10d, ebx
    shr     r10d, 22
    inc     r10                         ; vías
    mov     r11d, ebx
    shr     r11d, 12
    and     r11d, 0x3FF
    inc     r11                         ; particiones
    imul    r10, r11
    mov     r11d, ebx
    and     r11d, 0xFFF
    inc     r11                         ; bytes por línea
    imul    r10, r11
    mov     r11d, ecx
    inc     r11                         ; sets
    imul    r10, r11                    ; r10 = tamaño en bytes
    cmp     r9d, 1
    jne     .no_l1
    mov     [cache_l1d], r10
    jmp     .siguiente
.no_l1:
    cmp     r9d, 2
    jne     .no_l2
    mov     [cache_l2], r10
    jmp     .siguiente
.no_l2:
    cmp     r9d, 3
    jne     .siguiente
    mov     [cache_l3], r10
.siguiente:
    inc     r13
    cmp     r13, 16                     ; límite de seguridad
    jb      .subhoja
.fin:
    pop     r13
    pop     r12
    pop     rbx
    ret

; -----------------------------------------------------------------------------
; cache_detect — llena cache_l1d, cache_l2, cache_l3 (bytes)
; Intel: hoja 4. AMD/Hygon: hoja 8000001Dh si existe TOPOEXT
; (CPUID 80000001h ECX[22]); si no, hojas 80000005h/80000006h.
; Lo que no se detecte toma un valor típico y se marca en `supuestos`.
; -----------------------------------------------------------------------------
cache_detect:
    push    rbx
    push    r12                         ; r12 = máxima hoja básica
    push    r13                         ; r13 = primeros 4 bytes del fabricante
    xor     rax, rax
    mov     [cache_l1d], rax
    mov     [cache_l2], rax
    mov     [cache_l3], rax
    mov     [supuestos], rax
    xor     eax, eax
    xor     ecx, ecx
    cpuid
    mov     r12d, eax
    mov     r13d, ebx                   ; "Genu" / "Auth" / "Hygo"
    mov     eax, 0x80000000
    xor     ecx, ecx
    cpuid
    mov     [max_ext], rax
    cmp     r13d, 'Auth'                ; AuthenticAMD
    je      .amd
    cmp     r13d, 'Hygo'                ; HygonGenuine (derivado de AMD)
    je      .amd
    cmp     r12d, 4                     ; Intel y otros: hoja 4
    jb      .legado
    mov     rdi, 4
    call    recorrer_hoja
    jmp     .completar
.amd:
    cmp     dword [max_ext], 0x8000001D
    jb      .legado
    mov     eax, 0x80000001
    xor     ecx, ecx
    cpuid
    bt      ecx, 22                     ; TOPOEXT: existe la hoja 8000001Dh
    jnc     .legado
    mov     rdi, 0x8000001D
    call    recorrer_hoja
    jmp     .completar
.legado:
    cmp     dword [max_ext], 0x80000006
    jb      .completar
    mov     eax, 0x80000005
    xor     ecx, ecx
    cpuid
    shr     ecx, 24                     ; ECX[31:24] = L1 de datos en KB
    imul    rcx, rcx, KIB
    mov     [cache_l1d], rcx
    mov     eax, 0x80000006
    xor     ecx, ecx
    cpuid
    mov     r8d, ecx
    shr     r8d, 16                     ; ECX[31:16] = L2 en KB
    imul    r8, r8, KIB
    mov     [cache_l2], r8
    shr     edx, 18                     ; EDX[31:18] = L3 en unidades de 512 KB
    imul    rdx, rdx, 512 * KIB
    mov     [cache_l3], rdx
.completar:
    cmp     qword [cache_l1d], 0
    jne     .l2
    mov     qword [cache_l1d], 32 * KIB
    or      qword [supuestos], SUPUESTO_L1
.l2:
    cmp     qword [cache_l2], 0
    jne     .l3
    mov     qword [cache_l2], 256 * KIB
    or      qword [supuestos], SUPUESTO_L2
.l3:
    cmp     qword [cache_l3], 0
    jne     .fin
    mov     rax, [cache_l2]             ; sin L3: suponer max(8 MiB, 4 x L2) para
    shl     rax, 2                      ; que su conjunto de trabajo quede fuera de L2
    mov     rcx, 8 * MIB
    cmp     rax, rcx
    cmovb   rax, rcx
    mov     [cache_l3], rax
    or      qword [supuestos], SUPUESTO_L3
.fin:
    pop     r13
    pop     r12
    pop     rbx
    ret

; -----------------------------------------------------------------------------
; reservar — memoria alineada a 2 MiB con páginas grandes si el kernel puede
; Entradas : rdi = bytes
; Salidas  : rax = dirección alineada, o 0 si mmap falló
; Notas    : se pide 2 MiB de más para poder alinear; madvise(MADV_HUGEPAGE)
;            reduce los fallos de TLB que inflarían la latencia medida.
; -----------------------------------------------------------------------------
reservar:
    push    rbx                         ; rbx = bytes útiles
    mov     rbx, rdi
    lea     rsi, [rdi + ALINEACION_HUGE]
    mov     [raw_tam], rsi
    mov     rax, SYS_MMAP
    xor     rdi, rdi
    mov     rdx, PROT_READ | PROT_WRITE
    mov     r10, MAP_PRIVATE | MAP_ANONYMOUS
    mov     r8, -1
    xor     r9, r9
    syscall
    CHECK_SYSCALL .error
    mov     [raw_base], rax
    add     rax, ALINEACION_HUGE - 1
    and     rax, -ALINEACION_HUGE       ; redondear hacia arriba a 2 MiB
    push    rax
    mov     rdi, rax
    mov     rsi, rbx
    mov     rdx, MADV_HUGEPAGE
    mov     rax, SYS_MADVISE
    syscall                             ; si falla (THP desactivado) se sigue igual
    pop     rax
    pop     rbx
    ret
.error:
    xor     rax, rax
    pop     rbx
    ret

; -----------------------------------------------------------------------------
; liberar — munmap del último bloque reservado
; -----------------------------------------------------------------------------
liberar:
    mov     rax, SYS_MUNMAP
    mov     rdi, [raw_base]
    mov     rsi, [raw_tam]
    syscall
    ret

; -----------------------------------------------------------------------------
; armar_cadena — convierte un buffer en una lista enlazada cíclica aleatoria
; Entradas : rdi = base (alineada a 64), rsi = cantidad de nodos (>= 2)
; Salidas  : rax = primer nodo
; Método   : 1) nodo[k] = k
;            2) Sattolo: para i = n-1 .. 1, j = aleatorio en [0, i-1],
;               intercambiar nodo[i] y nodo[j]. El resultado es una
;               permutación con UN SOLO ciclo que pasa por todos los nodos.
;            3) nodo[k] = base + nodo[k] * 64 (índice -> puntero)
;            Aleatorio en [0, i-1] = parte alta de (xorshift64 * i), sin división.
; -----------------------------------------------------------------------------
armar_cadena:
    xor     rcx, rcx
.identidad:
    mov     rax, rcx
    shl     rax, 6                      ; desplazamiento del nodo = k * 64
    mov     [rdi + rax], rcx
    inc     rcx
    cmp     rcx, rsi
    jb      .identidad

    mov     r8, [rng]                   ; estado del generador
    lea     rcx, [rsi - 1]              ; i = n - 1
.sattolo:
    test    rcx, rcx
    jz      .punteros
    mov     rax, r8                     ; xorshift64 (Marsaglia, 2003)
    shl     rax, 13
    xor     r8, rax
    mov     rax, r8
    shr     rax, 7
    xor     r8, rax
    mov     rax, r8
    shl     rax, 17
    xor     r8, rax
    mov     rax, r8
    mul     rcx                         ; rdx = floor(aleatorio * i / 2^64) en [0, i-1]
    mov     r9, rcx
    shl     r9, 6
    mov     r10, rdx
    shl     r10, 6
    mov     r11, [rdi + r9]             ; intercambio nodo[i] <-> nodo[j]
    mov     rax, [rdi + r10]
    mov     [rdi + r9], rax
    mov     [rdi + r10], r11
    dec     rcx
    jmp     .sattolo

.punteros:
    mov     [rng], r8
    xor     rcx, rcx
.convertir:
    mov     rax, rcx
    shl     rax, 6
    mov     r9, [rdi + rax]             ; índice del siguiente
    shl     r9, 6
    add     r9, rdi                     ; -> dirección del siguiente
    mov     [rdi + rax], r9
    inc     rcx
    cmp     rcx, rsi
    jb      .convertir
    mov     rax, rdi
    ret

; -----------------------------------------------------------------------------
; calentar — recorre la cadena para traer los datos (y las entradas de TLB)
; Entradas : rdi = nodo inicial, rsi = pasos
; -----------------------------------------------------------------------------
calentar:
    mov     rax, rdi
.paso:
    mov     rax, [rax]
    dec     rsi
    jnz     .paso
    ret

; -----------------------------------------------------------------------------
; medir_overhead — mínimo de MUESTRAS_OVERHEAD mediciones vacías -> [overhead]
; -----------------------------------------------------------------------------
medir_overhead:
    push    rbx
    push    r12
    push    r13
    mov     r12, -1
    mov     r13, MUESTRAS_OVERHEAD
.muestra:
    call    tsc_begin
    mov     rbx, rax
    call    tsc_end
    sub     rax, rbx
    cmp     rax, r12
    cmovb   r12, rax
    dec     r13
    jnz     .muestra
    mov     [overhead], r12
    pop     r13
    pop     r12
    pop     rbx
    ret

; -----------------------------------------------------------------------------
; POR_ACCESO nombre, instrucción — genera una medición "TSC antes y después
; de cada acceso". Entradas: rdi = puntero inicial, rsi = muestras.
; Salidas: rax = ciclos x 10 por acceso (promedio sin atípicos - overhead)
; -----------------------------------------------------------------------------
%macro POR_ACCESO 2
%1:
    push    rbx                         ; rbx = TSC inicial
    push    r12                         ; r12 = puntero de la cadena
    push    r13                         ; r13 = muestras restantes
    push    r14                         ; r14 = suma de ciclos
    push    r15                         ; r15 = muestras válidas
    mov     r12, rdi
    mov     r13, rsi
    xor     r14, r14
    xor     r15, r15
%%muestra:
    call    tsc_begin                   ; lfence; rdtsc; lfence
    mov     rbx, rax
    %2                                  ; el acceso medido
    call    tsc_end                     ; rdtscp espera a que el acceso termine
    sub     rax, rbx
    cmp     rax, ATIPICO
    ja      %%descartar
    add     r14, rax
    inc     r15
%%descartar:
    dec     r13
    jnz     %%muestra
    mov     rdi, r14
    mov     rsi, 10
    mov     rdx, r15
    call    mul_div                     ; promedio x 10
    mov     rcx, [overhead]
    imul    rcx, rcx, 10
    sub     rax, rcx                    ; descontar el costo de medir
    jae     %%fin
    xor     rax, rax
%%fin:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
%endmacro

POR_ACCESO acceso_memoria, {mov r12, [r12]}     ; una carga dependiente
POR_ACCESO acceso_registro, {add r12, r13}      ; una suma entre registros

; -----------------------------------------------------------------------------
; cadena_memoria — latencia promedio de CARGAS_CADENA cargas encadenadas
; Entradas : rdi = nodo inicial
; Salidas  : rax = ciclos x 10 por carga
; -----------------------------------------------------------------------------
cadena_memoria:
    push    rbx
    push    r12
    push    r13
    mov     r12, rdi
    call    tsc_begin
    mov     rbx, rax
    mov     rax, r12
    mov     rcx, CARGAS_CADENA / 8
.vuelta:
    mov     rax, [rax]                  ; 8 cargas, cada una necesita la anterior
    mov     rax, [rax]
    mov     rax, [rax]
    mov     rax, [rax]
    mov     rax, [rax]
    mov     rax, [rax]
    mov     rax, [rax]
    mov     rax, [rax]
    dec     rcx
    jnz     .vuelta
    mov     r13, rax                    ; conservar la dependencia hasta tsc_end
    call    tsc_end
    sub     rax, rbx
    mov     rdi, rax
    mov     rsi, 10
    mov     rdx, CARGAS_CADENA
    call    mul_div
    pop     r13
    pop     r12
    pop     rbx
    ret

; -----------------------------------------------------------------------------
; cadena_registro — latencia de una suma registro-registro dependiente
; Salidas  : rax = ciclos x 10 por suma
; -----------------------------------------------------------------------------
cadena_registro:
    push    rbx
    call    tsc_begin
    mov     rbx, rax
    xor     rax, rax
    mov     rdx, 1
    mov     rcx, CARGAS_CADENA / 8
.vuelta:
    add     rax, rdx                    ; cada suma depende de la anterior (rax)
    add     rax, rdx
    add     rax, rdx
    add     rax, rdx
    add     rax, rdx
    add     rax, rdx
    add     rax, rdx
    add     rax, rdx
    dec     rcx
    jnz     .vuelta
    call    tsc_end
    sub     rax, rbx
    mov     rdi, rax
    mov     rsi, 10
    mov     rdx, CARGAS_CADENA
    call    mul_div
    pop     rbx
    ret

; -----------------------------------------------------------------------------
; secuencial — recorre un buffer línea por línea en orden
; Entradas : rdi = base, rsi = líneas, rdx = 1 para usar prefetcht0
; Salidas  : rax = ciclos x 10 por línea
; Notas    : las cargas son independientes entre sí (la dirección no depende
;            del dato): mide el ritmo al que llegan líneas desde RAM con el
;            prefetcher de hardware ayudando, no la latencia de una sola.
; -----------------------------------------------------------------------------
secuencial:
    push    rbx                         ; rbx = TSC inicial
    push    r12                         ; r12 = base
    push    r13                         ; r13 = fin (bytes)
    push    r14                         ; r14 = prefetch sí/no
    push    r15                         ; r15 = líneas
    mov     r12, rdi
    mov     r15, rsi
    mov     r13, rsi
    shl     r13, 6
    mov     r14, rdx
    call    tsc_begin
    mov     rbx, rax
    xor     rax, rax
    xor     rcx, rcx
    test    r14, r14
    jnz     .con_prefetch
.sin_prefetch:
    add     rax, [r12 + rcx]            ; una carga por línea
    add     rcx, LINEA
    cmp     rcx, r13
    jb      .sin_prefetch
    jmp     .medido
.con_prefetch:
    prefetcht0 [r12 + rcx + 512]        ; pedir 8 líneas por delante
    add     rax, [r12 + rcx]
    add     rcx, LINEA
    cmp     rcx, r13
    jb      .con_prefetch
.medido:
    call    tsc_end
    sub     rax, rbx
    mov     rdi, rax
    mov     rsi, 10
    mov     rdx, r15
    call    mul_div
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; -----------------------------------------------------------------------------
; medir_nivel — arma la cadena del nivel i, la calienta y la mide
; Entradas : rdi = índice de nivel (1..4)
; Salidas  : rax = 0 ok, 1 si no se pudo reservar memoria
; Notas    : en el nivel RAM también corre la demostración de prefetch.
; -----------------------------------------------------------------------------
medir_nivel:
    push    rbx                         ; rbx = nivel
    push    r12                         ; r12 = base
    push    r13                         ; r13 = nodos
    mov     rbx, rdi
    lea     rax, [trabajo]
    mov     rdi, [rax + rbx*8]
    call    reservar
    test    rax, rax
    jz      .error
    mov     r12, rax
    lea     rax, [trabajo]
    mov     r13, [rax + rbx*8]
    shr     r13, 6                      ; nodos de 64 B
    mov     rdi, r12
    mov     rsi, r13
    call    armar_cadena
    mov     rdi, r12
    mov     rsi, r13
    cmp     rsi, CALENTAR_MAX
    jbe     .calentar
    mov     rsi, CALENTAR_MAX
.calentar:
    call    calentar
    mov     rdi, r12
    mov     rsi, MUESTRAS_ACCESO
    call    acceso_memoria
    lea     rcx, [lat_acceso]
    mov     [rcx + rbx*8], rax
    mov     rdi, r12
    call    cadena_memoria
    lea     rcx, [lat_cadena]
    mov     [rcx + rbx*8], rax
    cmp     rbx, NIVELES - 1
    jne     .liberar
    mov     [pf_aleatorio], rax         ; RAM: la cadena es el caso aleatorio
    mov     rdi, r12
    mov     rsi, r13
    xor     rdx, rdx
    call    secuencial
    mov     [pf_secuencial], rax
    mov     rdi, r12
    mov     rsi, r13
    mov     rdx, 1
    call    secuencial
    mov     [pf_prefetch], rax
.liberar:
    call    liberar
    xor     rax, rax
    jmp     .fin
.error:
    mov     rax, 1
.fin:
    pop     r13
    pop     r12
    pop     rbx
    ret

; -----------------------------------------------------------------------------
; out_ciclos — imprime un valor x10 con un decimal en un campo de `ancho`
; Entradas : rdi = valor x 10, rsi = ancho
; -----------------------------------------------------------------------------
out_ciclos:
    push    rbx                         ; rbx = inicio del campo
    push    r12                         ; r12 = ancho
    push    r13
    mov     r13, rdi
    mov     r12, rsi
    call    out_contador
    mov     rbx, rax
    mov     rdi, r13
    mov     rsi, 1
    call    out_fixed
    mov     rdi, rbx
    mov     rsi, r12
    call    out_pad_hasta
    pop     r13
    pop     r12
    pop     rbx
    ret

; -----------------------------------------------------------------------------
; mod_cache_run — punto de entrada del módulo M5
; Salidas  : rax = 0 ok, 1 si no se pudo reservar memoria
; -----------------------------------------------------------------------------
mod_cache_run:
    push    rbx
    push    r12
    push    r13
    mov     rax, SEMILLA
    mov     [rng], rax
    call    cache_detect
    call    medir_overhead

    ; ---- memoria total (columna de RAM) -----------------------------------------
    mov     qword [ram_total], 0
    mov     rax, SYS_SYSINFO
    lea     rdi, [info_sistema]
    syscall
    CHECK_SYSCALL .sin_sysinfo
    mov     eax, [info_sistema + SI_MEM_UNIT]
    imul    rax, [info_sistema + SI_TOTALRAM]
    mov     [ram_total], rax
.sin_sysinfo:

    ; ---- conjuntos de trabajo ---------------------------------------------------
    mov     rax, [cache_l1d]
    shr     rax, 1
    mov     [trabajo + 8], rax          ; L1: la mitad de L1
    mov     rax, [cache_l1d]
    add     rax, [cache_l2]
    shr     rax, 1
    mov     [trabajo + 16], rax         ; L2: entre L1 y L2
    mov     rax, [cache_l2]
    add     rax, [cache_l3]
    shr     rax, 1                      ; L3: entre L2 y L3 ...
    mov     rcx, [cache_l2]
    shl     rcx, 2
    cmp     rax, rcx
    cmova   rax, rcx                    ; ... pero como mucho 4 x L2: la L3 es
    mov     [trabajo + 24], rax         ; compartida y en un servidor con otros
                                        ; procesos (o VMs) sólo una parte está
                                        ; disponible; un conjunto más grande
                                        ; terminaría midiendo RAM
    mov     rax, [cache_l3]
    shl     rax, 2                      ; RAM: 4 x L3 ...
    mov     rcx, RAM_MIN
    cmp     rax, rcx
    cmovb   rax, rcx                    ; ... al menos 64 MiB ...
    mov     rcx, RAM_MAX
    cmp     rax, rcx
    cmova   rax, rcx                    ; ... y como mucho 256 MiB
    mov     [trabajo + 32], rax
    mov     rcx, 1
.alinear:                               ; múltiplos de 64 B (nodos completos)
    lea     rdx, [trabajo]
    and     qword [rdx + rcx*8], -LINEA
    inc     rcx
    cmp     rcx, NIVELES
    jb      .alinear

    ; ---- mediciones -------------------------------------------------------------
    xor     rdi, rdi                    ; valor inicial de la cadena de sumas
    mov     rsi, MUESTRAS_ACCESO
    call    acceso_registro
    mov     [lat_acceso], rax
    call    cadena_registro
    mov     [lat_cadena], rax
    mov     rbx, 1
.nivel:
    mov     rdi, rbx
    call    medir_nivel
    test    rax, rax
    jnz     .error
    inc     rbx
    cmp     rbx, NIVELES
    jb      .nivel

    ; ---- tabla --------------------------------------------------------------------
    PRINT   t_encabezado
    xor     rbx, rbx
.fila:
    lea     rax, [nombres_nivel]
    mov     rdi, [rax + rbx*8]
    lea     rax, [largos_nivel]
    mov     rsi, [rax + rbx*8]
    call    out_str
    call    out_contador
    mov     r12, rax                    ; inicio de la columna "Tamaño"
    test    rbx, rbx
    jnz     .con_tamano
    PRINT   t_guion
    jmp     .tamano_listo
.con_tamano:
    cmp     rbx, NIVELES - 1
    jne     .tam_cache
    mov     rdi, [ram_total]
    call    out_size
    jmp     .tamano_listo
.tam_cache:
    lea     rax, [cache_l1d - 8]        ; cache_l1d, cache_l2, cache_l3 son contiguos
    mov     rdi, [rax + rbx*8]
    call    out_size
    mov     rax, [supuestos]
    lea     rcx, [rbx - 1]
    bt      rax, rcx                    ; ¿este tamaño fue supuesto?
    jnc     .tamano_listo
    PRINT   t_supuesto
.tamano_listo:
    mov     rdi, r12
    mov     rsi, 12
    call    out_pad_hasta
    lea     rax, [lat_acceso]
    mov     rdi, [rax + rbx*8]
    mov     rsi, 13
    call    out_ciclos
    lea     rax, [lat_cadena]
    mov     rdi, [rax + rbx*8]
    mov     rsi, 1
    call    out_ciclos
    call    out_nl
    inc     rbx
    cmp     rbx, NIVELES
    jb      .fila

    ; ---- razón RAM / L1 (cadena) -----------------------------------------------
    PRINT   l_razon
    mov     rax, [lat_cadena + 32]
    xor     rdx, rdx
    mov     rcx, [lat_cadena + 8]
    test    rcx, rcx
    jz      .sin_razon
    div     rcx
.sin_razon:
    mov     rdi, rax
    call    out_u64
    PRINT   t_x
    call    out_nl

    ; ---- conjuntos de trabajo -----------------------------------------------------
    PRINT   l_trabajo
    mov     rbx, 1
.trab:
    cmp     rbx, 1
    je      .trab_sin_coma
    PRINT   t_coma
.trab_sin_coma:
    lea     rax, [nombres_trab]
    mov     rdi, [rax + rbx*8]
    call    out_cstr
    PRINT   t_sp
    lea     rax, [trabajo]
    mov     rdi, [rax + rbx*8]
    call    out_size
    inc     rbx
    cmp     rbx, NIVELES
    jb      .trab
    call    out_nl
    cmp     qword [supuestos], 0
    je      .prefetch
    PRINT   t_nota_sup

    ; ---- demostración de prefetch -------------------------------------------------
.prefetch:
    call    out_nl
    PRINT   l_pref
    PRINT   l_aleatorio
    mov     rdi, [pf_aleatorio]
    mov     rsi, 1
    call    out_ciclos
    call    out_nl
    PRINT   l_secuencial
    mov     rdi, [pf_secuencial]
    mov     rsi, 1
    call    out_ciclos
    call    out_nl
    PRINT   l_seq_pf
    mov     rdi, [pf_prefetch]
    mov     rsi, 1
    call    out_ciclos
    call    out_nl
    xor     rax, rax
    jmp     .fin

.error:
    PRINT   t_error
    mov     rax, 1
.fin:
    pop     r13
    pop     r12
    pop     rbx
    ret
