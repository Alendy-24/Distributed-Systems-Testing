# Distributed-Systems-Testing

Proyecto de la asignatura **Introducción a Sistemas Distribuidos** — Pontificia Universidad Javeriana (2026-30).

Este repositorio contiene el **SRB (Sistema de Reserva de Boletos)**: un sistema distribuido, escalable y tolerante a fallas, junto con los scripts y herramientas para desplegarlo en varias máquinas virtuales, someterlo a carga y medir su comportamiento.

**Versión actual:** SRB v3.5 (2026-11-18) · **Lenguaje:** C++17 · **Comunicación:** ZeroMQ · **Base de datos:** PostgreSQL

---

## ¿Qué hace el SRB?

Permite a clientes concurrentes realizar operaciones sobre eventos con asientos limitados:

| Operación | Tipo | Descripción |
|---|---|---|
| Consulta | Síncrona | Ver eventos y asientos disponibles |
| Reserva | Síncrona | Reservar asientos de una ocurrencia de un evento |
| Modificación | Síncrona | Cambiar el número de asientos o la fecha (otra ocurrencia del mismo evento en el mismo mes) |
| Cancelación | **Asíncrona** | Se confirma al instante (ACK) y el cliente recibe una notificación cuando se efectúa en la BD |

## Arquitectura

El sistema se organiza en tres capas distribuidas en 5 VMs:

| VM | Capa | Procesos |
|---|---|---|
| **VM1** | Consumidores y control | `generador` / `cliente`; desde aquí se arranca, mide y detiene todo por ssh |
| **VM2** | Almacenamiento | PostgreSQL + `persistencia` |
| **VM3** | Lógica de negocio | `gestor` (GT) + `cancelaciones` + `rmc` (nivel `base`) |
| **VM4** | Lógica de negocio | `rmc` (nivel `vm4`) y, en la variante `escalable`, el GT de relevo |
| **VM5** | Lógica de negocio | `rmc` (nivel `vm5`) |

Componentes principales:

- **GT (Gestor de Transacciones):** recibe las solicitudes de los clientes, las reparte entre los RMC y decide cuándo activar o liberar VMs.
- **RMC (Servicio de reserva, modificación y consulta):** ejecuta la lógica de negocio contra la persistencia. Se conecta al GT (no escucha) y avisa `READY`.
- **Persistencia:** único punto de acceso a PostgreSQL, con un pool de hilos.
- **Cancelaciones:** procesa las cancelaciones asíncronas y publica la notificación al cliente.

### Características destacadas

- **Escalado automático por CPU (scale-out / scale-in):** el GT activa o libera VMs de RMC según la CPU que cada una reporta en su heartbeat.
- **Leaky bucket:** cuando todas las VMs están activas y siguen saturadas, una cola acotada protege la latencia y rechaza el excedente con `SOBRECARGA`.
- **Tolerancia a fallas:** reasignación de solicitudes si cae un RMC y GT de relevo si cae el principal (patrones *Lazy Pirate* y *Paranoid Pirate*).
- **Patrones ZeroMQ:** REQ/ROUTER, ROUTER/DEALER, PUSH/PULL y PUB/SUB.

## Estructura del repositorio

```
.
└── srb/
    ├── Makefile
    ├── README.md               guía completa: instalación, ejecución y medición
    ├── ARQUITECTURA_FINAL.md   arquitectura, patrones, ventajas y desventajas
    ├── CAMBIOS.md              historial de cambios por versión
    ├── DISENO_Y_PRUEBAS.txt    diseño detallado y protocolo de pruebas
    ├── VERSION
    ├── src/                    código fuente C++ (GT, RMC, persistencia, cancelaciones, generador, cliente)
    ├── tests/                  pruebas unitarias y funcionales
    ├── scripts/                despliegue por ssh, monitores y pruebas de carga
    ├── analisis/               scripts de Python para gráficos y veredictos
    └── ejemplos/               archivo de operaciones de ejemplo para el cliente
```

## Requisitos

- `g++` con soporte C++17 y `make`
- `libzmq3-dev` y `cppzmq` (`zmq.hpp`, `zmq_addon.hpp`)
- `libpq-dev`, `libpqxx-dev` y PostgreSQL (solo en la VM de la base de datos)
- Python 3 con `pandas` y `matplotlib` (solo para el análisis de resultados)
- Acceso ssh sin contraseña desde VM1 hacia las demás VMs

## Compilación

Los binarios no se copian entre máquinas: se compilan en cada VM, y solo lo que esa VM necesita.

```bash
sudo apt install -y build-essential libzmq3-dev
sudo apt install -y libpq-dev libpqxx-dev postgresql      # solo VM2 (BD)

cd srb
make                                  # VM1 y VM2: todo
make bin/gestor bin/rmc bin/cancelaciones   # VM3
make bin/gestor bin/rmc               # VM4
make bin/rmc                          # VM5
```

## Inicio rápido

Toda la ejecución se controla desde **VM1**. Primero se configura una sola vez el archivo de IP de las VMs:

```bash
cd srb
cp scripts/vms.conf.ejemplo scripts/vms.conf && nano scripts/vms.conf
scripts/prueba_empirica.sh mapa        # quién es quién
scripts/prueba_empirica.sh verificar   # ssh, binarios y puertos
```

Luego se ejecutan las dos pruebas principales (cada una arranca la topología, genera la carga y entrega un veredicto):

```bash
scripts/test1.sh | tee test1.txt       # una VM alcanza: carga ligera, sin scale-out   (~1 min)
scripts/test2.sh | tee test2.txt       # carga creciente: se ocupan VM3+VM4+VM5 y el leaky bucket (~3 min)
scripts/prueba_empirica.sh parar       # detiene todo en las 5 VMs
```

Los resultados quedan en `resultados_test1/` y `resultados_test2/` (gráfico `escalamiento.png`, `veredicto.md`, CSV por segundo, etc.).

### Pruebas en una sola máquina

Para verificar el sistema sin desplegarlo en las 5 VMs:

```bash
cd srb
make
scripts/pruebas_automaticas.sh 15      # batería completa (~3 min)
scripts/prueba_local.sh 20 8 4         # demo rápida de toda la arquitectura
```

## ¿Qué verifican test1 y test2?

| | test1 | test2 |
|---|---|---|
| Objetivo | Con poco tráfico **una VM alcanza** (sin scale-out) | Con tráfico creciente se **ocupan las 3 VMs de lógica** |
| Resultado esperado | 1 nivel activo, VM3 por debajo del 50 % de CPU, sin errores | Orden de escalado 1 → 2 → 3 → 2 → 1, leaky bucket con rechazos `SOBRECARGA`, sin errores |
| Veredicto | `APROBADO` / `REVISAR` | `APROBADO` / `REVISAR` |

> **Nota:** `test1` y `test2` usan una carga sintética de CPU en el RMC (`--carga-cpu-ms`), ya que con el RMC real la base de datos se satura antes que la capa lógica. Esto debe mencionarse al presentar los resultados.

## Demostración de fallas

| Qué se hace | Qué se observa |
|---|---|
| `kill -9` al proceso `bin/rmc` de VM4 | El GT lo da por caído y reasigna sus solicitudes; los clientes no ven errores |
| `kill -9` al GT principal (variante `escalable`) | El trabajo continúa por el GT de relevo en VM4 y `errores=0` |

## Documentación

| Documento | Contenido |
|---|---|
| [`srb/README.md`](srb/README.md) | Guía completa: despliegue, parámetros de cada proceso, arranque manual, Tabla 1 |
| [`srb/ARQUITECTURA_FINAL.md`](srb/ARQUITECTURA_FINAL.md) | Composición del proyecto, patrones, mejoras frente a la primera entrega |
| [`srb/CAMBIOS.md`](srb/CAMBIOS.md) | Qué cambió en cada versión y por qué |
| [`srb/DISENO_Y_PRUEBAS.txt`](srb/DISENO_Y_PRUEBAS.txt) | Diseño detallado y protocolo de pruebas |

## Limitaciones conocidas

- PostgreSQL y el servicio de persistencia son una sola instancia.
- El servicio de Cancelaciones es una sola instancia; las cancelaciones aceptadas y aún no efectuadas pueden perderse si el GT muere en ese instante.
- El escalado es lógico: el GT activa o libera réplicas ya arrancadas, no enciende ni apaga máquinas.
- Si la base de datos es el cuello de botella, activar más VMs de RMC no mejora el rendimiento.

## Autora

[Alendy-24](https://github.com/Alendy-24)
