# LowMonitor

**Diagnóstico y monitorización de hardware en ensamblador x86-64** — Proyecto del curso
Arquitectura de Computadoras 2, Universidad Mariano Gálvez de Guatemala (2026-2).

Aplicación de línea de comandos escrita en NASM que, sin libc y sólo con llamadas al sistema de
Linux, identifica el procesador, prueba puertos de E/S, verifica la integridad de la memoria, mide
el rendimiento del CPU, la latencia de cada nivel de la jerarquía de memoria y ejecuta operaciones SIMD.

| Módulo | Subcomando | Estado |
|--------|------------|--------|
| M1 Identificación del CPU | `cpu` | listo |
| M2 Monitor de puertos E/S | `puertos` | listo |
| M3 Diagnóstico de memoria | `memoria` | listo |
| M4 Rendimiento del CPU | `rendimiento` | listo |
| M5 Jerarquía de memoria | `jerarquia` | listo |
| M6 Operaciones SIMD (bonus) | `simd` | listo |

## Requisitos

- Linux x86-64 (Ubuntu 24.04+/26.04, nativo o WSL2)
- NASM ≥ 2.15, GNU ld (binutils), make

```bash
sudo apt install nasm make binutils
```

## Compilar y ejecutar

```bash
make            # compila bin/lowmonitor
make test       # pruebas automáticas
./bin/lowmonitor [todo|cpu|puertos|memoria|rendimiento|jerarquia|simd|ayuda]
sudo ./bin/lowmonitor puertos   # acceso real a puertos E/S (opcional)
make help       # todos los objetivos
```

## Binario precompilado

`entrega/lowmonitor` es el ejecutable ELF64 x86-64 (estático, sin libc, sin símbolos) listo para usar en
Linux x86-64 o WSL2; su SHA-256 está en `entrega/lowmonitor.sha256`. Se regenera con `make entrega`.

```bash
sha256sum -c entrega/lowmonitor.sha256
./entrega/lowmonitor
```

## Estructura

```
src/            código fuente NASM (main, lib/, mod/, inc/)
entrega/        binario ELF64 de entrega y su SHA-256
tests/          pruebas automáticas (make test)
docs/           reporte técnico (reporte/), decisiones técnicas, guía WSL2 y notas
evidencia/      salidas reales de ejecución para el reporte
scripts/        utilidades (evidencia)
```

## Documentación

**Reporte técnico:** [docs/reporte/Reporte-Tecnico-LowMonitor-Grupo6.pdf](docs/reporte/Reporte-Tecnico-LowMonitor-Grupo6.pdf)
— arquitectura del programa, descripción de cada módulo con su salida real, compilación y pruebas.

Decisiones técnicas en [docs/decisiones.md](docs/decisiones.md).

Probar en Windows: [docs/entorno-windows-wsl.md](docs/entorno-windows-wsl.md).

## Equipo de desarrollo — Grupo 6

- Yesfer Bany Fuentes Orozco
- Astrid Noemí Herrera Solórzano
- Fatima Paola Ranero García
- Gilma Odalis Velasquez Pérez

Curso Arquitectura de Computadoras 2 · Docente: Ing. René Ornélyz · Código original desarrollado para el curso.
