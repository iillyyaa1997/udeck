import Foundation

/// uDeck по-русски.
///
/// Написано, а не переведено дословно: там, где английская фраза строится
/// иначе, взята та, которую сказал бы русский человек. Названия — uDeck, macOS,
/// Developer ID, Mac — остаются как есть.
struct Russian: Vocabulary {
    func callAsFunction(_ phrase: Phrase) -> String {
        switch phrase {

        // Меню в строке состояния
        case .menuShowPanel: "Показать uDeck"
        case .menuRefreshAll: "Обновить все плагины"
        case .menuSettings: "Настройки…"
        case .menuOpenPluginsFolder: "Открыть папку плагинов"
        case .menuCopyDiagnostics: "Скопировать диагностику"
        case .menuQuit: "Завершить uDeck"

        // Окно настроек
        case .settingsWindowTitle: "Настройки uDeck"
        case .sectionGeneral: "Общие"
        case .sectionOpening: "Появление"
        case .sectionLook: "Вид"
        case .sectionPlugins: "Плагины"
        case .sectionAbout: "О программе"

        // Появление
        case .openingGesture: "Жест"
        case .openingGestureToggle: "Открывать движением курсора к верхнему краю экрана"
        case .openingPauseFirst: "Сначала пауза"
        case .openingPushPast: "Или продавить за край"
        case .openingStayQuiet: "Затем тишина"
        case .openingShortcut: "Сочетание"
        case .openingShortcutToggle: "Открывать сочетанием клавиш"
        case .openingKeys: "Клавиши"
        case .openingNeedsModifier:
            "Выберите хотя бы один модификатор — без него эта клавиша отбирается у всех приложений на этом Mac."
        case .openingAlso: "Ещё"
        case .openingRetract: "Убирать при переходе в другое приложение"
        case .openingFullscreen: "Открывать поверх полноэкранных приложений"
        case .openingKeepPolling: "Продолжать выполнять плагины, пока панель убрана"
        case .openingPermissions:
            "uDeck не просит у macOS никаких разрешений. Он следит за курсором, для чего разрешение не нужно, и регистрирует одно сочетание клавиш — это не то же самое, что следить за клавиатурой."

        // Вид
        case .lookLightLook: "Светлый вид"
        case .lookDarkLook: "Тёмный вид"
        case .lookCustom: "Свой"
        case .lookBuiltIn: "Встроенные"
        case .lookSaved: "Сохранённые"
        case .lookShows: "Показывать"
        case .lookLight: "Светлый"
        case .lookDark: "Тёмный"
        case .lookLightFromHour(let hour): "Светлый с \(hour):00"
        case .lookDarkFromHour(let hour): "Тёмный с \(hour):00"
        case .lookGlass: "Стекло"
        case .glassRegular: "Обычное"
        case .glassClear: "Прозрачное"
        case .lookTintCoversMaterial(let percent):
            "При заливке \(percent) % разница почти не видна — заливка перекрывает материал. Убавьте её, чтобы различить."
        case .lookAmount: "Количество"
        case .lookTint: "Заливка"
        case .tintLighter: "Светлее"
        case .tintDarker: "Темнее"
        case .lookStrength: "Сила"
        case .lookTintColour: "Цвет заливки"
        case .lookText: "Текст"
        case .lookBrightness: "Яркость"
        case .lookColour: "Цвет"
        case .lookDensity: "Плотность"
        case .lookTextSize: "Размер текста"
        case .densityCompact: "Плотно"
        case .densityNormal: "Обычно"
        case .densityCozy: "Просторно"
        case .lookLanguage: "Язык"
        case .languageSystem: "Системный"
        case .lookNameThisLook: "Название вида"

        case .sampleTitle: "Сессии Claude"
        case .sampleChip: "4 активных"
        case .sampleBody: "личный · 48 % за неделю"
        case .sampleFooter: "проверено минуту назад"

        // Встроенные виды
        case .modeLight: "Светлый"
        case .modeDark: "Тёмный"
        case .modeContrast: "Контрастный"
        case .modeGhost: "Призрак"
        case .modePaper: "Бумага"
        case .modeSmoke: "Дым"

        // Чем выбирается вид
        case .sourceSystem: "Система"
        case .sourceManual: "Вручную"
        case .sourceSchedule: "По часам"

        // Плагины
        case .pluginsInstalled: "Установленные"
        case .pluginsOpenFolder: "Открыть папку"
        case .pluginsLookAgain: "Искать заново"
        case .pluginsNothingInstalled:
            "Пока ничего не установлено. uDeck ничего не показывает сам — всё в панели приходит из плагинов."
        case .pluginsStaleness(let seconds, let multiplier):
            "Карточка без собственного срока считается свежей \(seconds) с, потом тускнеет, а после \(multiplier)× от него её значения скрываются совсем."
        case .pluginEnabled: "Включён"
        case .pluginMore: "Подробнее"
        case .pluginLess: "Свернуть"
        case .pluginSettings: "Настройки"
        case .pluginEverySeconds(let seconds): "каждые \(seconds) с"
        case .pluginLastFailure(let reason): "Последний сбой: \(reason)"
        case .permissionsAsksNothing: "Ничего не просит"
        case .permissionsAsksTo: "Этот плагин просит:"
        case .permissionsDeclared: "заявлено"
        case .permissionsDeclaredHelp:
            "uDeck показывает это и не запустит плагин без вашего согласия, но удержать уже запущенную программу он не может — см. документацию по плагинам."
        case .permissionsPluginAsksTo(let name): "\(name) просит:"
        case .permissionsUnsandboxed:
            "uDeck запускает этот плагин от вашего имени, без песочницы. Разрешить — значит согласиться запустить эту программу; отказать — значит uDeck её никогда не запустит."
        case .permissionsAllowAndRun: "Разрешить и запустить"

        // Что плагин может попросить
        case .capabilityRead(let glob): "читать файлы по маске \(glob)"
        case .capabilityWrite(let glob): "писать файлы по маске \(glob)"
        case .capabilityExec(let command): "запускать \(command)"
        case .capabilityNetwork(let host): "обращаться к \(host) по сети"
        case .capabilityScreen: "видеть список запущенных приложений и переключаться между ними"
        case .capabilitySecret(let name): "получать от uDeck секрет «\(name)»"

        // О программе
        case .aboutTitle: "uDeck"
        case .aboutTagline: "Панель у верхнего края экрана. Всё в ней — плагины."
        case .aboutThisBuild: "Эта сборка"
        case .aboutNotSigned: "Не подписана Developer ID и не заверена у Apple."
        case .aboutAdHoc:
            "Сборки подписаны ad-hoc, поэтому скачанную копию macOS при первом запуске не пустит — нажмите правой кнопкой и выберите «Открыть». Собранной вами самостоятельно это не касается."
        case .aboutNotSandboxed: "Без песочницы, и иначе нельзя: плагины запускают команды."
        case .aboutReadPermissions:
            "Прочитайте раздел о разрешениях в документации по плагинам, прежде чем ставить чужой плагин."
        case .aboutProblems: "Проблемы"

        // Панель
        case .deckNothingPlaced: "Пока ничего не размещено"
        case .deckNothingOwn: "uDeck ничего не показывает сам. Откройте его и добавьте плагин."
        case .deckClickToWork: "Нажмите мышью или клавишей, чтобы работать здесь"
        case .cardRefreshNow: "Обновить сейчас"
        case .cardRemoveFromTab: "Убрать с этой вкладки"
        case .cardDragToMove: "Тяните, чтобы переместить это окно"
        case .cardDragToResize: "Тяните, чтобы изменить размер — по целым ячейкам"
        case .cardOwnDrawing: "СОБСТВЕННЫЙ РИСУНОК ПЛАГИНА"
        case .cardKindNotDrawn(let kind): "«\(kind)» эта версия uDeck не рисует"
        case .cardUnsupportedRow(let kind):
            "плагин прислал строку «\(kind)», которую эта версия uDeck не рисует"
        case .emptyNoPlugins: "Плагины не установлены"
        case .emptyTabEmpty: "Вкладка пуста"
        case .emptyNoPluginsBody(let path):
            "uDeck сам по себе ничего не показывает — всё в панели приходит из плагинов. Положите первый в \(path), чтобы начать."
        case .emptyTabEmptyBody: "Добавьте на эту вкладку один из установленных плагинов."
        case .emptyOpenPluginsFolder: "Открыть папку плагинов"
        case .emptyLookAgain: "Искать плагины заново"
        case .emptyAdd: "Добавить"
        case .islandNothingPlaced: "uDeck, пока ничего не размещено"
        case .islandWorstState(let state): "uDeck, худшее состояние \(state)"

        // Вкладки и кнопки самой панели
        case .tabName: "Название вкладки"
        case .tabAdd: "Добавить вкладку"
        case .tabRename: "Переименовать"
        case .tabClose: "Закрыть вкладку"
        case .tabClickAgainToRename: "Нажмите ещё раз, чтобы переименовать"
        case .tabShowThis: "Показать эту вкладку"
        case .controlDensity(let name): "Плотность: \(name)"
        case .controlRefresh: "Обновить всё сейчас"
        case .controlSettings: "Настройки"
        case .controlSendAway: "Убрать панель"

        // Действия
        case .actionSave: "Сохранить"
        case .actionUse: "Применить"
        case .actionDelete: "Удалить"
        case .actionAllow: "Разрешить"
        case .actionDecline: "Отказать"
        case .actionRun: "Запустить"
        case .actionCancel: "Отмена"
        case .actionClear: "Очистить"

        // Единицы
        case .unitMilliseconds(let value): "\(value) мс"
        case .unitPoints(let value): "\(value) пт"
        case .unitSeconds(let value): String(format: "%.1f с", value)
        case .unitPercent(let value): "\(value) %"
        }
    }
}
