# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Это **публичная копия** приложения Veglia — единственная папка на этом Маке с git и
репозиторием на GitHub: `github.com/rroossaarroossaa/veglia`. Владелица выложила её
бесплатно 18.09.2026. Этот файл в git не попадает (`.gitignore`), он только для сессий.

## Правила публичной версии — установлены владелицей 18.09

- **Только английский.** README, комментарии в коде, подписи на картинках, сообщения
  коммитов. Русской части в README нет и не нужно.
- **Автор — она, «Rosa Things».** Нигде не упоминать студию ДАКОД (ни в README, ни в
  лицензии, ни в идентификаторах: bundle id `com.rosathings.veglia`, помощник крышки
  `com.rosathings.veglia.lid`). Коммиты **без** строки `Co-Authored-By: Claude`: она не
  хочет видеть Claude среди контрибьюторов. История репозитория переписана с нуля ради этого.
- Побольше тем (topics) у репозитория, чтобы находили.
- Раздел «Support» ждёт ссылку на донат и PayPal — она пришлёт.

## Откуда берётся код

Рабочая копия, из которой всё собирается и запускается на этом Маке, живёт в
`~/.claude/tools/awake/app/` (там же `CLAUDE.md` с историей решений). Исходники там
теперь с английскими комментариями — одна правда на обе копии. Правки делать **там**,
сюда переносить:

```bash
rsync -a --delete --exclude build ~/.claude/tools/awake/app/{Sources,icons,lid} ./
cp ~/.claude/tools/awake/app/build.sh ./
```

Отвергнутые варианты иконок лежат в `~/.claude/tools/awake/app/icons-alternatives/` и в
публичную копию не входят.

## Релиз

```bash
~/.claude/tools/awake/app/build.sh           # собирает ~/Applications/Veglia.app
ditto -c -k --keepParent ~/Applications/Veglia.app Veglia.zip
gh release create vX.Y Veglia.zip --title "Veglia X.Y" --notes "…"
```

Приложение подписано только ad hoc: у скачавших будет предупреждение Gatekeeper, в README
описан обход через «правой кнопкой → Открыть». Платная подпись Developer ID (99 $/год)
отложена до появления скачиваний и донатов.

Доступ к GitHub с этого Мака: `gh` залогинен в аккаунт `rroossaarroossaa` (device flow,
подтверждён через её Chrome 18.09). Git-идентичность задана только в этом репозитории:
`Rosa Things <163554448+rroossaarroossaa@users.noreply.github.com>`.
