# Rift Helper

App Android (Flutter) com tier list e assistente de draft para **League of Legends: Wild Rift**.

## Funções

- **Tier List** por rota (Barão, Selva, Meio, Dragão, Suporte), com taxa de vitória, escolha e ban, busca e ordenação.
- **Draft**: marque bans e picks dos dois times; o app sugere as melhores escolhas livres para a sua rota, bans e mostra as ameaças do time inimigo.
- **Atualização de dados**: ao abrir, tenta baixar `assets/meta.json` deste repositório (constante `kRemoteDataUrl` em `lib/main.dart`). Sem internet, usa os dados embutidos.

## Compilar

O GitHub Actions compila a cada push na `main` (aba **Actions → Build APK → Artifacts**).

Localmente:

```bash
flutter create --platforms=android .
flutter build apk --release
```

## Atualizar os dados

Edite `assets/meta.json` (patch, data e lista `stats` com `name`, `lane`, `win`, `pick`, `ban`) e faça push. O app instalado pega a nova versão ao tocar em atualizar.

Dados atuais: patch 7.3e, via WildRiftFire (servidor chinês).

Projeto de fã, sem vínculo com a Riot Games.
