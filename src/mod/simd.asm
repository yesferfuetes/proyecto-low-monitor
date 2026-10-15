; =============================================================================
; simd.asm — M6: Operaciones SIMD (SSE2 / AVX2 / AVX-512)
; -----------------------------------------------------------------------------
; Proyecto : LowMonitor
; Exporta  : mod_simd_run
;
; SIMD (Single Instruction, Multiple Data): una instrucción opera sobre
; varios datos empaquetados en un registro ancho:
;   XMM 128 bits = 4 floats (SSE/SSE2)
;   YMM 256 bits = 8 floats (AVX/AVX2)
;   ZMM 512 bits = 16 floats (AVX-512), con registros de máscara k0-k7
;
; Para cada ISA disponible se ejecutan suma, multiplicación y comparación
; vectorizadas sobre arreglos de floats y se comparan BIT A BIT con una
; versión escalar de referencia (IEEE-754 da el mismo resultado por elemento
; sin importar el ancho del vector). Luego se mide C = A*B + C en GFLOPS.
;
; Despacho seguro: cada ruta sólo se ejecuta si cpu_features (M1) indica que
; la CPU tiene la extensión Y que el SO guarda esos registros (XCR0). Si no,
; se informa y se continúa: nunca se provoca #UD (SIGILL).
; Tras usar YMM/ZMM se ejecuta VZEROUPPER: evita la penalización de transición
; entre código AVX y SSE heredado.
;
; Nota: las operaciones de punto flotante sobre YMM pertenecen a AVX; AVX2
; agrega las enteras de 256 bits. La ruta de 256 bits se habilita con AVX2 +
; soporte del SO porque así la nombra el enunciado.
;
; Referencias: Intel SDM Vol. 1 cap. 10-15 (SSE, AVX, AVX-512); Vol. 2
;              (ADDPS, MULPS, CMPPS, MOVMSKPS, VFMADD231PS, KMOVW, MOVNTPS).
; =============================================================================

default rel

%include "lib.inc"
%include "cpu.inc"

extern cpu_detect, cpu_features, perf_calibrar, tsc_hz

N                   equ 2048          ; floats por arreglo (8 KiB)
BYTES               equ N * 4
REPS                equ 40000         ; repeticiones del benchmark
FLOP_BENCH          equ 2 * N * REPS  ; mult + suma por elemento y repetición
CUENTA_ESPERADA     equ N - 3         ; A[i] > B[i]  <=>  0.75 i > 2  <=>  i >= 3
GT_OQ               equ 0x1E          ; predicado de vcmpps: mayor que, ordenado, sin señal
BLOQUE_NT           equ 64 * 1024 * 1024
NS_A_MBS            equ 1000          ; bytes * 1000 / ns = MB/s

; Registro de la tabla de ISAs
ISA_NOMBRE          equ 0
ISA_LARGO           equ 8
ISA_LANES           equ 16
ISA_CPU             equ 24            ; bits de cpu_features que debe tener la CPU
ISA_SO              equ 32            ; bits de soporte del SO
ISA_SUMA            equ 40
ISA_MULT            equ 48
ISA_COMP            equ 56
ISA_BENCH           equ 64
ISA_CORTO           equ 72            ; nombre corto (cadena C)
ISA_TAM             equ 80
NUM_ISAS            equ 3

; =============================================================================
section .data
; Constantes, strings, tablas de datos
; =============================================================================
STR n_escalar,  "Escalar (referencia):     "
STR n_sse2,     "SSE2 (128b, 4 lanes):     "
STR n_avx2,     "AVX2 (256b, 8 lanes):     "
STR n_avx512,   "AVX-512 (512b, 16 lanes): "
STR n_fma,      "FMA (256b):               "
STR l_avx2_hab, "AVX2 habilitado:          "
STR l_through,  "Throughput:               "
STR l_bench,    "Benchmark:                "
STR l_nt_norm,  "Escritura normal 64 MB:   "
STR l_nt_nt,    "Escritura NT 64 MB:       "

STR t_si,       "Sí   "
STR t_suma,     "suma "
STR t_mult,     "  mult "
STR t_comp,     "  comp "
STR t_ok,       "[OK]"
STR t_error,    "[ERROR]"
STR t_gflops,   " GFLOPS  x"
STR t_gflops_s, " GFLOPS"
STR t_dos_esp,  "  "
STR t_no_cpu,   "No soportado por la CPU"
STR t_no_so,    "No habilitado por el SO"
STR t_ops,      " operaciones paralelas ("
STR t_abre,     " ("
STR t_cierra,   ")"
STR t_mbs,      " MB/s"
STR t_err_mmap, "[ERROR] no se pudo reservar memoria para la prueba NT", 10

c_sse2      db "SSE2", 0
c_avx2      db "AVX2", 0
c_avx512    db "AVX-512", 0
c_escalar   db "escalar", 0
c_fma       db "FMA (256b)", 0

align 4
f_medio     dd 0.5
f_cuarto    dd 0.25
f_dos       dd 2.0
f_uno       dd 1.0

align 8
tabla_isas:
    dq n_sse2, n_sse2_len, 4
    dq 1 << FEAT_SSE2, 0
    dq sse_suma, sse_mult, sse_comp, sse_bench, c_sse2
    dq n_avx2, n_avx2_len, 8
    dq (1 << FEAT_AVX2) | (1 << FEAT_AVX), 1 << FEAT_OS_AVX
    dq avx2_suma, avx2_mult, avx2_comp, avx2_bench, c_avx2
    dq n_avx512, n_avx512_len, 16
    dq 1 << FEAT_AVX512F, 1 << FEAT_OS_AVX512
    dq avx512_suma, avx512_mult, avx512_comp, avx512_bench, c_avx512

; =============================================================================
section .bss align=64
; Variables reservadas (buffers, contadores)
; (align=64: los arreglos quedan alineados para movaps/vmovaps de 512 bits)
; =============================================================================
arr_a           resb BYTES
arr_b           resb BYTES
arr_c           resb BYTES
ref_suma        resb BYTES              ; resultados escalares de referencia
ref_mult        resb BYTES
cuenta_ref      resq 1
ciclos_escalar  resq 1
usar_popcnt     resq 1
mejor_lanes     resq 1                  ; ISA más ancha disponible
mejor_nombre    resq 1
max_gflops      resq 1                  ; mejor benchmark (x100)
max_nombre      resq 1
avx2_ok         resq 1
hubo_error      resq 1                  ; 1 si alguna verificación falló

; =============================================================================
section .text
; =============================================================================
global mod_simd_run

; -----------------------------------------------------------------------------
; BASES — carga en r8, r9, r10 las direcciones de A, B, C y pone rcx = 0
; (con default rel no se puede indexar una etiqueta directamente)
; -----------------------------------------------------------------------------
%macro BASES 0
    lea     r8, [arr_a]
    lea     r9, [arr_b]
    lea     r10, [arr_c]
    xor     rcx, rcx
%endmacro

; -----------------------------------------------------------------------------
; bits_en — cantidad de bits en 1
; Entradas : rdi = valor     Salidas: rax     Modifica: rdx (respeta rcx, r8-r11)
; -----------------------------------------------------------------------------
bits_en:
    cmp     qword [usar_popcnt], 0
    je      .software
    popcnt  rax, rdi
    ret
.software:
    xor     rax, rax
.bit:
    test    rdi, rdi
    jz      .fin
    lea     rdx, [rdi - 1]
    and     rdi, rdx                    ; borrar el 1 más bajo
    inc     rax
    jmp     .bit
.fin:
    ret

; =============================================================================
; Escalar (referencia): un float por instrucción
; =============================================================================
esc_suma:
    BASES
.vuelta:
    movss   xmm0, [r8 + rcx*4]
    addss   xmm0, [r9 + rcx*4]          ; un solo float
    movss   [r10 + rcx*4], xmm0
    inc     rcx
    cmp     rcx, N
    jb      .vuelta
    ret

esc_mult:
    BASES
.vuelta:
    movss   xmm0, [r8 + rcx*4]
    mulss   xmm0, [r9 + rcx*4]
    movss   [r10 + rcx*4], xmm0
    inc     rcx
    cmp     rcx, N
    jb      .vuelta
    ret

; Salidas: rax = cantidad de i con A[i] > B[i]
esc_comp:
    BASES
    xor     r11, r11
.vuelta:
    movss   xmm0, [r8 + rcx*4]
    comiss  xmm0, [r9 + rcx*4]          ; fija ZF/CF como una comparación sin signo
    jbe     .no_mayor
    inc     r11
.no_mayor:
    inc     rcx
    cmp     rcx, N
    jb      .vuelta
    mov     rax, r11
    ret

esc_bench:
    mov     rdx, REPS
.rep:
    BASES
.vuelta:
    movss   xmm0, [r8 + rcx*4]
    mulss   xmm0, [r9 + rcx*4]          ; A*B
    addss   xmm0, [r10 + rcx*4]         ; + C
    movss   [r10 + rcx*4], xmm0
    inc     rcx
    cmp     rcx, N
    jb      .vuelta
    dec     rdx
    jnz     .rep
    ret

; =============================================================================
; SSE2: XMM de 128 bits = 4 floats por instrucción
; =============================================================================
sse_suma:
    BASES
.vuelta:
    movaps  xmm0, [r8 + rcx]            ; 4 floats alineados a 16
    addps   xmm0, [r9 + rcx]            ; 4 sumas en paralelo
    movaps  [r10 + rcx], xmm0
    add     rcx, 16
    cmp     rcx, BYTES
    jb      .vuelta
    ret

sse_mult:
    BASES
.vuelta:
    movaps  xmm0, [r8 + rcx]
    mulps   xmm0, [r9 + rcx]            ; 4 productos en paralelo
    movaps  [r10 + rcx], xmm0
    add     rcx, 16
    cmp     rcx, BYTES
    jb      .vuelta
    ret

sse_comp:
    BASES
    xor     r11, r11
.vuelta:
    movaps  xmm1, [r9 + rcx]            ; B
    cmpltps xmm1, [r8 + rcx]            ; B < A (= A > B): cada lane queda en 1s o 0s
    movmskps edi, xmm1                  ; bit de signo de cada lane -> 4 bits en edi
    call    bits_en
    add     r11, rax
    add     rcx, 16
    cmp     rcx, BYTES
    jb      .vuelta
    mov     rax, r11
    ret

sse_bench:
    mov     rdx, REPS
.rep:
    BASES
.vuelta:                                ; desenrollado x4: 4 vectores independientes
    movaps  xmm0, [r8 + rcx]
    movaps  xmm1, [r8 + rcx + 16]
    movaps  xmm2, [r8 + rcx + 32]
    movaps  xmm3, [r8 + rcx + 48]
    mulps   xmm0, [r9 + rcx]
    mulps   xmm1, [r9 + rcx + 16]
    mulps   xmm2, [r9 + rcx + 32]
    mulps   xmm3, [r9 + rcx + 48]
    addps   xmm0, [r10 + rcx]
    addps   xmm1, [r10 + rcx + 16]
    addps   xmm2, [r10 + rcx + 32]
    addps   xmm3, [r10 + rcx + 48]
    movaps  [r10 + rcx], xmm0
    movaps  [r10 + rcx + 16], xmm1
    movaps  [r10 + rcx + 32], xmm2
    movaps  [r10 + rcx + 48], xmm3
    add     rcx, 64
    cmp     rcx, BYTES
    jb      .vuelta
    dec     rdx
    jnz     .rep
    ret

; =============================================================================
; VEX — genera suma, mult. y benchmark para YMM (AVX2) o ZMM (AVX-512)
;   %1 = prefijo de nombre, %2 = familia de registro (ymm | zmm), %3 = bytes
; Sintaxis de 3 operandos: vaddps destino, fuente1, fuente2 (no destruye fuentes)
; =============================================================================
%macro VEX 3
%1_suma:
    BASES
%%suma:
    vmovaps %{2}0, [r8 + rcx]
    vaddps  %{2}0, %{2}0, [r9 + rcx]
    vmovaps [r10 + rcx], %{2}0
    add     rcx, %3
    cmp     rcx, BYTES
    jb      %%suma
    vzeroupper                          ; limpiar la parte alta antes de volver a SSE
    ret

%1_mult:
    BASES
%%mult:
    vmovaps %{2}0, [r8 + rcx]
    vmulps  %{2}0, %{2}0, [r9 + rcx]
    vmovaps [r10 + rcx], %{2}0
    add     rcx, %3
    cmp     rcx, BYTES
    jb      %%mult
    vzeroupper
    ret

%1_bench:
    mov     rdx, REPS
%%rep:
    BASES
%%vuelta:                               ; desenrollado x4
    vmovaps %{2}0, [r8 + rcx]
    vmovaps %{2}1, [r8 + rcx + %3]
    vmovaps %{2}2, [r8 + rcx + 2*%3]
    vmovaps %{2}3, [r8 + rcx + 3*%3]
    vmulps  %{2}0, %{2}0, [r9 + rcx]
    vmulps  %{2}1, %{2}1, [r9 + rcx + %3]
    vmulps  %{2}2, %{2}2, [r9 + rcx + 2*%3]
    vmulps  %{2}3, %{2}3, [r9 + rcx + 3*%3]
    vaddps  %{2}0, %{2}0, [r10 + rcx]
    vaddps  %{2}1, %{2}1, [r10 + rcx + %3]
    vaddps  %{2}2, %{2}2, [r10 + rcx + 2*%3]
    vaddps  %{2}3, %{2}3, [r10 + rcx + 3*%3]
    vmovaps [r10 + rcx], %{2}0
    vmovaps [r10 + rcx + %3], %{2}1
    vmovaps [r10 + rcx + 2*%3], %{2}2
    vmovaps [r10 + rcx + 3*%3], %{2}3
    add     rcx, 4*%3
    cmp     rcx, BYTES
    jb      %%vuelta
    dec     rdx
    jnz     %%rep
    vzeroupper
    ret
%endmacro

VEX avx2,   ymm, 32                     ; 8 floats por instrucción
VEX avx512, zmm, 64                     ; 16 floats por instrucción

; AVX2: comparación -> máscara de 8 bits con vmovmskps
avx2_comp:
    BASES
    xor     r11, r11
.vuelta:
    vmovaps ymm0, [r8 + rcx]
    vcmpps  ymm1, ymm0, [r9 + rcx], GT_OQ   ; A > B en 8 lanes
    vmovmskps edi, ymm1                 ; 8 bits
    call    bits_en
    add     r11, rax
    add     rcx, 32
    cmp     rcx, BYTES
    jb      .vuelta
    vzeroupper
    mov     rax, r11
    ret

; AVX-512: la comparación escribe directamente un registro de máscara k1
avx512_comp:
    BASES
    xor     r11, r11
.vuelta:
    vmovaps zmm0, [r8 + rcx]
    vcmpps  k1, zmm0, [r9 + rcx], GT_OQ ; 16 bits de resultado en k1
    kmovw   edi, k1                     ; máscara -> registro general
    call    bits_en
    add     r11, rax
    add     rcx, 64
    cmp     rcx, BYTES
    jb      .vuelta
    vzeroupper
    mov     rax, r11
    ret

; FMA: C = A*B + C en una sola instrucción y un solo redondeo
fma_bench:
    mov     rdx, REPS
.rep:
    BASES
.vuelta:
    vmovaps ymm0, [r10 + rcx]
    vmovaps ymm1, [r10 + rcx + 32]
    vmovaps ymm2, [r10 + rcx + 64]
    vmovaps ymm3, [r10 + rcx + 96]
    vmovaps ymm4, [r8 + rcx]
    vmovaps ymm5, [r8 + rcx + 32]
    vmovaps ymm6, [r8 + rcx + 64]
    vmovaps ymm7, [r8 + rcx + 96]
    vfmadd231ps ymm0, ymm4, [r9 + rcx]      ; ymm0 += ymm4 * B  (2 FLOP por lane)
    vfmadd231ps ymm1, ymm5, [r9 + rcx + 32]
    vfmadd231ps ymm2, ymm6, [r9 + rcx + 64]
    vfmadd231ps ymm3, ymm7, [r9 + rcx + 96]
    vmovaps [r10 + rcx], ymm0
    vmovaps [r10 + rcx + 32], ymm1
    vmovaps [r10 + rcx + 64], ymm2
    vmovaps [r10 + rcx + 96], ymm3
    add     rcx, 128
    cmp     rcx, BYTES
    jb      .vuelta
    dec     rdx
    jnz     .rep
    vzeroupper
    ret

; =============================================================================
; Utilidades del módulo
; =============================================================================

; inicializar — A[i] = i * 0.5 ; B[i] = 2.0 - i * 0.25
inicializar:
    BASES
    movss   xmm2, [f_medio]
    movss   xmm3, [f_cuarto]
    movss   xmm4, [f_dos]
.vuelta:
    cvtsi2ss xmm0, rcx                  ; entero de 64 bits -> float
    movaps  xmm1, xmm0
    mulss   xmm0, xmm2
    movss   [r8 + rcx*4], xmm0
    mulss   xmm1, xmm3
    movaps  xmm0, xmm4
    subss   xmm0, xmm1
    movss   [r9 + rcx*4], xmm0
    inc     rcx
    cmp     rcx, N
    jb      .vuelta
    ret

; limpiar_c — C = 0
limpiar_c:
    lea     rdi, [arr_c]
    xor     rax, rax
    mov     rcx, BYTES
    rep     stosb
    ret

; copiar_c — rdi = destino: copia C
copiar_c:
    lea     rsi, [arr_c]
    mov     rcx, BYTES
    rep     movsb
    ret

; igual_c — rdi = referencia. Salidas: rax = 1 si C es idéntico bit a bit
igual_c:
    lea     rsi, [arr_c]
    mov     rcx, BYTES / 8
    repe    cmpsq                       ; compara qword a qword mientras sean iguales
    sete    al
    movzx   rax, al
    ret

; medir_bench — rdi = función. Salidas: rax = ciclos TSC
medir_bench:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     r12, rdi
    call    limpiar_c
    call    tsc_begin
    mov     rbx, rax
    call    r12
    call    tsc_end
    sub     rax, rbx
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

; out_ok — rdi = 1 -> "[OK]", 0 -> "[ERROR]"
out_ok:
    test    rdi, rdi
    jz      .error
    lea     rdi, [t_ok]
    mov     rsi, t_ok_len
    jmp     out_str
.error:
    mov     qword [hubo_error], 1
    lea     rdi, [t_error]
    mov     rsi, t_error_len
    jmp     out_str

; out_rendimiento — imprime "G.GG GFLOPS  xS.S" y registra el máximo
; Entradas : rdi = ciclos, rsi = nombre corto (cadena C)
out_rendimiento:
    push    rbx                         ; rbx = ciclos
    push    r12                         ; r12 = nombre
    push    r13                         ; r13 = GFLOPS x 100
    mov     rbx, rdi
    mov     r12, rsi
    mov     rdi, FLOP_BENCH
    mov     rsi, [tsc_hz]
    mov     rdx, rbx
    call    mul_div                     ; FLOP por segundo
    xor     rdx, rdx
    mov     rcx, 10000000
    div     rcx                         ; GFLOPS x 100
    mov     r13, rax
    cmp     r13, [max_gflops]
    jbe     .imprimir
    mov     [max_gflops], r13
    mov     [max_nombre], r12
.imprimir:
    mov     rdi, r13
    mov     rsi, 2
    call    out_fixed
    PRINT   t_gflops
    mov     rdi, [ciclos_escalar]
    mov     rsi, 10
    mov     rdx, rbx
    call    mul_div                     ; speedup x 10 = ciclos escalar / ciclos ISA
    mov     rdi, rax
    mov     rsi, 1
    call    out_fixed
    call    out_nl
    pop     r13
    pop     r12
    pop     rbx
    ret

; out_motivo — explica por qué una ISA no está disponible
; Entradas : rdi = registro de la tabla
out_motivo:
    mov     rax, [cpu_features]
    mov     rcx, [rdi + ISA_CPU]
    and     rax, rcx
    cmp     rax, rcx
    jne     .no_cpu
    lea     rdi, [t_no_so]
    mov     rsi, t_no_so_len
    call    out_str
    jmp     out_nl
.no_cpu:
    lea     rdi, [t_no_cpu]
    mov     rsi, t_no_cpu_len
    call    out_str
    jmp     out_nl

; disponible — rdi = registro de la tabla. Salidas: rax = 1 si CPU y SO la soportan
disponible:
    mov     rax, [cpu_features]
    mov     rcx, [rdi + ISA_CPU]
    or      rcx, [rdi + ISA_SO]         ; todos los bits requeridos
    and     rax, rcx
    cmp     rax, rcx
    sete    al
    movzx   rax, al
    ret

; probar_isa — verifica y mide una ISA de la tabla
; Entradas : rdi = registro de la tabla
probar_isa:
    push    rbx                         ; rbx = registro
    push    r12
    push    r13
    mov     rbx, rdi
    mov     rdi, [rbx + ISA_NOMBRE]
    mov     rsi, [rbx + ISA_LARGO]
    call    out_str
    mov     rdi, rbx
    call    disponible
    test    rax, rax
    jnz     .disponible
    mov     rdi, rbx
    call    out_motivo
    jmp     .fin
.disponible:
    mov     rax, [rbx + ISA_LANES]      ; la tabla va de menor a mayor ancho
    mov     [mejor_lanes], rax
    mov     rax, [rbx + ISA_CORTO]
    mov     [mejor_nombre], rax
    PRINT   t_si
    ; suma
    PRINT   t_suma
    call    [rbx + ISA_SUMA]
    lea     rdi, [ref_suma]
    call    igual_c
    mov     rdi, rax
    call    out_ok
    ; multiplicación
    PRINT   t_mult
    call    [rbx + ISA_MULT]
    lea     rdi, [ref_mult]
    call    igual_c
    mov     rdi, rax
    call    out_ok
    ; comparación
    PRINT   t_comp
    call    [rbx + ISA_COMP]
    cmp     rax, [cuenta_ref]
    sete    al
    movzx   rdi, al
    call    out_ok
    PRINT   t_dos_esp
    ; benchmark
    mov     rdi, [rbx + ISA_BENCH]
    call    medir_bench
    mov     rdi, rax
    mov     rsi, [rbx + ISA_CORTO]
    call    out_rendimiento
.fin:
    pop     r13
    pop     r12
    pop     rbx
    ret

; escritura_nt — compara escribir 64 MB con stores normales vs non-temporal
escritura_nt:
    push    rbx                         ; rbx = bloque
    push    r12                         ; r12 = instante inicial
    push    r13                         ; r13 = 1 si se usa AVX
    mov     rax, SYS_MMAP
    xor     rdi, rdi
    mov     rsi, BLOQUE_NT
    mov     rdx, PROT_READ | PROT_WRITE
    mov     r10, MAP_PRIVATE | MAP_ANONYMOUS | MAP_POPULATE
    mov     r8, -1
    xor     r9, r9
    syscall
    CHECK_SYSCALL .error
    mov     rbx, rax
    mov     r13, [avx2_ok]

    ; ---- stores normales: cada línea se lee primero (RFO) y queda en caché ----
    PRINT   l_nt_norm
    call    mono_ns
    mov     r12, rax
    xor     rcx, rcx
    test    r13, r13
    jz      .normal_sse
    vbroadcastss ymm0, [f_uno]
.normal_avx:
    vmovaps [rbx + rcx], ymm0
    vmovaps [rbx + rcx + 32], ymm0
    add     rcx, 64
    cmp     rcx, BLOQUE_NT
    jb      .normal_avx
    vzeroupper
    jmp     .normal_fin
.normal_sse:
    movss   xmm0, [f_uno]
    shufps  xmm0, xmm0, 0               ; replicar en los 4 lanes
.normal_sse_v:
    movaps  [rbx + rcx], xmm0
    movaps  [rbx + rcx + 16], xmm0
    movaps  [rbx + rcx + 32], xmm0
    movaps  [rbx + rcx + 48], xmm0
    add     rcx, 64
    cmp     rcx, BLOQUE_NT
    jb      .normal_sse_v
.normal_fin:
    call    mono_ns
    sub     rax, r12
    mov     rdx, rax
    mov     rdi, BLOQUE_NT
    mov     rsi, NS_A_MBS
    call    mul_div
    mov     rdi, rax
    call    out_u64
    PRINT   t_mbs
    call    out_nl

    ; ---- non-temporal: van directo a RAM por write combining, sin RFO ---------
    PRINT   l_nt_nt
    call    mono_ns
    mov     r12, rax
    xor     rcx, rcx
    test    r13, r13
    jz      .nt_sse
    vbroadcastss ymm0, [f_uno]
.nt_avx:
    vmovntps [rbx + rcx], ymm0
    vmovntps [rbx + rcx + 32], ymm0
    add     rcx, 64
    cmp     rcx, BLOQUE_NT
    jb      .nt_avx
    vzeroupper
    jmp     .nt_fin
.nt_sse:
    movss   xmm0, [f_uno]
    shufps  xmm0, xmm0, 0
.nt_sse_v:
    movntps [rbx + rcx], xmm0
    movntps [rbx + rcx + 16], xmm0
    movntps [rbx + rcx + 32], xmm0
    movntps [rbx + rcx + 48], xmm0
    add     rcx, 64
    cmp     rcx, BLOQUE_NT
    jb      .nt_sse_v
.nt_fin:
    sfence                              ; vaciar los buffers de write combining
    call    mono_ns
    sub     rax, r12
    mov     rdx, rax
    mov     rdi, BLOQUE_NT
    mov     rsi, NS_A_MBS
    call    mul_div
    mov     rdi, rax
    call    out_u64
    PRINT   t_mbs
    call    out_nl

    mov     rax, SYS_MUNMAP
    mov     rdi, rbx
    mov     rsi, BLOQUE_NT
    syscall
    xor     rax, rax
    jmp     .fin
.error:
    PRINT   t_err_mmap
    mov     rax, 1
.fin:
    pop     r13
    pop     r12
    pop     rbx
    ret

; -----------------------------------------------------------------------------
; mod_simd_run — punto de entrada del módulo M6
; Salidas  : rax = 0 si todas las verificaciones dieron OK
; -----------------------------------------------------------------------------
mod_simd_run:
    push    rbx
    push    r12
    push    r13
    call    cpu_detect
    call    perf_calibrar               ; tsc_hz para convertir ciclos en GFLOPS
    mov     rax, [cpu_features]
    xor     rcx, rcx
    bt      rax, FEAT_POPCNT
    setc    cl
    mov     [usar_popcnt], rcx
    xor     rax, rax
    mov     [hubo_error], rax
    mov     [max_gflops], rax
    mov     [mejor_lanes], rax
    mov     [max_nombre], rax
    lea     rax, [c_escalar]
    mov     [mejor_nombre], rax
    mov     qword [mejor_lanes], 1

    ; ---- referencia escalar --------------------------------------------------------
    call    inicializar
    call    esc_suma
    lea     rdi, [ref_suma]
    call    copiar_c
    call    esc_mult
    lea     rdi, [ref_mult]
    call    copiar_c
    call    esc_comp
    mov     [cuenta_ref], rax
    lea     rdi, [esc_bench]
    call    medir_bench
    mov     [ciclos_escalar], rax
    PRINT   n_escalar
    PRINT   t_si
    mov     rdi, [ciclos_escalar]
    lea     rsi, [c_escalar]
    call    out_rendimiento

    ; ---- ISAs vectoriales -----------------------------------------------------------
    lea     rdi, [tabla_isas + ISA_TAM]  ; AVX2 (para la escritura NT y el resumen)
    call    disponible
    mov     [avx2_ok], rax
    xor     r12, r12
.isa:
    mov     rax, r12
    imul    rax, rax, ISA_TAM
    lea     rdi, [tabla_isas]
    add     rdi, rax
    call    probar_isa
    inc     r12
    cmp     r12, NUM_ISAS
    jb      .isa

    ; ---- FMA ------------------------------------------------------------------------
    PRINT   n_fma
    mov     rax, [cpu_features]
    bt      rax, FEAT_FMA
    jnc     .fma_no_cpu
    bt      rax, FEAT_OS_AVX
    jnc     .fma_no_so
    PRINT   t_si
    lea     rdi, [fma_bench]
    call    medir_bench
    mov     rdi, rax
    lea     rsi, [c_fma]
    call    out_rendimiento
    jmp     .resumen
.fma_no_cpu:
    PRINT   t_no_cpu
    call    out_nl
    jmp     .resumen
.fma_no_so:
    PRINT   t_no_so
    call    out_nl

    ; ---- resumen en el formato del enunciado ------------------------------------------
.resumen:
    PRINT   l_avx2_hab
    mov     rdi, [avx2_ok]
    call    out_bool
    call    out_nl
    PRINT   l_through
    mov     rdi, [mejor_lanes]
    call    out_u64
    PRINT   t_ops
    mov     rdi, [mejor_nombre]
    call    out_cstr
    PRINT   t_cierra
    call    out_nl
    PRINT   l_bench
    mov     rdi, [max_gflops]
    mov     rsi, 2
    call    out_fixed
    PRINT   t_gflops_s
    PRINT   t_abre
    mov     rdi, [max_nombre]
    call    out_cstr
    PRINT   t_cierra
    call    out_nl

    call    escritura_nt
    or      rax, [hubo_error]           ; error si falló una verificación o la prueba NT
    pop     r13
    pop     r12
    pop     rbx
    ret
