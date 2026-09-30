; =============================================================================
; syscalls.inc — Constantes de la interfaz de llamadas al sistema de Linux x86-64
; -----------------------------------------------------------------------------
; Proyecto : LowMonitor
; Contenido: sólo constantes (equ); no genera código ni datos.
;
; Convención del kernel para `syscall` (x86-64):
;   rax = número de syscall
;   rdi, rsi, rdx, r10, r8, r9 = argumentos 1..6   (¡r10, no rcx!)
;   retorno en rax; valores en [-4095, -1] son -errno
;   la instrucción destruye rcx (guarda RIP) y r11 (guarda RFLAGS)
; Referencia: arch/x86/entry/syscalls/syscall_64.tbl del kernel de Linux.
; =============================================================================

%ifndef SYSCALLS_INC
%define SYSCALLS_INC

; ---- Números de syscall ------------------------------------------------------
SYS_READ            equ 0
SYS_WRITE           equ 1
SYS_MMAP            equ 9
SYS_MUNMAP          equ 11
SYS_RT_SIGACTION    equ 13
SYS_RT_SIGRETURN    equ 15
SYS_IOCTL           equ 16
SYS_NANOSLEEP       equ 35
SYS_EXIT            equ 60
SYS_SYSINFO         equ 99
SYS_IOPL            equ 172
SYS_IOPERM          equ 173
SYS_SCHED_SETAFFINITY equ 203
SYS_CLOCK_GETTIME   equ 228
SYS_EXIT_GROUP      equ 231
SYS_PERF_EVENT_OPEN equ 298

; ---- Descriptores de archivo estándar ---------------------------------------
STDIN               equ 0
STDOUT              equ 1
STDERR              equ 2

; ---- errno (se reciben negados en rax) --------------------------------------
EPERM               equ 1
EINTR               equ 4
ENOMEM              equ 12
EACCES              equ 13
EINVAL              equ 22
ENOSPC              equ 28
ENOSYS              equ 38
ENOENT              equ 2
MAX_ERRNO           equ 4095          ; rax >= -4095 (sin signo) indica error

; ---- mmap --------------------------------------------------------------------
PROT_READ           equ 0x1
PROT_WRITE          equ 0x2
MAP_PRIVATE         equ 0x02
MAP_ANONYMOUS       equ 0x20
MAP_POPULATE        equ 0x8000        ; prefalla las páginas: memoria física real ya asignada

; ---- Señales / rt_sigaction ---------------------------------------------------
SIGSEGV             equ 11
SA_SIGINFO          equ 0x00000004    ; el handler recibe (signo, siginfo*, ucontext*)
SA_RESTORER         equ 0x04000000    ; obligatorio en x86-64: indicamos nuestro trampolín
SIG_DFL             equ 0
SIGSET_SIZE         equ 8             ; tamaño de sigset_t que espera el kernel
UC_RIP              equ 0xA8          ; offsetof(ucontext_t, uc_mcontext.gregs[REG_RIP])

; ---- Relojes -----------------------------------------------------------------
CLOCK_MONOTONIC     equ 1

%endif ; SYSCALLS_INC
