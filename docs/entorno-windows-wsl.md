# Máquina de pruebas: Windows + WSL2

El programa es un ELF64 para Linux x86-64. En Windows se ejecuta dentro de **WSL2**
(una VM ligera con kernel Linux real). No funciona en WSL1 ni en PowerShell/CMD.

## 1. Instalación (una sola vez)

En PowerShell **como administrador**:

```powershell
wsl --install -d Ubuntu      # o la versión más reciente disponible: wsl --list --online
wsl --set-default-version 2
```

Reiniciar, abrir "Ubuntu", crear usuario. Luego, dentro de Ubuntu:

```bash
sudo apt update
sudo apt install -y nasm make binutils gdb git
nasm -v          # debe ser >= 2.15
```

Credenciales de GitHub (repositorio privado):

```bash
sudo apt install -y gh
gh auth login    # GitHub.com -> HTTPS -> navegador
```

## 2. Clonar y compilar

> Clonar **dentro del sistema de archivos de Linux** (`~`), no en `/mnt/c/...`:
> es mucho más rápido y evita problemas de permisos y fin de línea CRLF.

```bash
cd ~
git clone https://github.com/yesferfuetes/proyecto-low-monitor.git
cd proyecto-low-monitor
make check-tools
make
make test
./bin/lowmonitor
```

Actualizar tras nuevos cambios:

```bash
git pull && make && make test
```

## 3. Guardar evidencia para el reporte

```bash
make evidencia          # crea evidencia/<fecha>_<host>/ ; pregunta si también con sudo
git add evidencia && git commit -m "test: evidencia WSL2 módulo N" && git push
```

Además, tomar captura de pantalla de la terminal (Win + Shift + S) y guardarla en la misma carpeta.

## 4. Limitaciones conocidas de WSL2 (relevantes para el reporte)

| Aspecto | Efecto | Módulo |
|---------|--------|--------|
| Hipervisor Hyper-V | `CPUID` reporta `Hipervisor: Microsoft Hv`; algunos leafs pueden estar filtrados | M1 |
| Puertos E/S | Sin root: `[PROTEGIDO]`. Con root: varios dispositivos legados no están emulados → `[NO PRESENTE]` | M2 |
| RAM | La VM ve por defecto ~50 % de la RAM del host (configurable en `%UserProfile%\.wslconfig`, `memory=`) | M3 |
| Contadores PMU | `perf_event_open` normalmente no disponible → CPI/IPC estimados con TSC | M4 |
| Ruido | Windows sigue ejecutando procesos: cerrar aplicaciones pesadas antes de medir | M4, M5, M6 |
| AVX-512 | Se expone si el procesador del host lo tiene | M1, M6 |

Opcional, para más RAM visible en la VM, crear `C:\Users\<usuario>\.wslconfig`:

```ini
[wsl2]
memory=12GB
processors=8
```

y ejecutar `wsl --shutdown` antes de volver a abrir Ubuntu.
