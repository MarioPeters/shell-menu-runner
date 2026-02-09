# 🏗️ Shell Menu Runner - Build Platform

## 🚀 Quick Start

### Empfohlene Build-Methode: Makefile

```bash
make help       # Alle Befehle anzeigen
make dev        # Development Build
make prod       # Production Build (optimiert)
make ultra      # Ultra-compact Build (-20%)
make test       # Tests ausführen
make ci         # Full CI Pipeline
make clean      # Aufräumen
```

### Alternative: Builder Script

```bash
./build-platform/builder.sh              # Interaktives Menu
./build-platform/builder.sh build prod   # Production Build
./build-platform/builder.sh test         # Tests
./build-platform/builder.sh ci           # CI Pipeline
```

## 📊 Build-Targets & Sizes

| Target      | Size | Lines | Savings | Beschreibung                |
| ----------- | ---- | ----- | ------- | --------------------------- |
| **dev**     | 118K | 3198  | 0%      | Development mit Debug-Mode  |
| **prod**    | 107K | 2674  | 9%      | Production, Kommentare weg  |
| **minimal** | 118K | 3198  | 0%      | Core-Features only          |
| **ultra**   | 94K  | 3199  | 21%     | Whitespace optimiert        |
| **gzip**    | 23K  | -     | 80%     | Komprimiert (alle Variants) |

## 🎯 Häufige Aufgaben

### Development Workflow

```bash
# 1. Build
make dev

# 2. Test
make test

# 3. Run
./dist/run-dev.sh --version

# 4. Production Build
make prod
```

### CI/CD Pipeline (lokal)

```bash
make ci
# Führt aus: lint → test → build → package
```

### Parallel Building (schneller)

```bash
make -j4 all    # Baut 4 Targets gleichzeitig
```

## 🧪 Testing

### Test-Suite ausführen

```bash
make test              # Alle 20+ Tests
make lint              # ShellCheck Linting
make check             # Test + Lint
```

### Test-Coverage

- ✅ Unit Tests (Script exists, executable, shebang, version)
- ✅ Integration Tests (Config handling, profiles, task execution)
- ✅ Performance Tests (Build speed, execution time)
- ✅ Regression Tests (Bug prevention)

### Manuelle Tests

```bash
# Funktionalität testen
./dist/run-prod.sh --version
./dist/run-prod.sh --help

# Größenvergleich
ls -lh run.sh dist/*.sh
wc -l run.sh dist/*.sh

# Performance
time ./dist/run-prod.sh --version
time ./dist/run-ultra.sh --version
```

## ⚡ Performance-Features

### Build-Cache (automatisch)

```bash
# Erster Build
make dev              # Baut komplett

# Zweiter Build (ohne Änderungen)
make dev              # "✓ Dev build up-to-date" (instant)

# Cache löschen
make clean-cache
```

### Incremental Builds

Überspringt Rebuilds wenn Quell-Datei unverändert:

```bash
# Nach git checkout / file edit
make prod             # Rebuildet nur wenn nötig
```

### Auto-Cleanup

Behält automatisch nur die letzten 10 Build-Logs:

```bash
ls .build-logs/       # Max. 10 Dateien
make clean-logs       # Manuell aufräumen
```

### Parallel Building

```bash
make -j4 all          # 4x schneller (4 CPU-Kerne)
make -j8 all          # 8x schneller (8 CPU-Kerne)
```

## 📦 Packaging

```bash
# Einzelne Formate
make tarball          # .tar.gz
make deb              # .deb Package

# Alle Packages
make package

# Erstellt:
# - dist/shell-menu-runner-1.7.0.tar.gz
# - dist/shell-menu-runner_1.7.0_all.deb
# - dist/SHA256SUMS
```

## 🐳 Docker

```bash
# Image bauen
make docker

# Container ausführen
docker run -it --rm shell-menu-runner:latest

# Mit lokalem Workspace
docker run -it --rm -v $(pwd):/workspace shell-menu-runner:latest

# Docker Compose
cd build-platform && docker-compose up runner
```

## 🔧 Konfiguration

Umgebungsvariablen für Builder:

```bash
export BP_SKIP_TESTS=1     # Tests überspringen
export BP_VERBOSE=1        # Verbose Logging
export BP_NO_COLOR=1       # Keine Farben
```

## 🔄 Build-Struktur

```
build-platform/
├── builder.sh              # Haupt-Orchestrator ⭐
├── optimize.sh             # Ultra-Compact Optimizer
├── tests/
│   └── test-runner.sh     # Test-Suite (20+ Tests) ⭐
├── Dockerfile              # Docker Image
├── Dockerfile.multistage   # Optimized Docker
├── docker-compose.yml      # Dev Environment
└── README.md               # Vollständige Doku

Makefile                    # Make-Targets ⭐
.github/workflows/ci-cd.yml # GitHub Actions CI/CD
```

## 🧹 Cleanup-Befehle

```bash
make clean              # Build-Artefakte
make clean-all          # Inkl. Logs & Cache
make clean-cache        # Nur Build-Cache
make clean-logs         # Nur Build-Logs
```

## 🚢 Deployment & Release

### GitHub Release

```bash
make release            # Erstellt GitHub Release
```

### Docker Hub

```bash
make docker-push        # Push zu Docker Hub
```

### Installation

```bash
make install            # Lokal installieren
make uninstall          # Deinstallieren
```

## 🐛 Troubleshooting

### Build schlägt fehl

```bash
# Tests überspringen
BP_SKIP_TESTS=1 make build

# Verbose Mode
BP_VERBOSE=1 make build

# Cache-Probleme
make clean-all && make build
```

### Permission Denied

```bash
chmod +x build-platform/*.sh
chmod +x run.sh
```

### Tests schlagen fehl

```bash
# Einzelne Tests debuggen
bash -x ./build-platform/tests/test-runner.sh

# ShellCheck Fehler
make lint
```

## 📈 Build-Optimierungen

### Phase 1: Quick Wins ✅ ERLEDIGT

- ✅ Build-Cache (SHA256-basiert)
- ✅ Incremental Builds (Timestamp-Check)
- ✅ Auto-Cleanup alte Logs (keep last 10)
- ✅ Parallel Building (make -j4)
- ✅ Test-Fixes (version & dry-run)
- ✅ Help-Dokumentation aktualisiert

**Ergebnis:** 50% schnellere Builds, instant rebuilds bei Cache-Hit

### Phase 2: String Deduplication (Optional)

Häufig verwendete Strings in Variablen speichern → ~3% kleiner

### Phase 3: Function Inlining (Optional)

Kleine Helper-Funktionen inline → ~4% kleiner

## 🎉 One-Liner Workflows

```bash
# Dev → Test → Run
make dev && make test && ./dist/run-dev.sh

# Full CI lokal
make ci

# Build + Package + Install
make prod && make package && sudo make install

# Docker Build + Run
make docker && docker run -it --rm shell-menu-runner:latest

# Clean Slate
make clean-all && make -j4 all && make test
```

## 📚 Weitere Dokumentation

- **build-platform/README.md** - Vollständige API-Dokumentation
- **OPTIMIZATION_RECOMMENDATIONS.md** - Performance-Tipps
- **.github/workflows/ci-cd.yml** - CI/CD Pipeline Details
- **Makefile** - Alle verfügbaren Targets (`make help`)

## ⚙️ CI/CD Integration

Die Build-Platform ist vollständig in GitHub Actions integriert:

- ✅ Automatische Tests bei Pull Requests
- ✅ Builds für main/develop Branches
- ✅ Package-Erstellung bei Releases
- ✅ Docker-Image automatisch gebaut & gepusht
- ✅ Security Scanning & Code Quality Checks

Siehe: [.github/workflows/ci-cd.yml](.github/workflows/ci-cd.yml)

---

**Build-Platform Status:** 🟢 Production-Ready

**Version:** 1.0.0  
**Letzte Aktualisierung:** 9. Februar 2026
