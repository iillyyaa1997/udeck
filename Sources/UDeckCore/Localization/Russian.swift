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
        case .lookPresets: "Пресеты"
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
        case .lookStates: "Состояния"
        case .lookStateAllTogether: "Настроить все вместе"
        case .stateNotchIsTheIsland: "на этом экране остров рисует чёлка"
        case .stateDropToSeparate: "Перетащи сюда, чтобы настроить отдельно"
        case .lookSharedEverywhere: "Одинаково во всех состояниях"
        case .lookStateLink: "Связать"
        case .lookStateUnlink: "Разъединить"
        case .lookStateMixed: "Выделены состояния из разных связок"
        case .lookEditingEverything: "Правим все состояния"
        case .lookEditingStates: "Правим"
        case .lookEditingCount(let n):
            switch n % 10 {
            case 1 where n % 100 != 11: "Правим \(n) состояние"
            case 2...4 where !(11...14).contains(n % 100): "Правим \(n) состояния"
            default: "Правим \(n) состояний"
            }
        case .statePhaseCollapsed: "Закрыт"
        case .statePhasePeek: "Наведён"
        case .statePhaseOpen: "Раскрыт"
        case .statePhaseFullscreen: "На весь экран"
        case .stateSurroundingOrdinary: "обычно"
        case .stateSurroundingFullscreen: "другое приложение на весь экран"
        case .lookQuietLevel: "Видно"
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

        case .sampleTitle: "Диск"
        case .sampleChip: "78 ГБ свободно"
        case .sampleBody: "системный том · из 460 ГБ"
        case .sampleFooter: "проверено минуту назад"

        // Встроенные виды
        case .modeLight: "Светлый"
        case .modeDark: "Тёмный"
        case .modeContrast: "Контрастный"
        case .modeGhost: "Призрак"
        case .modePaper: "Бумага"
        case .modeSmoke: "Дым"
        case .modeLightSummary: "Светлая панель с тёмным текстом, для работы поверх документов."
        case .modeDarkSummary: "Тёмная панель со светлым текстом, для работы поверх тёмных экранов."
        case .modeContrastSummary: "Почти непрозрачная, чтобы читалась поверх чего угодно."
        case .modeGhostSummary: "Почти нет — содержимое висит над тем, что за ним."
        case .modePaperSummary: "Плотная светлая поверхность, для чтения, а не для взгляда."
        case .modeSmokeSummary: "Рассеянная, но всё ещё явно материал."

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

        // Плагины из репозитория
        case .pluginsOfficialCatalogue: "Официальный каталог"
        case .pluginsOfficialCatalogueHelp(let source):
            "uDeck читает список плагинов в \(source) через несколько секунд после запуска, раз в день и по кнопке «Проверить» — только список и манифест каждого плагина. Файлы плагина скачиваются, лишь когда вы нажимаете «Установить». Если выключить, uDeck не делает никаких запросов о плагинах; установленные продолжают работать."
        case .catalogueCheckNow: "Проверить"
        case .catalogueChecked(let source, let time): "\(source) · проверено в \(time)"
        case .catalogueNeverRead(let source): "\(source) · ещё не прочитан"
        case .catalogueReading: "Читаю каталог…"
        case .catalogueOff:
            "Официальный каталог выключен. Установленные плагины продолжают работать; их обновления uDeck не ищет."
        case .catalogueEmpty: "В репозитории пока нет плагинов."
        case .catalogueUpdatesWaiting(let count): "Ждут обновления: \(count)"
        case .catalogueLimited(let readAt, let until):
            "GitHub без входа разрешает 60 запросов в час с одного адреса, и они израсходованы — uDeck или чем-то ещё на этом же подключении. "
                + (readAt.map { "Список ниже — на \($0); " } ?? "")
                + "uDeck посмотрит снова после \(until)."
        case .catalogueRawLimited(let until):
            "Файловый сервер GitHub попросил подождать; до \(until) файлы с него не скачиваются."
        case .catalogueUnreachable(let reason, let readAt):
            "Не удалось связаться с GitHub: \(reason)." + (readAt.map { " Список ниже — на \($0)." } ?? "")
        case .catalogueNotFound(let source): "\(source) не найден или закрыт."
        case .catalogueNotARepository(let source, let branch):
            "\(source) — не репозиторий плагинов uDeck: в корне \(branch) нет udeck-plugins.json."
        case .catalogueFutureFormat(let declared):
            "Этот репозиторий в формате \(declared); этот uDeck читает формат \(RepositoryPassport.supportedFormat). Обновите uDeck."
        case .catalogueInvalidPassport(let source, let reason):
            "udeck-plugins.json в \(source) uDeck прочитать не может: \(reason)."
        case .catalogueRefused(let status): "GitHub отказал в запросе (HTTP \(status))."
        case .catalogueBadAnswer(let reason): "GitHub ответил так, что uDeck не понял ответа: \(reason)."
        case .catalogueArrivedDifferent(let path, let expected, let got):
            "\(path) пришёл не таким, как его перечисляет репозиторий (ожидался \(expected), пришёл \(got))."
        case .catalogueVerified: "Проверен"
        case .catalogueSize(let files, let size): "файлов: \(files) · \(size)"
        case .catalogueAsksTo(let list): "Просит \(list)"
        case .catalogueInstall: "Установить"
        case .catalogueUpdate: "Обновить"
        case .catalogueReplace: "Заменить…"
        case .catalogueInstalled: "Установлен"
        case .catalogueAvailable(let version): "Доступна \(version)"
        case .catalogueChangedStill(let version): "Изменён в репозитории, всё ещё \(version)"
        case .catalogueRepositoryNowHas(let version): "В репозитории теперь \(version)"
        case .catalogueSwitchTo(let version): "Перейти на \(version)"
        case .catalogueUpdateNeedsAPI(let version, let api): "\(version) нужен uDeck новее (api \(api))"
        case .catalogueUpdateNeedsUDeck(let version, let required): "\(version) нужен uDeck \(required)"
        case .catalogueUpdateCannotInstall(let version): "\(version) здесь не установить"
        case .catalogueGone: "Больше нет в репозитории"
        case .catalogueOwnFolder(let id): "Установлена ваша собственная папка \(id)"
        case .catalogueMissing(let id, let path): "\(id) нет в \(path)"
        case .catalogueReinstall(let version): "Переустановить \(version)"
        case .catalogueDetails: "Подробности"
        case .catalogueWhatChanged: "Что изменилось"
        case .catalogueOpenOnGitHub: "Открыть на GitHub"
        case .catalogueEarlierVersions: "Прежние версии…"
        case .catalogueBackTo(let version): "Вернуть \(version)"
        case .catalogueRemove: "Удалить"
        case .catalogueWorking: "Выполняется…"
        case .catalogueReplaceConfirm(let id, let path):
            "В \(path) лежит ваша собственная папка \(id). Установка переместит её в Корзину и поставит на её место \(id) из репозитория."
        case .catalogueUpdateOverChanges(let id, let version):
            "Ваши изменения в \(id) будут перемещены в Корзину и заменены версией \(version)."
        case .catalogueRemoveConfirm(let id):
            "Удалить \(id)? Его папка и кэш удаляются, а вместе с ними уходят ваше решение о разрешениях, его настройки и все его окна на всех вкладках."
        case .catalogueRemoveOwnConfirm(let id):
            "Удалить \(id)? Его папка переместится в Корзину — возможно, это ваша единственная копия, — а кэш, решение о разрешениях, настройки и все его окна уйдут."
        case .catalogueRefusal(let refusal): Self.refusal(refusal)
        case .catalogueFileUnreachable(let path, let reason):
            "\(path) не удалось скачать: \(reason); ничего не установлено."
        case .catalogueTookTooLong: "Установка шла дольше пяти минут и была остановлена; ничего не установлено."
        case .catalogueCannotWrite(let reason): "uDeck не смог записать на диск: \(reason)"
        case .catalogueRecordsBroken(let reason):
            "~/.udeck/installed.json не читается, поэтому uDeck ничего не устанавливает, не обновляет и не удаляет, пока это не исправлено: \(reason)"
        case .pluginMarkVerified: "Проверен"
        case .pluginMarkOwnFolder: "Ваша собственная папка"
        case .pluginMarkModified: "Изменён на этом Mac"
        case .pluginMarkMissing: "Папки нет"
        case .pluginFrom(let source, let commit): "Из \(source), коммит \(commit)"
        case .pluginPinned: "Оставлен на этой версии — о новых всё равно сообщается"
        case .historyTitle(let name): "Прежние версии \(name)"
        case .historyReading: "Читаю историю плагина…"
        case .historyNone: "В истории нет версий этого плагина."
        case .historyInstalledMark: "установлена"
        case .historyInstall: "Установить эту версию"
        case .historyFailed: "Историю прочитать не удалось:"
        case .windowNotInPluginsFolder(let id, let path): "\(id) нет в \(path)"
        case .windowWillNotRun(let id): "\(id) не запустится:"
        case .windowReinstall: "Переустановить"

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
        case .generalStartup: "Вход"
        case .generalOpenAtLogin: "Открывать при входе"
        case .generalOpensWhich(let path, let opens):
            opens ? "Откроется: \(path)" : "Откроется при включении: \(path)"
        case .generalNotInstalled(let path):
            "Эта копия не установлена как приложение, поэтому открывать её при входе нельзя: \(path). Соберите приложение через Scripts/make-app.sh и запускайте его."
        case .generalRecordVanished: "macOS больше не хранит эту запись."
        case .generalDidNotTake: "macOS не сохранила эту запись."
        case .generalAnotherCopy(let path):
            "На компьютере есть другая копия uDeck: \(path) — запись могла уйти к ней."
        case .generalWaitsForApproval: "macOS ждёт, что вы разрешите это в Системных настройках."
        case .generalLoginFailed(let reason): "Не получилось: \(reason)"
        case .generalOpenLoginItems: "Открыть «Объекты входа и расширения»"

        case .updatesTitle: "Обновления"
        case .updatesCheckNow: "Проверить сейчас"
        case .updatesAutomatically: "Проверять обновления автоматически"
        case .updatesAutomaticallyHelp:
            "Раз в сутки uDeck спрашивает github.com, нет ли новой версии. Если выключить — только по кнопке «Проверить сейчас»."
        case .updatesNeverChecked: "Ещё не проверялось."
        case .updatesJustChecked: "Проверено только что."
        case .updatesLastChecked(let when): "Проверено \(when)."

        case .updatesInstalled: "Установлена"
        case .updatesLatest: "Последняя"
        case .updatesChecking: "Проверяем…"
        case .updatesUpToDate: "Установлена последняя версия."
        case .updatesAvailable(let version): "Доступна версия \(version)."
        case .updatesInstallNow(let version): "Обновить до \(version)"
        case .updatesDownloading: "Скачиваем…"
        case .updatesReady: "Скачано и готово."
        case .updatesRestartToInstall: "Перезапустить и установить"
        case .updatesFailed(let reason): "Проверка не завершилась: \(reason)"

        case .menuBrokenPlugins(let count):
            {
                // 1 плагин, 2-4 плагина, 5+ плагинов — и 11-14 всегда «плагинов».
                let tail = count % 100
                let last = count % 10
                let word: String
                if (11 ... 14).contains(tail) { word = "плагинов" }
                else if last == 1 { word = "плагин" }
                else if (2 ... 4).contains(last) { word = "плагина" }
                else { word = "плагинов" }
                return "\(count) \(word) не запустится"
            }()

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

extension Russian {
    /// Каждый отказ называет плагин, что не так и что это исправит.
    static func refusal(_ refusal: RepositoryRefusal) -> String {
        func size(_ bytes: Int) -> String { ByteCount.text(bytes, kilo: "КБ", mega: "МБ", unit: "Б", separator: ",") }
        return switch refusal {
        case .folderNameNotAnID(let folder):
            "plugins/\(folder) — не идентификатор плагина: строчные латинские буквы, цифры, «.», «_» и «-», не длиннее 64, в начале буква или цифра."
        case .noManifest(let path): "Нет \(path); без него папка — не плагин."
        case .manifestUnreadable(let path, let detail): "\(path) — не годный манифест: \(detail)"
        case .manifestIDMismatch(let declared, let folder):
            "Манифест в plugins/\(folder) называет свой id «\(declared)»; он должен совпадать с именем папки."
        case .manifestProblem(let id, let detail): "\(id): \(detail)"
        case .apiNotSpoken(let name, let version, let api):
            "\(name) \(version) написан для контракта плагинов api \(api); этот uDeck знает api \(PluginAPI.current). Обновите uDeck, чтобы его установить."
        case .needsNewerUDeck(let name, let version, let required, let running):
            "\(name) \(version) нужен uDeck \(required) или новее; это uDeck \(running). Обновите uDeck (Настройки → О программе), чтобы его установить."
        case .versionNotComparable(let name, let version):
            "Версия \(name) «\(version)» — не MAJOR.MINOR.PATCH, uDeck не может отличить её от другой; из репозитория её не установить."
        case .minUDeckNotComparable(let name, let text):
            "minUDeck у \(name) «\(text)» — не MAJOR.MINOR.PATCH, и неясно, какой выпуск uDeck нужен; из репозитория его не установить."
        case .producerMissing(let path): "Манифест запускает \(path), а в репозитории его нет."
        case .producerNotExecutable(let path):
            "\(path) закоммичен без права на запуск (режим git 100755), а uDeck берёт это право из репозитория; закоммитьте его после chmod +x."
        case .producerOutsideFolder(let path): "\(path) ведёт за пределы папки плагина."
        case .linkOrSubmodule(let path, let isLink):
            "\(path) — \(isLink ? "символическая ссылка" : "подмодуль"); в плагине из репозитория могут быть только файлы и папки."
        case .nameNotAllowed(let path):
            "\(path): в именах можно только латинские буквы, цифры, «.», «_» и «-», и имя не может начинаться с «.»"
        case .namesDifferOnlyInCase(let path, let other):
            "\(path) и \(other) различаются только регистром букв, а диск Mac считает их одним файлом."
        case .tooLarge(let id, let bytes, let files):
            "\(id) — это \(size(bytes)) в \(files) файлах; uDeck ставит плагины до 10 МБ и до \(RepositoryRules.maximumFiles) файлов."
        case .fileTooLarge(let path, let bytes):
            "\(path) весит \(size(bytes)); один файл плагина может быть не больше 5 МБ."
        case .nestedTooDeep(let path): "\(path) вложен глубже \(RepositoryRules.maximumDepth) папок."
        case .sizeNotListed(let path): "Репозиторий не указал размер \(path)."
        case .arrivedDifferent(let path, let expected, let got):
            "\(path) пришёл не таким, как его перечисляет репозиторий (ожидался \(expected), пришёл \(got)); ничего не установлено."
        case .folderDoesNotAddUp(let id):
            "Файлы \(id) не складываются в ту папку, которую перечисляет репозиторий; ничего не установлено."
        case .lfsPointer(let path):
            "\(path) — указатель Git LFS, а не сам файл; содержимое LFS uDeck не скачивает."
        case .arrivedLarger(let path, _):
            "\(path) пришёл больше, чем указано в репозитории; ничего не установлено."
        case .failsTheUsualChecks(_, let detail): detail
        case .notTheVersionShown(let id, let shown, let arrived):
            "\(id) пришёл версией \(arrived), а не \(shown), как показывал каталог; ничего не установлено. Проверьте снова."
        case .folderAppeared(let id):
            "Пока uDeck устанавливал, в папке плагинов появилась папка \(id); ничего не изменено."
        }
    }
}
