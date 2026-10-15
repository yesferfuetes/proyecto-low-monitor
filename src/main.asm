; =============================================================================
; main.asm — Punto de entrada y línea de comandos de LowMonitor
; -----------------------------------------------------------------------------
; Proyecto : LowMonitor — Diagnóstico y monitorización de hardware x86-64
; Plataforma: Linux x86-64, NASM (-f elf64), GNU ld, sin libc
;
; Exporta  : _start
; Uso      : lowmonitor [todo|cpu|puertos|memoria|rendimiento|jerarquia|simd|ayuda]
;            Sin argumentos equivale a "todo".
;
; Flujo de _start:
;   1. util_init (detección de RDTSCP para las mediciones)
;   2. lee argc/argv de la pila y busca el comando en cmd_tabla
;   3. imprime la identificación y ejecuta el comando
;   4. traduce el resultado a código de salida (0 ok, 1 uso, 2 módulo con error)
;
; Despacho: cmd_tabla es una tabla de registros de 3 qwords
;   [nombre (cadena C), encabezado (cadena C o 0), función]
;   Las entradas con encabezado != 0 son módulos de diagnóstico: "todo"
;   recorre la misma tabla y ejecuta todos los módulos en orden.
; =============================================================================

default rel

%include "lib.inc"

extern mod_cpu_run, mod_ports_run, mod_mem_run
extern mod_perf_run, mod_cache_run, mod_simd_run
extern selftest_run, ports_senales_run, memtest_inject_run

CMD_NOMBRE          equ 0             ; offset del puntero al nombre
CMD_ENCAB           equ 8             ; offset del puntero al encabezado
CMD_FUNC            equ 16            ; offset del puntero a la función
CMD_TAM             equ 24            ; tamaño de un registro de la tabla

; =============================================================================
section .data
; Constantes, strings, tablas de datos
; =============================================================================
STR msg_banner, "LowMonitor v0.4.0 - Diagnóstico y monitorización de hardware x86-64", 10
STR msg_uso, "Uso: lowmonitor [todo|cpu|puertos|memoria|rendimiento|jerarquia|simd|ayuda]", 10
STR msg_desconocido, "lowmonitor: comando desconocido: "
STR msg_demasiados, "lowmonitor: se esperaba como máximo un argumento", 10
STR msg_nl, 10

; ---- Nombres de comandos (cadenas C, se comparan con argv[1]) ----------------
c_todo          db "todo", 0
c_cpu           db "cpu", 0
c_puertos       db "puertos", 0
c_memoria       db "memoria", 0
c_rendimiento   db "rendimiento", 0
c_jerarquia     db "jerarquia", 0
c_simd          db "simd", 0
c_ayuda         db "ayuda", 0
c_h             db "-h", 0
c_help          db "--help", 0
c_selftest      db "_selftest", 0        ; oculto: autoverificación de la librería
c_senales       db "_puertos_senales", 0 ; oculto: verifica restauración de handlers (M2)
c_inyectar      db "_memtest_inject", 0  ; oculto: M3 con 3 bits volteados a propósito

; ---- Encabezados de módulo -----------------------------------------------------
h_m1            db "== [M1] Identificación del CPU ==", 10, 0
h_m2            db "== [M2] Monitor de puertos E/S ==", 10, 0
h_m3            db "== [M3] Diagnóstico de memoria ==", 10, 0
h_m4            db "== [M4] Monitor de rendimiento del CPU ==", 10, 0
h_m5            db "== [M5] Gestión jerárquica de memoria ==", 10, 0
h_m6            db "== [M6] Operaciones SIMD ==", 10, 0

; ---- Tabla de despacho: nombre, encabezado, función ------------------------------
align 8
cmd_tabla:
    dq c_todo,        0,    ejecutar_todo    ; primera entrada = comando por defecto
    dq c_cpu,         h_m1, mod_cpu_run
    dq c_puertos,     h_m2, mod_ports_run
    dq c_memoria,     h_m3, mod_mem_run
    dq c_rendimiento, h_m4, mod_perf_run
    dq c_jerarquia,   h_m5, mod_cache_run
    dq c_simd,        h_m6, mod_simd_run
    dq c_ayuda,       0,    mostrar_ayuda
    dq c_h,           0,    mostrar_ayuda
    dq c_help,        0,    mostrar_ayuda
    dq c_selftest,    0,    selftest_run
    dq c_senales,     0,    ports_senales_run
    dq c_inyectar,    0,    memtest_inject_run
    dq 0                                     ; fin de la tabla

; =============================================================================
section .bss
; Variables reservadas (buffers, contadores) — no se necesitan aquí
; =============================================================================

; =============================================================================
section .text
; =============================================================================
global _start

; -----------------------------------------------------------------------------
; _start — punto de entrada principal (el kernel salta aquí tras execve)
; Pila al entrar (alineada a 16 por el ABI):
;   [rsp]      = argc
;   [rsp + 8]  = argv[0] (ruta del programa)
;   [rsp + 16] = argv[1] (comando) o NULL
; -----------------------------------------------------------------------------
_start:
    mov     rbx, rsp                    ; rbx = base de argc/argv (se conserva)
    call    util_init

    mov     r12, [rbx]                  ; r12 = argc
    lea     r13, [cmd_tabla]            ; por defecto: primera entrada ("todo")
    cmp     r12, 2
    jb      .ejecutar                   ; sin argumentos
    ja      .demasiados                 ; más de un argumento

    mov     rdi, [rbx + 16]             ; rdi = argv[1]
    call    buscar_comando              ; rax = registro de la tabla o 0
    test    rax, rax
    jz      .desconocido
    mov     r13, rax

.ejecutar:
    PRINT   msg_banner
    mov     rdi, r13
    call    ejecutar_entrada            ; rax = 0 ok, != 0 error del módulo
    mov     rdi, EXIT_OK
    test    rax, rax
    jz      .salir
    mov     rdi, EXIT_MODULO
.salir:
    call    sys_exit                    ; vacía el buffer y termina (no retorna)

.desconocido:
    lea     rdi, [msg_desconocido]
    mov     rsi, msg_desconocido_len
    call    err_write
    mov     rdi, [rbx + 16]             ; repetir el argumento recibido
    call    err_cstr
    lea     rdi, [msg_nl]
    mov     rsi, msg_nl_len
    call    err_write
    jmp     .uso_error

.demasiados:
    lea     rdi, [msg_demasiados]
    mov     rsi, msg_demasiados_len
    call    err_write

.uso_error:
    lea     rdi, [msg_uso]
    mov     rsi, msg_uso_len
    call    err_write
    mov     rdi, EXIT_USO
    call    sys_exit

; -----------------------------------------------------------------------------
; buscar_comando — busca un nombre en cmd_tabla
; Entradas : rdi = cadena C (argv[1])
; Salidas  : rax = dirección del registro encontrado, o 0 si no existe
; -----------------------------------------------------------------------------
buscar_comando:
    push    rbx                         ; rbx = registro actual
    push    r12                         ; r12 = nombre buscado
    sub     rsp, 8                      ; alinear la pila a 16 para las llamadas
    mov     r12, rdi
    lea     rbx, [cmd_tabla]
.siguiente:
    mov     rsi, [rbx + CMD_NOMBRE]
    test    rsi, rsi                    ; nombre NULL = fin de la tabla
    jz      .no_encontrado
    mov     rdi, r12
    call    str_eq
    test    rax, rax
    jnz     .encontrado
    add     rbx, CMD_TAM
    jmp     .siguiente
.encontrado:
    mov     rax, rbx
    jmp     .fin
.no_encontrado:
    xor     rax, rax
.fin:
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

; -----------------------------------------------------------------------------
; ejecutar_entrada — ejecuta un registro de la tabla
; Entradas : rdi = dirección del registro
; Salidas  : rax = valor devuelto por la función (0 = ok)
; -----------------------------------------------------------------------------
ejecutar_entrada:
    push    rbx                         ; rbx = registro (y alinea la pila)
    mov     rbx, rdi
    mov     rdi, [rbx + CMD_ENCAB]
    test    rdi, rdi
    jz      .funcion                    ; comandos sin encabezado (ayuda, todo...)
    call    out_cstr
.funcion:
    call    [rbx + CMD_FUNC]            ; llamada indirecta a través de la tabla
    pop     rbx
    ret

; -----------------------------------------------------------------------------
; ejecutar_todo — ejecuta todos los módulos de la tabla, en orden
; Salidas  : rax = 0 si todos terminaron bien, 1 si alguno falló
; Notas    : un módulo con error no detiene a los siguientes.
; -----------------------------------------------------------------------------
ejecutar_todo:
    push    rbx                         ; rbx = registro actual
    push    r12                         ; r12 = estado acumulado
    push    r13                         ; r13 = 1 después del primer módulo
    lea     rbx, [cmd_tabla]
    xor     r12, r12
    xor     r13, r13
.siguiente:
    cmp     qword [rbx + CMD_NOMBRE], 0
    je      .fin
    cmp     qword [rbx + CMD_ENCAB], 0
    je      .avanzar                    ; no es un módulo de diagnóstico
    test    r13, r13
    jz      .primero
    call    out_nl                      ; línea en blanco entre módulos
.primero:
    mov     r13, 1
    mov     rdi, rbx
    call    ejecutar_entrada
    test    rax, rax
    jz      .avanzar
    mov     r12, 1                      ; recordar que hubo un error
.avanzar:
    add     rbx, CMD_TAM
    jmp     .siguiente
.fin:
    mov     rax, r12
    pop     r13
    pop     r12
    pop     rbx
    ret

; -----------------------------------------------------------------------------
; mostrar_ayuda — imprime el uso del programa
; Salidas  : rax = 0
; -----------------------------------------------------------------------------
mostrar_ayuda:
    sub     rsp, 8                      ; alinear la pila
    PRINT   msg_uso
    add     rsp, 8
    xor     rax, rax
    ret
