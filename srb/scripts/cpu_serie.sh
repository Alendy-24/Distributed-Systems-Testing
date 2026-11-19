#!/usr/bin/env bash
# Serie de la CPU de ESTA máquina (% de todos sus núcleos), una muestra por segundo, en formato CSV "t_s,cpu_pct".
# La usa prueba_empirica.sh escalamiento en VM1 y en la VM de la BD (las demás informan su CPU al GT).
#
# Uso: scripts/cpu_serie.sh <segundos>
export LC_ALL=C
N=${1:-60}
leer() { awk '/^cpu /{b=$2+$3+$4+$7+$8+$9; print b, b+$5+$6}' /proc/stat; }
echo "t_s,cpu_pct"
read -r b0 t0 < <(leer)
for ((i = 1; i <= N; i++)); do
    sleep 1
    read -r b1 t1 < <(leer)
    awk -v i="$i" -v b0="$b0" -v t0="$t0" -v b1="$b1" -v t1="$t1" 'BEGIN{d=t1-t0; if(d<=0)d=1; printf "%d,%.1f\n", i, 100*(b1-b0)/d}'
    b0=$b1; t0=$t1
done
