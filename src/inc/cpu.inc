; =============================================================================
; cpu.inc — Bits de la variable global cpu_features (qword)
; -----------------------------------------------------------------------------
; La llena cpu_detect (M1, src/mod/cpu.asm) a partir de CPUID y XGETBV.
; La consultan M4, M5 y M6 con `bt qword [cpu_features], FEAT_x` antes de
; ejecutar instrucciones opcionales, para no provocar nunca #UD (SIGILL).
; =============================================================================

%ifndef CPU_INC
%define CPU_INC

FEAT_SSE            equ 0             ; CPUID.1:EDX[25]
FEAT_SSE2           equ 1             ; CPUID.1:EDX[26]
FEAT_SSE3           equ 2             ; CPUID.1:ECX[0]
FEAT_SSSE3          equ 3             ; CPUID.1:ECX[9]
FEAT_SSE41          equ 4             ; CPUID.1:ECX[19]
FEAT_SSE42          equ 5             ; CPUID.1:ECX[20]
FEAT_AVX            equ 6             ; CPUID.1:ECX[28]
FEAT_AVX2           equ 7             ; CPUID.7.0:EBX[5]
FEAT_FMA            equ 8             ; CPUID.1:ECX[12]
FEAT_AVX512F        equ 9             ; CPUID.7.0:EBX[16]
FEAT_AVX512DQ       equ 10            ; CPUID.7.0:EBX[17]
FEAT_AVX512BW       equ 11            ; CPUID.7.0:EBX[30]
FEAT_AVX512VL       equ 12            ; CPUID.7.0:EBX[31]
FEAT_POPCNT         equ 13            ; CPUID.1:ECX[23]
FEAT_RDTSCP         equ 14            ; CPUID.80000001h:EDX[27]
FEAT_INVTSC         equ 15            ; CPUID.80000007h:EDX[8]
FEAT_HYPERVISOR     equ 16            ; CPUID.1:ECX[31]
FEAT_LM             equ 17            ; CPUID.80000001h:EDX[29] (modo largo = x86-64)
FEAT_OS_AVX         equ 18            ; XCR0[2:1] = 11b (el SO guarda YMM)
FEAT_OS_AVX512      equ 19            ; XCR0[7:5] = 111b (el SO guarda ZMM y k0-k7)
FEAT_CLFLUSH        equ 20            ; CPUID.1:EDX[19]

%endif ; CPU_INC
