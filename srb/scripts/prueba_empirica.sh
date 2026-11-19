#!/usr/bin/env bash
# Prueba empírica del SRB, DESDE EL NODO GENERADOR DE CARGA (VM1).
# Arranca la topología en las otras VMs por ssh, genera la carga desde esta máquina, mide la CPU de cada
# componente en cada nodo mientras corre, y al final dice dónde está el cuello de botella.
#
#   scripts/prueba_empirica.sh mapa                      quién es quién (qué rol cumple cada VM)
#   scripts/prueba_empirica.sh verificar                 ssh, binarios compilados, puertos
#   scripts/prueba_empirica.sh correr base               1 RMC de 1 hilo + persistencia de 1 hilo (3 VMs)
#   scripts/prueba_empirica.sh correr escalable          RMC en VM4+VM5, persistencia multihilo, GT de relevo
#   scripts/prueba_empirica.sh correr elastica           arranca como "base" y a los ELASTICA_S s une VM4 y VM5
#                                                        EN PLENA CARGA (se ve el salto de throughput)
#   scripts/prueba_empirica.sh parar                     detiene los procesos del SRB en todas las VMs
#
# Configuración: copie scripts/vms.conf.ejemplo a scripts/vms.conf y ponga las IP reales.
# Requisitos: ssh sin contraseña desde esta VM hacia VM2, VM3, VM4 y VM5 (ver README), el proyecto compilado
# (make) en la MISMA ruta en todas las VMs, y PostgreSQL con la base "srb" en VM3.
#
# Variables opcionales: CLIENTES="3 5 8" REPS=1 DUR=60 CAL=10 HILOS_BD=4 HILOS_RMC=2 ASIENTOS=5000
#                       ELASTICA_S=25 SALIDA=resultados_empiricos MODO=local (ensayo en una sola máquina)
set -u
cd "$(dirname "$0")/.."
CONF=${CONF:-scripts/vms.conf}
# shellcheck disable=SC1090
[ -f "$CONF" ] && . "$CONF"
MODO=${MODO:-ssh}
USUARIO=${USUARIO:-$(whoami)}
RUTA=${RUTA:-$PWD}
IP_GT=${IP_GT:-localhost}; IP_BD=${IP_BD:-localhost}; IP_VM4=${IP_VM4:-localhost}; IP_VM5=${IP_VM5:-localhost}
SSH_OPTS=${SSH_OPTS:--o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new}
CLIENTES=${CLIENTES:-"3 5 8"}; REPS=${REPS:-1}; DUR=${DUR:-60}; CAL=${CAL:-10}
HILOS_BD=${HILOS_BD:-4}; HILOS_RMC=${HILOS_RMC:-2}; ASIENTOS=${ASIENTOS:-5000}
ELASTICA_S=${ELASTICA_S:-25}
SALIDA=${SALIDA:-resultados_empiricos}
HOSTS=$(printf '%s\n' "$IP_GT" "$IP_BD" "$IP_VM4" "$IP_VM5" | awk '!v[$0]++')

en() {  # en <ip> <comando>: ejecuta en esa VM, dentro de la carpeta del proyecto
    local ip=$1; shift
    if [ "$MODO" = "local" ]; then bash -c "cd '$RUTA' && $*"
    else ssh $SSH_OPTS "$USUARIO@$ip" "cd '$RUTA' && $*"; fi
}
lanzar() {  # lanzar <ip> <nombre_log> <comando>: arranca en segundo plano, sobrevive al cierre de ssh
    en "$1" "mkdir -p logs && (setsid nohup $3 > logs/$2.log 2>&1 < /dev/null &); sleep 0.2; true"
}
rol_de() {  # etiqueta de los roles que tiene una IP según vms.conf
    local ip=$1 r=""
    [ "$ip" = "$IP_GT" ] && r="$r+VM2(GT)"; [ "$ip" = "$IP_BD" ] && r="$r+VM3(BD)"
    [ "$ip" = "$IP_VM4" ] && r="$r+VM4"; [ "$ip" = "$IP_VM5" ] && r="$r+VM5"
    echo "${r#+}"
}

cmd_mapa() {
    echo "Según scripts/vms.conf:   VM2 (GT + cancelaciones) = $IP_GT   VM3 (BD) = $IP_BD   VM4 = $IP_VM4   VM5 = $IP_VM5"
    echo "Lo que dice cada máquina:"
    for ip in $HOSTS; do
        printf '  %-16s ' "$ip"; en "$ip" "scripts/quien_soy.sh --corto" 2>&1 | tail -1
    done
    echo "(Esta máquina, VM1, es el generador: $(hostname) [$(hostname -I 2>/dev/null | awk '{print $1}')])"
}

cmd_verificar() {
    local mal=0
    for ip in $HOSTS; do
        echo "-- $ip  ($(rol_de "$ip"))"
        if ! en "$ip" "hostname" >/dev/null 2>&1; then
            echo "   ERROR: no hay ssh sin contraseña hacia $USUARIO@$ip (ver 'Preparar el ssh' en el README)"; mal=1; continue
        fi
        faltan=""
        necesarios=""   # solo los binarios que esa VM necesita según su rol
        [ "$ip" = "$IP_BD" ] && necesarios="$necesarios persistencia"
        [ "$ip" = "$IP_GT" ] && necesarios="$necesarios gestor cancelaciones rmc"
        [ "$ip" = "$IP_VM4" ] && necesarios="$necesarios gestor rmc"
        [ "$ip" = "$IP_VM5" ] && necesarios="$necesarios rmc"
        for b in $(echo $necesarios | tr ' ' '\n' | sort -u); do
            en "$ip" "test -x bin/$b" 2>/dev/null || faltan="$faltan $b"
        done
        [ -n "$faltan" ] && { echo "   AVISO: faltan binarios:$faltan (en esa VM: cd $RUTA && make bin/${faltan# } -- ver 'Preparar VM4 y VM5' en el README)"; }
        en "$ip" "test -x scripts/muestreo_cpu.sh" 2>/dev/null || { echo "   ERROR: falta scripts/muestreo_cpu.sh (copie la carpeta scripts/)"; mal=1; }
        echo "   ok: $(en "$ip" 'hostname; nproc' | paste -sd' ') núcleos"
    done
    test -x bin/generador || { echo "ERROR: compile el generador en esta máquina (make)"; mal=1; }
    echo "Puertos que esta VM necesita alcanzar (si el SRB ya está corriendo): GT $IP_GT:5555 y :5558"
    for p in 5555 5558; do
        timeout 3 bash -c "</dev/tcp/$IP_GT/$p" 2>/dev/null && echo "   $IP_GT:$p  abierto" || echo "   $IP_GT:$p  cerrado (¿GT/cancelaciones sin arrancar o firewall?)"
    done
    return $mal
}

parar_todo() {
    for ip in $HOSTS; do
        en "$ip" "pkill -TERM -f '[s]upervisor.sh'; pkill -TERM -f '[b]in/(persistencia|gestor|rmc|cancelaciones)'; sleep 0.7; pkill -KILL -f '[b]in/(persistencia|gestor|rmc|cancelaciones)'; true" 2>/dev/null
    done
}

lanzar_rmcs_vm4_vm5() {
    local gts="tcp://$IP_GT:5556,tcp://$IP_VM4:6556"
    lanzar "$IP_VM4" rmc_vm4 "bin/rmc --silencioso --nombre vm4 --hilos $HILOS_RMC --gt $gts --persistencia tcp://$IP_BD:5559"
    lanzar "$IP_VM5" rmc_vm5 "bin/rmc --silencioso --nombre vm5 --hilos $HILOS_RMC --gt $gts --persistencia tcp://$IP_BD:5559"
}

esperar_registro() {  # esperar_registro <cuántos RMC (hilos) debe ver el GT>
    local n=0
    for _ in $(seq 1 25); do
        n=$(en "$IP_GT" "grep -c 'RMC registrado' logs/gt1.log 2>/dev/null; true" | tail -1)
        [ "${n:-0}" -ge "$1" ] && { echo "   el GT ve $n trabajadores RMC registrados"; return 0; }
        sleep 1
    done
    echo "   ERROR: el GT solo ve ${n:-0} de $1 trabajadores RMC. Revise (logs/ en cada VM):"
    echo "     - que el RMC de VM4/VM5 compiló y arrancó (logs/rmc_vm4.log, logs/rmc_vm5.log)"
    echo "     - que VM4/VM5 alcanzan $IP_GT:5556 y $IP_BD:5559 (firewall: 'nc -zv $IP_GT 5556')"
    return 1
}

arrancar() {  # arrancar <base|escalable|elastica>
    local arq=$1 hb=$HILOS_BD
    [ "$arq" = base ] && hb=1
    echo ">> Arrancando topología '$arq' (persistencia con $hb hilos)"
    parar_todo; sleep 1
    lanzar "$IP_BD" persistencia "bin/persistencia --reset --silencioso --hilos $hb --asientos $ASIENTOS"
    sleep 2.5
    lanzar "$IP_GT" cancelaciones "bin/cancelaciones --silencioso --persistencia tcp://$IP_BD:5559"
    lanzar "$IP_GT" gt1 "bin/gestor --silencioso --nombre GT1 --cancel tcp://localhost:5557 --stats-csv logs/gt1.csv"
    case $arq in
        base)
            lanzar "$IP_GT" rmc_base "bin/rmc --silencioso --nombre base --hilos 1 --gt tcp://localhost:5556 --persistencia tcp://$IP_BD:5559"
            ESPERADOS=1 ;;
        escalable)
            lanzar "$IP_VM4" gt2 "bin/gestor --silencioso --nombre GT2 --bind tcp://*:6555 --bind-rmc tcp://*:6556 --cancel tcp://$IP_GT:5557"
            sleep 1; lanzar_rmcs_vm4_vm5
            ESPERADOS=$((2 * HILOS_RMC)) ;;
        elastica)
            lanzar "$IP_VM4" gt2 "bin/gestor --silencioso --nombre GT2 --bind tcp://*:6555 --bind-rmc tcp://*:6556 --cancel tcp://$IP_GT:5557"
            sleep 1
            lanzar "$IP_GT" rmc_base "bin/rmc --silencioso --nombre base --hilos 1 --gt tcp://$IP_GT:5556,tcp://$IP_VM4:6556 --persistencia tcp://$IP_BD:5559"
            ESPERADOS=1 ;;
    esac
    esperar_registro "$ESPERADOS"
}

perfil() {  # perfil del enunciado para N clientes
    case $1 in
        3) echo "--solo-consulta 2 --pct-consulta 50 --pct-reserva 50 --pct-modificar 0" ;;
        5) echo "--solo-consulta 3 --pct-consulta 0 --pct-reserva 70 --pct-modificar 30" ;;
        *) echo "--solo-consulta $(( $1 / 2 )) --pct-consulta 0 --pct-reserva 70 --pct-modificar 30" ;;
    esac
}

un_escenario() {  # un_escenario <arq> <clientes> <repeticion>
    local arq=$1 N=$2 R=$3 etq="${1}_c${2}_r${3}" W=$((DUR - 3)) gts="tcp://$IP_GT:5555"
    [ "$arq" != base ] && gts="$gts,tcp://$IP_VM4:6555"
    mkdir -p "$SALIDA/tmp"; rm -f "$SALIDA"/tmp/*
    echo; echo "== corrida $etq: $N clientes, ${CAL}s de calentamiento + ${DUR}s medidos =="
    en "$IP_BD" "pkill -USR2 -f '[b]in/persistencia'"; sleep 4          # BD al estado inicial
    en "$IP_GT" "pkill -USR1 -f '[b]in/gestor .*GT1'; true"; sleep 1     # contadores del GT en cero

    SAMPLERS=()
    for ip in $HOSTS; do   # muestreo de CPU en cada nodo, alineado con la ventana medida
        en "$ip" "scripts/muestreo_cpu.sh $CAL $W '$(rol_de "$ip")'" > "$SALIDA/tmp/cpu_$ip.txt" 2>&1 &
        SAMPLERS+=($!)
    done
    if [ "$arq" = elastica ]; then   # VM4 y VM5 se unen en plena carga
        ( sleep $((CAL + ELASTICA_S)); echo "   >>> $(date +%H:%M:%S) se unen RMC de VM4 y VM5 <<<"; lanzar_rmcs_vm4_vm5 ) &
        SAMPLERS+=($!)
    fi
    # shellcheck disable=SC2046
    timeout $((CAL + DUR + 40)) bin/generador --clientes "$N" $(perfil "$N") --rpm 0 \
        --duracion $((CAL + DUR)) --calentamiento "$CAL" --gt "$gts" --notif "tcp://$IP_GT:5558" \
        --arquitectura "$arq" --repeticion "$R" --muestras "$SALIDA/${etq}_muestras.csv" \
        > "$SALIDA/${etq}.gen.log" 2>&1
    wait "${SAMPLERS[@]}" 2>/dev/null

    # --- rendimiento visto por los clientes
    grep -E "CONSULTA:|RESERVA:|MODIFIC|errores=" "$SALIDA/${etq}.gen.log" | sed 's/^\[[0-9:.]*\] \[CARGA\] /   /'
    local n; n=$(grep -E "CONSULTA:|RESERVA:|MODIFIC" "$SALIDA/${etq}.gen.log" | sed -n 's/.* n=\([0-9]*\) .*/\1/p' | paste -sd+ | bc)
    n=${n:-0}
    # --- reparto de trabajo entre VMs según el GT
    en "$IP_GT" "pkill -USR1 -f '[b]in/gestor .*GT1'; sleep 0.8; grep 'reparto entre VMs' logs/gt1.log | tail -1" 2>/dev/null | sed 's/^\[[0-9:.]*\] /   /'
    # --- CPU por nodo y componente
    echo "   CPU durante la ventana medida (${W}s):"
    printf '   %-22s %-14s %8s %14s\n' "Nodo" "Componente" "CPU (s)" "% de 1 núcleo"
    cat "$SALIDA"/tmp/cpu_*.txt | awk '$1=="MUESTREO" && ($4>0.05){printf "   %-22s %-14s %8.2f %13s%%\n",$2,$3,$4,$5}'
    cat "$SALIDA"/tmp/cpu_*.txt | awk '$1=="NODO"{printf "   >> nodo %-22s CPU total %3d%% de %d núcleos (iowait %d%%)\n",$2,$3,$5,$4}'
    # --- ms de CPU por transacción y cuello de botella
    cat "$SALIDA"/tmp/cpu_*.txt | awk -v n="$n" -v dur="$DUR" -v w="$W" '
        $1=="MUESTREO" && $3!="generador" {cpu[$3]+=$4; tot+=$4}
        END{ if(n>0){ printf "   CPU por transacción (todas las VMs):"; for(k in cpu) printf "  %s=%.3f ms", k, 1000*cpu[k]*dur/(w*n); printf "  TOTAL=%.3f ms\n", 1000*tot*dur/(w*n)}
             m=0; for(k in cpu) if(cpu[k]>m){m=cpu[k]; mk=k}
             if(tot>0) printf "   Componente que más CPU consume: %s (%.0f%% de la CPU del sistema)\n", mk, 100*m/tot }'
    cat "$SALIDA"/tmp/cpu_*.txt | awk '$1=="NODO" && $3>=85{printf "   *** nodo %s SATURADO (CPU total %d%%) ***\n",$2,$3}'
    echo "$arq,$N,$R,$n" >> "$SALIDA/resumen.csv"
}

cmd_correr() {
    local arq=${1:-}
    case $arq in base|escalable|elastica) ;; *) echo "Uso: $0 correr base|escalable|elastica"; exit 2 ;; esac
    test -x bin/generador || { echo "Falta bin/generador: haga 'make' en esta máquina"; exit 1; }
    mkdir -p "$SALIDA"
    arrancar "$arq" || { echo "No se pudo completar el arranque: corrijo y vuelvo a intentar (use '$0 parar' antes)"; exit 1; }
    for N in $CLIENTES; do
        for R in $(seq 1 "$REPS"); do un_escenario "$arq" "$N" "$R"; done
    done
    if [ "$arq" = elastica ]; then
        echo; echo "== Throughput por segundo (ops/s) cada 5 s; las réplicas se unen en t=$((CAL + ELASTICA_S)) s =="
        for f in "$SALIDA"/elastica_c*_r*_muestras.csv; do
            echo " $(basename "$f" _muestras.csv)"
            awk -F, 'NR>1 && $1!="arquitectura"{t=$7+0; b=int(t/5)*5; c[b]++; if(!n++||t<tmin)tmin=t; if(t>tmax)tmax=t}
                 END{for(b in c){b+=0; lo=(b>tmin)?b:tmin; hi=(b+5<tmax)?b+5:tmax; s=hi-lo; if(s<1)s=1; printf "   t=%3d s  %7.1f ops/s\n", b, c[b]/s}}' "$f" | sort
        done
    fi
    echo; echo "Listo. Archivos en $SALIDA/ . Para la Tabla 1:  python3 analisis/analisis.py '$SALIDA/*_muestras.csv' --salida $SALIDA"
    echo "Guarde también la salida de esta ejecución (la CPU por componente es evidencia para el informe)."
}

case "${1:-}" in
    mapa) cmd_mapa ;;
    verificar) cmd_verificar ;;
    correr) cmd_correr "${2:-}" ;;
    parar) parar_todo; echo "Procesos del SRB detenidos en: $HOSTS" ;;
    *) sed -n '2,24p' "$0"; exit 2 ;;
esac
