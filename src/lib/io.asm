; =============================================================================
; io.asm — Rutinas de salida con buffer (sin libc)
; -----------------------------------------------------------------------------
; Proyecto : LowMonitor
; Propósito: toda la salida del programa se acumula en un buffer de 4 KiB en
;            .bss y se envía al kernel con write(2) sólo cuando se llena o al
;            llamar a out_flush. Así una pantalla completa de diagnóstico
;            cuesta una o dos llamadas al sistema en lugar de cientos.
;
; Exporta  : out_str, out_cstr, out_char, out_nl, out_spaces,
;            out_u64, out_i64, out_hex, out_fixed, out_size, out_bool,
;            out_flush
;
; Convención: System V AMD64. Ninguna función de este archivo hace syscall
;             excepto out_flush. Si write falla, out_flush termina el proceso
;             con EXIT_SISTEMA tras avisar por stderr.
; =============================================================================

default rel

%define IO_IMPL                         ; este archivo implementa las out_*
%include "lib.inc"

OUTBUF_SIZE         equ 4096          ; tamaño del buffer de salida (una página)
NUMBUF_SIZE         equ 32            ; u64 ocupa como máximo 20 dígitos decimales

; =============================================================================
section .data
; Constantes, strings, tablas de datos
; =============================================================================
hex_digits      db "0123456789ABCDEF"   ; tabla de traducción nibble -> carácter
size_units      db "B KBMBGBTB"         ; unidades de 2 bytes; "B " se imprime como "B"
SIZE_UNIT_MAX   equ 4                   ; índice de "TB"

STR txt_si, "Sí"
STR txt_no, "No"
STR msg_write_err, "lowmonitor: error al escribir en la salida estándar", 10
STR txt_errno, "errno "

; Nombres de errno frecuentes: pares (número, cadena C), fin con 0
e_eperm         db "EPERM", 0
e_enoent        db "ENOENT", 0
e_eintr         db "EINTR", 0
e_enomem        db "ENOMEM", 0
e_eacces        db "EACCES", 0
e_enodev        db "ENODEV", 0
e_einval        db "EINVAL", 0
e_enospc        db "ENOSPC", 0
e_enosys        db "ENOSYS", 0
e_eopnotsupp    db "EOPNOTSUPP", 0
align 8
tabla_errno:
    dq EPERM, e_eperm
    dq ENOENT, e_enoent
    dq EINTR, e_eintr
    dq ENOMEM, e_enomem
    dq EACCES, e_eacces
    dq ENODEV, e_enodev
    dq EINVAL, e_einval
    dq ENOSPC, e_enospc
    dq ENOSYS, e_enosys
    dq EOPNOTSUPP, e_eopnotsupp
    dq 0

; =============================================================================
section .bss align=64
; Variables reservadas (buffers, contadores)
; (align=64 en la sección: outbuf, el primer dato, queda alineado a una línea de caché)
; =============================================================================
outbuf          resb OUTBUF_SIZE        ; buffer de salida (alineado a línea de caché)
outpos          resq 1                  ; bytes ocupados en outbuf
numbuf          resb NUMBUF_SIZE        ; área temporal para convertir números

; =============================================================================
section .text
; =============================================================================
global out_str, out_cstr, out_char, out_nl, out_spaces
global out_u64, out_i64, out_hex, out_fixed, out_size, out_bool, out_flush, out_errno

; -----------------------------------------------------------------------------
; out_str — copia una cadena de longitud conocida al buffer de salida
; Entradas : rdi = dirección de los bytes, rsi = cantidad de bytes
; Salidas  : ninguna
; Modifica : rax, rcx, rdx, rsi, rdi, r8-r11 (caller-saved)
; Notas    : si el buffer se llena a mitad de la copia, se vacía y continúa;
;            por eso admite cadenas de cualquier tamaño.
; -----------------------------------------------------------------------------
out_str:
    push    rbx                         ; rbx sólo se guarda para alinear la pila
    push    r12                         ; r12 = puntero de origen pendiente
    push    r13                         ; r13 = bytes pendientes de copiar
    mov     r12, rdi
    mov     r13, rsi
.bucle:
    test    r13, r13                    ; ¿queda algo por copiar?
    jz      .fin
    mov     rax, OUTBUF_SIZE
    sub     rax, [outpos]               ; rax = espacio libre en el buffer
    jnz     .copiar
    call    out_flush                   ; buffer lleno: enviarlo al kernel
    jmp     .bucle
.copiar:
    cmp     rax, r13
    cmova   rax, r13                    ; n = min(espacio libre, pendientes)
    lea     rdi, [outbuf]
    add     rdi, [outpos]               ; destino = outbuf + outpos
    mov     rsi, r12                    ; origen
    mov     rcx, rax                    ; contador para rep movsb
    add     [outpos], rax               ; actualizar ocupación
    add     r12, rax                    ; avanzar origen
    sub     r13, rax                    ; descontar pendientes
    rep     movsb                       ; copia rcx bytes [rsi] -> [rdi] (DF=0 por ABI)
    jmp     .bucle
.fin:
    pop     r13
    pop     r12
    pop     rbx
    ret

; -----------------------------------------------------------------------------
; out_cstr — copia una cadena terminada en byte 0
; Entradas : rdi = dirección de la cadena
; Modifica : caller-saved
; -----------------------------------------------------------------------------
out_cstr:
    mov     rsi, rdi                    ; rsi recorre la cadena buscando el 0
.buscar:
    cmp     byte [rsi], 0
    je      .medida
    inc     rsi
    jmp     .buscar
.medida:
    sub     rsi, rdi                    ; longitud = fin - inicio
    jmp     out_str                     ; llamada de cola: out_str retorna al llamador

; -----------------------------------------------------------------------------
; out_char — agrega un byte al buffer
; Entradas : dil = byte (parte baja de rdi)
; Modifica : rax, rdx (y caller-saved si hay que vaciar el buffer)
; -----------------------------------------------------------------------------
out_char:
    mov     rax, [outpos]
    cmp     rax, OUTBUF_SIZE            ; ¿buffer lleno?
    jb      .guardar
    push    rdi                         ; preservar el byte (y alinear la pila a 16)
    call    out_flush                   ; deja outpos en 0
    pop     rdi
    xor     rax, rax                    ; nueva posición = 0
.guardar:
    lea     rdx, [outbuf]
    mov     [rdx + rax], dil            ; escribir el byte en outbuf[outpos]
    inc     rax
    mov     [outpos], rax
    ret

; -----------------------------------------------------------------------------
; out_nl — agrega un salto de línea
; -----------------------------------------------------------------------------
out_nl:
    mov     rdi, 10                     ; '\n'
    jmp     out_char

; -----------------------------------------------------------------------------
; out_spaces — agrega n espacios
; Entradas : rdi = n (0 no imprime nada)
; -----------------------------------------------------------------------------
out_spaces:
    push    rbx                         ; rbx = contador (preservado entre llamadas)
    mov     rbx, rdi
.bucle:
    test    rbx, rbx
    jz      .fin
    mov     rdi, ' '
    call    out_char
    dec     rbx
    jmp     .bucle
.fin:
    pop     rbx
    ret

; -----------------------------------------------------------------------------
; out_u64 — imprime un entero sin signo de 64 bits en decimal
; Entradas : rdi = valor
; Método   : divisiones sucesivas entre 10 (div de 128/64 bits: rdx:rax / rcx);
;            cada residuo es un dígito, se escriben de derecha a izquierda en
;            numbuf y luego se copia el tramo usado.
; -----------------------------------------------------------------------------
out_u64:
    mov     rax, rdi                    ; dividendo
    mov     rcx, 10                     ; divisor
    lea     r8, [numbuf + NUMBUF_SIZE]  ; r8 = cursor, empieza al final
.digito:
    xor     rdx, rdx                    ; parte alta del dividendo = 0
    div     rcx                         ; rax = cociente, rdx = residuo (0..9)
    add     rdx, '0'                    ; residuo -> carácter ASCII
    dec     r8
    mov     [r8], dl                    ; guardar el dígito
    test    rax, rax                    ; ¿quedan dígitos? (hace al menos uno: "0")
    jnz     .digito
    mov     rdi, r8                     ; inicio del número
    lea     rsi, [numbuf + NUMBUF_SIZE]
    sub     rsi, r8                     ; longitud = fin - cursor
    jmp     out_str

; -----------------------------------------------------------------------------
; out_i64 — imprime un entero con signo de 64 bits en decimal
; Entradas : rdi = valor (complemento a 2)
; Notas    : -2^63 funciona: neg lo deja igual y como sin signo vale 2^63.
; -----------------------------------------------------------------------------
out_i64:
    test    rdi, rdi                    ; SF=1 si es negativo
    jns     out_u64                     ; positivo: imprimir tal cual
    push    rdi                         ; guardar valor (y alinear pila)
    mov     rdi, '-'
    call    out_char
    pop     rdi
    neg     rdi                         ; valor absoluto en complemento a 2
    jmp     out_u64

; -----------------------------------------------------------------------------
; out_hex — imprime un valor en hexadecimal (mayúsculas, sin prefijo)
; Entradas : rdi = valor, rsi = dígitos mínimos (1..16; se rellena con ceros)
; Ejemplo  : (0x3F8, 4) -> "03F8"     (0xDEADBEEF, 2) -> "DEADBEEF"
; Método   : se toma el nibble bajo con AND 0Fh, se traduce con la tabla
;            hex_digits y se desplaza el valor 4 bits a la derecha.
; -----------------------------------------------------------------------------
out_hex:
    mov     rax, rdi                    ; valor a convertir
    mov     rcx, rsi                    ; rcx = dígitos que faltan para el mínimo
    lea     r8, [numbuf + NUMBUF_SIZE]  ; cursor desde el final
    lea     r9, [hex_digits]            ; base de la tabla de traducción
.digito:
    mov     rdx, rax
    and     rdx, 0x0F                   ; nibble bajo (0..15)
    mov     dl, [r9 + rdx]              ; carácter correspondiente
    dec     r8
    mov     [r8], dl
    shr     rax, 4                      ; siguiente nibble
    dec     rcx                         ; un dígito menos para el mínimo
    jg      .digito                     ; faltan dígitos de relleno
    test    rax, rax
    jnz     .digito                     ; el valor aún tiene nibbles significativos
    mov     rdi, r8
    lea     rsi, [numbuf + NUMBUF_SIZE]
    sub     rsi, r8
    jmp     out_str

; -----------------------------------------------------------------------------
; out_fixed — imprime un número en punto fijo decimal
; Entradas : rdi = valor escalado (entero = real * 10^d), rsi = d (0..18)
; Ejemplo  : (1800, 3) -> "1.800"     (5, 2) -> "0.05"     (7, 0) -> "7"
; Método   : parte entera = valor / 10^d; fracción = valor mod 10^d impresa
;            con exactamente d dígitos (ceros a la izquierda).
; -----------------------------------------------------------------------------
out_fixed:
    push    rbx                         ; rbx = 10^d
    push    r12                         ; r12 = d
    push    r13                         ; r13 = fracción
    mov     r12, rsi
    ; --- 10^d por multiplicaciones sucesivas ---
    mov     rbx, 1
    mov     rcx, r12
.potencia:
    test    rcx, rcx
    jz      .dividir
    imul    rbx, rbx, 10
    dec     rcx
    jmp     .potencia
.dividir:
    mov     rax, rdi
    xor     rdx, rdx
    div     rbx                         ; rax = parte entera, rdx = fracción
    mov     r13, rdx
    mov     rdi, rax
    call    out_u64                     ; imprimir la parte entera
    test    r12, r12                    ; sin decimales: terminado
    jz      .fin
    mov     rdi, '.'
    call    out_char
    ; --- fracción con d dígitos exactos ---
    mov     rax, r13
    mov     rcx, r12
    mov     r9, 10
    lea     r8, [numbuf + NUMBUF_SIZE]
.frac:
    xor     rdx, rdx
    div     r9                          ; siguiente dígito de la fracción (derecha a izquierda)
    add     rdx, '0'
    dec     r8
    mov     [r8], dl
    dec     rcx
    jnz     .frac
    mov     rdi, r8
    mov     rsi, r12                    ; longitud = d
    call    out_str
.fin:
    pop     r13
    pop     r12
    pop     rbx
    ret

; -----------------------------------------------------------------------------
; out_size — imprime una cantidad de bytes con unidad legible (base 1024)
; Entradas : rdi = bytes
; Ejemplos : 512 -> "512 B"   49152 -> "48 KB"   1310720 -> "1280 KB"
;            34359738368 -> "32 GB"   16662888448 -> "16 GB"
; Regla    : mientras valor >= 1024 y unidad < TB:
;              múltiplo exacto de 1024  -> dividir (sin pérdida)
;              si no, y valor >= 10240  -> dividir redondeando (error < 5 %)
;              si no                    -> detenerse (p. ej. 1280 KB)
; -----------------------------------------------------------------------------
out_size:
    push    rbx                         ; rbx = índice de unidad (0=B .. 4=TB)
    mov     rax, rdi
    xor     rbx, rbx
.escalar:
    cmp     rax, 1024
    jb      .imprimir
    cmp     rbx, SIZE_UNIT_MAX
    jae     .imprimir
    test    rax, 1023                   ; ¿múltiplo exacto de 1024? (10 bits bajos en 0)
    jz      .exacto
    cmp     rax, 10240
    jb      .imprimir                   ; poca magnitud: redondear perdería precisión
    add     rax, 512                    ; redondeo al más cercano: (v + 512) / 1024
.exacto:
    shr     rax, 10                     ; dividir entre 1024 = desplazar 10 bits
    inc     rbx
    jmp     .escalar
.imprimir:
    mov     rdi, rax
    call    out_u64
    mov     rdi, ' '
    call    out_char
    lea     rdi, [size_units]
    lea     rdi, [rdi + rbx*2]          ; cada unidad ocupa 2 bytes en la tabla
    mov     rsi, 2
    test    rbx, rbx
    jnz     .unidad
    mov     rsi, 1                      ; "B" sin el espacio de relleno
.unidad:
    call    out_str
    pop     rbx
    ret

; -----------------------------------------------------------------------------
; out_bool — imprime "Sí" o "No"
; Entradas : rdi = 0 -> "No"; cualquier otro valor -> "Sí"
; -----------------------------------------------------------------------------
out_bool:
    test    rdi, rdi
    jz      .no
    lea     rdi, [txt_si]
    mov     rsi, txt_si_len
    jmp     out_str
.no:
    lea     rdi, [txt_no]
    mov     rsi, txt_no_len
    jmp     out_str

; -----------------------------------------------------------------------------
; out_errno — imprime el nombre de un error devuelto por una syscall
; Entradas : rdi = -errno (valor negativo tal como lo deja el kernel en rax)
; Ejemplo  : -13 -> "EACCES"; un errno sin nombre en la tabla -> "errno N"
; -----------------------------------------------------------------------------
out_errno:
    neg     rdi                         ; errno positivo
    lea     rax, [tabla_errno]
.buscar:
    mov     rcx, [rax]
    test    rcx, rcx                    ; fin de la tabla
    jz      .numero
    cmp     rcx, rdi
    je      .nombre
    add     rax, 16
    jmp     .buscar
.nombre:
    mov     rdi, [rax + 8]
    jmp     out_cstr
.numero:
    push    rdi                         ; guardar errno (y alinear la pila)
    lea     rdi, [txt_errno]
    mov     rsi, txt_errno_len
    call    out_str
    pop     rdi
    jmp     out_u64

; -----------------------------------------------------------------------------
; out_flush — envía el contenido del buffer a stdout con write(2)
; Entradas : ninguna
; Salidas  : rax = 0; el buffer queda vacío
; Errores  : reintenta si write fue interrumpido (EINTR) o escribió sólo una
;            parte. Cualquier otro error (p. ej. ENOSPC en /dev/full) avisa por
;            stderr y termina el proceso con EXIT_SISTEMA: seguir sin poder
;            mostrar resultados no tiene sentido.
; Modifica : rax, rcx, rdx, rsi, rdi, r11 (syscall destruye rcx y r11)
; -----------------------------------------------------------------------------
out_flush:
    push    rbx                         ; alineación
    push    r12                         ; r12 = puntero a lo pendiente de enviar
    push    r13                         ; r13 = bytes pendientes
    lea     r12, [outbuf]
    mov     r13, [outpos]
.escribir:
    test    r13, r13
    jz      .vacio
    mov     rax, SYS_WRITE
    mov     rdi, STDOUT
    mov     rsi, r12
    mov     rdx, r13
    syscall                             ; rax = bytes escritos o -errno
    cmp     rax, -EINTR
    je      .escribir                   ; interrumpido por una señal: reintentar
    CHECK_SYSCALL .error
    test    rax, rax
    jz      .error                      ; 0 bytes escritos: no hay progreso posible
    add     r12, rax                    ; escritura parcial: avanzar y continuar
    sub     r13, rax
    jmp     .escribir
.vacio:
    mov     qword [outpos], 0
    xor     rax, rax
    pop     r13
    pop     r12
    pop     rbx
    ret
.error:
    ; Aviso directo a stderr (sin buffer) y salida inmediata.
    mov     rax, SYS_WRITE
    mov     rdi, STDERR
    lea     rsi, [msg_write_err]
    mov     rdx, msg_write_err_len
    syscall
    mov     rax, SYS_EXIT_GROUP
    mov     rdi, EXIT_SISTEMA
    syscall
