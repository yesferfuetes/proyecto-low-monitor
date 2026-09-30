# LowMonitor

**Diagnóstico y monitorización de hardware en ensamblador x86-64** — Proyecto del curso
Arquitectura de Computadoras 2, Universidad Mariano Gálvez de Guatemala (2026-2).

Aplicación de línea de comandos escrita en NASM que, sin libc y sólo con llamadas al sistema de
Linux, identifica el procesador, prueba puertos de E/S, verifica la integridad de la memoria, mide
el rendimiento del CPU, la latencia de cada nivel de la jerarquía de memoria y ejecuta operaciones SIMD.

| Módulo | Subcomando | Estado |
|--------|------------|--------|
| M1 Identificación del CPU | `cpu` | pendiente |
| M2 Monitor de puertos E/S | `puertos` | pendiente |
| M3 Diagnóstico de memoria | `memoria` | pendiente |
| M4 Rendimiento del CPU | `rendimiento` | pendiente |
| M5 Jerarquía de memoria | `jerarquia` | pendiente |
| M6 Operaciones SIMD (bonus) | `simd` | pendiente |

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

El binario precompilado (ELF64) está en [Releases](../../releases).

## Estructura

```
src/            código fuente NASM (main, lib/, mod/, inc/)
tests/          pruebas automáticas (make test)
docs/           decisiones técnicas, guía WSL2, notas y reporte
evidencia/      salidas reales de ejecución para el reporte
scripts/        utilidades (evidencia)
```

## Documentación

Decisiones técnicas en [docs/decisiones.md](docs/decisiones.md).

Probar en Windows: [docs/entorno-windows-wsl.md](docs/entorno-windows-wsl.md).

## Autor

Yesfer Fuentes — código original desarrollado para el curso.
