# SoundMac

Um mixer de volume nativo pra macOS: um ícone na menu bar que mostra todo app
tocando som no momento, cada um com seu próprio slider e botão de mute —
independente do volume geral do sistema.

Sem depender de driver de áudio, kext ou extensão de sistema. Usa a API
pública de **Process Tap** do Core Audio (macOS 14.2+) pra capturar e
controlar o áudio de cada processo individualmente.

## Funcionalidades

- Detecta automaticamente quais apps estão tocando áudio agora
- Slider de volume e botão de mute independentes por app
- Volume de cada app é lembrado entre reinicializações
- Abrir automaticamente no login (opcional)
- Roda como app de menu bar puro — sem ícone no Dock

## Requisitos

- macOS 14.2 (Sonoma) ou mais recente
- Xcode Command Line Tools (ou Xcode) com Swift 5.10+

## Build

```bash
./build.sh              # gera SoundMac.app na raiz do projeto
./build.sh --install    # gera e copia pra /Applications
```

Ou, pra rodar direto sem empacotar (útil durante desenvolvimento):

```bash
cd SoundMac
swift run
```

Rodando via `swift run`, o pedido de permissão de captura de áudio aparece
vinculado ao processo que iniciou o binário (o terminal/IDE), não ao
SoundMac. Pra testar a permissão de verdade, use `./build.sh` e abra o
`.app` gerado.

## Permissões

Na primeira vez que algum app começa a tocar som, o macOS pede autorização
pro SoundMac capturar áudio do sistema (`kTCCServiceAudioCapture`). Isso
aparece automaticamente da primeira vez; se for negado ou não aparecer,
resete com:

```bash
tccutil reset All com.soundmac.app
```

e reabra o app.

## Como funciona

- **`ProcessDiscovery`** — faz polling na lista de processos do Core Audio
  (`kAudioHardwarePropertyProcessObjectList`) pra saber quais estão
  ativamente renderizando áudio. Uma vez que um processo é visto tocando
  som, ele continua "rastreado" até realmente fechar — não até parar de
  tocar por um instante — porque a flag `isRunningOutput` pisca
  constantemente durante reprodução normal (silêncio entre faixas, pausas
  etc.), e reagir a cada piscada causaria estalos.

- **`AudioEngine`** — mantém um **pool fixo de 12 "slots"**, cada um com um
  Core Audio Process Tap já criado desde a inicialização, todos apontando
  inicialmente pro próprio processo do SoundMac (silencioso). Um app novo
  é "atribuído" a um slot livre reapontando o tap existente pra ele — a
  contagem de taps do aggregate device nunca muda em runtime, porque
  redimensionar essa lista é o que causa estalos audíveis em tudo mais que
  já está tocando. O tap entra desmutado (o app original continua tocando
  normalmente por ~40ms com fade-in gradual da nossa cópia) e só depois é
  mutado na fonte — assim a transição vira uma sobreposição breve em vez
  de um corte seco.

- Todos os taps + o dispositivo de saída real são combinados num
  **aggregate device** privado, com um `AudioDeviceIOProc` que soma as
  amostras de cada slot já aplicando o gain configurado por app, e escreve
  o resultado misturado na saída física.

- **`SettingsStore`** — persiste volume/mute por app (chaveado pelo bundle
  ID) em `UserDefaults`.

- **`LaunchAtLogin`** — usa `SMAppService` (macOS 13+) pra registrar o app
  como item de login.

## Limitações conhecidas

- Quando um app **novo** começa a tocar pela primeira vez (ou reabre depois
  de fechado), há um soluço bem breve (~10ms) no início. É uma
  característica do próprio `coreaudiod` ao reatribuir o alvo de um tap —
  não algo controlável a nível de aplicação. Apps já tocando não são
  afetados.
- Volume é por **app**, não por aba de navegador — o macOS não expõe áudio
  por aba nativamente; isso exigiria uma extensão de navegador separada.
- O pool tem 12 slots fixos. Se mais de 12 apps distintos tocarem áudio ao
  mesmo tempo, os excedentes não são controlados até um slot vagar
  (aumente `AudioEngine.slotCount` se precisar de mais).
- Assinatura ad-hoc (sem Apple Developer ID) — suficiente pra uso local,
  mas cada rebuild pode exigir reautorizar a permissão de captura de áudio.
