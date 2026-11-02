# =============================================================================
# Makefile — LowMonitor: compilación automática
# -----------------------------------------------------------------------------
# Ensambla todos los src/**/*.asm con NASM (elf64) y los enlaza con GNU ld
# en un ELF64 estático sin libc.
#
#   make              compila bin/lowmonitor (con símbolos DWARF)
#   make DEBUG=0      compila sin símbolos (release)   -> hacer 'make clean' antes
#   make run ARGS=cpu ejecuta con argumentos
#   make test         pruebas automáticas (tests/smoke.sh)
#   make help         lista todos los objetivos
# =============================================================================

NAME      := lowmonitor
SRC_DIR   := src
INC_DIR   := $(SRC_DIR)/inc
BUILD_DIR := build
BIN_DIR   := bin
TARGET    := $(BIN_DIR)/$(NAME)

NASM      ?= nasm
LD        ?= ld
GDB       ?= gdb
DEBUG     ?= 1
ARGS      ?=

# -f elf64 : objeto ELF de 64 bits      -Wall : todas las advertencias
# -I       : ruta de los .inc (la barra final es obligatoria en NASM)
NASMFLAGS := -f elf64 -Wall -I$(INC_DIR)/
# -m elf_x86_64  : salida ELF64 x86-64
# -z noexecstack : pila no ejecutable (evita el warning de binutils >= 2.39)
LDFLAGS   := -m elf_x86_64 -z noexecstack

ifeq ($(DEBUG),1)
  NASMFLAGS += -g -F dwarf
else
  LDFLAGS   += -s
endif

# Descubrimiento automático de fuentes: src/mod/cpu.asm -> build/mod/cpu.o
SRCS := $(shell find $(SRC_DIR) -name '*.asm' | sort)
OBJS := $(patsubst $(SRC_DIR)/%.asm,$(BUILD_DIR)/%.o,$(SRCS))
DEPS := $(OBJS:.o=.d)

.PHONY: all run test debug info evidencia entrega check-tools clean help

all: $(TARGET)

# Enlace final
$(TARGET): $(OBJS)
	@mkdir -p $(BIN_DIR)
	$(LD) $(LDFLAGS) -o $@ $(OBJS)

# Ensamblado; -MD/-MP generan build/**/*.d para recompilar si cambia un .inc
$(BUILD_DIR)/%.o: $(SRC_DIR)/%.asm
	@mkdir -p $(dir $@)
	$(NASM) $(NASMFLAGS) -MD $(@:.o=.d) -MP -o $@ $<

-include $(DEPS)

run: $(TARGET)
	./$(TARGET) $(ARGS)

test: $(TARGET)
	@bash tests/smoke.sh $(TARGET)

debug: $(TARGET)
	$(GDB) -q --args ./$(TARGET) $(ARGS)

info: $(TARGET)
	@file $(TARGET)
	@readelf -h $(TARGET) | grep -E 'Class|Type|Machine|Entry'
	@size $(TARGET)

evidencia: $(TARGET)
	@bash scripts/evidencia.sh $(TARGET)

# Binario de entrega: compilación limpia sin símbolos, copiado a entrega/ con su SHA-256
entrega:
	$(MAKE) clean
	$(MAKE) DEBUG=0
	@mkdir -p entrega
	cp $(TARGET) entrega/$(NAME)
	cd entrega && sha256sum $(NAME) > $(NAME).sha256
	@file entrega/$(NAME)
	@cat entrega/$(NAME).sha256

check-tools:
	@command -v $(NASM) >/dev/null 2>&1 || { echo "Falta nasm  -> sudo apt install nasm"; exit 1; }
	@command -v $(LD)   >/dev/null 2>&1 || { echo "Falta ld    -> sudo apt install binutils"; exit 1; }
	@v=$$($(NASM) -v | sed -E 's/^NASM version ([0-9]+\.[0-9]+).*/\1/'); \
	 if [ "$$(printf '%s\n%s\n' 2.15 "$$v" | sort -V | head -n1)" != "2.15" ]; then \
	   echo "NASM $$v es muy antiguo (se requiere >= 2.15)"; exit 1; fi; \
	 echo "nasm $$v OK"
	@$(LD) -v
	@[ "$$(uname -m)" = "x86_64" ] && echo "arquitectura x86_64 OK" || \
	 echo "AVISO: esta máquina es $$(uname -m); el binario sólo se ejecuta en x86-64"

clean:
	rm -rf $(BUILD_DIR) $(BIN_DIR)

help:
	@echo "Objetivos:"
	@echo "  all          compila $(TARGET) (DEBUG=1 por defecto)"
	@echo "  run          ejecuta; argumentos con ARGS=\"cpu\""
	@echo "  test         pruebas automáticas (tests/smoke.sh)"
	@echo "  debug        abre gdb sobre el binario"
	@echo "  info         cabecera ELF y tamaños de sección"
	@echo "  evidencia    guarda salida + datos del sistema en evidencia/"
	@echo "  entrega      binario release (sin símbolos) + SHA-256 en entrega/"
	@echo "  check-tools  verifica nasm >= 2.15, ld y arquitectura"
	@echo "  clean        borra build/ y bin/"
