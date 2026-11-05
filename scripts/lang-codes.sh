#!/bin/bash
# Expand a comma-separated vernacular language filter (e.g. "es,eu,ca,gl") into the codes to
# keep, one per line, lower case: each code as given plus, for ISO 639-1 codes, their
# ISO 639-3 form, because the GBIF backbone used "es" and COL XR uses "spa".
# Used by the --filter_lang step and by scripts/verify-artifacts.sh, so both agree.
declare -A iso3=(
  [ar]=ara [ca]=cat [cs]=ces [cy]=cym [da]=dan [de]=deu [el]=ell [en]=eng [es]=spa [et]=est
  [eu]=eus [fi]=fin [fr]=fra [ga]=gle [gl]=glg [hu]=hun [it]=ita [ja]=jpn [ko]=kor [nb]=nob
  [nl]=nld [nn]=nno [no]=nor [pl]=pol [pt]=por [ro]=ron [ru]=rus [sk]=slk [sl]=slv [sv]=swe
  [tr]=tur [uk]=ukr [zh]=zho
)
for code in $(printf '%s' "$1" | tr ',' ' ' | tr '[:upper:]' '[:lower:]'); do
  echo "$code"
  [[ -n "${iso3[$code]}" ]] && echo "${iso3[$code]}"
done
exit 0
