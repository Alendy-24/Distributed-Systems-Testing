#!/usr/bin/env bash
# test2: ver scripts/prueba_empirica.sh (cabecera) y el README. Se ejecuta desde VM1:  scripts/test2.sh
cd "$(dirname "$0")/.." || exit 1
export T2_PASOS="${T2_PASOS:-16 32 64 128 256}"
exec scripts/test2.sh "$@"
