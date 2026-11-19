#!/usr/bin/env bash
# test2: ver scripts/prueba_empirica.sh (cabecera) y el README. Se ejecuta desde VM1:  scripts/test2.sh
cd "$(dirname "$0")/.." && exec scripts/prueba_empirica.sh test2 "$@"
