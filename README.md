# DroneFlames Reborn

Неофициальная надстройка над PC-портом игры **DroneFlames** на Godot 4.7.2.

## Происхождение и авторы

- **Базис** — [DroneFlames-PC-Port](https://github.com/makkaX2/DroneFlames-PC-Port): нативный ПК-порт DroneFlames. Автор порта — [@droneflamesmod](https://t.me/droneflamesmod), репозиторий — [@makkaX2](https://github.com/makkaX2). Сообщество базового порта: [t.me/droneflamesmod](https://t.me/droneflamesmod).
- **Надстройка** — [Illusivecup](https://github.com/Illusivecup): FPS-оптимизации, хост-авторитетный мультиплеер HostSim, Rust-ядро симуляции и сетевых дельт, набор модов, CI-сборки Windows/macOS/Android.

Игра DroneFlames принадлежит своим оригинальным авторам; оба проекта — некоммерческие фанатские порты.

## Стек

- **Движок:** Godot 4.7.2 (GDScript)
- **Нативное ядро:** Rust — `rust/dfarmy` (движок армий, HostSim-дельты) и `native/df_native` (пассы симуляции), GDExtension; без натива работает GDScript-фолбэк
- **CI/CD:** GitHub Actions — сборки Windows (ZIP/Setup), macOS (DMG/ZIP), Android (APK)

## Запуск

Готовые сборки — на странице [релизов](https://github.com/Illusivecup/DroneFlames-Reborn/releases/latest):

- **Windows** — Setup (установщик) или Portable ZIP
- **macOS** — DMG или ZIP (Intel + Apple Silicon)
- **Android** — APK

## Запуск из исходников

```bash
git clone https://github.com/Illusivecup/DroneFlames-Reborn.git
cd DroneFlames-Reborn
# откройте папку в Godot 4.7.2 и нажмите F5
```

Сборка нативного ядра (опционально):

```bash
cargo build --release --manifest-path native/df_native/Cargo.toml
cargo build --release --manifest-path rust/dfarmy/Cargo.toml
```

Сборка релизных пакетов:

```bash
python3 build.py   # ZIP + инсталлятор в dist/
```

## Структура репозитория

```text
├── game/                  # симуляция: main, army, operations, экономика, ИИ
├── core/                  # базовые подсистемы (моды, звук, палитра, клавиши)
├── ui/                    # HUD, меню, окна, косметика
├── world/                 # генерация мира, слои рендера, шейдеры
├── net/                   # мультиплеер (ENet/WebRTC, HostSim), аккаунты, автообновление
├── rust/dfarmy/           # Rust: движок армий + DfDelta (HostSim-дельты)
├── native/df_native/      # Rust: нативные пассы симуляции (godot-rust, GDExtension)
├── addons/                # GDExtension-подключения и собранные бинарники
├── mods/                  # моды (.dfmod, менеджер)
├── translations/          # локализация (RU/EN/UK/ES)
├── docs/                  # технические заметки (UPSTREAM_TRACKING, NET_RESILIENCE, PERFORMANCE)
├── dev/                   # dev-утилиты и бенчмарки
├── tools/                 # вспомогательные скрипты
├── build.py               # сборка ZIP/инсталлятора
└── project.godot          # конфигурация Godot 4.7
```

## Дисклеймер

Проект некоммерческий и фанатский, не аффилирован с авторами игры DroneFlames. Все права на игру принадлежат её правообладателям, код базового порта — его автору. По вопросам согласования или удаления — issue в этом репозитории или контакты авторов выше.
