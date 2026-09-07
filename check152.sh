#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# check152.sh v2.1 — аудит сайтов на видимые признаки соблюдения 152-ФЗ
#
# По каждому домену обходит главную и до N внутренних страниц (контакты,
# политика, услуги, заказ) и собирает:
#   * HTTP-код, редиректы, финальный URL, размер, кодировку, сервер
#   * Set-Cookie до какого-либо согласия + наличие cookie-баннера
#   * формы: action, поля, чекбоксы согласия, ПРЕДУСТАНОВЛЕННЫЕ чекбоксы
#   * ссылку на политику обработки ПДн + проверку, что она открывается
#   * реквизиты оператора: ИНН / ОГРН(ИП) / «ИП Фамилия»
#   * сторонние ресурсы: отдельно иностранные (трансграничная передача)
#     и российские
#   * виджеты-сборщики ПДн: Marquiz, JivoSite, Bitrix24, Tilda, Calltouch,
#     Envybox, Callibri, amoCRM, GetCourse, Flexbe, Roistat, YClients и др.
#   * сводку рисков по домену и итоговую таблицу
#
# Запуск:
#   bash check152.sh > audit.txt 2>&1        # все 15 доменов из списка ниже
#   bash check152.sh vorotas.ru bezleo.ru    # только указанные
#   PAGES=15 bash check152.sh > audit.txt    # глубже обход (по умолчанию 8)
#   WHOIS=1 bash check152.sh > audit.txt     # + владелец домена (нужен whois)
#   KEEP=1  bash check152.sh > audit.txt     # сохранить HTML в ./check152-dump
#
# Ограничения — важно при чтении отчёта:
#   - разбирается только статический HTML. Формы и виджеты, которые
#     дорисовывает JavaScript, скрипт не увидит. «Не найдено» != «нет».
#   - обход идёт по ссылкам с главной, глубина 1.
#   - юридической оценки скрипт не даёт, он собирает факты.
#
# Зависимости: bash 4+, GNU sed, GNU grep, curl, awk, iconv.
# Опционально: python3 или idn2 (punycode для .рф), whois.
# ---------------------------------------------------------------------------

VERSION="2.1"

# ---- локаль: нужна UTF-8, иначе grep -i не работает по кириллице -----------
for L in C.UTF-8 C.utf8 ru_RU.UTF-8 ru_RU.utf8 en_US.UTF-8; do
  if locale -a 2>/dev/null | grep -qix "$L"; then export LC_ALL="$L"; break; fi
done
: "${LC_ALL:=C.UTF-8}"; export LC_ALL LANG="$LC_ALL"

# кириллица через диапазоны ([а-яё]) в C.UTF-8 даёт "Invalid collation
# character", поэтому перечисляем буквы явно
# значение HTML-атрибута: "в кавычках", 'в апострофах' или без кавычек вовсе
AV='("[^"]*"|'"'"'[^'"'"']*'"'"'|[^ >]+)'

CL='[абвгдеёжзийклмнопрстуфхцчшщъыьэюя]'
CU='[АБВГДЕЁЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯ]'

# ---- домены по умолчанию (hostland, аккаунт host1410221) -------------------
DEFAULT_DOMAINS=(
  barleomedia.ru
  vorotas.ru
  vorota.me
  1000ворот.рф
  воротасервис.рф
  тысячаворот.рф
  воротагода.рф
  zemgu.ru
  zemguru.ru
  земельныйэксперт.рф
  твоепитание.рф
  snezhausmanova.ru
  snezhannanutri.ru
  bezleo.ru
  letsgoushki.ru
)

# ---- настройки -------------------------------------------------------------
PAGES="${PAGES:-8}"
TIMEOUT="${TIMEOUT:-25}"
KEEP="${KEEP:-0}"
WHOIS="${WHOIS:-0}"
UA="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0 Safari/537.36"
DUMP="./check152-dump"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/check152.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
[ "$KEEP" = "1" ] && mkdir -p "$DUMP"

# ---- словари ---------------------------------------------------------------
FOREIGN='google-analytics\.com|googletagmanager\.com|googleadservices|googlesyndication|doubleclick\.net|google\.com/recaptcha|recaptcha\.net|gstatic\.com|googleapis\.com|maps\.google|connect\.facebook|facebook\.(net|com)|fbcdn\.net|instagram\.com|tiktok\.com|twitter\.com|hotjar\.com|clarity\.ms|amplitude\.com|mixpanel\.com|segment\.(io|com)|intercom\.(io|com)|tawk\.to|crisp\.chat|zendesk\.com|hubspot|mailchimp|stripe\.com|paypal\.com|cdnjs\.cloudflare\.com|cloudflareinsights\.com|jsdelivr\.net|unpkg\.com|bootstrapcdn\.com|code\.jquery\.com|aspnetcdn\.com|fontawesome\.com|youtube\.com|ytimg\.com|youtu\.be|vimeo\.com|gravatar\.com|wp\.com|addthis\.com|disqus\.com|typekit\.net'
RUSSIAN='mc\.yandex\.|yandex\.(ru|net|st|com)|yastatic\.net|top-fwz1\.mail\.ru|top\.mail\.ru|ad\.mail\.ru|vk\.(com|ru)|userapi\.com|ok\.ru|rambler\.ru|rutube\.ru|dzen\.ru|jivo|marquiz|bitrix24|tilda(cdn|\.cc)|calltouch|envybox|callibri|amocrm|getcourse|flexbe|yclients|roistat|mango-office|sendpulse|unisender|sber|tinkoff|yoomoney|robokassa|cloudpayments|cdn\.envybox'
declare -A WIDGETS=(
  ["Marquiz (квиз-форма)"]='marquiz\.(ru|io|net)'
  ["JivoSite (чат)"]='jivosite\.com|jivo\.(ru|chat)|code\.jivo'
  ["Bitrix24 (CRM-форма/чат)"]='bitrix24|b24-|crm-form'
  ["Tilda (формы)"]='tilda\.(cc|ws)|tildacdn'
  ["Calltouch (коллтрекинг)"]='calltouch\.ru'
  ["Envybox (обратный звонок)"]='envybox\.io|envy-cdn|envycdn'
  ["Callibri (виджет)"]='callibri\.(ru|com)'
  ["Roistat (аналитика)"]='roistat\.com'
  ["amoCRM (формы)"]='amocrm\.(ru|com)|amo-forms'
  ["GetCourse"]='getcourse\.ru'
  ["Flexbe"]='flexbe\.(ru|com)'
  ["YClients (онлайн-запись)"]='yclients\.com'
  ["Mango Office"]='mango-office\.ru'
  ["SendPulse"]='sendpulse\.com'
  ["Битрикс CMS (форма)"]='bitrix/js|bitrix/templates'
  ["WordPress (CF7/WPForms)"]='contact-form-7|wpforms|wp-content/plugins'
  ["Google reCAPTCHA"]='recaptcha'
)

# ---- утилиты ---------------------------------------------------------------
hr()    { printf '%s\n' "----------------------------------------------------------------------"; }
head2() { printf '\n== %s\n' "$*"; }
# ${#l} в UTF-8-локали считает символы, а не байты — колонки не разъезжаются
kv()    { local l="$1" p; p=$((24-${#l})); [ $p -lt 1 ] && p=1
          printf '  %s%*s%s\n' "$l" "$p" "" "$2"; }

to_ascii() {
  local d="$1"
  case "$d" in *[!a-zA-Z0-9.:/-]*) ;; *) printf '%s' "$d"; return;; esac
  if command -v idn2 >/dev/null 2>&1; then
    idn2 "$d" 2>/dev/null || printf '%s' "$d"
  elif command -v python3 >/dev/null 2>&1; then
    python3 - "$d" <<'PY' 2>/dev/null || printf '%s' "$d"
import sys
d = sys.argv[1]
print('.'.join(l if l.isascii() else l.encode('idna').decode('ascii') for l in d.split('.')))
PY
  else
    printf '%s' "$d"
  fi
}

# fetch URL BODY HDR -> печатает "code size final_url time redirects";
# кодировку кладёт в $WORK/charset (переменная не выжила бы: вызов в $( ))
fetch() {
  local url="$1" body="$2" hdr="$3" meta cs
  : > "$body.raw"; : > "$body"; : > "$hdr"
  meta=$(curl -sS -L --max-redirs 8 --max-time "$TIMEOUT" --connect-timeout 10 \
              -A "$UA" -H 'Accept-Language: ru,en;q=0.8' \
              -D "$hdr" -o "$body.raw" \
              -w '%{http_code} %{size_download} %{url_effective} %{time_total} %{num_redirects}' \
              "$url" 2>"$WORK/err") || meta="000 0 $url 0 0"
  cs=$(grep -i '^content-type:' "$hdr" 2>/dev/null | tail -1 | grep -oiE 'charset=[a-z0-9_-]+' | head -1 | cut -d= -f2)
  [ -z "$cs" ] && cs=$(head -c 4000 "$body.raw" 2>/dev/null | grep -oiE 'charset=["'"'"']?[a-z0-9_-]+' | head -1 | sed 's/.*=//; s/["'"'"']//g')
  cs=$(printf '%s' "${cs:-utf-8}" | tr 'A-Z' 'a-z' | tr -d ' \r')
  case "$cs" in
    windows-1251|cp1251|1251) iconv -f CP1251 -t UTF-8//TRANSLIT "$body.raw" > "$body" 2>/dev/null || cp "$body.raw" "$body" ;;
    koi8-r|koi8r)             iconv -f KOI8-R -t UTF-8//TRANSLIT "$body.raw" > "$body" 2>/dev/null || cp "$body.raw" "$body" ;;
    *)                        cp "$body.raw" "$body" ;;
  esac
  printf '%s' "$cs" > "$WORK/charset"
  printf '%s' "$meta"
}

# имена тегов -> нижний регистр (чтобы разбирать <FORM>, <Input>, </A>)
norm() { sed -E 's@<(/?)([A-Za-z][A-Za-z0-9]*)@<\1\L\2@g' "$1" | tr '\r\n\t' '   '; }

absurl() { # $1=base $2=href
  local base="$1" h="$2" origin path
  origin=$(printf '%s' "$base" | sed -E 's@^(https?://[^/]+).*@\1@')
  case "$h" in
    http://*|https://*) printf '%s' "$h" ;;
    //*)                printf '%s:%s' "${base%%:*}" "$h" ;;
    /*)                 printf '%s%s' "$origin" "$h" ;;
    ''|'#'*|javascript:*|mailto:*|tel:*) printf '' ;;
    *)                  path=$(printf '%s' "$base" | sed -E 's@[^/]*$@@'); printf '%s%s' "$path" "$h" ;;
  esac
}

# ---- разбор одной страницы -> файлы-накопители $ACC_* -----------------------
analyze_page() {
  local url="$1" body="$2" hdr="$3" tag="$4" n blk
  n=$(norm "$body")

  # --- формы ---------------------------------------------------------------
  # "|| [ -n "$blk" ]" обязателен: после tr в потоке нет финального \n,
  # без него read вернёт 1 и тело цикла не выполнится ни разу
  printf '%s' "$n" | sed 's@<form@\n<form@g' | tail -n +2 | \
  while IFS= read -r blk || [ -n "$blk" ]; do
    [ -z "$blk" ] && continue
    blk="${blk%%</form>*}"
    local act fields cb pre lbl
    act=$(printf '%s' "$blk"    | grep -oiE "action *= *$AV" | head -1 | sed -E 's/^.*action *= *//I; s/^["'"'"']//; s/["'"'"']$//')
    fields=$(printf '%s' "$blk" | grep -oiE "<(input|textarea|select)[^>]*name *= *$AV" | sed -E 's/^.*name *= *//I; s/^["'"'"']//; s/["'"'"']$//' | tr '\n' ',' | sed 's/,$//')
    [ -z "$fields" ] && fields=$(printf '%s' "$blk" | grep -oiE '<(input|textarea|select)[^>]*type *= *["'"'"']?[a-z]*' | sed -E 's/.*type *= *["'"'"']?//' | tr '\n' ',' | sed 's/,$//')
    cb=$(printf '%s' "$blk"     | grep -oicE '<input[^>]*type *= *["'"'"']?checkbox')
    pre=$(printf '%s' "$blk"    | grep -oiE '<input[^>]*type *= *["'"'"']?checkbox[^>]*>' | grep -ciE '(^| )checked')
    lbl=$(printf '%s' "$blk"    | sed 's/<[^>]*>/ /g' | grep -oiE "(согла$CL*|персональн$CL*|обработк$CL*|политик$CL*|оферт$CL*)" | sort -u | tr '\n' ' ')
    printf 'стр %s | action=%s | поля=%s | чекбоксов=%s | предустановлено=%s | слова=%s\n' \
      "$tag" "${act:-<нет>}" "${fields:-<нет>}" "${cb:-0}" "${pre:-0}" "${lbl:-<НЕТ УПОМИНАНИЙ>}" >> "$ACC_FORMS"
  done

  # чекбоксы вне <form> (частый случай у конструкторов)
  printf '%s' "$n" | grep -oiE '<input[^>]*type *= *["'"'"']?checkbox[^>]*>' | \
  while IFS= read -r c || [ -n "$c" ]; do
    printf '%s|%s|%s\n' "$tag" "$(printf '%s' "$c" | grep -ciE '(^| )checked')" "$(printf '%s' "$c" | cut -c1-150)" >> "$ACC_CHECKS"
  done

  # --- ссылки на политику --------------------------------------------------
  printf '%s' "$n" | sed 's@<a @\n<a @g' | grep '^<a ' | \
  grep -iE "(polic|privac|politik|konfidenc|personal|persdan|soglasie|agreement|dogovor|oferta|политик|конфиденц|персональн|оферт|соглашени)" | \
  while IFS= read -r a || [ -n "$a" ]; do
    local href txt
    href=$(printf '%s' "$a" | grep -oiE "href *= *$AV" | head -1 | sed -E 's/^.*href *= *//I; s/^["'"'"']//; s/["'"'"']$//')
    txt=$(printf '%s' "${a%%</a>*}" | sed 's/<[^>]*>/ /g; s/|/ /g; s/  */ /g; s/^ //; s/ $//' | cut -c1-80)
    [ -n "$href" ] && printf '%s|%s|%s\n' "$(absurl "$url" "$href")" "${txt:-?}" "$tag" >> "$ACC_POLICY"
  done

  # --- реквизиты оператора --------------------------------------------------
  printf '%s' "$n" | sed 's/<[^>]*>/ /g' | grep -oiE '(ОГРНИП|ОГРН|ИНН)[:. ]*[0-9]{10,15}'   | sort -u >> "$ACC_REQ"
  printf '%s' "$n" | sed 's/<[^>]*>/ /g' | grep -oE  "ИП $CU$CL+( $CU($CL+|\.)){0,2}"          | sort -u >> "$ACC_REQ"
  printf '%s' "$n" | sed 's/<[^>]*>/ /g' | grep -oiE "самозанят$CL*|индивидуальн$CL+ предпринимател$CL+" | sort -u >> "$ACC_REQ"

  # --- сторонние ресурсы ----------------------------------------------------
  printf '%s' "$n" | grep -oiE '(src|href) *= *["'"'"']?((https?:)?//)[^"'"'"' >]+' | sed -E 's@.*//@@; s@[/?#].*@@' | sort -u >> "$ACC_HOSTS"
  printf '%s' "$n" | grep -oiE 'ym\(|yaCounter|gtag\(|dataLayer|fbq\(|_tmr|VK\.Retargeting' | sort -u | sed "s@\$@  (инлайн, стр $tag)@" >> "$ACC_INLINE"

  # --- виджеты --------------------------------------------------------------
  local w
  for w in "${!WIDGETS[@]}"; do
    printf '%s' "$n" | grep -qiE "${WIDGETS[$w]}" && printf '%s|%s\n' "$w" "$tag" >> "$ACC_WIDGETS"
  done

  # --- cookie-баннер --------------------------------------------------------
  if printf '%s' "$n" | grep -qiE '(cookie|куки)' && \
     printf '%s' "$n" | grep -qiE "(принима|соглас|разреш|понятно|accept|agree)"; then
    printf '%s\n' "$tag" >> "$ACC_COOKIEUI"
  fi

  grep -i '^set-cookie:' "$hdr" 2>/dev/null | sed -E 's/^[Ss]et-[Cc]ookie: *([^=]+)=.*/\1/' | tr -d '\r' >> "$ACC_SETCOOKIE"
}

# ---- обход одного домена ---------------------------------------------------
audit_domain() {
  local idx="$1" total="$2" domain="$3" ascii base
  ascii=$(to_ascii "$domain")
  case "$domain" in http://*|https://*) base="$domain"; ascii="$domain" ;; *) base="https://$ascii/" ;; esac

  hr; printf '[%s/%s] %s\n' "$idx" "$total" "$domain"
  [ "$ascii" != "$domain" ] && printf '        punycode: %s\n' "$ascii"
  hr

  ACC_FORMS="$WORK/forms";  ACC_CHECKS="$WORK/checks"; ACC_POLICY="$WORK/policy"
  ACC_REQ="$WORK/req";      ACC_HOSTS="$WORK/hosts";   ACC_WIDGETS="$WORK/widgets"
  ACC_COOKIEUI="$WORK/cui"; ACC_SETCOOKIE="$WORK/sc";  ACC_INLINE="$WORK/inline"
  : > "$ACC_FORMS"; : > "$ACC_CHECKS"; : > "$ACC_POLICY"; : > "$ACC_REQ"
  : > "$ACC_HOSTS"; : > "$ACC_WIDGETS"; : > "$ACC_COOKIEUI"; : > "$ACC_SETCOOKIE"; : > "$ACC_INLINE"
  RISKS=()

  local meta code size final ttime nred
  meta=$(fetch "$base" "$WORK/b0" "$WORK/h0")
  read -r code size final ttime nred <<< "$meta"
  # старые сайты часто живут только на http — не хороним домен раньше времени
  if [ "$code" = "000" ]; then
    case "$base" in https://*)
      meta=$(fetch "http://${base#https://}" "$WORK/b0" "$WORK/h0")
      read -r code size final ttime nred <<< "$meta"
      [ "$code" != "000" ] && kv "Примечание" "https не отвечает, сайт открылся только по http" ;;
    esac
  fi

  kv "HTTP"           "$code  (${size} байт, $(printf '%.2f' "${ttime:-0}") c, редиректов: ${nred:-0})"
  kv "Финальный URL"  "$final"
  kv "Кодировка"      "$(cat "$WORK/charset" 2>/dev/null)"
  kv "Сервер"         "$(grep -i '^server:' "$WORK/h0" 2>/dev/null | tail -1 | cut -d' ' -f2- | tr -d '\r')"

  if [ "$code" = "000" ]; then
    kv "ОШИБКА" "$(head -2 "$WORK/err" 2>/dev/null | tr '\n' ' ')"
    printf '  [!] сайт недоступен — проверить вручную\n\n'
    printf '%s\t%s\tнедоступен\n' "$domain" "$code" >> "$WORK/summary"; return
  fi
  if [ "$code" -ge 400 ] 2>/dev/null; then
    printf '  [!] главная отдаёт %s — проверить вручную\n\n' "$code"
    printf '%s\t%s\tHTTP %s\n' "$domain" "$code" "$code" >> "$WORK/summary"; return
  fi
  case "$final" in http://*) RISKS+=("сайт работает по HTTP без TLS — данные из форм идут открытым текстом");; esac
  [ "$KEEP" = "1" ] && cp "$WORK/b0" "$DUMP/${ascii//[^A-Za-z0-9.-]/_}_index.html" 2>/dev/null

  analyze_page "$final" "$WORK/b0" "$WORK/h0" "/"

  # --- отбор внутренних страниц: сначала «интересные» по URL ----------------
  local host; host=$(printf '%s' "$final" | sed -E 's@^https?://([^/]+).*@\1@')
  norm "$WORK/b0" | sed 's@<a @\n<a @g' | grep '^<a ' | \
    grep -oiE "href *= *$AV" | sed -E 's/^.*href *= *//I; s/^["'"'"']//; s/["'"'"']$//' | \
    while IFS= read -r h || [ -n "$h" ]; do absurl "$final" "$h"; echo; done | \
    grep -iE "^https?://$host" | sed 's/#.*//; s@/$@/@' | sort -u > "$WORK/links.all"
  grep -iE '(kontakt|contact|polic|privac|politik|konfidenc|personal|persdan|soglas|about|o-nas|o_nas|company|zayav|zakaz|order|zapis|uslug|service|price|cena|dostavk|oplat|consult|form|feedback|obratn|oferta|dogovor)' \
    "$WORK/links.all" > "$WORK/links.pick" 2>/dev/null
  grep -vxFf "$WORK/links.pick" "$WORK/links.all" 2>/dev/null >> "$WORK/links.pick"
  grep -vxF "$final" "$WORK/links.pick" 2>/dev/null | head -n "$PAGES" > "$WORK/links.use"

  local visited=1 u i=1 m c s f t r
  while IFS= read -r u || [ -n "$u" ]; do
    [ -z "$u" ] && continue
    m=$(fetch "$u" "$WORK/bp" "$WORK/hp"); read -r c s f t r <<< "$m"
    printf '  стр %-2s %-4s %s\n' "$i" "$c" "$(printf '%s' "$u" | cut -c1-88)"
    if [ "$c" != "000" ] && [ "$c" -lt 400 ] 2>/dev/null; then
      analyze_page "$f" "$WORK/bp" "$WORK/hp" "$(printf '%s' "$u" | sed -E "s@^https?://$host@@" | cut -c1-40)"
      [ "$KEEP" = "1" ] && cp "$WORK/bp" "$DUMP/${ascii//[^A-Za-z0-9.-]/_}_p${i}.html" 2>/dev/null
      visited=$((visited+1))
    fi
    i=$((i+1))
  done < "$WORK/links.use"
  kv "Страниц проверено" "$visited  (лимит PAGES=$PAGES)"

  # --- ФОРМЫ ----------------------------------------------------------------
  head2 "Формы и согласие"
  local cb=0 pre=0 nf=0
  if [ -s "$ACC_FORMS" ]; then
    nf=$(wc -l < "$ACC_FORMS")
    sort -u "$ACC_FORMS" | sed 's/^/    /'
    cb=$(sed -n 's/.*чекбоксов=\([0-9]*\).*/\1/p' "$ACC_FORMS" | awk '{s+=$1} END{print s+0}')
    pre=$(sed -n 's/.*предустановлено=\([0-9]*\).*/\1/p' "$ACC_FORMS" | awk '{s+=$1} END{print s+0}')
    kv "Всего форм" "$nf"
    kv "Чекбоксов в формах" "$cb  (предустановлено: $pre)"
    [ "$cb" -eq 0 ]  && RISKS+=("есть формы ($nf шт.), но НЕТ чекбокса согласия — согласие на обработку ПДн не фиксируется (ст.9 152-ФЗ)")
    [ "$pre" -gt 0 ] && RISKS+=("чекбокс(ы) предустановлены (checked) — согласие должно быть активным действием пользователя, галочка по умолчанию согласием не является")
    grep -q 'слова=<НЕТ УПОМИНАНИЙ>' "$ACC_FORMS" && RISKS+=("в части форм рядом с полями нет текста про согласие / персональные данные / политику")
  else
    kv "Формы" "не найдены в статическом HTML"
    printf '    (!) если формы рисует JS или это виджет — проверять браузером\n'
  fi
  if [ -s "$ACC_CHECKS" ]; then
    local pre2; pre2=$(awk -F'|' '$2>0' "$ACC_CHECKS" | wc -l)
    kv "Чекбоксов на страницах" "$(wc -l < "$ACC_CHECKS")  (предустановлено: $pre2)"
    [ "$pre2" -gt 0 ] && { awk -F'|' '$2>0' "$ACC_CHECKS" | head -5 | sed 's/^/    ПРЕДУСТАНОВЛЕН: /'
                           RISKS+=("найдены предустановленные чекбоксы — убрать атрибут checked"); }
  fi

  # --- ПОЛИТИКА -------------------------------------------------------------
  head2 "Политика обработки ПДн"
  if [ -s "$ACC_POLICY" ]; then
    local purl ptxt pon pc
    # процесс-подстановка, а не пайп: иначе RISKS+= уйдёт в subshell и пропадёт
    while IFS='|' read -r purl ptxt pon || [ -n "$purl" ]; do
      pc=$(curl -sS -o /dev/null -L --max-time 15 -A "$UA" -w '%{http_code}' "$purl" 2>/dev/null)
      printf '    [%s] %s\n          текст ссылки: "%s"   (найдена на: %s)\n' "${pc:-err}" "$purl" "$ptxt" "$pon"
      case "$pc" in 2*|3*) ;; *) RISKS+=("ссылка на политику отдаёт ${pc:-ошибку}: $purl");; esac
    done < <(sort -u -t'|' -k1,1 "$ACC_POLICY" | head -6)
  else
    kv "Политика" "ССЫЛКА НЕ НАЙДЕНА"
    RISKS+=("нет ссылки на политику обработки ПДн — по ч.2 ст.18.1 152-ФЗ она обязательна и должна быть доступна с любой страницы, где собираются данные")
  fi

  # --- COOKIE ---------------------------------------------------------------
  head2 "Cookie"
  local sc; sc=$(sort -u "$ACC_SETCOOKIE" | tr '\n' ' ')
  kv "Set-Cookie (до согласия)" "${sc:-нет}"
  if [ -s "$ACC_COOKIEUI" ]; then
    kv "Cookie-баннер" "возможно, есть — проверить глазами (стр: $(sort -u "$ACC_COOKIEUI" | head -3 | tr '\n' ' '))"
  else
    kv "Cookie-баннер" "не найден"
    [ -n "$sc" ] && RISKS+=("cookie ставятся до любого уведомления, баннера нет")
  fi

  # --- РЕКВИЗИТЫ ------------------------------------------------------------
  head2 "Реквизиты оператора на сайте"
  if [ -s "$ACC_REQ" ]; then
    sort -u "$ACC_REQ" | sed 's/^/    /'
  else
    kv "Реквизиты" "НЕ НАЙДЕНЫ (ни ИНН, ни ОГРНИП, ни «ИП Фамилия»)"
    RISKS+=("не указан оператор ПДн (ИП / ИНН / ОГРНИП) — пользователь не знает, кому даёт согласие")
  fi

  # --- СТОРОННИЕ РЕСУРСЫ ----------------------------------------------------
  head2 "Сторонние ресурсы"
  local ext fo ru other
  ext=$(sort -u "$ACC_HOSTS" | grep -viE "^(www\.)?($host|$ascii)$")
  fo=$(printf '%s\n' "$ext" | grep -iE "$FOREIGN" | grep -v '^$' | sort -u)
  ru=$(printf '%s\n' "$ext" | grep -viE "$FOREIGN" | grep -iE "$RUSSIAN" | grep -v '^$' | sort -u)
  if [ -n "$fo" ]; then
    printf '  ИНОСТРАННЫЕ (трансграничная передача, ст.12 152-ФЗ):\n'
    printf '%s\n' "$fo" | sed 's/^/    ! /'
    RISKS+=("иностранные сервисы: $(printf '%s' "$fo" | tr '\n' ' ') — это трансграничная передача, нужна отдельно описанная в политике правовая база и отметка в уведомлении РКН")
  else
    kv "Иностранные" "не найдены"
  fi
  if [ -n "$ru" ]; then printf '  РОССИЙСКИЕ:\n'; printf '%s\n' "$ru" | sed 's/^/    - /'
  else kv "Российские" "не найдены"; fi
  other=$(printf '%s\n' "$ext" | grep -viE "$FOREIGN" | grep -viE "$RUSSIAN" | grep -v '^$' | head -15)
  [ -n "$other" ] && { printf '  ПРОЧИЕ хосты:\n'; printf '%s\n' "$other" | sed 's/^/    . /'; }
  [ -s "$ACC_INLINE" ] && { printf '  Инлайн-счётчики:\n'; sort -u "$ACC_INLINE" | sed 's/^/    . /'; }

  # --- ВИДЖЕТЫ --------------------------------------------------------------
  head2 "Виджеты, собирающие ПДн"
  if [ -s "$ACC_WIDGETS" ]; then
    sort -u "$ACC_WIDGETS" | awk -F'|' '{a[$1]=a[$1]" "$2} END{for(k in a) printf "    %s\n        страницы:%s\n", k, a[k]}'
    RISKS+=("сторонние виджеты собирают ПДн в чужую систему — это обработчик по поручению: нужен договор (ч.3 ст.6 152-ФЗ) и упоминание в политике")
  else
    kv "Виджеты" "не обнаружены в статическом HTML"
  fi

  # --- WHOIS ----------------------------------------------------------------
  if [ "$WHOIS" = "1" ] && command -v whois >/dev/null 2>&1; then
    head2 "WHOIS (владелец домена)"
    whois "$ascii" 2>/dev/null | grep -iE '^(org|person|registrar|admin-contact|created|paid-till|registrant|e-mail)' | head -10 | sed 's/^/    /'
  fi

  # --- ИТОГ -----------------------------------------------------------------
  head2 "ИТОГ по домену"
  if [ ${#RISKS[@]} -eq 0 ]; then
    printf '    явных нарушений в статическом HTML не видно — проверить формы/виджеты браузером\n'
    printf '%s\t%s\tOK\n' "$domain" "$code" >> "$WORK/summary"
  else
    local rr; for rr in "${RISKS[@]}"; do printf '  [!] %s\n' "$rr"; done
    printf '%s\t%s\tрисков: %s\n' "$domain" "$code" "${#RISKS[@]}" >> "$WORK/summary"
  fi
  printf '\n'
}

# ---- main ------------------------------------------------------------------
if [ $# -gt 0 ]; then DOMAINS=("$@"); else DOMAINS=("${DEFAULT_DOMAINS[@]}"); fi
: > "$WORK/summary"

printf '=== check152.sh v%s — аудит %s доменов ===\n' "$VERSION" "${#DOMAINS[@]}"
printf 'Дата: %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"
printf 'Настройки: PAGES=%s TIMEOUT=%s WHOIS=%s KEEP=%s LC_ALL=%s\n' "$PAGES" "$TIMEOUT" "$WHOIS" "$KEEP" "$LC_ALL"
printf 'ВНИМАНИЕ: разбирается только статический HTML. Формы и виджеты, которые\n'
printf 'дорисовывает JavaScript, скрипт не видит — их проверять браузером.\n\n'

i=1
for d in "${DOMAINS[@]}"; do audit_domain "$i" "${#DOMAINS[@]}" "$d"; i=$((i+1)); done

hr; printf 'СВОДКА\n'; hr
printf '%-26s %-6s %s\n' "ДОМЕН" "HTTP" "РЕЗУЛЬТАТ"
while IFS=$'\t' read -r d c r || [ -n "$d" ]; do
  p=$((26-${#d})); [ $p -lt 1 ] && p=1
  printf '%s%*s %-6s %s\n' "$d" "$p" "" "$c" "$r"
done < "$WORK/summary"
hr
printf 'Чего скрипт увидеть НЕ может — проверить руками:\n'
printf '  1. Формы и виджеты на JS (Marquiz, JivoSite, всплывающие окна) — открыть сайт в браузере.\n'
printf '  2. Подавалось ли уведомление в РКН и от какого ИП — реестр операторов на pd.rkn.gov.ru по ИНН.\n'
printf '  3. Совпадает ли владелец домена (WHOIS / панель регистратора) с ИП в реквизитах на сайте.\n'
printf '  4. Соответствует ли текст политики тому, что реально собирают формы.\n'
printf '  5. Где физически хранятся ПДн (БД хостинга, CRM, таблицы) — локализация, ч.5 ст.18 152-ФЗ.\n'
