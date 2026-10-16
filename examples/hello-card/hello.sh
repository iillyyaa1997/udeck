#!/bin/sh
# The smallest useful uDeck plugin: it prints one card and exits.
#
# A plugin needs no permissions to exist. This one reads nothing and runs
# nothing, so its manifest declares no permissions and uDeck never asks the
# operator about it.
#
# Settings arrive as environment variables holding JSON. `greeting` is a string,
# so its value arrives quoted — strip the quotes rather than assuming.
#
# UDECK_LANG is the language the panel is speaking. Answer in it if you can and
# fall back to what you write in if you cannot — a producer that ignores the
# variable entirely is perfectly correct, just monolingual. Note that this is
# the variable to read: LANG and LC_ALL are pinned to a UTF-8 locale so that
# printing non-Latin text works at all, and they do not follow the setting.

greeting=$(printf '%s' "${UDECK_SETTING_GREETING:-\"Hello\"}" | sed 's/^"//; s/"$//')
show_table=${UDECK_SETTING_SHOW_TABLE:-true}

case "${UDECK_LANG:-en}" in
  ru)
    from='из shell-скрипта.'
    appearance_label='оформление'
    reason_label='обновлено потому что'
    meter_label='пример шкалы'
    list_first='строка списка'
    list_first_note='с примечанием'
    list_second='ещё одна'
    list_second_note='в цвете предупреждения'
    log_new='строка журнала'
    log_old='и предыдущая'
    table_kind='тип строки'
    table_count='сколько'
    table_declared='объявлено'
    table_drawn='нарисовано здесь'
    ;;
  *)
    from='from a shell script.'
    appearance_label='appearance'
    reason_label='refreshed because'
    meter_label='an example meter'
    list_first='a list row'
    list_first_note='with a note'
    list_second='another'
    list_second_note='warn tint'
    log_new='a log row'
    log_old='and an older one'
    table_kind='row type'
    table_count='count'
    table_declared='declared'
    table_drawn='drawn here'
    ;;
esac

table_row=''
if [ "$show_table" = "true" ]; then
  table_row=',
    { "table": { "columns": [ {"title": "'$table_kind'"}, {"title": "'$table_count'", "align": "trailing"} ],
                 "rows": [ ["'$table_declared'", "8"], ["'$table_drawn'", "7"] ] } }'
fi

# printf, and not a here-document: a Mac's /bin/sh is bash 3.2, which writes
# every here-document to a file in /var/tmp — once a poll. Each %s is the
# argument in its place below; %% is a percent sign.
printf '{
  "state": "ok",
  "chip": "example",
  "rows": [
    { "text": "%s %s" },
    { "kv": ["%s", "%s"] },
    { "kv": ["%s", "%s", "ok"] },
    { "meter": { "value": 0.42, "label": "%s", "caption": "42%%" } },
    { "list": [
        { "text": "%s", "note": "%s", "icon": "ok" },
        { "text": "%s", "note": "%s", "icon": "warn", "state": "warn" }
      ] },
    { "spark": [3, 7, 4, 9, 6, 11, 8] },
    { "log": ["%s", "%s"] }%s
  ],
  "ttl": 30
}
' "$greeting" "$from" \
  "$appearance_label" "${UDECK_APPEARANCE:-unknown}" \
  "$reason_label" "${UDECK_REFRESH_REASON:-unknown}" \
  "$meter_label" \
  "$list_first" "$list_first_note" "$list_second" "$list_second_note" \
  "$log_new" "$log_old" "$table_row"
