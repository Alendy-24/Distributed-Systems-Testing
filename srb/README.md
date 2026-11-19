# SRB – Sistema de Reserva de Boletos (segunda entrega: escalable y tolerante a fallas)

Pontificia Universidad Javeriana · Introducción a Sistemas Distribuidos · 2026-30.
C++17 + ZeroMQ + PostgreSQL. El diseño y el protocolo de pruebas están en `DISENO_Y_PRUEBAS.txt`.

Operaciones: **consulta, reserva, modificación** (número de asientos o cambio de fecha a otra
ocurrencia del mismo evento en el mismo mes) — síncronas — y **cancelación** — asíncrona, con
notificación al cliente cuando se efectúa en la BD.

## Qué hace escalable y tolerante a fallas al sistema (resumen)

| Elemento | Escalabilidad | Tolerancia a fallas |
|---|---|---|
| **RMC** (réplicas en VM4 y VM5, varios hilos) | El GT reparte cada solicitud al RMC libre que lleva más tiempo ocioso (LRU) → trabajo equitativo entre las 2 VMs (el GT imprime el reparto por VM) | El RMC envía *heartbeats*; si calla, el GT lo da por caído y **reasigna** la solicitud en curso a otro RMC. Con `scripts/supervisor.sh` un proceso nuevo lo sustituye y se re-registra solo |
| **GT** (principal en VM2 + relevo en VM4) | Un solo GT atiende a muchos clientes (ROUTER asíncrono) | El relevo es el mismo binario; los RMC se registran en ambos. Si el principal cae, el cliente (*Lazy Pirate*) agota el tiempo, reintenta con el **mismo idMensaje** en el relevo y sigue |
| **Persistencia** (VM3) | N hilos, cada uno con su conexión a PostgreSQL (ROUTER/DEALER interno) | Cada transacción mutante guarda `(idCliente, idMensaje)` en la tabla `transaccion`: un reintento o reasignación **no duplica** la reserva, devuelve el resultado guardado |
| **Generador de carga** | Se puede dividir entre 2 VMs (`--vm-indice 0/1 --vm-total 2`); cada VM atiende la mitad de los clientes | — |

## Estructura

```
srb/
├── Makefile
├── README.md
├── VERSION                        qué versión tiene cada VM (cat VERSION)
├── DISENO_Y_PRUEBAS.txt           diseño final y protocolo de pruebas (para el informe)
├── ejemplos/caso_ejemplo.txt      operaciones de ejemplo para bin/cliente ("caso del profesor")
├── analisis/analisis.py           Tabla 1 y gráficos (pandas + matplotlib) a partir de los CSV
├── scripts/
│   ├── pruebas_automaticas.sh     batería completa (52 comprobaciones) en UNA máquina
│   ├── prueba_local.sh            demostración rápida de toda la arquitectura en una máquina
│   ├── tabla1.sh                  corridas de la Tabla 1 (base/escalable; 3, 5, 8 clientes; N repeticiones)
│   ├── prueba_empirica.sh         DESDE VM1: arranca la topología por ssh, genera carga y mide CPU en cada nodo
│   ├── muestreo_cpu.sh            lo usa el anterior en cada VM (CPU por componente)
│   ├── quien_soy.sh               en cada VM: dice qué máquina es y qué rol cumple
│   ├── actualizar_vms.sh          git pull + compilar en todas las VMs (desde VM1)
│   ├── vms.conf.ejemplo           IP de las VMs (copiar a vms.conf)
│   └── supervisor.sh              relanza un servicio si muere
├── src/
│   ├── common.hpp                 Mensaje, serialización, EnlaceGT (Lazy Pirate), utilidades ZeroMQ
│   ├── gestor_transacciones.cpp   GestorTransacciones  (ROUTER clientes, ROUTER RMC, PUSH)
│   ├── servicio_rmc.cpp           ServicioRMC          (DEALER -> GT, REQ -> Persistencia)
│   ├── servicio_persistencia.cpp  ServicioPersistencia (ROUTER/DEALER + hilos REP + PostgreSQL)
│   ├── servicio_cancelaciones.cpp ServicioCancelaciones(PULL <- GT, REQ -> Persistencia, PUB)
│   ├── generador_carga.cpp        GeneradorCarga, Cliente, Metricas
│   └── cliente_archivo.cpp        cliente que ejecuta un archivo de operaciones
└── tests/
    ├── test_mensaje.cpp           18 pruebas unitarias de la serialización
    └── prueba_funcional.cpp       41 pruebas de extremo a extremo
```

## Requisitos (Ubuntu/Debian) y compilación

```bash
sudo apt install -y build-essential libzmq3-dev libpq-dev libpqxx-dev postgresql
# cppzmq: dos headers (zmq.hpp y zmq_addon.hpp) en /usr/local/include o en src/
make            # genera todo en bin/   (make clean para limpiar)
```

La **base de datos** solo se necesita en la VM de persistencia (VM3). Con autenticación por socket
de Unix (sin contraseña), el servicio corre con el mismo usuario de Linux que tenga rol en PostgreSQL:

```bash
sudo -u postgres createuser $USER
sudo -u postgres createdb -O $USER srb
```

Compile en **cada** VM (los binarios no se copian entre máquinas: copie la carpeta `srb/` y haga `make`).

## Pruebas en una sola máquina (sin desplegar)

```bash
make
scripts/pruebas_automaticas.sh 15     # batería completa; 15 s por prueba de carga (~3 min)
scripts/prueba_local.sh 20 8 4        # demo: 20 s, 8 clientes, 4 solo consulta, 2 "VMs" de RMC y 2 de generador
```

## Despliegue en 5 máquinas

| VM | Capa | Procesos |
|---|---|---|
| VM1 | Consumidores | `bin/generador` (o `bin/cliente`) |
| VM2 | Lógica de negocio (entrada) | GT principal + Cancelaciones |
| VM3 | Almacenamiento | PostgreSQL + `bin/persistencia` |
| VM4 | Lógica de negocio (réplica A) | RMC `vm4` + GT de relevo |
| VM5 | Lógica de negocio (réplica B) | RMC `vm5` (+ segundo generador opcional) |

Con solo 3 máquinas (mínimo del enunciado) se omiten VM4/VM5 y el RMC corre en VM2 (arquitectura base).

**Puertos:** GT principal 5555 (clientes) y 5556 (RMC) · Cancelaciones 5557 (PULL) y 5558 (PUB) ·
Persistencia 5559 · GT de relevo 6555 y 6556. Abra en el firewall: VM2 → 5555, 5556, 5557, 5558;
VM3 → 5559; VM4 → 6555, 6556.

> **Antes de copiar un comando**: en cada máquina defina primero las IP **reales** (no deje `IP_...` literal,
> ZeroMQ no resuelve ese nombre y los procesos "se quedan esperando"):
> ```bash
> export IP_GT=10.x.x.x   IP_RELEVO=10.x.x.x   IP_BD=10.x.x.x   # VM2, VM4, VM3
> ```

Orden de arranque: **VM3 → VM2 → VM4/VM5 → VM1**. Una terminal por proceso (o `nohup … &`).

```bash
# ---- VM3: almacenamiento -------------------------------------------------------------
./bin/persistencia --reset --hilos 4                      # --reset recarga los 50 eventos

# ---- VM2: entrada del negocio --------------------------------------------------------
./bin/cancelaciones --persistencia tcp://$IP_BD:5559
./bin/gestor --nombre GT1 --cancel tcp://localhost:5557 --stats-csv logs/gt1.csv

# ---- VM4: réplica A + GT de relevo ----------------------------------------------------
./bin/gestor --nombre GT2 --bind tcp://*:6555 --bind-rmc tcp://*:6556 --cancel tcp://$IP_GT:5557
scripts/supervisor.sh ./bin/rmc --nombre vm4 --hilos 2 \
        --gt tcp://$IP_GT:5556,tcp://$IP_RELEVO:6556 --persistencia tcp://$IP_BD:5559

# ---- VM5: réplica B -------------------------------------------------------------------
scripts/supervisor.sh ./bin/rmc --nombre vm5 --hilos 2 \
        --gt tcp://$IP_GT:5556,tcp://$IP_RELEVO:6556 --persistencia tcp://$IP_BD:5559

# ---- VM1: clientes (8 clientes, 4 solo consulta, 120 s) -----------------------------------
./bin/generador --gt tcp://$IP_GT:5555,tcp://$IP_RELEVO:6555 --notif tcp://$IP_GT:5558 \
        --clientes 8 --solo-consulta 4 --rpm 60 --duracion 120 --calentamiento 10 --csv resultados.csv
```

**Generador repartido en 2 VMs** (los clientes 1..N se reparten por paridad; los ids no se pisan):

```bash
# VM1:  … --vm-indice 0 --vm-total 2        VM5:  … --vm-indice 1 --vm-total 2     (resto de argumentos iguales)
```

## Mantener todas las VMs al día (git)

Un solo clon por VM (`git clone <url> ~/srb`). Cuando cambie algo:

```bash
# en la máquina donde edita:
git add -A && git commit -m "mensaje" && git push
# desde VM1 (ssh sin contraseña + scripts/vms.conf):
scripts/actualizar_vms.sh          # git pull + make de lo que necesita cada VM; muestra la versión de cada una
scripts/prueba_empirica.sh parar   # y volver a arrancar los servicios para usar los binarios nuevos
```

Los binarios (`bin/`), los logs, los resultados y `scripts/vms.conf` NO van al repositorio (están en `.gitignore`):
cada VM compila los suyos y tiene sus propias IP. A mano, en una VM: `git pull && make bin/rmc` (o los binarios de su rol).

## ¿Qué máquina es cuál? (`quien_soy.sh`)

En cada VM (no necesita configuración; funciona aunque no haya nada corriendo):

```bash
cd ~/srb && scripts/quien_soy.sh          # nombre, IP, procesos, puertos en escucha y ROL deducido
scripts/quien_soy.sh --fijar VM4          # si no hay nada corriendo, anota una vez el rol en ~/.srb_rol
```

El rol se deduce de lo que corre: PostgreSQL/persistencia = VM3; `gestor` con puerto 5555 = GT principal (VM2);
`gestor` en 6555/6556 = GT de relevo; `rmc --nombre vm4` = réplica A; `generador` = VM1. Desde VM1 se ven todas
de una vez con `scripts/prueba_empirica.sh mapa` (necesita ssh sin contraseña y `scripts/vms.conf`).

## Preparar VM4 y VM5 (las réplicas de RMC)

**Los RMC no "escuchan" la carga: se conectan ellos al GT** (y a la persistencia) y avisan `READY`; el GT les envía
trabajo. Por eso en VM4/VM5 no hay puertos de entrada que abrir para el RMC (solo para el GT de relevo en VM4), y
el GT incorpora cualquier RMC nuevo en el momento en que arranca, incluso en plena carga.

1. **Copiar el proyecto** (desde VM1, o desde donde esté `srb/`). Si VM4/VM5 no tienen `zmq.hpp` en
   `/usr/local/include`, cópielo dentro de `srb/src/` (el Makefile usa `-Isrc`):
   ```bash
   cp /usr/local/include/zmq.hpp /usr/local/include/zmq_addon.hpp ~/srb/src/     # en la VM que los tenga
   rsync -a --exclude bin --exclude logs ~/srb/ USUARIO@IP_VM4:~/srb/              # idem para IP_VM5
   ```
2. **Compilar solo lo que esa VM usa** (no necesita PostgreSQL ni libpqxx):
   ```bash
   sudo apt install -y build-essential libzmq3-dev
   cd ~/srb && make bin/rmc bin/gestor          # VM4;  en VM5 basta  make bin/rmc
   ```
3. **Firewall** (si `sudo ufw status` dice *active*; en nubes con grupos de seguridad ábralos allí):
   `VM4: sudo ufw allow 6555/tcp && sudo ufw allow 6556/tcp` · `VM2: 5555 5556 5557 5558` · `VM3: 5559`.
4. **Comprobar que VM4/VM5 alcanzan al GT y a la persistencia** (con el GT y la persistencia ya arrancados):
   ```bash
   timeout 3 bash -c "</dev/tcp/$IP_GT/5556" && echo "GT ok"        # debe decir ok
   timeout 3 bash -c "</dev/tcp/$IP_BD/5559" && echo "BD ok"
   ```
5. **Arrancar el RMC** (comando completo en "Despliegue en 5 máquinas"). Para saber que quedó bien:
   en VM2 `grep "RMC registrado" logs/gt1.log` (una línea por hilo: `vm4/h0`, `vm4/h1`…) y en VM4 `scripts/quien_soy.sh`.
6. **Dar de alta la carga en las dos a la vez**: no hay nada más que configurar; el reparto es automático (LRU) y el GT
   lo imprime: `kill -USR1 $(pgrep -f '[b]in/gestor')` → `reparto entre VMs: vm4=… (50%) vm5=… (50%)`.

## Prueba empírica desde el nodo generador (VM1)

Qué consume más CPU y si VM4/VM5 ayudan: un solo comando por arquitectura, ejecutado en VM1.

```bash
# 0) ssh sin contraseña desde VM1 hacia VM2..VM5 (una sola vez)
ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519
for ip in IP_VM2 IP_VM3 IP_VM4 IP_VM5; do ssh-copy-id USUARIO@$ip; done      # con las IP reales
# 1) configuración
cd ~/srb && cp scripts/vms.conf.ejemplo scripts/vms.conf && nano scripts/vms.conf   # IP reales y USUARIO/RUTA
# 2) comprobaciones
scripts/prueba_empirica.sh mapa           # quién es quién
scripts/prueba_empirica.sh verificar      # ssh, binarios, puertos
# 3) corridas (CLIENTES="3 5 8" por defecto; DUR=60 s medidos; ~1.5 min por escenario)
scripts/prueba_empirica.sh correr base      | tee emp_base.txt
scripts/prueba_empirica.sh correr escalable | tee emp_escalable.txt
scripts/prueba_empirica.sh correr elastica  | tee emp_elastica.txt     # VM4/VM5 se unen en plena carga
scripts/prueba_empirica.sh parar
```

Por cada escenario imprime: tiempos y TPM vistos por los clientes, reparto de solicitudes entre VMs (según el GT),
**CPU de cada componente en cada nodo** (`gestor`, `rmc`, `persistencia`, `postgres`, `generador`), CPU total del nodo
con aviso si pasa de 85 % (saturado), **ms de CPU por transacción** y el componente que más CPU consume.
En `elastica` muestra además los ops/s cada 5 s para ver el salto cuando se unen las réplicas. Los CSV de muestras
quedan en `resultados_empiricos/` y sirven para `analisis/analisis.py` (Tabla 1 y gráficos).

Cómo leerlo: si `postgres`+`persistencia` suman la mayor parte de la CPU y el nodo VM3 se acerca al 100 %, el cuello
de botella es la base de datos y más RMC no mejora más; si VM3 tiene CPU de sobra y el throughput sube al añadir
trabajadores, el límite era la concurrencia del RMC (cada solicitud ocupa un trabajador mientras espera a la BD).

## Demostración de las fallas (sustentación)

Con el generador corriendo (`--rpm 0` para ver el efecto):

| Qué se hace | Qué se observa |
|---|---|
| `kill -9` al RMC de VM4 (el proceso `bin/rmc`) | GT1: `RMC vm4/h0 sin señales: se da por caído … se reasigna`; los clientes no ven errores; el supervisor arranca un proceso nuevo y el GT lo registra otra vez |
| `kill -9` al GT1 (VM2) | El generador imprime `cambios_de_GT=N`; el trabajo sigue por GT2 (VM4); `errores=0` |
| Al terminar | `reservas_confirmadas` del generador = `select count(*) from reserva` (no hay reservas perdidas ni duplicadas) |

## Ver el estado de la BD y de cada proceso

- **BD completa:** `kill -USR1 $(pgrep -f '[b]in/persistencia')` imprime la tabla; también al arrancar y al apagar.
  `--volcar-cada 5` imprime un resumen cada 5 s. Con SQL: `psql -d srb -c "select * from reserva order by 1"`.
- **Restablecer la BD al estado inicial entre corridas:** `kill -USR2 $(pgrep -f '[b]in/persistencia')`.
- **Operaciones de cada proceso:** una línea por operación con su resultado (EXITO/RECHAZO/ERROR) salvo con `--silencioso`.
- **GT:** `kill -USR1 $(pgrep -f '[b]in/gestor')` imprime `GT-STATS` (totales, TPM por tipo, reparto por VM,
  reasignadas, inválidas), lo añade a `--stats-csv` y pone los contadores en cero.

## Reproducir el caso de prueba del profesor

Escriba las operaciones en un archivo (ver `ejemplos/caso_ejemplo.txt` y el formato en `src/cliente_archivo.cpp`) y:

```bash
psql -d srb -c "select sum(asientos_ocupados) from evento"          # BD antes (VM3)
./bin/cliente mi_caso.txt --gt tcp://$IP_GT:5555 --notif tcp://$IP_GT:5558
psql -d srb -c "select * from reserva order by 1"                    # BD después
```

## Medidas de rendimiento (Tabla 1)

1. **Arquitectura base**: GT + 1 RMC de **1 hilo** (en VM2, `--gt tcp://localhost:5556`) + persistencia con
   `--hilos 1`. Sin VM4/VM5 ni relevo.
2. **Arquitectura escalable**: la de arriba (VM4+VM5 con RMC de 2 hilos, persistencia `--hilos 4`, relevo).
3. Persistencia siempre con más asientos para que no se agoten durante la corrida y no distorsionen los
   tiempos: `./bin/persistencia --reset --silencioso --hilos <1|4> --asientos 5000`. Servicios con `--silencioso`.
4. Desde una máquina con `ssh` sin contraseña a las demás (ver variables al inicio del script):

```bash
ARQ=base      MODO=ssh GEN0=u@IP_VM1 BD_HOST=u@IP_BD GT_HOST=u@IP_GT GT_EPS=tcp://$IP_GT:5555 \
              NOTIF=tcp://$IP_GT:5558 scripts/tabla1.sh
# (cambie la topología a la escalable) y luego:
ARQ=escalable MODO=ssh GEN0=u@IP_VM1 GEN1=u@IP_VM5 BD_HOST=u@IP_BD GT_HOST=u@IP_GT \
              GT_EPS=tcp://$IP_GT:5555,tcp://$IP_RELEVO:6555 NOTIF=tcp://$IP_GT:5558 scripts/tabla1.sh
python3 analisis/analisis.py 'resultados/*muestras*.csv' --salida resultados
```

   Cada corrida: restablece la BD, 15 s de calentamiento descartados + 120 s medidos, 3 repeticiones por
   escenario (3, 5 y 8 clientes). Sale `resultados/tabla1.csv|md` y PNG de tiempo promedio, p95 y TPM.
   Si no tiene `ssh` entre las VMs, ejecute a mano en cada VM los comandos de `scripts/tabla1.sh`.

## Parámetros

- **persistencia:** `--bind tcp://*:5559` `--db "dbname=srb"` `--hilos 4` `--reset` `--mes 202611` `--eventos 50`
  `--dobles 20` `--asientos 100` `--volcar-cada SEG` `--silencioso`
- **gestor:** `--bind tcp://*:5555` `--bind-rmc tcp://*:5556` `--cancel tcp://host:5557` `--hb-ms 500`
  `--liveness 4` `--ttl 15` `--stats-csv archivo` `--nombre GT1` `--silencioso`
- **rmc:** `--gt tcp://h:5556[,tcp://h2:6556]` `--persistencia tcp://h:5559` `--hilos 2` `--nombre vm4`
  `--hb-ms 500` `--liveness 4` `--timeout-ms 3000` `--silencioso`
- **cancelaciones:** `--bind-pull tcp://*:5557` `--bind-pub tcp://*:5558` `--persistencia tcp://h:5559` `--silencioso`
- **generador:** `--gt tcp://a:5555[,tcp://b:6555]` `--notif tcp://h:5558` `--clientes N` `--solo-consulta K`
  `--rpm N` (0 = sin pausa; el enunciado exige ≥ 20) `--duracion SEG` `--calentamiento SEG` `--timeout-ms 4000`
  `--reintentos 3` `--pct-consulta 40 --pct-reserva 40 --pct-modificar 20 --pct-cancelar 0` (suman 100)
  `--max-asientos 4` `--eventos 50 --dobles 20 --mes 202611` `--semilla` `--vm-indice I --vm-total T`
  `--arquitectura base|escalable --repeticion R` `--csv resumen.csv` `--muestras muestras.csv`
- **cliente:** `archivo.txt` `--gt` `--notif` `--todo` `--esperar-notif MS` `--pausa-ms MS`

## Mensajes y patrones

Texto de una línea, 14 campos separados por `|` (ver `common.hpp`): `idMensaje|tipo|idCliente|endpoint|idEvento|
idOcurrencia|mes|numAsientos|idReserva|fechaNueva|numAsientosNuevo|tsEnvio|resultado|eventos`.

| Canal | Patrón ZeroMQ |
|---|---|
| Cliente → GT (síncrono) | REQ / ROUTER + *Lazy Pirate* (timeout, reintento con el mismo id, cambio de GT) |
| GT ↔ RMC (síncrono) | ROUTER / DEALER, *Paranoid Pirate* (READY, heartbeats, LRU, reasignación) |
| RMC → Persistencia (síncrono) | REQ → ROUTER/DEALER → hilos REP |
| Cancelación (asíncrono) | Cliente → GT (REQ/REP, ACK inmediato) → PUSH/PULL → Cancelaciones → Persistencia (REQ/REP) |
| Notificación | PUB/SUB (tópico `c<idCliente>|`) |

## Limitaciones conocidas

- PostgreSQL y el servicio de persistencia son una sola instancia (el enunciado exige tolerar fallas del GT y del RMC).
- El servicio de Cancelaciones es una sola instancia: si cae toda la VM2 los GT dejan de poder entregar cancelaciones
  hasta que se relance (el supervisor lo reinicia si solo cae el proceso).
- Las cancelaciones aceptadas y aún no efectuadas viven en la cola del GT → PULL; si el proceso GT muere en ese instante
  pueden perderse (el cliente ya recibió el ACK).
- Todo el sistema se verificó en una sola máquina; el despliegue real en 5 VMs se prueba con los comandos de arriba.
